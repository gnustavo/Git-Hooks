#!/usr/bin/env perl

package Git::Hooks::CheckWhitespace;
# ABSTRACT: Git::Hooks plugin for checking whitespace errors

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Git::More;
use Text::Glob qw/glob_to_regex/;
use Error qw(:try);

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
        $old_commit = $Git::More::EMPTY_COMMIT if $old_commit eq $Git::More::UNDEF_COMMIT;
        $errors += try {
            # WHY SCALAR? Even though we aren't interested in the command
            # output we can't invoke Git::command in void context. I don't
            # know why, but in void context it doesn't throw an exception
            # when the command fails. So, we force it to be invoked in
            # scalar context.
            scalar $git->command(
                [qw/diff-tree -r --check/, $old_commit, $new_commit],
                {STDERR => 0},
            );
            return 0;
        } otherwise {
            my $error = shift;
            $git->error($PKG, "whitespace errors in the changed files in $ref", $error->cmd_output());
            return 1;
        };
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    return try {
        # See WHY SCALAR? above.
        scalar $git->command(
            [qw/diff-index --check --cached/, $git->get_head_or_empty_tree()],
            {STDERR => 0},
        );
    } otherwise {
        my $error = shift;
        $git->error($PKG, 'whitespace errors in the changed files', $error->cmd_output());
        return;
    };
}

sub check_patchset {
    my ($git, $opts) = @_;

    return 1 if im_admin($git);

    return try {
        # See WHY SCALAR? above.
        scalar $git->command(
            [qw/diff-tree -r -m --check/, $opts->{'--commit'}],
            {STDERR => 0},
        );
    } otherwise {
        my $error = shift;
        $git->error($PKG, 'whitespace errors in the changed files', $error->cmd_output());
        return;
    };
}

# Install hooks
PRE_COMMIT       \&check_commit;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;

1;

__END__
=for Pod::Coverage check_affected_refs check_commit check_patchset

=head1 NAME

CheckWhitespace - Git::Hooks plugin for checking whitespace errors

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to check if the
contents of files added to or modified in the repository have whitespace
errors as detected by C<git diff --check> command. If they don't, the
commit/push is aborted.

=over

=item * B<pre-commit>

=item * B<update>

=item * B<pre-receive>

=item * B<ref-update>

=item * B<patchset-created>

=item * B<draft-published>

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckWhitespace

=head1 CONFIGURATION

There's no configuration needed or provided.
