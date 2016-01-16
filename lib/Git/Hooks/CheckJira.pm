#!/usr/bin/env perl

package Git::Hooks::CheckJira;
# ABSTRACT: Git::Hooks plugin which requires citation of JIRA issues in commit messages

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Path::Tiny;
use List::MoreUtils qw/uniq/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};

    # Default matchkey for matching default JIRA keys.
    $default->{matchkey}   //= ['\b[A-Z][A-Z]+-\d+\b'];

    $default->{require}    //= [1];
    $default->{unresolved} //= [1];

    return;
}

##########

sub grok_msg_jiras {
    my ($git, $msg) = @_;

    my $matchkey = $git->get_config($CFG => 'matchkey');
    my @matchlog = $git->get_config($CFG => 'matchlog');

    # Grok the JIRA issue keys from the commit log
    if (@matchlog) {
        my @keys;
        foreach my $matchlog (@matchlog) {
            if (my ($match) = ($msg =~ /$matchlog/)) {
                push @keys, ($match =~ /$matchkey/go);
            }
        }
        return @keys;
    } else {
        return $msg =~ /$matchkey/go;
    }
}

sub _jira {
    my ($git) = @_;

    my $cache = $git->cache($PKG);

    # Connect to JIRA if not yet connected
    unless (exists $cache->{jira}) {
        unless (eval { require JIRA::REST; }) {
            $git->error($PKG, "Please, install Perl module JIRA::REST to use the CheckJira plugin", $@);
            return;
        }

        my %jira;
        for my $option (qw/jiraurl jirauser jirapass/) {
            $jira{$option} = $git->get_config($CFG => $option)
                or $git->error($PKG, "missing $CFG.$option configuration attribute")
                    and return;
        }
        $jira{jiraurl} =~ s:/+$::; # trim trailing slashes from the URL

        my $jira = eval { JIRA::REST->new($jira{jiraurl}, $jira{jirauser}, $jira{jirapass}) };
        length $@
            and $git->error($PKG, "cannot connect to the JIRA server at '$jira{jiraurl}' as '$jira{jirauser}", $@)
                and return;
        $cache->{jira} = $jira;
    }

    return $cache->{jira};
}

# Returns a JIRA::REST object or undef if there is any problem

sub get_issue {
    my ($git, $key) = @_;

    my $jira = _jira($git);

    my $cache = $git->cache($PKG);

    # Try to get the issue from the cache
    unless (exists $cache->{keys}{$key}) {
        $cache->{keys}{$key} = eval { $jira->GET("/issue/$key") };
        length $@
            and $git->error($PKG, "cannot get issue $key", $@)
                and return;
    }

    return $cache->{keys}{$key};
}

sub check_codes {
    my ($git) = @_;

    my @codes;

  CODE:
    foreach my $check ($git->get_config($CFG => 'check-code')) {
        my $code;
        if ($check =~ s/^file://) {
            $code = do $check;
            unless ($code) {
                if (length $@) {
                    $git->error($PKG, "couldn't parse option check-code ($check)", $@);
                } elsif (! defined $code) {
                    $git->error($PKG, "couldn't do option check-code ($check)", $!);
                } else {
                    $git->error($PKG, "couldn't run option check-code ($check)");
                }
                next CODE;
            }
        } else {
            $code = eval $check; ## no critic (BuiltinFunctions::ProhibitStringyEval)
            length $@
                and $git->error($PKG, "couldn't parse option check-code value", $@)
                    and next CODE;
        }
        defined $code and ref $code and ref $code eq 'CODE'
            or $git->error($PKG, "option check-code must end with a code ref")
                and next CODE;
        push @codes, $code;
    }

    return @codes;
}

sub _check_jira_keys {          ## no critic (ProhibitExcessComplexity)
    my ($git, $commit, $ref, @keys) = @_;

    unless (@keys) {
        if ($git->get_config($CFG => 'require')) {
            my $shortid = exists $commit->{commit} ? substr($commit->{commit}, 0, 8) : '';
            $git->error($PKG, "commit $shortid must cite a JIRA in its message");
            return 0;
        } else {
            return 1;
        }
    }

    my @issues;

    my %projects    = map {($_ => undef)} $git->get_config($CFG => 'project');
    my $unresolved  = $git->get_config($CFG => 'unresolved');
    my %status      = map {($_ => undef)} $git->get_config($CFG => 'status');
    my %issuetype   = map {($_ => undef)} $git->get_config($CFG => 'issuetype');
    my $by_assignee = $git->get_config($CFG => 'by-assignee');
    my @versions;
    foreach ($git->get_config($CFG => 'fixversion')) {
        my ($branch, $version) = split ' ', $_, 2;
        my $last_paren_match;
        if ($branch =~ /^\^/) {
            next unless $ref =~ qr/$branch/;
            $last_paren_match = $+;
        } else {
            next unless $ref eq $branch;
        }
        if ($version =~ /^\^/) {
            $version =~ s/\$\+/\Q$last_paren_match\E/g if defined $last_paren_match;
            push @versions, qr/$version/;
        } else {
            $version =~ s/\$\+/$last_paren_match/g if defined $last_paren_match;
            push @versions, $version;
        }
    }

    my $errors = 0;

  KEY:
    foreach my $key (@keys) {
        not %projects
            or $key =~ /([^-]+)/ and exists $projects{$1}
                or $git->error($PKG, "do not cite issue $key. This repository accepts only issues from: "
                                   . join(' ', sort keys %projects))
                    and next KEY;

        my $issue = get_issue($git, $key)
            or ++$errors
                and next KEY;

        if (%issuetype && ! exists $issuetype{$issue->{fields}{issuetype}{name}}) {
            my @issuetypes = sort keys %issuetype;
            $git->error(
                $PKG,
                "issue $key cannot be used because it is of the unapproved type '$issue->{fields}{issuetype}{name}'",
                "You can use the following issue types: @issuetypes",
            );
            ++$errors;
            next KEY;
        }

        if (%status && ! exists $status{$issue->{fields}{status}{name}}) {
            my @statuses = sort keys %status;
            $git->error(
                $PKG,
                "issue $key cannot be used because it is in the unapproved status '$issue->{fields}{status}{name}'",
                "The following statuses are approved: @statuses",
            );
            ++$errors;
            next KEY;
        }

        if ($unresolved && defined $issue->{fields}{resolution}) {
            $git->error($PKG, "issue $key cannot be used because it is already resolved");
            ++$errors;
            next KEY;
        }

      VERSION:
        foreach my $version (@versions) {
            foreach my $fixversion (@{$issue->{fields}{fixVersions}}) {
                if (ref $version) {
                    next VERSION if $fixversion->{name} =~ $version;
                } else {
                    next VERSION if $fixversion->{name} eq $version;
                }
            }
            $git->error($PKG, "issue $key has no fixVersion matching '$version', which is required for commits affecting '$ref'");
            ++$errors;
            next KEY;
        }

        if ($by_assignee) {
            my $user = $git->authenticated_user()
                or $git->error($PKG, "cannot grok the authenticated user")
                    and ++$errors
                        and next KEY;

            if (my $assignee = $issue->{fields}{assignee}) {
                my $name = $assignee->{name};
                $user eq $name
                    or $git->error($PKG, "issue $key should be assigned to '$user', not '$name'")
                        and ++$errors
                            and next KEY;
            } else {
                $git->error($PKG, "issue $key should be assigned to '$user', but it's unassigned");
                ++$errors;
                next KEY;
            }
        }

        push @issues, $issue;
    }

    foreach my $code (check_codes($git)) {
        my $ok = eval { $code->($git, $commit, _jira($git), @issues) };
        if (defined $ok) {
            ++$errors unless $ok;
        } elsif (length $@) {
            $git->error($PKG, 'error while evaluating check-code', $@);
            ++$errors;
        }
    }

    return $errors == 0;
}

sub check_commit_msg {
    my ($git, $commit, $ref) = @_;

    return _check_jira_keys($git, $commit, $ref, uniq(grok_msg_jiras($git, $commit->{body})));
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    return 1 if im_admin($git);

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    # The --branch argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $branch = $opts->{'--branch'};
    $branch = "refs/heads/$branch"
        unless $branch =~ m:^refs/:;

    return 1 unless is_ref_enabled($branch, $git->get_config($CFG => 'ref'));

    return check_commit_msg($git, $commit, $branch);
}

sub check_message_file {
    my ($git, $commit_msg_file) = @_;

    _setup_config($git);

    my $current_branch = $git->get_current_branch();
    return 1 unless is_ref_enabled($current_branch, $git->get_config($CFG => 'ref'));

    my $msg = eval { path($commit_msg_file)->slurp };
    defined $msg
        or $git->error($PKG, "cannot open file '$commit_msg_file' for reading: $@")
            and return 0;

    # Remove comment lines from the message file contents.
    $msg =~ s/^#[^\n]*\n//mgs;

    return check_commit_msg(
        $git,
        { body => $msg }, # fake a commit hash to simplify check_commit_msg
        $current_branch,
    );
}

sub check_ref {
    my ($git, $ref) = @_;

    return 1 unless is_ref_enabled($ref, $git->get_config($CFG => 'ref'));

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        check_commit_msg($git, $commit, $ref)
            or ++$errors;
    }

    # Disconnect from JIRA
    $git->clean_cache($PKG);

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref)
            or ++$errors;
    }

    # Disconnect from JIRA
    $git->clean_cache($PKG);

    return $errors == 0;
}

sub notify_commit_msg {
    my ($git, $commit, $ref, $visibility) = @_;

    my @keys = uniq(grok_msg_jiras($git, $commit->{body}));

    return 0 unless @keys;

    my $jira = _jira($git);

    my %comment = (
        body => "[$PKG] commit refers to this issue:\n\n"
            . $git->command(show => '--stat', $commit->{commit}),
    );
    $comment{visibility} = $visibility if $visibility;

    my $errors = 0;

    foreach my $key (@keys) {
        eval { $jira->POST("/issue/$key/comment", \%comment); 1; }
            or $git->error($PKG, "Cannot add a comment to JIRA issue $key:", $@)
            and ++$errors;
    }

    return $errors;
}

sub notify_ref {
    my ($git, $ref, $visibility) = @_;

    return 1 unless is_ref_enabled($ref, $git->get_config($CFG => 'ref'));

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        $errors += notify_commit_msg($git, $commit, $ref, $visibility);
    }

    return $errors == 0;
}

# This routine can act as a post-receive hook.
sub notify_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    my $comment = $git->get_config($PKG => 'comment');

    return 1 unless defined $comment;

    my $visibility;
    if (length $comment) {
        if ($comment =~ /^(role|group):(.+)/) {
            $visibility = {
                type  => $1,
                value => $2,
            };
        } else {
            $git->error($PKG, "Invalid argument to githooks.checkjira.comment: $comment");
            return 0;
        }
    }

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        $errors += notify_ref($git, $ref, $visibility);
    }

    # Disconnect from JIRA
    $git->clean_cache($PKG);

    return $errors == 0;
}

# Install hooks
COMMIT_MSG       \&check_message_file;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
POST_RECEIVE     \&notify_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;
1;


__END__
=for Pod::Coverage check_codes check_commit_msg check_ref notify_commit_msg notify_ref get_issue grok_msg_jiras

=head1 NAME

CheckJira - Git::Hooks plugin which requires citation of JIRA
issues in commit messages.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to guarantee
that every commit message cites at least one valid JIRA issue key in
its log message, so that you can be certain that every change has a
proper change request (a.k.a. ticket) open.

=over

=item * B<commit-msg>

This hook is invoked during the commit, to check if the commit message
cites valid JIRA issues.

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, to check if the commit
message cites valid JIRA issues.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
to check if the commit message cites valid JIRA issues.

=item * B<post-receive>

This hook is invoked once in the remote repository after a successful C<git
push>. It's used to notify JIRA of commits citing its issues via comments.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review, to check if the commit message cites valid JIRA issues.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*), to check if the commit
message cites valid JIRA issues.

=back

It requires that any Git commits affecting all or some branches must
make reference to valid JIRA issues in the commit log message. JIRA
issues are cited by their keys which, by default, consist of a
sequence of uppercase letters separated by an hyphen from a sequence of
digits. E.g., C<CDS-123>, C<RT-1>, and C<GIT-97>.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckJira

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkjira.ref REFSPEC

By default, the message of every commit is checked. If you want to
have them checked only for some refs (usually some branch under
refs/heads/), you may specify them with one or more instances of this
option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 githooks.checkjira.jiraurl URL

This option specifies the JIRA server HTTP URL, used to construct the
C<JIRA::REST> object which is used to interact with your JIRA
server. Please, see the JIRA::REST documentation to know about them.

=head2 githooks.checkjira.jirauser USERNAME

This option specifies the JIRA server username, used to construct the
C<JIRA::REST> object.

=head2 githooks.checkjira.jirapass PASSWORD

This option specifies the JIRA server password, used to construct the
C<JIRA::REST> object.

=head2 githooks.checkjira.matchkey REGEXP

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyphen, followed by a sequence of digits. If
you customized your L<JIRA project
keys|https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>,
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=head2 githooks.checkjira.matchlog REGEXP

By default, JIRA keys are looked for in all of the commit message. However,
this can lead to some false positives, since the default issue pattern can
match other things besides JIRA issue keys. You may use this option to
restrict the places inside the commit message where the keys are going to be
looked for. You do this by specifying a regular expression with a capture
group (a pair of parenthesis) in it. The commit message is matched against
the regular expression and the JIRA tickets are looked for only within the
part that matched the capture group.

Here are some examples:

=over

=item * C<\[([^]]+)\]>

Looks for JIRA keys inside the first pair of brackets found in the
message.

=item * C<(?s)^\[([^]]+)\]>

Looks for JIRA keys inside a pair of brackets that must be at the
beginning of the message's title.

=item * C<(?im)^Bug:(.*)>

Looks for JIRA keys in a line beginning with C<Bug:>. This is a common
convention around some high caliber projects, such as OpenStack and
Wikimedia.

=back

This is a multi-valued option. You may specify it more than once. All
regexes are tried and JIRA keys are looked for in all of them. This
allows you to more easily accomodate more than one way of specifying
JIRA keys if you wish.

=head2 githooks.checkjira.project KEY

By default, the committer can reference any JIRA issue in the commit
log. You can restrict the allowed keys to a set of JIRA projects by
specifying a JIRA project key to this option. You can allow more than one
project by specifying this option multiple times, once per project key.

If you set this option, then any cited JIRA issue that doesn't belong to one
of the specified projects causes an error.

=head2 githooks.checkjira.require [01]

By default, the log must reference at least one JIRA issue. You can
make the reference optional by setting this option to 0.

=head2 githooks.checkjira.unresolved [01]

By default, every issue referenced must be unresolved, i.e., it must
not have a resolution. You can relax this requirement by setting this
option to 0.

=head2 githooks.checkjira.status STATUSNAME

By default, it doesn't matter in which status the JIRA issues are. By
setting this multi-valued option you can restrict the valid statuses for the
issues.

=head2 githooks.checkjira.issuetype ISSUETYPENAME

By default, it doesn't matter what type of JIRA issues are cited. By setting
this multi-valued option you can restrict the valid issue types.

=head2 githooks.checkjira.fixversion BRANCH FIXVERSION

This multi-valued option allows you to specify that commits affecting BRANCH
must cite only issues that have their C<Fix For Version> field matching
FIXVERSION. This may be useful if you have release branches associated with
particular JIRA versions.

BRANCH can be specified as a complete ref name (e.g. "refs/heads/master") or
by a regular expression starting with a caret (C<^>), which is kept as part
of the regexp (e.g. "^refs/heads/(master|fix)").

FIXVERSION can be specified as a complete JIRA version name (e.g. "1.2.3")
or by a regular expression starting with a caret (C<^>), which is kept as
part of the regexp (e.g. "^1\.2").

As a special feature, if BRANCH is a regular expression containing capture
groups, then every occurrence of the substring C<$+> in FIXVERSION, if any,
is replaced by the text matched by the last capture group in BRANCH. (Hint:
Perl's C<$+> variable is defined as "The text matched by the last bracket of
the last successful search pattern.") If FIXVERSION is also a regular
expression, the C<$+> are replaced by the text properly escaped so that it
matches literally.

Commits that do not affect any BRANCH are accepted by default.

So, suppose you have this configuration:

  [githooks "checkjira"]
    fixversion = refs/heads/master          future
    fixversion = ^refs/heads/(\d+\.\d+)\.   ^$+

Then, commits affecting the C<master> branch must cite issues assigned to
the C<future> version. Also, commits affecting any branch which name begins
with a version number (e.g. C<1.0.3>) be assinged to the corresponding JIRA
version (e.g. C<1.0>).

=head2 githooks.checkjira.by-assignee [01]

By default, the committer can reference any valid JIRA issue. Setting
this value 1 requires that the user doing the push/commit (as
specified by the C<userenv> configuration variable) be the current
issue's assignee.

=head2 githooks.checkjira.check-code CODESPEC

If the above checks aren't enough you can use this option to define a
custom code to check your commits. The code may be specified directly
as the option's value or you may specify it indirectly via the
filename of a script. If the option's value starts with "file:", the
remaining is treated as the script filename, which is executed by a do
command. Otherwise, the option's value is executed directly by an
eval. Either way, the code must end with the definition of a routine,
which will be called once for each commit with the following
arguments:

=over

=item * B<GIT>

The Git repository object used to grok information about the commit.

=item * B<COMMITID>

The SHA-1 id of the Git commit. It is undef in the C<commit-msg> hook,
because there is no commit yet.

=item * B<JIRA>

The JIRA::REST object used to talk to the JIRA server.

Note that up to version 0.047 of Git::Hooks::CheckJira this used to be a
JIRA::Client object, which uses JIRA's SOAP API which was deprecated on JIRA
6.0 and won't be available anymore on JIRA 7.0.

If you have code relying on the JIRA::Client module you're advised to
rewrite it using the JIRA::REST module. As a stopgap measure you can
disregard the JIRA::REST object and create your own JIRA::Client object.

=item * B<ISSUES...>

The remaining arguments are RemoteIssue objects representing the
issues being cited by the commit's message.

=back

The subroutine should return a boolean value indicating success. Any
errors should be produced by invoking the B<Git::More::error> method.

If the subroutine returns undef it's considered to have succeeded.

If it raises an exception (e.g., by invoking B<die>) it's considered
to have failed and a proper message is produced to the user.

=head2 githooks.checkjira.comment [VISIBILITY]

If this option is set and the C<post-receive> hook is enabled, for every
pushed commit, every cited JIRA issue receives a comment showing the result
of the C<git show --stat COMMIT> command. This is meant to notify the issue
assignee of commits refering to the issue.

Note that the user with which C<Git::Hooks> authenticates to JIRA must have
permission to add comments to the issues or an error will be
logged. However, since this happens after the push, the result of the
operation isn't affected.

You can restrict the visibility of comments with the optional argument,
which must be in the form TYPE:VALUE, where TYPE may be one of:

=over

=item * B<role>

In this case, VALUE must be the name of a JIRA role, such as
C<Administrators>, C<Developers>, or C<Users>.

=item * B<group>

In this case, VALUE must be the name of a JIRA group.

=back

=head1 EXPORTS

This module exports two routines that can be used directly without
using all of Git::Hooks infrastructure.

=head2 check_affected_refs GIT

This is the routine used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head2 check_message_file GIT, MSGFILE

This is the routine used to implement the C<commit-msg> hook. It needs
a C<Git::More> object and the name of a file containing the commit
message.

=head2 check_patchset GIT, HASH

This is the routine used to implement the C<patchset-created> Gerrit
hook. It needs a C<Git::More> object and the hash containing the
arguments passed to the hook by Gerrit.

=head2 notify_affected_refs GIT

This is the routine used to implement the C<post-receive> hook. It needs a
C<Git::More> object.

=head1 SEE ALSO

=over

=item * L<Git::More>

=item * L<JIRA::REST>

=item * L<JIRA::Client>

=back

=head1 REFERENCES

=over

=item This script is heavily inspired (and sometimes derived) from Joyjit
Nath's L<git-jira-hook|https://github.com/joyjit/git-jira-hook>.

=item L<JIRA SOAP API deprecation
notice|https://developer.atlassian.com/display/JIRADEV/SOAP+and+XML-RPC+API+Deprecated+in+JIRA+6.0>

=back
