#!/usr/bin/env perl

# Copyright (C) 2012 by CPqD

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Git::Hooks::CheckJira;
# ABSTRACT: Git::Hooks plugin which requires citation of JIRA issues in commit messages.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use File::Slurp;
use Data::Util qw(:check);
use List::MoreUtils qw/uniq/;
use JIRA::Client;

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

    my $matchkey = $git->config($CFG => 'matchkey');
    my $matchlog = $git->config($CFG => 'matchlog');

    # Grok the JIRA issue keys from the commit log
    if ($matchlog) {
        if (my ($match) = ($msg =~ /$matchlog/o)) {
            return $match =~ /$matchkey/go;
        } else {
            return ();
        }
    } else {
        return $msg =~ /$matchkey/go;
    }
}

my $JIRA;

sub get_issue {
    my ($git, $key) = @_;

    # Connect to JIRA if not yet connected
    unless (defined $JIRA) {
        my %jira;
        for my $option (qw/jiraurl jirauser jirapass/) {
            $jira{$option} = $git->config($CFG => $option)
                or die "$PKG: Missing $CFG.$option configuration attribute.\n";
        }
        $jira{jiraurl} =~ s:/+$::; # trim trailing slashes from the URL
        $JIRA = eval {JIRA::Client->new($jira{jiraurl}, $jira{jirauser}, $jira{jirapass})};
        die "$PKG: cannot connect to the JIRA server at '$jira{jiraurl}' as '$jira{jirauser}': $@\n"
            if $@;
    }

    my $cache = $git->cache($PKG);

    # Try to get the issue from the cache
    unless (exists $cache->{$key}) {
        $cache->{$key} = eval {$JIRA->getIssue($key)};
        die "$PKG: cannot get issue $key: $@\n" if $@;
    }

    return $cache->{$key};
}

sub ferror {
    my ($key, $commit, $ref, $error) = @_;
    my $msg = "$PKG: issue $key, $error.\n  (cited ";
    $msg .= "by $commit->{commit} " if $commit->{commit};
    $msg .= "in $ref)";
    return $msg;
}

sub check_codes {
    my ($git) = @_;

    my @codes;

    foreach my $check ($git->config($CFG => 'check-code')) {
        my $code;
        if ($check =~ s/^file://) {
            $code = do $check;
            unless ($code) {
                die "$PKG: couldn't parse option check-code ($check): $@\n" if $@;
                die "$PKG: couldn't do option check-code ($check): $!\n"    unless defined $code;
                die "$PKG: couldn't run option check-code ($check)\n"       unless $code;
            }
        } else {
            $code = eval $check; ## no critic (BuiltinFunctions::ProhibitStringyEval)
            die "$PKG: couldn't parse option check-code value:\n$@\n" if $@;
        }
        is_code_ref($code)
            or die "$PKG: option check-code must end with a code ref.\n";
        push @codes, $code;
    }

    return @codes;
}

sub check_commit_msg {
    my ($git, $commit, $ref) = @_;

    my @keys  = uniq(grok_msg_jiras($git, $commit->{body}));
    my $nkeys = @keys;

    # Filter out JIRAs not belonging to any of the specific projects,
    # if any. We don't care about them.
    if (my @projects = $git->config($CFG => 'project')) {
        my %projects = map {($_ => undef)} @projects;
        @keys = grep {/([^-]+)/ && exists $projects{$1}} @keys;
    }

    unless (@keys) {
        if ($git->config($CFG => 'require')) {
            my $shortid = substr $commit->{commit}, 0, 8;
            if (@keys == $nkeys) {
                die <<"EOF";
$PKG: commit $shortid (in $ref) does not cite any JIRA in the message:
$commit->{body}
EOF
            } else {
                my $project = join(' ', $git->config($CFG => 'project'));
                die <<"EOF";
$PKG: commit $shortid (in $ref) does not cite any JIRA from the expected
$PKG: projects ($project) in the message:
$commit->{body}
EOF
            }
        } else {
            return;
        }
    }

    my @issues;

    my $unresolved  = $git->config($CFG => 'unresolved');
    my $by_assignee = $git->config($CFG => 'by-assignee');

    foreach my $key (@keys) {
        my $issue = get_issue($git, $key);

        if ($unresolved && defined $issue->{resolution}) {
            die ferror($key, $commit, $ref, "is already resolved"), "\n";
        }

        if ($by_assignee) {
            my $user = $git->authenticated_user()
                or die ferror($key, $commit, $ref,
                              "cannot grok the authenticated user"), "\n";

            $user eq $issue->{assignee}
                or die ferror($key, $commit, $ref,
                              "is currently assigned to '$issue->{assignee}' but should be assigned to you ($user)"), "\n";
        }

        push @issues, $issue;
    }

    foreach my $code (check_codes($git)) {
        $code->($git, $commit, $JIRA, @issues);
    }

    return;
}

sub check_message_file {
    my ($git, $commit_msg_file) = @_;

    _setup_config($git);

    my $current_branch = 'refs/heads/' . $git->get_current_branch();
    return unless is_ref_enabled($current_branch, $git->config($CFG => 'ref'));

    my $msg = read_file($commit_msg_file)
        or die "$PKG: Can't open file '$commit_msg_file' for reading: $!\n";

    # Remove comment lines from the message file contents.
    $msg =~ s/^#[^\n]*\n//mgs;

    check_commit_msg(
        $git,
        { commit => '', body => $msg }, # fake a commit hash to simplify check_commit_msg
        $current_branch,
    );

    return;
}

sub check_ref {
    my ($git, $ref) = @_;

    return unless is_ref_enabled($ref, $git->config($CFG => 'ref'));

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        check_commit_msg($git, $commit, $ref);
    }

    return;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return if im_admin($git);

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref);
    }

    return;
}

# Install hooks
COMMIT_MSG  \&check_message_file;
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=for Pod::Coverage check_codes check_commit_msg check_ref ferror get_issue grok_msg_jiras

=head1 NAME

CheckJira - Git::Hooks plugin which requires citation of JIRA
issues in commit messages.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to guarantee
that every commit message cites at least one valid JIRA issue key in
its log message, so that you can be certain that every change has a
proper change request (a.k.a. ticket) open.

=over

=item C<commit-msg>

This hook is invoked during the commit, to check if the commit message
cites valid JIRA issues.

=item C<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, to check if the commit
message cites valid JIRA issues.

=item C<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
to check if the commit message cites valid JIRA issues.

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

=head2 githooks.checkjira.userenv STRING

This variable is deprecated. Please, use the C<githooks.userenv>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 githooks.checkjira.admin USERSPEC

This variable is deprecated. Please, use the C<githooks.admin>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 githooks.checkjira.jiraurl URL

This option specifies the JIRA server HTTP URL, used to construct the
C<JIRA::Client> object which is used to interact with your JIRA
server. Please, see the JIRA::Client documentation to know about them.

=head2 githooks.checkjira.jirauser USERNAME

This option specifies the JIRA server username, used to construct the
C<JIRA::Client> object.

=head2 githooks.checkjira.jirapass PASSWORD

This option specifies the JIRA server password, used to construct the
C<JIRA::Client> object.

=head2 githooks.checkjira.matchkey REGEXP

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyphen, followed by a sequence of digits. If
you customized your JIRA project keys
(L<https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>),
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=head2 githooks.checkjira.matchlog REGEXP

By default, JIRA keys are looked for in all of the commit
message. However, this can lead to some false positives, since the
default issue pattern can match other things besides JIRA issue
keys. You may use this option to restrict the places inside the commit
message where the keys are going to be looked for.

For example, set it to C<\[([^]]+)\]> to require that JIRA keys be
cited inside the first pair of brackets found in the message.

=head2 githooks.checkjira.project STRING

By default, the committer can reference any JIRA issue in the commit
log. You can restrict the allowed keys to a set of JIRA projects by
specifying a JIRA project key to this option. You can enable more than
one project by specifying more than one value to this option.

=head2 githooks.checkjira.require [01]

By default, the log must reference at least one JIRA issue. You can
make the reference optional by setting this option to 0.

=head2 githooks.checkjira.unresolved [01]

By default, every issue referenced must be unresolved, i.e., it must
not have a resolution. You can relax this requirement by setting this
option to 0.

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

=item GIT

The Git repository object used to grok information about the commit.

=item COMMITID

The SHA-1 id of the Git commit. It is undef in the C<commit-msg> hook,
because there is no commit yet.

=item JIRA

The JIRA::Client object used to talk to the JIRA server.

=item ISSUES...

The remaining arguments are RemoteIssue objects representing the
issues being cited by the commit's message.

=back

The subroutine must simply return with no value to indicate success
and must die to indicate failure.

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

=head1 SEE ALSO

C<Git::More>

C<JIRA::Client>

=head1 REFERENCES

This script is heavily inspired (and sometimes derived) from Joyjit
Nath's git-jira-hook (L<https://github.com/joyjit/git-jira-hook>).
