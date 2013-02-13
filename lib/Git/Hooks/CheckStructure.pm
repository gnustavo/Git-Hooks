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

package Git::Hooks::CheckStructure;
# ABSTRACT: Git::Hooks plugin for ref/file structure validation.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Data::Util qw(:check);
use File::Slurp;
use Error qw(:try);

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

##########

sub get_structure {
    my ($git, $what) = @_;

    if (my $value = $git->get_config($CFG => $what)) {
        local $@ = undef;
        my $structure = eval {eval_gitconfig($value)};
        die "$PKG: $@\n" if $@;
        return $structure;
    } else {
        return;
    }
}

sub check_array_structure {
    my ($structure, $path) = @_;

    return (0, "syntax error: odd number of elements in structure spec, while checking")
        unless scalar(@$structure) % 2 == 0;
    return (0, "the component ($path->[0]) should be a DIR in")
        if @$path < 2;
    shift @$path;
    # Return ok if the directory doesn't have subcomponents.
    return (1) if @$path == 1 && length($path->[0]) == 0;

    for (my $s=0; $s<$#$structure; $s+=2) {
        my ($lhs, $rhs) = @{$structure}[$s, $s+1];
        if (is_string($lhs)) {
            if ($path->[0] eq $lhs) {
                return check_structure($rhs, $path);
            } elsif (is_integer($lhs)) {
                if ($lhs) {
                    return check_structure($rhs, $path);
                } elsif (is_string($rhs)) {
                    return (0, "$rhs, while checking");
                } else {
                    return (0, "syntax error: the right hand side of a number must be a string, while checking");
                }
            }
            # next
        } elsif (is_rx($lhs)) {
            if ($path->[0] =~ $lhs) {
                return check_structure($rhs, $path);
            }
            # next
        } else {
            my $what = ref $lhs;
            return (0, "syntax error: the left hand side of arrays in the structure spec must be scalars or qr/Regexes/, not $what, while checking");
        }
    }
    return (0, "the component ($path->[0]) is not allowed in");
}

sub check_string_structure {
    my ($structure, $path) = @_;

    if ($structure eq 'DIR') {
        return (1) if @$path > 1;
        return (0, "the component '$path->[0]' should be a DIR in");
    } elsif ($structure eq 'FILE') {
        return (0, "the component '$path->[0]' should be a FILE in") if @$path > 1;
        return (1);
    } elsif (is_integer($structure)) {
        return (1) if $structure;
        return (0, "invalid component '$path->[0]'");
    } else {
        return (0, "syntax error: unknown string spec '$structure', while checking");
    }
    return (0, "the component ($path->[0]) is not allowed in");
}

sub check_structure {
    my ($structure, $path) = @_;

    @$path > 0 or die "$PKG(check_structure): Internal error!\n";

    if (is_array_ref($structure)) {
        return check_array_structure($structure, $path);
    } elsif (is_string($structure)) {
        return check_string_structure($structure, $path);
    } else {
        my $what = ref $structure;
        return (0, "syntax error: invalid reference to a $what in the structure spec, while checking");
    }
}

sub check_added_files {
    my ($git, $files) = @_;

    my $errors = 0;

    foreach my $file (sort keys %$files) {
        # Split the $file path in its components. We prefix $file with
        # a slash to make it look like an absolute path for
        # check_structure.
        my ($code, $error) = check_structure(get_structure($git, 'file'), [split '/', "/$file"]);
        unless ($code) {
            $git->error($PKG, "$error: $file\n");
            $errors++;
        }
    }

    return $errors == 0;
}

sub check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    my $errors = 0;

    # Check names of newly created refs
    if (my $structure = get_structure($git, 'ref')) {
        if ($old_commit eq '0' x 40) {
            check_structure($structure, [split '/', "/$ref"])
                or $git->error($PKG, "reference name '$ref' not allowed\n")
                    and $errors++;
        }
    }

    # Check names of newly added files
    if (get_structure($git, 'file')) {
        check_added_files($git, $git->get_diff_files('--diff-filter=A', $old_commit, $new_commit))
            or $errors++;
    }

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref)
            or $errors++;
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    return check_added_files($git, $git->get_diff_files('--diff-filter=A', '--cached'));
}

# Install hooks
PRE_COMMIT       \&check_commit;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_commit;

1;

__END__
=for Pod::Coverage check_added_files check_ref get_structure check_array_structure check_string_structure

=head1 NAME

CheckStructure - Git::Hooks plugin for ref/file structure validation.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to check if the
files and references (branches and tags) added to the repository are
allowed by their structure specification. If they don't, the
commit/push is aborted.

=over

=item * B<pre-commit>

This hook is invoked once in the local repository during a C<git
commit>. It checks if files being added comply with the file structure
definition.

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, checking if the references
and files being added to the repository comply with its structure
definition.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
checking if the references and files being added to the repository
comply with its structure definition.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review, to check if the references and files being added to the
repository comply with its structure definition.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*), to check if the references
and files being added to the repository comply with its structure
definition.

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckStructure

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkstructure.file STRUCTURE

This directive specifies the repository file structure, causing the
push to abort if it adds any file that does not comply.

The STRUCTURE argument must be a Perl data structure specifying the
file structure recursively as follows.

=over

=item * B<ARRAY REF>

An array ref specifies the contents of a directory. The referenced
array must contain a pair number of elements. Each pair consists of a
NAME_DEF and a STRUCTURE. The NAME_DEF specifies the name of the
component contained in the directory and the STRUCTURE specifies
recursively what it must be.

The NAME_DEF specifies a name in one of these ways:

=over

=item * B<STRING>

A string specifies the component name literally.

=item * B<qr/REGEXP/>

A regexp specifies the class of names that match it.

=item * B<NUMBER>

A number may be used as an else-clause. A positive number means that
any name not yet matched by the previous NAME DEFs must conform to the
associated STRUCTURE.

A negative number means that no name will do and signals an error. In
this case, if the STRUCTURE is a string it is used as a help message
which is sent back to the user.

=back

If no NAME_DEF matches the component being looked for, then it is a
structure violation and the hook fails.

=item * B<STRING>

A string must be one of 'FILE' and 'DIR', specifying what the
component must be a file or a directory, respectively.

=item * B<NUMBER>

A positive number simply tells that the component can be anything:
file or directory.

A negative number tells that any component is a structure violation
and the hook fails.

=back

You can specify the githooks.checkstructure.file structure using
either an C<eval:> or a C<file:> prefixed value, because they have to
be evaluated as Perl expressions. The later is probably more
convenient for most cases.

Let's see an example to make things clearer. Suppose the code below is
in a file called C<hooks/file-structure.def> under the repository
directory.

        my $perl_standard_files = qr/^(Changes|dist\.ini|Makefile.PL|README)$/;

        [
            '.gitignore'         => 'FILE',
            $perl_standard_files => 'FILE',
            lib                  => [
                qr/\.pm$/        => 'FILE',
                1                => 'DIR',
            ],
            't'                  => [
                qr/\.t$/         => 'FILE',
            ],
        ];

Note that the last expression in the file is an array ref which
specifies the repository file structure. It has four name/value
pairs. The first one admits a file called literally C<.gitignore> at
the repository's root. The second admits a bunch of files commonly
present in Perl module distributions, which names are specified by
means of a regular expression. The third specifies that there might be
a directory called C<lib> at the repository's root, which may contain
only C<.pm> files and sub-directories under it. The fourth specifies
that there might be a C<t> directory, under which only <.t> files are
admitted. No other file or directory is admitted at the repository's
root.

In order to make the plugin read the specification from the file,
configure it like this:

    git config githooks.checkstructure.file file:hooks/file-structure.def

=head2 githooks.checkstructure.ref STRUCTURE

This directive specifies the repository ref structure, causing the
push to abort if it adds any reference (branch, tag, etc.) that does
not comply.

The STRUCTURE argument must be a Perl data structure specifying the
ref structure recursively in exactly the same way as was explained for
the C<githooks.checkstructure.file> variable above. Consider that reference
names always begin with C<refs/>. Branches are kept under
C<refs/heads/>, tags under C<refs/tags>, remotes under
C<refs/remotes>, and so on.

Let's see an example to make things clearer. Suppose the code below is
in a file called C<hooks/ref-structure.def> under the repository
directory.

    my $version = qr/\d+\.\d+\.\d+(?:-[a-z_]+(?:\.\d+)?)?/;

    [
        refs => [
            heads => [
                qr/feature-.*/ => 'FILE',
                qr/release-.*/ => 'FILE',
                dev            => 'DIR',
            ],
            tags  => [
                qr/^v${version}$/ => 'FILE',
                qr/^build-\d+$/   => 'FILE',
            ],
        ],
    ];

The last expression in the file is an array ref which specifies the
reference structure. In this case, it is very strict about which names
are allowed for branches and tags. Branch names must begin with
C<feature-> or C<release->. The C<refs/heads/dev/> "directory" is
probably a place for developers to create personal branches
freely. There can be two kinds of tag names. The first one is for
version tags and the second for tags generated by the build system.

Note that the plugin only checks references created during a push
command. You don't need to explicitly allow for the C<master> branch,
because it is created during the init command. You also don't have to
be concerned with the C<refs/remotes> references, because they aren't
used in the remote repository of a push.

In order to make the plugin read the specification from the file,
configure it like this:

    git config githooks.checkstructure.ref file:hooks/ref-structure.def

=head1 EXPORTS

This module exports two routines that can be used directly without
using all of Git::Hooks infrastructure.

=head2 check_affected_refs GIT

This is the routine used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head2 check_commit GIT

This is the routine used to implement the C<pre-commit>. It needs a
C<Git::More> object.

=head2 check_structure STRUCTURE, PATH

This is the main routine of the hook. It gets (usually) an array-ref
specifying the repository STRUCTURE and a PATH to check against it. It
returns a tuple, the first value of which is a boolean telling if the
check was successful or not. The second value is an error message, in
case the check failed.
