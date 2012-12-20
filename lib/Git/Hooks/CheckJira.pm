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

(my $HOOK = __PACKAGE__) =~ s/.*:://;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    # Default matchkey for matching default JIRA keys.
    $config->{$HOOK}{matchkey}   //= ['\b[A-Z][A-Z]+-\d+\b'];

    $config->{$HOOK}{require}    //= [1];
    $config->{$HOOK}{unresolved} //= [1];

    return;
}

##########

sub grok_msg_jiras {
    my ($git, $msg) = @_;

    state $matchkey = $git->config_scalar($HOOK => 'matchkey');
    state $matchlog = $git->config_scalar($HOOK => 'matchlog');

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
            $jira{$option} = $git->config_scalar($HOOK => $option)
                or die "$HOOK: Missing $HOOK.$option configuration attribute.\n";
        }
        $jira{jiraurl} =~ s:/+$::; # trim trailing slashes from the URL
        $JIRA = eval {JIRA::Client->new($jira{jiraurl}, $jira{jirauser}, $jira{jirapass})};
        die "$HOOK: cannot connect to the JIRA server at '$jira{jiraurl}' as '$jira{jirauser}': $@\n"
            if $@;
    }

    state %issue_cache;

    # Try to get the issue from the cache
    unless (exists $issue_cache{$key}) {
        $issue_cache{$key} = eval {$JIRA->getIssue($key)};
        die "$HOOK: cannot get issue $key: $@\n" if $@;
    }

    return $issue_cache{$key};
}

sub ferror {
    my ($key, $commit, $ref, $error) = @_;
    my $msg = "$HOOK: issue $key, $error.\n  (cited ";
    $msg .= "by $commit->{commit} " if $commit->{commit};
    $msg .= "in $ref)";
    return $msg;
}

sub check_codes {
    my ($git) = @_;

    state $codes = undef;

    unless (defined $codes) {
        $codes = [];
        foreach my $code ($git->config_list($HOOK => 'check-code')) {
            my $check;
            if ($code =~ s/^file://) {
                $check = do $code;
                unless ($check) {
                    die "$HOOK: couldn't parse option check-code ($code): $@\n" if $@;
                    die "$HOOK: couldn't do option check-code ($code): $!\n"    unless defined $check;
                    die "$HOOK: couldn't run option check-code ($code)\n"       unless $check;
                }
            } else {
                $check = eval $code; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                die "$HOOK: couldn't parse option check-code value:\n$@\n" if $@;
            }
            is_code_ref($check)
                or die "$HOOK: option check-code must end with a code ref.\n";
            push @$codes, $check;
        }
    }

    return @$codes;
}

sub check_commit_msg {
    my ($git, $commit, $ref) = @_;

    my @keys  = uniq(grok_msg_jiras($git, $commit->{body}));
    my $nkeys = @keys;

    # Filter out JIRAs not belonging to any of the specific projects,
    # if any. We don't care about them.
    state $projects = {map {($_ => undef)} $git->config_list($HOOK => 'project')};
    if (keys %$projects) {
        @keys = grep {/([^-]+)/ && exists $projects->{$1}} @keys;
    }

    unless (@keys) {
        if ($git->config_scalar($HOOK => 'require')) {
            my $shortid = substr $commit->{commit}, 0, 8;
            if (@keys == $nkeys) {
                die <<"EOF";
$HOOK: commit $shortid (in $ref) does not cite any JIRA in the message:
$commit->{body}
EOF
            } else {
                my $project = join(' ', $git->config_list($HOOK => 'project'));
                die <<"EOF";
$HOOK: commit $shortid (in $ref) does not cite any JIRA from the expected
$HOOK: projects ($project) in the message:
$commit->{body}
EOF
            }
        } else {
            return;
        }
    }

    my @issues;

    state $unresolved = $git->config_scalar($HOOK => 'unresolved');
    state $committer  = $git->config_scalar($HOOK => 'by-assignee');

    foreach my $key (@keys) {
        my $issue = get_issue($git, $key);

        if ($unresolved && defined $issue->{resolution}) {
            die ferror($key, $commit, $ref, "is already resolved"), "\n";
        }

        if ($committer) {
            exists $ENV{$committer}
                or die ferror($key, $commit, $ref,
                              "the environment variable '$committer' is undefined. Cannot get committer name"), "\n";

            $ENV{$committer} eq $issue->{assignee}
                or die ferror($key, $commit, $ref,
                              "is currently assigned to '$issue->{assignee}' but should be assigned to you ($ENV{$committer})"), "\n";
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
    return unless is_ref_enabled($current_branch, $git->config_list($HOOK => 'ref'));

    my $msg = read_file($commit_msg_file)
        or die "$HOOK: Can't open file '$commit_msg_file' for reading: $!\n";

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

    return unless is_ref_enabled($ref, $git->config_list($HOOK => 'ref'));

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

This Git::Hooks plugin can act as any of the below hooks to guarantee
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

To enable it you should define the appropriate Git configuration
option:

    git config --add githooks.commit-msg  CheckJira
    git config --add githooks.update      CheckJira
    git config --add githooks.pre-receive CheckJira

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 CheckJira.ref REFSPEC

By default, the message of every commit is checked. If you want to
have them checked only for some refs (usually some branch under
refs/heads/), you may specify them with one or more instances of this
option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 CheckJira.userenv STRING

This variable is deprecated. Please, use the C<githooks.userenv>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 CheckJira.admin USERSPEC

This variable is deprecated. Please, use the C<githooks.admin>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 CheckJira.jiraurl URL

This option specifies the JIRA server HTTP URL, used to construct the
C<JIRA::Client> object which is used to interact with your JIRA
server. Please, see the JIRA::Client documentation to know about them.

=head2 CheckJira.jirauser USERNAME

This option specifies the JIRA server username, used to construct the
C<JIRA::Client> object.

=head2 CheckJira.jirapass PASSWORD

This option specifies the JIRA server password, used to construct the
C<JIRA::Client> object.

=head2 CheckJira.matchkey REGEXP

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyphen, followed by a sequence of digits. If
you customized your JIRA project keys
(L<https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>),
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=head2 CheckJira.matchlog REGEXP

By default, JIRA keys are looked for in all of the commit
message. However, this can lead to some false positives, since the
default issue pattern can match other things besides JIRA issue
keys. You may use this option to restrict the places inside the commit
message where the keys are going to be looked for.

For example, set it to C<\[([^]]+)\]> to require that JIRA keys be
cited inside the first pair of brackets found in the message.

=head2 CheckJira.project STRING

By default, the committer can reference any JIRA issue in the commit
log. You can restrict the allowed keys to a set of JIRA projects by
specifying a JIRA project key to this option. You can enable more than
one project by specifying more than one value to this option.

=head2 CheckJira.require [01]

By default, the log must reference at least one JIRA issue. You can
make the reference optional by setting this option to 0.

=head2 CheckJira.unresolved [01]

By default, every issue referenced must be unresolved, i.e., it must
not have a resolution. You can relax this requirement by setting this
option to 0.

=head2 CheckJira.by-assignee STRING

By default, the committer can reference any valid JIRA issue. Setting
this value to the name of an environment variable, the script will
check if its value is equal to the referenced JIRA issue's assignee.

=head2 CheckJira.check-code CODESPEC

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
