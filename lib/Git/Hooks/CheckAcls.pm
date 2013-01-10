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

package Git::Hooks::CheckAcls;
# ABSTRACT: Git::Hooks plugin for branch/tag access control.

use 5.010;
use utf8;
use strict;
use warnings;
use File::Slurp;
use Error qw(:try);
use Git::Hooks qw/:DEFAULT :utils/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

##########

sub grok_acls {
    my ($git) = @_;

    my @acls;                   # This will hold the ACL specs

    foreach my $acl ($git->get_config($CFG => 'acl')) {
        # Interpolate environment variables embedded as "{VAR}".
        $acl =~ s/{(\w+)}/$ENV{$1}/ige;
        push @acls, [split / /, $acl, 3];
    }

    return @acls;
}

sub match_ref {
    my ($ref, $spec) = @_;

    if ($spec =~ /^\^/) {
        return 1 if $ref =~ $spec;
    } elsif ($spec =~ /^!(.*)/) {
        return 1 if $ref !~ $1;
    } else {
        return 1 if $ref eq $spec;
    }
    return 0;
}

sub check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # Grok which operation we're doing on this ref
    my $op;
    if      ($old_commit eq '0' x 40) {
        $op = 'C';              # create
    } elsif ($new_commit eq '0' x 40) {
        $op = 'D';              # delete
    } elsif ($ref !~ m:^refs/heads/:) {
        $op = 'R';              # rewrite a non-branch
    } else {
        # This is an U if "merge-base(old, new) == old". Otherwise it's an R.
        $op = eval { ($git->merge_base({}, $old_commit, $new_commit))[0] eq $old_commit ? 'U' : 'R' };
        $op = 'R' unless defined $op; # Probably $old_commit and $new_commit do not have a common ancestor.
    }

    foreach my $acl (grok_acls($git)) {
        my ($who, $what, $refspec) = @$acl;
        next unless match_user($git, $who);
        next unless match_ref($ref, $refspec);
        $what =~ /[^CRUD-]/ and die "$PKG: invalid acl 'what' component ($what).\n";
        return if index($what, $op) != -1;
    }

    # Assign meaningful names to op codes.
    my %op = (
        C => 'create',
        R => 'rewind/rebase',
        U => 'update',
        D => 'delete',
    );

    my $myself = $git->authenticated_user();

    die "$PKG: you ($myself) cannot $op{$op} ref $ref.\n";
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return if im_admin($git);

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref);
    }

    return;
}

# Install hooks
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=for Pod::Coverage check_ref grok_acls match_ref

=head1 NAME

Git::Hooks::CheckAcls - Git::Hooks plugin for branch/tag access control.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to guarantee
that only allowed users can push commits and tags to specific
branches.

=over

=item C<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, checking if the user
performing the push can update the branch in question.

=item C<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
checking if the user performing the push can update every affected
branch.

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckAcls

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkacls.userenv STRING

This variable is deprecated. Please, use the C<githooks.userenv>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 githooks.checkacls.admin USERSPEC

This variable is deprecated. Please, use the C<githooks.admin>
variable, which is defined in the Git::Hooks module. Please, see its
documentation to understand it.

=head2 githooks.checkacls.acl ACL

The authorization specification for a repository is defined by the set
of ACLs defined by this option. Each ACL specify 'who' has 'what' kind
of access to which refs, by means of a string with three components
separated by spaces:

    who what refs

By default, nobody has access to anything, except the above-specified
admins. During an update, all the ACLs are processed in the order
defined by the C<git config --list> command. The first ACL matching
the authenticated username and the affected reference name (usually a
branch) defines what operations are allowed. If no ACL matches
username and reference name, then the operation is denied.

The 'who' component specifies to which users this ACL gives access. It
can be specified in the same three ways as was explained to the
CheckAcls.admin option above.

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

You may specify that the user has B<no> access whatsoever to the
references by using a single hyphen (C<->) as the what component.

The 'refs' component specifies which refs this ACL applies to. It can
be specified in one of these formats:

=over

=item ^REGEXP

A regular expression anchored at the beginning of the reference name.
For example, "^refs/heads", meaning every branch.

=item !REGEXP

A negated regular expression. For example, "!^refs/heads/master",
meaning everything but the master branch.

=item STRING

The complete name of a reference. For example, "refs/heads/master".

=back

The ACL specification can embed strings in the format C<{VAR}>. These
strings are substituted by the corresponding environment's variable
VAR value. This interpolation occurs before the components are split
and processed.

This is useful, for instance, if you want developers to be restricted
in what they can do to official branches but to have complete control
with their own branch namespace.

    git config CheckAcls.acl '^. CRUD ^refs/heads/{USER}/'
    git config CheckAcls.acl '^. U    ^refs/heads'

In this example, every user (^.) has complete control (CRUD) to the
branches below "refs/heads/{USER}". Supposing the environment variable
USER contains the user's login name during a "pre-receive" hook. For
all other branches (^refs/heads) the users have only update (U) rights.

=head1 EXPORTS

This module exports two routines that can be used directly without
using all of Git::Hooks infrastructure.

=head2 check_affected_refs GIT

This is the routine used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head1 REFERENCES

This script is heavily inspired (and, in some places, derived) from
the update-paranoid example hook which comes with the Git distribution
(L<https://github.com/gitster/git/blob/b12905140a8239ac687450ad43f18b5f0bcfb62e/contrib/hooks/update-paranoid>).
