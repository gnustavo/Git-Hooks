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
use Git::Hooks;
use File::Slurp;

my $HOOK = "check-acls";

#############
# Grok hook configuration, check it and set defaults.

my $Config = hook_config($HOOK);

# Userenv is a scalar and 'USER' is its default.
$Config->{userenv} //= ['USER'];
my $myself = $ENV{$Config->{userenv}[-1]}
    or die "$HOOK: opttion userenv environment variable ($Config->{userenv}[-1]) is not defined.\n";

# Admin is an array. We create an empty one if absent, to make it
# easier to check later on
$Config->{admin} //= [];

##########

sub grok_acls {
    my ($git) = @_;
    state $acls = do {
	my @acls;		# This will hold the ACL specs
	my $option = $Config->{acl} || [];
	foreach my $acl (@$option) {
	    push @acls, [split / /, $acl, 3];
	}
	\@acls;
    };
    return $acls;
}

sub grok_groups_spec {
    my ($git, $specs, $source) = @_;
    my %groups;
    foreach (@$specs) {
	s/\#.*//;		# strip comments
	next unless /\S/;	# skip blank lines
	/^\s*(\w+)\s*=\s*(.+?)\s*$/
	    or die "$HOOK: invalid line in '$source': $_\n";
	my ($groupname, $members) = ($1, $2);
	exists $groups{"\@$groupname"}
	    and die "$HOOK: redefinition of group ($groupname) in '$source': $_\n";
	foreach my $member (split / /, $members) {
	    if ($member =~ /^\@/) {
		# group member
		$groups{"\@$groupname"}{$member} = $groups{$member}
		    or die "HOOK: unknown group ($member) cited in '$source': $_\n";
	    } else {
		# user member
		$groups{"\@$groupname"}{$member} = undef;
	    }
	}
    }
    return \%groups;
}

sub grok_groups {
    my ($git) = @_;
    state $groups = do {
	my $option = $Config->{groups}
	    or die "$HOOK: you have to define the check-acls.groups option to use groups.\n";

	if (my ($groupfile) = ($option->[-1] =~ /^file:(.*)/)) {
	    my @groupspecs = read_file($groupfile);
	    defined $groupspecs[0]
		or die "$HOOK: can't open groups file ($groupfile): $!\n";
	    grok_groups_spec($git, \@groupspecs, $groupfile);
	} else {
	    my @groupspecs = split /\n/, $option->[-1];
	    grok_groups_spec($git, \@groupspecs, "$HOOK.groups");
	}
    };
    return $groups;
}

sub im_memberof {
    my ($git, $groupname) = @_;

    state $groups = grok_groups($git);

    return 0 unless exists $groups->{$groupname};

    my $group = $groups->{$groupname};
    return 1 if exists $group->{$myself};
    while (my ($member, $subgroup) = each %$group) {
	next     unless defined $subgroup;
	return 1 if     im_memberof($git, $member);
    }
    return 0;
}

sub match_user {
    my ($git, $spec) = @_;
    if ($spec =~ /^\^/) {
	return 1 if $myself =~ $spec;
    } elsif ($spec =~ /^@/) {
	return 1 if im_memberof($git, $spec);
    } else {
	return 1 if $myself eq $spec;
    }
    return 0;
}

sub match_ref {
    my ($ref, $spec) = @_;
    if ($spec =~ /^\^/) {
	return 1 if $ref =~ $spec;
    } else {
	return 1 if $ref eq $spec;
    }
    return 0;
}

sub im_admin {
    my ($git) = @_;
    state $i_am = do {
	my $match = 0;
	foreach my $admin (@{$Config->{admin}}) {
	    if (match_user($git, $admin)) {
		$match = 1;
		last;
	    }
	}
	$match;
    };
    return $i_am;
}

sub check_acls {
    my ($git, $ref, $old_commit, $new_commit) = @_;

    my $acls = grok_acls($git);

    # Grok which operation we're doing on this ref
    my $op;
    if      ($old_commit eq '0' x 40) {
	$op = 'C';		# create
    } elsif ($new_commit eq '0' x 40) {
	$op = 'D';		# delete
    } elsif ($ref !~ m:^refs/heads/:) {
	$op = 'R';		# rewrite a non-branch
    } else {
	# This is an U if "merge-base(old, new) == old". Otherwise it's an R.
	chomp(my $merge_base = $git->command('merge-base' => $old_commit, $new_commit));
	$op = ($merge_base eq $old_commit) ? 'U' : 'R';
    }

    foreach my $acl (@$acls) {
	my ($who, $what, $refspec) = @$acl;
	next unless match_user($git, $who);
	next unless match_ref($ref, $refspec);
	return if index($what, $op) != -1;
    }

    die "$HOOK: you ($myself) cannot change ($op) ref $ref.\n";
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return if im_admin($git);

    my $refs = $git->get_affected_refs();
    while (my ($refname, $ref) = each %$refs) {
	check_acls($git, $refname, @{$ref->{range}});
    }
}

# Install hooks
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=head1 SYNOPSIS

  check-acls.pl [--verbose] [--hook=update]      REF OLD_COMMIT NEW_COMMIT
  check-acls.pl [--verbose] [--hook=pre-receive]

=head1 DESCRIPTION

This script can act as one of two different Git hooks to guarantee
that only allowed users can push commits and tags to all or specific
branches.

To install it you must copy (or link) it to one of the two hook files
under C<.git/hooks> in your Git repository: C<pre-receive> and
C<update>. In this way, Git will call it with proper name and
arguments. For each hook it acts as follows:

=over

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

=item check-acls.userenv

When Git is performing its chores in the server to serve a push
request it's usually invoked via the SSH or a web service, which take
care of the authentication procedure. These services normally make the
autenticated user name available in an environment variable. You may
tell this hook which environment variabla it is by setting this option
to the variable's name. If not set, the hook will try to get the
user's name from the C<USER> environment variable and die if it's not
set.

=item check-acls.groups

You can define user groups in order to make it easier to configure
general acls. Use this option to tell where to find group
definitions in one of these ways:

=over

=item file:PATH/TO/FILE

As a text file named by PATH/TO/FILE, which may be absolute or
relative to the hooks current directory, which is usually the
repository's root in the server. It's sintax is very simple. Blank
lines are skipped. The hash (#) character starts a comment that goes
to the end of the current line. Group definitions are lines like this:

    groupname = userA userB @othergroupname userC

Each group must be defined in a single line. Spaces are significant
only between users and group references.

Note that a group can reference other groups by name. To make a group
reference, simple prefix its name with an at sign (@). Group
references must reference groups previously defined in the file.

=item GROUPS

If the option's value doesn't start with any of the above prefixes, it
must contain the group definitions itself.

=back

=item check-acls.admin

When this hook is installed, by default no user can change any
reference in the repository, unless she has an explicit allowance
given by one ACL (se the check-acls.acl option below). It may be
usefull to give full access to a group of admins who shouldn't be
subject to the ACL specifications. You may use one or more such
options to give admin access to a group of people. The value of each
option is interpreted in one of these ways:

=over

=item username

A C<username> specifying a single user. The username specification
must match "/^\w+$/i" and will be compared to the authenticated user's
name case sensitively.

=item @groupname

A C<groupname> specifying a single group. The groupname specification
must follow the same rules as the username above.

=item ^regex

A C<regex> which will be matched against the authenticated user's name
case-insensitively. The caret is part of the regex, meaning that it's
anchored at the start of the username.

=back

=item check-acls.acl

The authorization specification for a repository is defined by the set
of ACLs defined by this option. Each ACL specify 'who' has 'what' kind
of access to which refs, by means of a string with three components
separated by spaces:

    who what refname

By default, nobody has access to anything, except the above-specified
admins. During an update, all the ACLs matching the authenticated
user's name are checked to see if she has authorization to do what she
wants to specific branches and tags.

The 'who' component specifies to which users this ACL gives access. It
can be specified in the same three ways as was explained to the
check-acls.admin option above.

The 'what' component specifies what kind of access to allow. It's
specified as a string of one or more of the following opcodes:

=over

=item C

Create a new ref.

=item R

Rewind/Rebase an existing ref. (With commit loss.)

=item U

Update an existing ref. (A fast-forward with no commit loss.)

=item D

Delete an existing ref.

=back

The 'refname' component specifies which refs this ACL applies to. It
can be specified as the complete ref name (e.g. "refs/heads/master")
or by a regular expression starting with a caret (C<^>), which is kept
as part of the regexp.

=back

=head1 REFERENCES

This script is heavily inspired (and sometimes derived) from the
update-paranoid example hook which comes with the Git distribution
(L<https://github.com/gitster/git/blob/b12905140a8239ac687450ad43f18b5f0bcfb62e/contrib/hooks/update-paranoid>).

