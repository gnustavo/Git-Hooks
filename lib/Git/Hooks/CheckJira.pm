#!/usr/bin/env perl

package Git::Hooks::CheckJira;
# ABSTRACT: Git::Hooks plugin which requires citation of JIRA issues in commit messages

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks;
use Git::Repository::Log;
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

    $default->{require}    //= ['true'];
    $default->{unresolved} //= ['true'];

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
            $git->fault(<<EOS, {details => $@});
I could not load the JIRA::REST Perl module.

I need it to talk to your JIRA server, as configured by the
$CFG.jiraurl, $CFG.jirauser, and $CFG.jirapass
options in your Git configuration.

Please, install the module or disable these options to proceed.
EOS
            return;
        }

        my %jira;
        for my $option (qw/jiraurl jirauser jirapass/) {
            $jira{$option} = $git->get_config($CFG => $option)
                or $git->fault(<<EOS, {option => $option})
The option is missing from the configuration.
It's required in order to connect to the JIRA server.
EOS
                and return;
        }
        $jira{jiraurl} =~ s:/+$::; # trim trailing slashes from the URL

        my $jira = eval { JIRA::REST->new($jira{jiraurl}, $jira{jirauser}, $jira{jirapass}) };
        length $@
            and $git->fault(<<EOS, {details => $@})
Cannot connect to the JIRA server at '$jira{jiraurl}' as '$jira{jirauser}.

Please, check your $CFG.jiraurl, $CFG.jirauser,
and $CFG.jirapass configuration options.
EOS
                and return;
        $cache->{jira} = $jira;
    }

    return $cache->{jira};
}

sub _jql_query {
    my ($git, $jql) = @_;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{jql}{$jql}) {
        my $jira = _jira($git);
        $jira->set_search_iterator({
            jql    => $jql,
            fields => $git->get_config($CFG => 'check-code')
                ? [qw/*all/]
                : [qw/assignee fixVersions resolution/],
        });
        while (my $issue = $jira->next_issue) {
            $cache->{jql}{$jql}{$issue->{key}} = $issue;
        }
    }

    return $cache->{jql}{$jql};
}

sub _disconnect_jira {
    my ($git) = @_;
    delete $git->cache($PKG)->{jira};
    return;
}

sub check_codes {
    my ($git) = @_;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{codes}) {
        $cache->{codes} = [];
      CODE:
        foreach my $check ($git->get_config($CFG => 'check-code')) {
            my $code;
            if ($check =~ s/^file://) {
                $code = do $check;
                unless ($code) {
                    if (length $@) {
                        $git->fault("I couldn't parse option value ($check).",
                                    {option => 'check-code', details => $@});
                    } elsif (! defined $code) {
                        $git->fault("I couldn't do option value ($check).",
                                    {option => 'check-code', details => $!});
                    } else {
                        $git->fault("I couldn't run  option value ($check).",
                                    {option => 'check-code'});
                    }
                    next CODE;
                }
            } else {
                $code = eval $check; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                length $@
                    and $git->fault("I couldn't parse option value.",
                                    {option => 'check-code', details => $@})
                    and next CODE;
            }
            defined $code and ref $code and ref $code eq 'CODE'
                or $git->fault("The option value must end with a code-ref.",
                               {option => 'check-code'})
                and next CODE;
            push @{$cache->{codes}}, $code;
        }
    }

    return @{$cache->{codes}};
}

sub _check_jira_keys {          ## no critic (ProhibitExcessComplexity)
    my ($git, $commit, $ref, @keys) = @_;

    unless (@keys) {
        if ($git->get_config_boolean($CFG => 'require')) {
            $git->fault(<<EOS, {commit => $commit});
The commit must cite a JIRA in its message.

Please, amend your commit to insert a JIRA key.
EOS
            return 0;
        } else {
            return 1;
        }
    }

    my %issues;                 # cache all grokked issues

    my $errors = 0;

    ############
    # JQL checks

    {
        # Build a list of JQL terms

        # Starting with a check to see if all JIRA keys exist
        my @jqls = ("key IN (@{[join(',', @keys)]})");

        # global JQL
        if (my $jql = $git->get_config($CFG => 'jql')) {
            push @jqls, $jql;
        }

        # ref-specific JQL
        foreach my $refjql (reverse $git->get_config($CFG => 'ref-jql')) {
            my ($match_ref, $jql) = split ' ', $refjql, 2;
            if ($ref =~ $match_ref) {
                push @jqls, $jql;
                last;
            }
        }

        # JQL terms for the deprecated configuration options
        foreach my $option (qw/project issuetype status/) {
            if (my @values = $git->get_config($CFG => $option)) {
                push @jqls, "$option IN ('" . join("','", @values) . "')";
            }
        }

        # Conjunct all terms in a single JQL expression
        my $JQL = '(' . join(') AND (', @jqls) . ')';

        # Squeeze multiple whitespaces in a single space to make it appear
        # neatly in error messages.
        $JQL =~ s/\s{2,}/ /g;

        my $issues = _jql_query($git, $JQL);

        @issues{keys %$issues} = values %$issues; # cache all matched issues

        if (my @issues_not_found  = sort grep { ! exists $issues->{$_} } @keys) {
            # Some issue keys were cited but not found in JIRA
            ++$errors;
            local $, = ' ';
            $git->fault(<<EOS, {commit => $commit});
The commit cites the following invalid issues:

  @issues_not_found

The issues do not match the following JQL expression:

  $JQL

Please, update your issues or fix your $CFG git configuration.
EOS
        }
    }

    # Return prematurely if there are no issues to check
    return $errors == 0 unless %issues;

    ################
    # Non-JQL checks
    {
        my $unresolved  = $git->get_config_boolean($CFG => 'unresolved');
        my $by_assignee = $git->get_config_boolean($CFG => 'by-assignee');
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

      ISSUE:
        while (my ($key, $issue) = each %issues) {
            if ($unresolved && defined $issue->{fields}{resolution}) {
                $git->fault(<<EOS, {commit => $commit, option => 'unresolved'});
The commit cites issue $key which is already resolved.

The option in your configuration requires that all JIRA issues be unresolved.
EOS
                ++$errors;
                next ISSUE;
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
                $git->fault(<<EOS, {commit => $commit, option => 'fixversion'});
The commit cites issue $key which is invalid.

Commits on '$ref' must cite issues associated with a fixVersion matching
'$version' according to the configuration option.
EOS
                ++$errors;
                next ISSUE;
            }

            if ($by_assignee) {
                my $user = $git->authenticated_user()
                    or $git->fault(<<EOS)
Internal error: I cannot get your username to authorize you.
Please check your Git::Hooks configuration with regards to the function
https://metacpan.org/pod/Git::Repository::Plugin::GitHooks#authenticated_user
EOS
                    and ++$errors
                    and next ISSUE;

                if (my $assignee = $issue->{fields}{assignee}) {
                    my $name = $assignee->{name};
                    $user eq $name
                        or $git->fault(<<EOS, {commit => $commit, option => 'by-assignee'})
The commit cites issue $key which is assigned to '$name'.
The option requires that cited issues be assigned to you ($user).
Please, update your issue.
EOS
                        and ++$errors
                        and next KEY;
                } else {
                    $git->fault(<<EOS, {commit => $commit, option => 'by-assignee'});
The commit cites issue $key which is unassigned.
The option requires that cited issues be assigned to you ($user).
Please, update your issue.
EOS
                    ++$errors;
                    next KEY;
                }
            }
        }
    }

    #############
    # Code checks

    foreach my $code (check_codes($git)) {
        if (my $jira = _jira($git)) {
            my $ok = eval { $code->($git, $commit, $jira, values %issues) };
            if (defined $ok) {
                ++$errors unless $ok;
            } elsif (length $@) {
                $git->fault('Error while evaluating option value.',
                            {option => 'check-code', details => $@});
                ++$errors;
            }
        } else {
            ++$errors;
        }
    }

    return $errors == 0;
}

sub check_commit_msg {
    my ($git, $commit, $ref) = @_;

    if ($commit->parent() > 1 && $git->get_config_boolean($CFG => 'skip-merges')) {
        return 1;
    } else {
        return _check_jira_keys($git, $commit, $ref, uniq(grok_msg_jiras($git, $commit->message)));
    }
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    # The --branch argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $branch = $opts->{'--branch'};
    $branch = "refs/heads/$branch"
        unless $branch =~ m:^refs/:;

    return 1 unless $git->is_reference_enabled($branch);

    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($branch, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($branch, @noref);
    }

    return check_commit_msg($git, $commit, $branch);
}

sub check_message_file {
    my ($git, $commit_msg_file) = @_;

    _setup_config($git);

    my $current_branch = $git->get_current_branch();

    return 1 unless $git->is_reference_enabled($current_branch);

    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($current_branch, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($current_branch, @noref);
    }

    my $msg = eval { path($commit_msg_file)->slurp };
    defined $msg
        or $git->fault("Cannot open file '$commit_msg_file' for reading:", {details => $@})
            and return 0;

    # Remove comment lines from the message file contents.
    $msg =~ s/^#[^\n]*\n//mgs;

    # Construct a fake commit object to pass to the check_commit_msg
    my $commit = Git::Repository::Log->new(
        commit    => '<new>',
        author    => 'Fake Author <author@example.net> 1234567890 -0300',
        committer => 'Fake Committer <committer@example.net> 1234567890 -0300',
        message   => $msg,
    );

    return check_commit_msg($git, $commit, $current_branch);
}

sub check_ref {
    my ($git, $ref) = @_;

    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($ref, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($ref, @noref);
    }

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        check_commit_msg($git, $commit, $ref)
            or ++$errors;
    }

    _disconnect_jira($git);

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        next unless $git->is_reference_enabled($ref);
        check_ref($git, $ref)
            or ++$errors;
    }

    _disconnect_jira($git);

    return $errors == 0;
}

sub notify_commit_msg {
    my ($git, $commit, $ref, $visibility) = @_;

    my @keys = uniq(grok_msg_jiras($git, $commit->message));

    return 0 unless @keys;

    my $jira = _jira($git) or return 1;

    my $show = $git->run(show => '--stat', $commit->commit);

    my %comment = (
        body => <<EOS,
[$PKG] commit refers to this issue:

{noformat}
$show
{noformat}
EOS
    );
    $comment{visibility} = $visibility if $visibility;

    my $errors = 0;

    foreach my $key (@keys) {
        eval { $jira->POST("/issue/$key/comment", undef, \%comment); 1; }
            or $git->fault("I could not add a comment to JIRA issue $key.",
                           {commit => $commit, details => $@})
            and ++$errors;
    }

    return $errors;
}

sub notify_ref {
    my ($git, $ref, $visibility) = @_;

    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($ref, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($ref, @noref);
    }

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

    my $comment = $git->get_config($CFG => 'comment');

    return 1 unless defined $comment;

    my $visibility;
    if ($comment =~ /^(role|group):(.+)/) {
        $visibility = {
            type  => $1,
            value => $2,
        };
    } elsif ($comment ne 'all') {
        $git->fault(<<EOS, {option => $comment});
Configuration error.

The option is defined as '$comment', but
the valid values are 'role:ROLE', 'group:GROUP', or 'all'.
Please, check your git configuration.
EOS
        return 0;
    }

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        next unless $git->is_reference_enabled($ref);
        $errors += notify_ref($git, $ref, $visibility);
    }

    _disconnect_jira($git);

    return $errors == 0;
}

INIT: {
    # Install hooks
    APPLYPATCH_MSG   \&check_message_file;
    COMMIT_MSG       \&check_message_file;
    UPDATE           \&check_affected_refs;
    PRE_RECEIVE      \&check_affected_refs;
    REF_UPDATE       \&check_affected_refs;
    POST_RECEIVE     \&notify_affected_refs;
    PATCHSET_CREATED \&check_patchset;
    DRAFT_PUBLISHED  \&check_patchset;
}
1;


__END__
=for Pod::Coverage check_codes check_commit_msg check_ref notify_commit_msg notify_ref grok_msg_jiras check_affected_refs check_message_file check_patchset notify_affected_refs

=head1 NAME

CheckJira - Git::Hooks plugin to implement JIRA checks

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckJira

    # These users are exempt from all checks
    admin = joe molly

  [githooks "checkjira"]

    # Configure the URL and the admin credentials to interact with the JIRA
    # server.
    jiraurl = https://jira.example.net
    jirauser = jiradmin
    jirapass = my-secret

    # Look for JIRA keys at the beginning of the commit messages title, enclosed
    # in brackets.
    matchlog = (?s)^\\[([^]]+)\\]

    # Impose restrictions on valid JIRA issues
    jql = project IN (ABC, UTF, GIT) AND \
          issuetype IN (Bug, Story) AND \
          status IN ("In progress", "In testing")

    # Require that all cited JIRA issues be assigned to the user pushing the
    # commits.
    by-assignee = true

    # Commits pushed to master must cite JIRAs associated with the fixVersion
    # 'future'
    fixversion = refs/heads/master             future

    # Commits pushed to release branches must cite JIRAs associated with the
    # fixVersion named after the same major.minor version number.
    fixversion = ^refs/heads/(\\d+\\.\\d+)\\.  ^$+

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to guarantee that
every commit message cites at least one valid JIRA issue key in its log
message, so that you can be certain that every change has a proper change
request (a.k.a. ticket) open.

=over

=item * B<commit-msg>, B<applypatch-msg>

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

    [githooks]
      plugin = CheckJira

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checkacls> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 jiraurl URL

This option specifies the JIRA server HTTP URL, used to construct the
C<JIRA::REST> object which is used to interact with your JIRA
server. Please, see the JIRA::REST documentation to know about them.

=head2 jirauser USERNAME

This option specifies the JIRA server username, used to construct the
C<JIRA::REST> object.

=head2 jirapass PASSWORD

This option specifies the JIRA server password, used to construct the
C<JIRA::REST> object.

=head2 matchkey REGEXP

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyphen, followed by a sequence of digits. If
you customized your L<JIRA project
keys|https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>,
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=head2 matchlog REGEXP

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
regexes are tried and JIRA keys are looked for in all of them. This allows
you to more easily accommodate more than one way of specifying JIRA keys if
you wish.

=head2 jql JQL

By default, any cited issue must exist on the server and be unresolved. You
can specify other restrictions (and even allow for resolved issues) by
specifying a L<JQL
expression|https://confluence.atlassian.com/jirasoftwarecloud/advanced-searching-764478330.html>
which must match all cited issues. For example, you may want to:

=over

=item * Allow for resolved issues

  [githooks "checkjira"]
    jql = resolution IS EMPTY OR resolution IS NOT EMPTY

=item * Require specific projects, issuetypes, and statuses

  [githooks "checkjira"]
    jql = project IN (ABC, UTF, GIT) AND issuetype IN (Bug, Story) AND status IN ("In progress", "In testing")

=back

This is a scalar option. Only the last JQL expression will be used to check the
issues.

=head2 ref-jql REF JQL

You may impose restrictions on specific branches (or, more broadly, any
reference) by mentioning them before the JQL expression. REF can be
specified as a complete ref name (e.g. "refs/heads/master") or by a regular
expression starting with a caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)"). For instance:

  [githooks "checkjira"]
    ref-jql = refs/heads/master fixVersion = future
    ref-jql = ^refs/heads/release/ fixVersion IN releasedVersions()

This is a scalar option. Only the last JQL expression will be used to check the
issues.

Note, though, that if there is a global JQL specified by the
B<githooks.checkjira.jql> option it will be checked separately and both
expressions must validate the issues matching REF.

=head2 require BOOL

By default, the log must reference at least one JIRA issue. You can
make the reference optional by setting this option to false.

=head2 unresolved BOOL

By default, every issue referenced must be unresolved, i.e., it must
not have a resolution. You can relax this requirement by setting this
option to false.

=head2 fixversion BRANCH FIXVERSION

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
with a version number (e.g. C<1.0.3>) be assigned to the corresponding JIRA
version (e.g. C<1.0>).

=head2 by-assignee BOOL

By default, the committer can reference any valid JIRA issue. Setting
this value to true requires that the user doing the push/commit (as
specified by the C<userenv> configuration variable) be the current
issue's assignee.

=head2 check-code CODESPEC

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

The routine must return a true value to signal success. It may return a false
value or throw an exception to signal failure. It's best if it uses the 'fault'
method to produce error messages.

=item * B<ISSUES...>

The remaining arguments are RemoteIssue objects representing the
issues being cited by the commit's message.

=back

The subroutine should return a boolean value indicating success. Any errors
should be produced by invoking the
B<Git::Repository::Plugin::GitHooks::error> method.

If the subroutine returns undef it's considered to have succeeded.

If it raises an exception (e.g., by invoking B<die>) it's considered
to have failed and a proper message is produced to the user.

=head2 comment VISIBILITY

If this option is set and the C<post-receive> hook is enabled, for every
pushed commit, every cited JIRA issue receives a comment showing the result
of the C<git show --stat COMMIT> command. This is meant to notify the issue
assignee of commits referring to the issue.

Note that the user with which C<Git::Hooks> authenticates to JIRA must have
permission to add comments to the issues or an error will be
logged. However, since this happens after the push, the result of the
operation isn't affected.

You must specify the VISIBILITY of the comments in one of these ways.

=over

=item * B<role:NAME>

In this case, NAME must be the name of a JIRA role, such as
C<Administrators>, C<Developers>, or C<Users>.

=item * B<group:NAME>

In this case, NAME must be the name of a JIRA group.

=item * B<all>

In this case, the visibility isn't restricted at all.

=back

=head2 skip-merges BOOL

By default, all commits are checked. You can exempt merge commits from being
checked by setting this option to true.

=head2 [DEPRECATED] project KEY

This option is B<DEPRECATED>. Please, use a JQL expression such the
following to restrict by project key:

  project IN (ABC, GIT)

By default, the committer can reference any JIRA issue in the commit
log. You can restrict the allowed keys to a set of JIRA projects by
specifying a JIRA project key to this option. You can allow more than one
project by specifying this option multiple times, once per project key.

If you set this option, then any cited JIRA issue that doesn't belong to one
of the specified projects causes an error.

=head2 [DEPRECATED] status STATUSNAME

This option is B<DEPRECATED>. Please, use a JQL expression such the
following to restrict by status:

  status IN (Open, "In Progress")

By default, it doesn't matter in which status the JIRA issues are. By
setting this multi-valued option you can restrict the valid statuses for the
issues.

=head2 [DEPRECATED] issuetype ISSUETYPENAME

This option is B<DEPRECATED>. Please, use a JQL expression such the
following to restrict by issue type:

  issuetype IN (Bug, Story)

By default, it doesn't matter what type of JIRA issues are cited. By setting
this multi-valued option you can restrict the valid issue types.

=head2 [DEPRECATED] ref REFSPEC

This option is DEPRECATED. Please, use the C<githooks.ref> option instead.

By default, the message of every commit is checked. If you want to
have them checked only for some refs (usually some branch under
refs/heads/), you may specify them with one or more instances of this
option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 [DEPRECATED] noref REFSPEC

This option is DEPRECATED. Please, use the C<githooks.noref> option instead.

By default, the message of every commit is checked. If you want to exclude
some refs (usually some branch under refs/heads/), you may specify them with
one or more instances of this option.

The refs can be specified as in the same way as to the C<ref> option above.

Note that the C<ref> option has precedence over the C<noref> option, i.e.,
if a reference matches both options it will be checked.

=head1 SEE ALSO

=over

=item * L<Git::Repository>

=item * L<JIRA::REST>

=item * L<JIRA::Client>

=back

=head1 REFERENCES

=over

=item * L<git-jira-hook|https://github.com/joyjit/git-jira-hook>

This script is heavily inspired (and sometimes derived) from Joyjit Nath's hook.

=item * L<JIRA SOAP API deprecation
notice|https://developer.atlassian.com/display/JIRADEV/SOAP+and+XML-RPC+API+Deprecated+in+JIRA+6.0>

=item * L<Yet Another Commit
Checker|https://github.com/sford/yet-another-commit-checker>

This Bitbucket plugin implements some nice checks with JIRA, from which we
stole some ideas.

=back
