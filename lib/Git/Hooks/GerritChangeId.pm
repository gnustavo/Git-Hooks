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

package Git::Hooks::GerritChangeId;
# ABSTRACT: Git::Hooks plugin to insert a Change-Id in a commit message.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use File::Slurp;
use File::Temp qw/tempfile/;
use Error qw(:try);

(my $HOOK = __PACKAGE__) =~ s/.*:://;

#############
# Grok hook configuration, check it and set defaults.

my $Config = hook_config($HOOK);

##########

sub clean_message {
    my ($msg) = @_;

    # strip comment lines
    $msg =~ s/^#.*\n?//mg;

    # strip Signed-of-by lines
    $msg =~ s/^Signed-off-by:.*\n?//img;

    # strip trailing whitespace from all lines
    $msg =~ s/\s+$//mg;

    # collapse multiple consecutive empty lines
    $msg =~ s/\n{3,}/\n\n/sg;

    # remove empty lines from the begining
    $msg =~ s/^\n+//;

    return '' unless length $msg;

    # remove empty lines from the end
    $msg =~ s/\n{2,}$/\n/;

    return $msg;
}

sub gen_change_id {
    my ($git, $msg) = @_;

    my ($fh, $filename) = tempfile(undef, UNLINK => 1);

    foreach my $info (
        [ tree      => [qw/write-tree/] ],
        [ parent    => [qw/rev-parse HEAD^0/] ],
        [ author    => [qw/var GIT_AUTHOR_IDENT/] ],
        [ committer => [qw/var GIT_COMMITTER_IDENT/] ],
    ) {
        try {
            $fh->print($info->[0], ' ', $git->command($info->[1], {STDERR => 0}), "\n");
        } otherwise {
            # Can't find info. That's ok.
        };
    }

    $fh->print("\n", $msg);
    $fh->close();

    return $git->hash_object(commit => $filename);
}

sub insert_change_id {
    my ($git, $msg) = @_;

    # Strip the patch data from the message.
    $msg =~ s:^diff --git a/.*::ms;

    # Does Change-Id: already exist? if so, exit (no change).
    return if $msg =~ /^Change-id:/im;

    # If the message is just blank space, exit.
    my $clean_msg = clean_message($msg);
    return unless length $clean_msg;

    # strip comment lines
    $msg =~ s/^#.*\n?//mg;

    # Split $msg in interleaved blocks of text and empty-lines
    my @blocks = split /(?<=\n)(\n+)/s, $msg;

    # strip a possible trailing empty line
    pop @blocks if $blocks[-1] =~ /^\n+$/;

    # Check if the last block is a footer
    my $has_footer;
    if (@blocks < 2) {
        $has_footer = 0;
    } else {
        $has_footer = 1;
        my $in_footer_comment = 0;
        foreach (split /^/m, $blocks[-1]) {
            if ($in_footer_comment) {
                $in_footer_comment = 0 if /\]$/;
            } elsif (/^\[[\w-]+:/i) {
                $in_footer_comment = 1;
            } elsif (! /^[\w-]+:/i) {
                $has_footer = 0;
                last;
            }
        }
    }

    # Build the Change-Id line.
    my $change_id = 'Change-Id: I' . gen_change_id($git, $clean_msg) . "\n";

    if ($has_footer) {
	# Try to insert the change-id line after leading Bug|Issue
	# lines in the footer.
	my $inserted = 0;
        my $where = 0;
	while ($blocks[-1] =~ /^([\w-]+?):.*/gim) {
            if ($1 =~ /^Bug|Issue$/i) {
                $where = pos($blocks[-1]);
            } else {
                substr $blocks[-1], $where, 0, $change_id;
                $inserted = 1;
                last;
            }
	}
	$blocks[-1] .= $change_id unless $inserted;
    } else {
	# Write the change-id in a new footer
	push @blocks, "\n$change_id";
    }

    return join('', @blocks);
};

sub rewrite_message {
    my ($git, $commit_msg_file) = @_;

    my $msg = read_file($commit_msg_file);
    defined $msg or die "$HOOK: Can't open file '$commit_msg_file' for reading: $!\n";

    my $new_msg = insert_change_id($git, $msg);

    # Rewrite the message file
    write_file($commit_msg_file, $new_msg)
	if defined $new_msg && $new_msg ne $msg;

    return;
}

# Install hooks
COMMIT_MSG \&rewrite_message;

1;


__END__
=for Pod::Coverage clean_message gen_change_id insert_change_id

=head1 NAME

Git::Hooks::GerritChangeId - Git::Hooks plugin to insert a Change-Id in a commit message.

=head1 DESCRIPTION

This Git::Hooks plugin is a reimplementation of Gerrit's official
commit-msg hook for inserting change-ids in git commit messages. (What
follows is a partial copy of that document's DESCRIPTION section.)

This plugin automatically inserts a globally unique Change-Id tag in
the footer of a commit message. When present, Gerrit uses this tag to
track commits across cherry-picks and rebases.

After the hook has been installed in the user's local Git repository
for a project, the hook will modify a commit message such as:

    Improve foo widget by attaching a bar.
    
    We want a bar, because it improves the foo by providing more
    wizbangery to the dowhatimeanery.
    
    Signed-off-by: A. U. Thor <author@example.com>

by inserting a new C<Change-Id: > line in the footer:

    Improve foo widget by attaching a bar.
    
    We want a bar, because it improves the foo by providing more
    wizbangery to the dowhatimeanery.
    
    Change-Id: Ic8aaa0728a43936cd4c6e1ed590e01ba8f0fbf5b
    Signed-off-by: A. U. Thor <author@example.com>

The hook implementation is reasonably intelligent at inserting the
Change-Id line before any Signed-off-by or Acked-by lines placed at
the end of the commit message by the author, but if no such lines are
present then it will just insert a blank line, and add the Change-Id
at the bottom of the message.

If a Change-Id line is already present in the message footer, the
script will do nothing, leaving the existing Change-Id
unmodified. This permits amending an existing commit, or allows the
user to insert the Change-Id manually after copying it from an
existing change viewed on the web.

To enable the plugin you should define the appropriate Git
configuration option like this:

    git config --add githooks.commit-msg  GerritChangeId

=head1 CONFIGURATION

There's no configuration needed or provided.

=head1 EXPORTS

This module exports one routine that can be used directly without
using all of Git::Hooks infrastructure.

=head2 rewrite_message GIT, MSGFILE

This is the routine used to implement the C<commit-msg> hook. It needs
a C<Git::More> object and the name of a file containing the commit
message.

=head1 REFERENCES

Gerrit's Home Page: L<http://gerrit.googlecode.com/>

Gerrit's official commit-msg hook: L<https://gerrit.googlesource.com/gerrit/+/master/gerrit-server/src/main/resources/com/google/gerrit/server/tools/root/hooks/commit-msg>

Gerrit's official hook documentation: L<https://gerrit.googlesource.com/gerrit/+/master/Documentation/cmd-hook-commit-msg.txt>
