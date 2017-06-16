#!/usr/bin/env perl

package Git::Hooks::CheckWhitespace;
# ABSTRACT: Git::Hooks plugin for checking whitespace errors

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks;
use Text::Glob qw/glob_to_regex/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
        my $cmd = $git->command(
            qw/diff-tree -r --check/,
            $old_commit eq $git->undef_commit ? $git->empty_tree : $old_commit,
            $new_commit,
        );
        my $stderr = do { local $/ = undef; readline($cmd->stderr)};
        $cmd->close;
        if ($cmd->exit() != 0) {
            $git->error($PKG, "whitespace errors in the changed files in $ref", $stderr);
            ++$errors;
        };
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    my $cmd = $git->command(qw/diff-index --check --cached/, $git->get_head_or_empty_tree());
    my $stderr = do { local $/ = undef; readline($cmd->stderr)};
    $cmd->close;
    if ($cmd->exit() == 0) {
        return 1;
    } else {
        $git->error($PKG, 'whitespace errors in the changed files', $stderr);
        return 0;
    };
}

sub check_patchset {
    my ($git, $opts) = @_;

    return 1 if $git->im_admin();

    my $cmd = $git->command(qw/diff-tree -r -m --check/, $opts->{'--commit'});
    my $stderr = do { local $/ = undef; readline($cmd->stderr)};
    $cmd->close;
    if ($cmd->exit() == 0) {
        return 1;
    } else {
        $git->error($PKG, 'whitespace errors in the changed files', $stderr);
        return 0;
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

This L<Git::Hooks> plugin hooks itself to the hooks below to check if the
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
