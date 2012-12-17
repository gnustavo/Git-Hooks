package Git::More;
# ABSTRACT: An extension of App::gh::Git with some goodies for hook developers.
use parent 'App::gh::Git';

use strict;
use warnings;
use Error qw(:try);
use Carp;

sub get_config {
    my ($git) = @_;

    unless (exists $git->{more}{config}) {
        my %config;
        my ($fh, $ctx) = $git->command_output_pipe(config => '--null', '--list');
        {
            local $/ = "\x0";
            while (<$fh>) {
                chop;           # final \x0
                my ($option, $value) = split /\n/, $_, 2;
                my ($section, $key)  = split /\./, $option, 2;
                push @{$config{$section}{$key}}, $value;
            }
        }
        try {
            $git->command_close_pipe($fh, $ctx);
        } otherwise {
            # No config option found. That's ok.
        };
        $git->{more}{config} = \%config;
    }

    return $git->{more}{config};
}

sub get_current_branch {
    my ($git) = @_;
    foreach ($git->command(branch => '--no-color')) {
        return $1 if /^\* (.*)/;
    }
    return;
}

sub get_commits {
    my ($git, $old_commit, $new_commit) = @_;
    my @commits;
    my ($pipe, $ctx) = $git->command_output_pipe(
        'rev-list',
        # See 'git help rev-list' to understand the --pretty argument
        '--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%s%n%n%b%x00',
        "$old_commit..$new_commit");
    {
        local $/ = "\x00\n";
        while (<$pipe>) {
            my %commit;
            @commit{qw/header commit tree parent
                       author_name author_email author_date
                       commmitter_name committer_email committer_date
                       body/} = split /\n/, $_, 11;
            push @commits, \%commit;
        }
    }
    $git->command_close_pipe($pipe, $ctx);
    return \@commits;
}

sub get_commit_msg {
    my ($git, $commit) = @_;
    my $body = $git->command('rev-list' => '--format=%B', '--max-count=1', $commit);
    $body =~ s/^[^\n]*\n//; # strip first line, which contains the commit id
    chomp $body;            # strip last newline
    return $body;
}

sub get_diff_files {
    my ($git, @args) = @_;
    my %affected;
    foreach ($git->command(diff => '--name-status', @args)) {
        my ($status, $name) = split ' ', $_, 2;
        $affected{$name} = $status;
    }
    return \%affected;
}


1; # End of Git::More
__END__

=head1 SYNOPSIS

    use Git::More;

    my $git = Git::More->repository();

    my $config  = $git->get_config('section');
    my $branch  = $git->get_current_branch();
    my $commits = $git->get_commits($oldcommit, $newcommit);
    my $message = $git->get_commit_msg('HEAD');

    my $files_modified_by_commit = $git->get_diff_files('--diff-filter=AM', '--cached');
    my $files_modified_by_push   = $git->get_diff_files('--diff-filter=AM', $oldcommit, $newcommit);

=head1 DESCRIPTION

This is an extension of the C<App::gh::Git> class. It's meant to
implement a few extra methods commonly needed by Git hook developers.

In particular, it's used by the standard hooks implemented by the
C<Git::Hooks> framework.

=head1 METHODS

=head2 get_config

This method groks the configuration options for the repository. It
returns every option found by invoking C<git config --list>.

The options are returned as a hash-ref pointing to a two-level
hash. For example, if the config options are these:

    section1.a=1
    section1.b=2
    section1.b=3
    section2.x.a=A
    section2.x.b=B
    section2.x.b=C

Then, it'll return this hash:

    {
        'section1' => {
            'a' => [1],
            'b' => [2, 3],
        },
        'section2' => {
            'x.a' => ['A'],
            'x.b' => ['B', 'C'],
        },
    }

The first level keys are the part of the option names before the first
dot. The second level keys are everything after the first dot in the
option names. You won't get more levels than two. In the example
above, you can see that the option "section2.x.a" is split in two:
"section2" in the first level and "x.a" in the second.

The values are always array-refs, even it there is only one value to a
specific option. For some options, it makes sense to have a list of
values attached to them. But even if you expect a single value to an
option you may have it defined in the global scope and redefined in
the local scope. In this case, it will appear as a two-element array,
the last one being the local value.

So, if you want to treat an option as single-valued, you should fetch
it like this:

     $h->{section1}{a}[-1]
     $h->{section2}{'x.a'}[-1]

=head2 get_current_branch

This method returns the repository's current branch name, as indicated
by the C<git branch> command. Note that its a ref short name, i.e.,
it's usually sub-intended to reside under the 'refs/heads/' ref scope.

=head2 get_commit_msg COMMIT_ID

This method returns the commit message (a.k.a. body) of the commit
identified by COMMIT_ID. The result is a string.

=head2 get_commits OLDCOMMIT NEWCOMMIT

This method returns a list of hashes representing every commit
reachable from NEWCOMMIT but not from OLDCOMMIT. It obtains this
information by invoking C<git rev-list OLDCOMIT..NEWCOMMIT>.

Each commit is represented by a hash with the following structure (the
codes are explained in the C<git help rev-list> document):

    {
        commit          => %H:  commit hash
        tree            => %T:  tree hash
        parent          => %P:  parent hashes (space separated)
        author_name     => %aN: author name
        author_email    => %aE: author email
        author_date     => %ai: author date in ISO8601 format
        commmitter_name => %cN: committer name
        committer_email => %cE: committer email
        committer_date  => %ci: committer date in ISO8601 format
        body            => %B:  raw body (aka commit message)
    }

=head2 get_diff_files DIFFARGS...

This method invokes the command C<git diff --name-status> with extra
options and arguments as passed to it. It returns a reference to a
hash mapping every affected files their affecting status. Its purpose
is to make it easy to grok the names of files affected by a commit or
a sequence of commits. Please, read C<git help diff> to know

A common usage is to grok every file added or modified in a pre-commit
hook:

    $git->get_diff_files('--diff-filter=AM', '--cached');

Another one is to grok every file added or modified in a pre-receive
hook:

    $git->get_diff_files('--diff-filter=AM', $old_commit, $new_commit);

=head1 SEE ALSO

C<App::gh::Git>
