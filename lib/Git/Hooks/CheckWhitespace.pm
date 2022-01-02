use warnings;

package Git::Hooks::CheckWhitespace;
# ABSTRACT: Git::Hooks plugin for checking whitespace errors

use v5.16.0;
use utf8;
use Log::Any '$log';
use Git::Hooks;

my $CFG = __PACKAGE__ =~ s/.*::/githooks./r;

# This routine can act both as an update or a pre-receive hook.
sub check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # If the reference is being deleted we have nothing to check
    next if $new_commit eq $git->undef_commit;

    # If the reference is being created we have to calculate a proper
    # $old_commit to diff against.
    if ($old_commit eq $git->undef_commit) {
        my $last_log;
        my $log_iterator = $git->log($new_commit, qw/--not --all/);
        while (my $log = $log_iterator->next()) {
            $last_log = $log;
        }
        next unless $last_log;
        my @parents = $last_log->parent;
        if (@parents == 0) {
            # We reached the repository root. Hence, let's consider
            # $old_commit to be the empty tree.
            $old_commit = $git->empty_tree;
        } elsif (@parents == 1) {
            # We reached the first new commit and it's a normal commit. So,
            # let's consider $old_commit to be its parent.
            $old_commit = $parents[0];
        } else {
            # We reached the first new commit and it's a merge commit. So,
            # let's consider $old_commit to be this commit, disregarding
            # only the eventual conflict resolutions.
            $old_commit = $last_log->commit;
        }
    }

    my $output = $git->run(
        {fatal => [-129, -128]},
        qw/diff-tree -r --check/,
        $old_commit eq $git->undef_commit ? $git->empty_tree : $old_commit,
        $new_commit);
    if ($? != 0) {
        $git->fault(<<'EOS', {ref => $ref, details => $output});
There are extra whitespaces in the changed files in the reference.
Please, remove them and amend your commit.
EOS
        return 1;
    };

    return 0;
}

sub check_commit {
    my ($git) = @_;

    my $output = $git->run(
        {fatal => [-129, -128]},
        qw/diff-index --check --cached/, $git->get_head_or_empty_tree());
    if ($? == 0) {
        return 1;
    } else {
        $git->fault(<<'EOS', {details => $output});
There are extra whitespaces in the changed files.
Please, remove them and amend your commit.
EOS
        return 0;
    };
}

sub check_patchset {
    my ($git, $branch, $commit) = @_;

    my $output = $git->run(
        {fatal => [-129, -128]},
        qw/diff-tree -r -m --check/, $commit->commit);
    if ($? == 0) {
        return 1;
    } else {
        $git->fault(<<'EOS', {commit => $commit->commit, details => $output});
There are extra whitespaces in the changed files.
Please, remove them and amend your commit.
EOS
        return 0;
    };
}

# Install hooks
GITHOOKS_CHECK_AFFECTED_REFS(\&check_ref);
GITHOOKS_CHECK_PRE_COMMIT(\&check_commit);
GITHOOKS_CHECK_PATCHSET(\&check_patchset);

1;

__END__
=for Pod::Coverage check_commit check_patchset check_ref

=head1 NAME

CheckWhitespace - Git::Hooks plugin for checking whitespace errors

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckWhitespace

    # These users are exempt from all checks
    admin = joe molly

The first section enables the plugin and defines the users C<joe> and C<molly>
as administrators, effectively exempting them from any restrictions the plugin
may impose.

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to check if the
contents of files added to or modified in the repository have whitespace
errors as detected by C<git diff --check> command. If they don't, the
commit/push is aborted.

=over

=item * B<pre-applypatch>

=item * B<pre-commit>

=item * B<update>

=item * B<pre-receive>

=item * B<ref-update>

=item * B<patchset-created>

=item * B<draft-published>

=back

To enable it you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckWhitespace

=head1 CONFIGURATION

There's no specific configuration for this plugin.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

