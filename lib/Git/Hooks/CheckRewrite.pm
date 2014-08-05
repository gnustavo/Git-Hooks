#!/usr/bin/env perl

package Git::Hooks::CheckRewrite;
# ABSTRACT: Git::Hooks plugin for checking against unsafe rewrites

use 5.010;
use utf8;
use strict;
use warnings;
use Error qw(:try);
use File::Slurp;
use File::Spec::Functions qw/catfile/;
use Git::Hooks qw/:DEFAULT :utils/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

##########

# Returns the name of a file where we record information about a
# commit that has to be shared between the pre- and post-commit hooks.
sub _record_filename {
    my ($git) = @_;

    return catfile($git->repo_path(), 'GITHOOKS_CHECKREWRITE');
}

# Returns all branches containing a specific commit. The command "git
# branch" returns the branch names prefixed with two characters, which
# we have to get rid of using substr.
sub _branches_containing {
    my ($git, $commit) = @_;
    return map { substr($_, 2) } $git->command('branch', '-a', '--contains', $commit);
}

sub record_commit_parents {
    my ($git) = @_;

    # Here we record the HEAD commit's own id and it's parent's ids in
    # a file under the git directory. The file has two lines in this
    # format:

    # commit SHA1
    # SHA1 SHA1 ...

    # The first line holds the HEAD commit's id and the second the ids
    # of its parents.

    write_file(_record_filename($git),
               scalar($git->command(qw/rev-list --pretty=format:%P -n 1 HEAD/)));

    return 1;
}

sub check_commit_amend {
    my ($git) = @_;

    my $record_file = _record_filename($git);

    -r $record_file
        or $git->error($PKG, "Can't read $record_file. You probably forgot to symlink the pre-commit hook.\n")
            and return 0;

    my ($old_commit, $old_parents) = read_file($record_file);

    chomp $old_commit;
    $old_commit =~ s/^commit\s+//;

    if (defined $old_parents) {
        chomp $old_parents;
    } else {
        # the repo's first commit has no parents.
        $old_parents = '';
    }

    my $new_parents = ($git->command(qw/rev-list --pretty=format:%P -n 1 HEAD/))[1];

    return 1 if $new_parents ne $old_parents;

    # Find all branches containing $old_commit
    my @branches = _branches_containing($git, $old_commit);

    if (@branches > 0) {
        # $old_commit is reachable by at least one branch, which means
        # the amend was unsafe.
        my $branches = join "\n    ", @branches;
        $git->error($PKG, <<"EOF");

You've just performed un unsafe "git commit --amend" because your
original HEAD ($old_commit) is still reachable by the following
branch(es):

    $branches

Consider amending it again:

    git commit --amend      # to amend it

EOF
        return 0;
    }

    return 1;
}

sub check_rebase {
    my ($git, $upstream, $branch) = @_;

    unless (defined $branch) {
        # This means we're rebasing the current branch. We try to grok
        # it's name using git symbolic-ref.
        try {
            chomp($branch = $git->command(qw/symbolic-ref -q HEAD/));
        } otherwise {
            # The command git symbolic-ref fails if we're in a
            # detached HEAD. In this situation we don't care about the
            # rewriting.
            return 1;
        };
    }

    # Find the base commit of the rebased sequence
    my $base_commit = $git->command_oneline('rev-list', '--topo-order', '--reverse', "$upstream..$branch");

    # If $upstream is a decendant of $branch, $base_commit is
    # empty. In this situation the rebase will turn out to be a simple
    # fast-forward merge from $branch on $upstream and there is
    # nothing to lose.
    return 1 unless $base_commit;

    # Find all branches containing that commit
    my @branches = _branches_containing($git, $base_commit);

    if (@branches > 1) {
        # The base commit is reachable by more than one branch, which
        # means the rewrite is unsafe.
        my $branches = join("\n    ", grep {$_ ne $branch} @branches);
        $git->error($PKG, <<"EOF");
This is an unsafe rebase because it would rewrite commits shared by
$branch and the following other branch(es):

    $branches
EOF
        return 0;
    }

    return 1;
}

# Install hooks
PRE_COMMIT  \&record_commit_parents;
POST_COMMIT \&check_commit_amend;
PRE_REBASE  \&check_rebase;

1;


__END__
=head1 NAME

Git::Hooks::CheckRewrite - Git::Hooks plugin for checking against unsafe rewrites

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the B<pre-rebase> hook to
guarantee that it is safe in the sense that no rewritten commit is
reachable by other branch than the one being rebased.

It also hooks itself to the B<pre-commit> and the B<post-commit> hooks
to detect unsafe B<git commit --amend> commands after the fact. An
amend is unsafe if the original commit is still reachable by any
branch after being amended. Unfortunately B<git> still does not
provide a way to detect unsafe amends before committing them.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckRewrite

=head1 CONFIGURATION

There's no configuration needed or provided.

=head1 EXPORTS

This module exports the following routines that can be used directly
without using all of Git::Hooks infrastructure.

=head2 record_commit_parents GIT

This is the routine used to implement the C<pre-commit> hook. It needs
a C<Git::More> object. It simply record the original commit id and its
parents in a file called C<GITHOOKS_CHECKREWRITE> inside the git
repository directory

=head2 check_commit_amend GIT

This is the routine used to implement the C<post-commit> hook. It
needs a C<Git::More> object. It reads the original commit id and its
parents from a file called C<GITHOOKS_CHECKREWRITE> inside the git
repository directory, which must have been created by the
C<record_commit_parents> routine during the C<pre-commit> hook. Using
this information it detects if this was an unsafe amend and tells the
user so.

=head2 check_rebase GIT, UPSTREAM [, BRANCH]

This is the routine used to implement the C<pre-rebase> hook. It needs
a B<Git::More> object, the name of the upstream branch onto which
we're rebasing and the name of the branch being rebased. (If BRANCH is
undefined it means that we're rebasing the current branch.

The routine dies with a suitable message if it detects that it will be
an unsafe rebase.

=head1 REFERENCES

Here are some references about what it means for a rewrite to be
unsafe and how to go about detecting them in git:

=over

=item * L<http://git.661346.n2.nabble.com/pre-rebase-safety-hook-td1614613.html>

=item * L<http://git.apache.org/xmlbeans.git/hooks/pre-rebase.sample>

=item * L<http://www.mentby.com/Group/git/rfc-pre-rebase-refuse-to-rewrite-commits-that-are-reachable-from-upstream.html>

=item * L<http://git.661346.n2.nabble.com/RFD-Rewriting-safety-warn-before-when-rewriting-published-history-td7254708.html>

=back
