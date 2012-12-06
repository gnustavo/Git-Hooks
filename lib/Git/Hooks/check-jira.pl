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
use Git::Hooks qw/:utils/;
use File::Slurp;
use Data::Util qw(:check);
use List::MoreUtils qw/uniq/;
use JIRA::Client;

my $HOOK = "check-jira";

#############
# Grok hook configuration, check it and set defaults.

my $Config = hook_config($HOOK);

# Default matchkey for matching default JIRA keys.
$Config->{matchkey} //= ['\b[A-Z][A-Z]+-\d+\b'];

# The check options are scalars with defaults
foreach my $option (qw/require unresolved/) {
    $Config->{$option} = exists $Config->{$option} ? $Config->{$option}[-1] : 1;
}

# Up to version 0.020 the configuration variables 'admin' and
# 'userenv' were defined for the check-jira plugin. In version 0.021
# they were both "promoted" to the Git::Hooks module, so that they can
# be used by any access control plugin. In order to maintain
# compatibility with their previous usage, here we virtually "inject"
# the variables in the "githooks" configuration section if they
# undefined there and are defined in the "check-jira" section.
foreach my $var (qw/admin userenv/) {
    if (exists $Config->{$var} && ! exists hook_config('githooks')->{$var}) {
	hook_config('githooks')->{$var} = $Config->{$var};
    }
}

##########

sub grok_msg_jiras {
    my ($msg) = @_;
    # Grok the JIRA issue keys from the commit log
    state $matchkey = qr/$Config->{matchkey}[-1]/;
    if (exists $Config->{matchlog}) {
	state $matchlog = is_rx($Config->{matchlog}[-1]) ? $Config->{matchlog}[-1] : qr/$Config->{matchlog}[-1]/;
	if (my ($match) = ($msg =~ $matchlog)) {
	    return $match =~ /$matchkey/g;
	} else {
	    return ();
	}
    } else {
	return $msg =~ /$matchkey/g;
    }
}

my $JIRA;

sub get_issue {
    my ($key) = @_;

    # Connect to JIRA if not yet connected
    unless (defined $JIRA) {
	for my $option (qw/jiraurl jirauser jirapass/) {
	    exists $Config->{$option}
		or die "$HOOK: Missing check-jira.$option configuration variable.\n";
	    $Config->{$option} = $Config->{$option}[-1];
	}
	$Config->{jiraurl} =~ s:/+$::; # trim trailing slashes from the URL
	$JIRA = eval {JIRA::Client->new($Config->{jiraurl}, $Config->{jirauser}, $Config->{jirapass})};
	die "$HOOK: cannot connect to the JIRA server at '$Config->{jiraurl}' as '$Config->{jirauser}': $@\n" if $@;
    }

    state %issue_cache;

    # Try to get the issue from the cache
    unless (exists $issue_cache{$key}) {
	$issue_cache{$key} = eval {$JIRA->getIssue($key)};
	die "$HOOK: cannot get issue $key: $@\n"	if $@;
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

sub check_codes {
    state $codes = undef;

    unless (defined $codes) {
	if (exists $Config->{'check-code'}) {
	    foreach my $code (@{$Config->{'check-code'}}) {
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
	} else {
	    $codes = [];
	}
    }

    return @$codes;
}

sub check_commit_msg {
    my ($git, $commit, $ref) = @_;

    my @keys = uniq(grok_msg_jiras($commit->{body}));
    my $nkeys = @keys;

    # Filter out JIRAs not belonging to any of the specific projects,
    # if any. We don't care about them.
    if (my $option = $Config->{project}) {
	state $projects = {map {($_ => undef)} @$option}; # hash it to speed up lookup
	@keys = grep {/([^-]+)/ && exists $projects->{$1}} @keys;
    }

    unless (@keys) {
	if ($Config->{require}) {
	    my $shortid = substr $commit->{commit}, 0, 8;
	    if (@keys == $nkeys) {
		die <<EOF;
$HOOK: commit $shortid (in $ref) does not cite any JIRA in the message:
$commit->{body}
EOF
	    } else {
		my $projects = join(' ', @{$Config->{project}});
		die <<EOF;
$HOOK: commit $shortid (in $ref) does not cite any JIRA from the expected
$HOOK: projects ($projects) in the message:
$commit->{body}
EOF
	    }
	} else {
	    return;
	}
    }

    my @issues;

    foreach my $key (@keys) {
	my $issue = get_issue($key);

	if ($Config->{unresolved} && defined $issue->{resolution}) {
	    die ferror($key, $commit, $ref, "is already resolved");
	}

	if (my $committer = $Config->{'by-assignee'}) {
	    $committer = $committer->[-1];
	    exists $ENV{$committer}
		or die ferror($key, $commit, $ref,
			      "the environment variable '$committer' is undefined. Cannot get committer name");

	    $ENV{$committer} eq $issue->{assignee}
		or die ferror($key, $commit, $ref,
			      "is currently assigned to '$issue->{assignee}' but should be assigned to you ($ENV{$committer})");
	}

	push @issues, $issue;
    }

    foreach my $code (check_codes()) {
	$code->($git, $commit, $JIRA, @issues);
    }

    return;
}

COMMIT_MSG {
    my ($git, $commit_msg_file) = @_;

    return if im_admin();

    my $current_branch = 'refs/heads/' . $git->get_current_branch();
    if (my $refs = $Config->{ref}) {
	return unless is_ref_enabled($refs, $current_branch);
    }

    my $msg = read_file($commit_msg_file);
    defined $msg or die "$HOOK: Can't open file '$commit_msg_file' for reading: $!\n";

    # Remove comment lines from the message file contents.
    $msg =~ s/\n#[^\n]*//sg;

    check_commit_msg(
	$git,
	{ commit => '', body => $msg },	# fake a commit hash to simplify check_commit_msg
	$current_branch,
    );
};

sub check_ref {
    my ($git, $ref) = @_;

    if (my $refs = $Config->{ref}) {
	return unless is_ref_enabled($refs, $ref);
    }

    foreach my $commit (@{get_affected_ref_commits($ref)}) {
	check_commit_msg($git, $commit, $ref);
    }
};

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return if im_admin();

    foreach my $ref (get_affected_refs()) {
	check_ref($git, $ref);
    }
}

# Install hooks
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=head1 NAME

check-jira.pl - Git::Hooks plugin which requires citation of JIRA
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

    git config --add githooks.commit-msg  check-jira.pl
    git config --add githooks.update      check-jira.pl
    git config --add githooks.pre-receive check-jira.pl

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 check-jira.ref REFSPEC

By default, the message of every commit is checked. If you want to
have them checked only for some refs (usually some branch under
refs/heads/), you may specify them with one or more instances of this
option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 check-jira.userenv STRING

This variable is deprecated. Please, use the C<githooks.userenv>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 check-jira.admin USERSPEC

This variable is deprecated. Please, use the C<githooks.admin>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 check-jira.jiraurl URL

=head2 check-jira.jirauser USERNAME

=head2 check-jira.jirapass PASSWORD

These options are required and are used to construct the
C<JIRA::Client> object which is used to interact with your JIRA
server. Please, see the JIRA::Client documentation to know about them.

=head2 check-jira.matchkey REGEXP

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyphen, followed by a sequence of digits. If
you customized your JIRA project keys
(L<https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>),
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=head2 check-jira.matchlog REGEXP

By default, JIRA keys are looked for in all of the commit
message. However, this can lead to some false positives, since the
default issue pattern can match other things besides JIRA issue
keys. You may use this option to restrict the places inside the commit
message where the keys are going to be looked for.

For example, set it to C<\[([^]]+)\]> to require that JIRA keys be
cited inside the first pair of brackets found in the message.

=head2 check-jira.project STRING

By default, the committer can reference any JIRA issue in the commit
log. You can restrict the allowed keys to a set of JIRA projects by
specifying a JIRA project key to this option. You can enable more than
one project by specifying more than one value to this option.

=head2 check-jira.require [01]

By default, the log must reference at least one JIRA issue. You can
make the reference optional by setting this option to 0.

=head2 check-jira.unresolved [01]

By default, every issue referenced must be unresolved, i.e., it must
not have a resolution. You can relax this requirement by setting this
option to 0.

=head2 check-jira.by-assignee STRING

By default, the committer can reference any valid JIRA issue. Setting
this value to the name of an environment variable, the script will
check if its value is equal to the referenced JIRA issue's assignee.

=head2 check-jira.check-code CODESPEC

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

=head1 SEE ALSO

C<Git::More>

C<JIRA::Client>

=head1 REFERENCES

This script is heavily inspired (and sometimes derived) from Joyjit
Nath's git-jira-hook (L<https://github.com/joyjit/git-jira-hook>).
