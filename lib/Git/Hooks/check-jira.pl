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

use 5.010;
use utf8;
use strict;
use warnings;
use File::Slurp;
use Data::Util qw(:check);
use List::MoreUtils qw/uniq/;
use JIRA::Client;

my $HOOK = "check-jira";

#############
# Grok hook configuration, check it and set defaults.

my $Config = config($HOOK);

# The JIRA connection options are scalars and required
foreach my $option (qw/jiraurl jirauser jirapass/) {
    exists $Config->{$option}
	or die "$HOOK: Missing check-jira.$option configuration variable.\n";
    $Config->{$option} = $Config->{$option}[-1];
}
$Config->{jiraurl} =~ s/\/+$//;

# Projects is an array which we'll convert into a hash to speed up
# lookups
if (exists $Config->{projects}) {
    $Config->{projects} = {map {($_ => undef)} $Config->{projects}};
}

# Matchlog and matchkey are scalars which we'll convert into Regexes
foreach my $option (qw/matchlog matchkey/) {
    if (defined $Config->{$option}) {
	my $regex = eval {qr/$Config->{$option}[-1]/};
	die "$HOOK: Invalid $option regex ($Config->{$option}[-1]).\n$@\n" if $@;
	$Config->{$option} = $regex;
    }
}
$Config->{matchkey} //= qr/\b[A-Z][A-Z]+-\d+\b/;

# The check options are scalars with defaults
foreach my $option (qw/require valid unresolved/) {
    $Config->{$option} = exists $Config->{$option} ? $Config->{$option}[-1] : 1;
}

# Check_code is an array of code snippets. We'll evaluate each one of
# them and save them as a sub-refs.
if (exists $Config->{check_code}) {
    foreach my $code (@{$Config->{check_code}}) {
	my $check;
	if ($code =~ s/^file://) {
	    $check = do $code;
	    unless ($check) {
		die "$HOOK: couldn't parse option check_code ($code): $@\n" if $@;
		die "$HOOK: couldn't do option check_code ($code): $!\n"    unless defined $check;
		die "$HOOK: couldn't run option check_code ($code)\n"       unless $check;
	    }
	} else {
	    $check = eval $code;
	    die "$HOOK: couldn't parse option check_code value:\n$@\n" if $@;
	}
	is_code_ref($check)
	    or die "$HOOK: option check_code must end with a code ref.\n";
	$code = $check;
    }
}

##########

sub grok_msg_jiras {
    my ($msg) = @_;
    # Grok the JIRA issue keys from the commit log
    if (exists $Config->{matchlog}) {
	if (my ($match) = ($msg =~ $Config->{matchlog})) {
	    return $match =~ /$Config->{matchkey}/g;
	} else {
	    return ();
	}
    } else {
	return $msg =~ /$Config->{matchkey}/g;
    }
}

my $JIRA;

sub get_issue {
    my ($key) = @_;

    # Connect to JIRA if not yet connected
    unless (defined $JIRA) {
	my ($jiraurl, $jirauser, $jirapass) = @{$Config}{qw/jiraurl jirauser jirapass/};
	$JIRA = eval {JIRA::Client->new($jiraurl, $jirauser, $jirapass)};
	die "$HOOK: cannot connect to the JIRA server at '$jiraurl' as '$jirauser': $@\n" if $@;
    }

    state %issue_cache;

    # Try to get the issue from the cache
    unless (exists $issue_cache{$key}) {
	$issue_cache{$key} = eval {$JIRA->getIssue($key)};
	die "$HOOK: can't get issue $key: $@\n"	if $@;
    }

    return $issue_cache{$key};
}

sub ferror {
    my ($key, $commit, $ref, $error) = @_;
    my $msg = "$HOOK: issue $key, $error.\n  (cited ";
    $msg .= "by $commit->{commit} " if $commit->{commit};
    $msg .= "in $ref)\n";
    return $msg;
}

sub check_commit_msg {
    my ($git, $commit, $ref) = @_;

    my @keys = uniq(grok_msg_jiras($commit->{body}));

    unless (@keys) {
	if ($Config->{require}) {
	    die "$HOOK: commit $commit->{commit} (in $ref) does not cite any JIRA issue.\n";
	} else {
	    return;
	}
    }

    # Check if there is a restriction on the project keys allowed
    if (my $option = $Config->{projects}) {
	state $projects = [map {($_ => undef)} @$option];
	foreach my $key (@keys) {
	    my ($pkey, $pnum) = split /-/, $key;
	    die ferror($key, $commit, $ref,
		       "doesn't belong to the allowed projects: " . join(', ', sort keys @$projects))
		unless exists $projects->{$pkey};
	}
    }

    my @issues;

    foreach my $key (@keys) {
	my $issue = get_issue($key);

	if ($Config->{unresolved} && defined $issue->{resolution}) {
	    die ferror($key, $commit, $ref, "is already resolved");
	}

	if (my $committer = $Config->{by_assignee}) {
	    if ($ENV{$committer} ne $issue->{assignee}) {
		die ferror($key, $commit, $ref,
			   "is currently assigned to '$issue->{assignee}' but should be assigned to you ($ENV{$committer})");
	    }
	}

	push @issues, $issue;
    }

    if (exists $Config->{check_code}) {
	foreach my $check (@{$Config->{check_code}}) {
	    $check->($git, $commit, $JIRA, @issues);
	}
    }

    return;
}

COMMIT_MSG {
    my ($git, $commit_msg_file) = @_;

    my $cur_branch = 'refs/heads/' . $git->get_current_branch();
    if (my $branches = $Config->{branches}) {
	return unless $git->is_ref_enabled($branches, $cur_branch);
    }

    my $msg = read_file($commit_msg_file);
    defined $msg or die "$HOOK: Can't open file '$commit_msg_file' for reading: $!\n";

    check_commit_msg(
	$git,
	{ commit => '', body => $msg },	# fake a commit hash to simplify check_commit_msg
	$cur_branch,
    );
};

sub check_ref {
    my ($git, $ref) = @_;

    if (my $branches = $Config->{branches}) {
	return unless $git->is_ref_enabled($branches, $ref);
    }

    my $commits = $git->get_affected_commits()->{$ref}{commits};

    foreach my $commit (@$commits) {
	check_commit_msg($git, $commit, $ref);
    }
};

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return if im_admin($git);

    my $refs = $git->get_affected_refs();
    while (my ($refname, $ref) = each %$refs) {
	check_ref($git, $refname, @{$ref->{range}});
    }
}

# Install hooks
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=head1 SYNOPSIS

  check-jira.pl [--verbose] [--hook=commit-msg]  COMMIT_MSG_FILE
  check-jira.pl [--verbose] [--hook=update]      REF OLD_COMMIT NEW_COMMIT
  check-jira.pl [--verbose] [--hook=pre-receive]

=head1 DESCRIPTION

This script can act as one of three different Git hooks to guarantee
that every commit message cites at least one valid JIRA issue key in
its log message, so that you can be certain that every change has a
proper change request (a.k.a. ticket) open.

It requires that any Git commits affecting all or some branches must
make reference to valid JIRA issues in the commit log message. JIRA
issues are cited by their keys which, by default, consist of a
sequence of uppercase letters separated by an hyfen from a sequence of
digits. E.g., C<CDS-123>, C<RT-1>, and C<GIT-97>.

To install it you must copy (or link) it to one of the three hook
files under C<.git/hooks> in your Git repository: C<commit-msg>,
C<pre-receive>, and C<update>. In this way, Git will call it with
proper name and arguments. For each hook it acts as follows:

=over

=item C<commit-msg>

This hook is invoked locally during C<git commit> before it's
completed. The script reads the proposed commit message and checks if
it cites valid JIRA issue keys, aborting the commit otherwise.

=item C<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated. The script checks every
commit being updated for the branch.

=item C<pre-receive>

This hook is invoked once in the remote repository during C<git
push>. The script checks every commit being updated for every branch.

=back

It is configured by the following git options, which can be set via
the C<git config> command. Note that you may have options set in any
of the system, global, or local scopes. The script will use the most
restricted one.

=over

=item check-jira.jiraurl

=item check-jira.jirauser

=item check-jira.jirapass

These options are required and are used to construct the
C<JIRA::Client> object which is used to interact with your JIRA
server. Please, see the JIRA::Client documentation to know about them.

=item check-jira.matchkey

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyfen, followed by a sequence of digits. If
you customized your JIRA project keys
(L<https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>),
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=item check-jira.matchlog

By default, JIRA keys are looked for in all of the commit
message. However, this can lead to some false positives, since the
default issue pattern can match other things besides JIRA issue
keys. You may use this option to restrict the places inside the commit
message where the keys are going to be looked for.

For example, set it to "C<\[([^]]+)\]>" to require that JIRA keys be
cited inside the first pair of brackets found in the message.

=item check-jira.projects

By default, the commiter can reference any JIRA issue in the commit
log. You can restrict the allowed keys to a set of JIRA projects by
specifying a comma-or-space-separated list of project keys to this
option.

=item check-jira.require => [01]

By default, the log must reference at least one JIRA issue. You can
make the reference optional by setting this option to 0.

=item check-jira.unresolved => [01]

By default, every issue referenced must be unresolved, i.e., it must
not have a resolution. You can relax this requirement by setting this
option to 0.

=item check-jira.by_assignee

By default, the commiter can reference any valid JIRA issue. Setting
this value to the name of an environment variable, the script will
check if its value is equal to the referenced JIRA issues assignee.
FIXME: give a usage example.

=item check-jira.check_code

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

=item the Git repository object used to grok information about the
commit.

=item the SHA-1 id of the Git commit. It is undef in the C<commit-msg>
hook, because there is no commit yet.

=item the JIRA::Client object used to talk to the JIRA server.

=item the remaining arguments are RemoteIssue objects representing the
issues being cited by the commit's message.

=back

The subroutine must simply return with no value to indicate success
and must die to indicate failure.

Please, read the C<JIRA::Client> and C<Git::More> modules
documentation to understand how to use these objects.

=back

=head1 REFERENCES

This script is heavily inspired (and sometimes even derived) from the
Joyjit Nath's git-jira-hook
(L<https://github.com/joyjit/git-jira-hook/tree/4b9f7354851602c7d6e8a39386f0c16d729d2ac2>).
