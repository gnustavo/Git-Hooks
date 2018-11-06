use strict;
use warnings;

package Git::Hooks::CheckRewrite;
# ABSTRACT: Git::Hooks plugin for checking against unsafe rewrites

use 5.010;
use utf8;
use Path::Tiny;
use Log::Any '$log';
use Git::Hooks;

(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

##########

# Returns a Path::Tiny object represeting the name of a file where we record
# information about a commit that has to be shared between the pre- and
# post-commit hooks.
sub _record_filename {
    my ($git) = @_;

    return path($git->git_dir())->child('GITHOOKS_CHECKREWRITE');
}

# Returns all branches containing a specific commit. The command "git
# branch" returns the branch names prefixed with two characters, which
# we have to get rid of using substr.
sub _branches_containing {
    my ($git, $commit) = @_;
    return map { substr($_, 2) } $git->run('branch', '-a', '--contains', $commit);
}

sub record_commit_parents {
    my ($git) = @_;

    $log->debug(__PACKAGE__ . "::record_commit_parents");

    # Here we record the HEAD commit's own id and it's parent's ids in
    # a file under the git directory. The file has two lines in this
    # format:

    # commit SHA1
    # SHA1 SHA1 ...

    # The first line holds the HEAD commit's id and the second the ids of
    # its parents. In a brand new repository the rev-list command applied to
    # HEAD dies in error because HEAD isn't defined yet. This is why we
    # evaluate the command and replace its value by the empty string below.

    my $commit_parents = eval { $git->run(qw/rev-list --pretty=format:%P -n 1 HEAD/) } || '';

    _record_filename($git)->spew($commit_parents);

    return 1;
}

sub check_commit_amend {
    my ($git) = @_;

    $log->debug(__PACKAGE__ . "::check_commit_amend");

    my $record_file = _record_filename($git);

    -r $record_file
        or $git->fault(<<'EOS')
I cannot read $record_file.
Please, check if you forgot to create the pre-commit hook.
EOS
        and return 0;

    my ($old_commit, $old_parents) = $record_file->lines({chomp => 1});

    # For a brand new repository the commit information is empty and we
    # don't have to check anything.
    return 1 unless $old_commit;

    $old_commit =~ s/^commit\s+//;

    # the repo's first commit has no parents.
    $old_parents //= '';

    my $new_parents = ($git->run(qw/rev-list --pretty=format:%P -n 1 HEAD/))[1];

    return 1 if $new_parents ne $old_parents;

    # Find all branches containing $old_commit
    my @branches = _branches_containing($git, $old_commit);

    if (@branches > 0) {
        # $old_commit is reachable by at least one branch, which means
        # the amend was unsafe.
        my $branches = join "\n  ", @branches;
        $git->fault(<<"EOS");
You just performed an unsafe "git commit --amend" because your
original HEAD ($old_commit) is still reachable by the following
branch(es):

  $branches

Consider amending it again with the following command:

  git commit --amend
EOS
        return 0;
    }

    return 1;
}

sub check_rebase {
    my ($git, $upstream, $branch) = @_;

    $log->debug(__PACKAGE__ . "::check_rebase", {upstream => $upstream, branch => $branch});

    unless (defined $branch) {
        # This means we're rebasing the current branch. We try to grok
        # it's name using git symbolic-ref.
        my $success = eval { $branch = $git->run(qw/symbolic-ref -q HEAD/) };

        # The command git symbolic-ref fails if we're in a
        # detached HEAD. In this situation we don't care about the
        # rewriting.

        return 1 unless defined $success;
    }

    my @rebased_sequence = $git->run(qw/rev-list --topo-order --reverse/, "$upstream..$branch");

    # If $upstream is a decendant of $branch, the @rebased_sequence is
    # empty. In this situation the rebase will turn out to be a simple
    # fast-forward merge from $branch on $upstream and there is
    # nothing to lose.
    return 1 unless @rebased_sequence;

    # Find the base commit of the rebased sequence
    my $base_commit = $rebased_sequence[0];

    # Find all branches containing that commit
    my @branches = _branches_containing($git, $base_commit);

    if (@branches > 1) {
        # The base commit is reachable by more than one branch, which
        # means the rewrite is unsafe.
        my $branches = join("\n  ", grep {$_ ne $branch} @branches);
        $git->fault(<<"EOS");
You just performed an unsafe rebase because it would rewrite commits shared
by $branch and the following other branch(es):

  $branches

If the rebase was just effected, you can reset your branch to its previous
commit with the command:

  git reset --hard \@{1}

But be sure to understand the consequences of this command, as it can
potentially make you lose work.
EOS
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
=for Pod::Coverage check_commit_amend check_rebase record_commit_parents

=head1 NAME

Git::Hooks::CheckRewrite - Git::Hooks plugin for checking against unsafe rewrites

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckRewrite

    # These users are exempt from all checks
    admin = joe molly

This section enables the plugin and defines the users C<joe> and C<molly> as
administrators, effectively exempting them from any restrictions the plugin may
impose.

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the B<pre-rebase> hook to
guarantee that it is safe in the sense that no rewritten commit is reachable
by other branch than the one being rebased.

It also hooks itself to the B<pre-commit> and the B<post-commit> hooks
to detect unsafe B<git commit --amend> commands after the fact. An
amend is unsafe if the original commit is still reachable by any
branch after being amended. Unfortunately B<git> still does not
provide a way to detect unsafe amends before committing them.

To enable it you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckRewrite

=head1 CONFIGURATION

There's no configuration needed or provided.

=head1 REFERENCES

Here are some references about what it means for a rewrite to be
unsafe and how to go about detecting them in git:

=over

=item * L<http://git.661346.n2.nabble.com/pre-rebase-safety-hook-td1614613.html>

=item * L<http://git.apache.org/xmlbeans.git/hooks/pre-rebase.sample>

=item * L<http://www.mentby.com/Group/git/rfc-pre-rebase-refuse-to-rewrite-commits-that-are-reachable-from-upstream.html>

=item * L<http://git.661346.n2.nabble.com/RFD-Rewriting-safety-warn-before-when-rewriting-published-history-td7254708.html>

=back
