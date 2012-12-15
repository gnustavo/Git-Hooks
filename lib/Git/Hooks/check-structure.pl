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

package Git::Hooks::CheckStructure;
# ABSTRACT: Git::Hooks plugin for ref/file structure validation.

use Git::Hooks qw/:DEFAULT :utils/;
use Data::Util qw(:check);
use File::Slurp;
use Error qw(:try);

my $HOOK = flatten_plugin_name(__PACKAGE__);

#############
# Grok hook configuration and set defaults.

my $Config = hook_config($HOOK);

##########

sub file_structure {
    return unless exists $Config->{file};
    $@ = undef;
    state $structure = eval { eval_gitconfig($Config->{file}[-1]) };
    die "$HOOK: $@\n" if $@;
    return $structure;
}

sub ref_structure {
    return unless exists $Config->{ref};
    $@ = undef;
    state $structure = eval { eval_gitconfig($Config->{ref}[-1]) };
    die "$HOOK: $@\n" if $@;
    return $structure;
}

sub check_structure {
    my ($structure, $path) = @_;

    @$path > 0 or die "$HOOK(check_structure): Internal error!";

    if (is_array_ref($structure)) {
	return (0, "syntax error: odd number of elements in structure spec, while checking")
	    unless scalar(@$structure) % 2 == 0;
	return (0, "the component ($path->[0]) should be a DIR in")
	    unless @$path > 1;
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
    } elsif (is_string($structure)) {
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
    } else {
	my $what = ref $structure;
	return (0, "syntax error: invalid reference to a $what in the structure spec, while checking");
    }
}

sub check_added_files {
    my ($files) = @_;
    my @errors;
    foreach my $file (sort keys %$files) {
	# Split the $file path in its components. We prefix $file with
	# a slash to make it look like an absolute path for
	# check_structure.
	my ($code, $error) = check_structure(file_structure(), [split '/', "/$file"]);
	push @errors, "$error: $file" if $code == 0;
    }
    return @errors;
}

sub check_ref {
    my ($git, $ref) = @_;

    my @errors;

    my ($old_commit, $new_commit) = get_affected_ref_range($ref);

    # Check names of newly created refs
    if (my $structure = ref_structure()) {
	if ($old_commit eq '0' x 40) {
	    check_structure($structure, [split '/', "/$ref"])
		or push @errors, "reference name '$ref' not allowed";
	}
    }

    # Check names of newly added files
    if (file_structure()) {
	push @errors, check_added_files($git->get_diff_files('--diff-filter=A', $old_commit, $new_commit));
    }

    die join("\n", "$HOOK: errors in ref '$ref' commits", @errors), "\n" if @errors;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return if im_admin();

    foreach my $ref (get_affected_refs()) {
	check_ref($git, $ref);
    }
}

# Install hooks
PRE_COMMIT {
    my ($git) = @_;

    my @errors = check_added_files($git->get_diff_files('--diff-filter=A', '--cached'));

    die join("\n", "$HOOK: errors in commit", @errors), "\n" if @errors;
};

UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;

__END__

=head1 NAME

check-structure.pl - Git::Hooks plugin for ref/file structure validation.

=head1 DESCRIPTION

This Git::Hooks plugin can act as any of the below hooks to check if
the files and references (branches and tags) added to the repository
are allowed by their structure specification. If they don't, the
commit/push is aborted.

=over

=item C<pre-commit>

This hook is invoked once in the local repository during a C<git
commit>. It checks if files being added comply with the file structure
definition.

=item C<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, checking if the references
and files being added to the repository comply with its structure
definition.

=item C<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
checking if the references and files being added to the repository
comply with its structure definition.

=back

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 check-structure.file STRUCTURE

This directive specifies the repository file structure, causing the
push to abort if it adds any file that does not comply.

The STRUCTURE argument must be a Perl data structure specifying the
file structure recursively as follows.

=over

=item ARRAY REF

An array ref specifies the contents of a directory. The referenced
array must contain a pair number of elements. Each pair consists of a
NAME_DEF and a STRUCTURE. The NAME_DEF specifies the name of the
component contained in the directory and the STRUCTURE specifies
recursively what it must be.

The NAME_DEF specifies a name in one of these ways:

=over

=item STRING

A string specifies the component name literally.

=item qr/REGEXP/

A regexp specifies the class of names that match it.

=item NUMBER

A number may be used as an else-clause. A positive number means that
any name not yet matched by the previous NAME DEFs must conform to the
associated STRUCTURE.

A negative number means that no name will do and signals an error. In
this case, if the STRUCTURE is a string it is used as a help message
which is sent back to the user.

=back

If no NAME_DEF matches the component being looked for, then it is a
structure violation and the hook fails.

=item STRING

A string must be one of 'FILE' and 'DIR', specifying what the
component must be a file or a directory, respectively.

=item NUMBER

A positive number simply tells that the component can be anything:
file or directory.

A negative number tells that any component is a structure violation
and the hook fails.

=back

You can specify the check-structure.file structure using either an
C<eval:> or a C<file:> prefixed value, because they have to be
evaluated as Perl expressions. The later is probably more convenient
for most cases.

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

    git config check-structure.file file:hooks/file-structure.def

=head2 check-structure.ref STRUCTURE

This directive specifies the repository ref structure, causing the
push to abort if it adds any reference (branch, tag, etc.) that does
not comply.

The STRUCTURE argument must be a Perl data structure specifying the
ref structure recursively in exactly the same way as was explained for
the C<check-structure.file> variable above. Consider that reference
names always begin with C<refs/>. Branches are kept under
C<refs/heads/>, tags under C<refs/tags>, remotes under
C<refs/remotes>, Gerrit branches under C<refs/for>, and so on.

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

    git config check-structure.ref file:hooks/ref-structure.def
