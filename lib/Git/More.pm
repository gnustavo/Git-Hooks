use strict;
use warnings;

package Git::More;
# ABSTRACT: An extension of Git with some goodies for hook developers.
use App::gh::Git;
use parent -norequire, 'Git';

use Error qw(:try);
use Carp;

=head1 SYNOPSIS

    use Git::More;

    my $git = Git::More->repository();

    my $config  = $git->get_config('section');
    my $branch  = $git->get_current_branch();
    my $commits = $git->get_refs_commits();
    my $message = $git->get_commit_msg('HEAD');

=head1 DESCRIPTION

This is an extension of the Git class implemented by the
C<App::gh::Git> module. It's meant to implement a few extra methods
commonly needed by Git hook developers.

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

=cut

sub get_config {
    my ($git) = @_;

    unless (exists $git->{more}{config}) {
	my %config;
	my ($fh, $ctx) = $git->command_output_pipe(config => '--null', '--list');
	{
	    local $/ = "\x0";
	    while (<$fh>) {
		chop;		# final \x0
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

=head2 get_current_branch

This method returns the repository's current branch name, as indicated
by the C<git branch> command. Note that its a ref shortname, i.e.,
it's usually subintended to reside under the 'refs/heads/' ref scope.

=cut

sub get_current_branch {
    my ($git) = @_;
    foreach ($git->command(branch => '--no-color')) {
	return $1 if /^\* (.*)/;
    }
    return;
}

sub get_refs_ranges {
    my ($git) = @_;

    unless (exists $git->{more}{refs}{ranges}) {
	my %refs;
	while (<>) {
	    chomp;
	    my ($old_commit, $new_commit, $ref) = split;
	    $refs{$ref} = [$old_commit, $new_commit];
	}
	$git->{more}{refs}{ranges} = \%refs;
    }

    return %{$git->{more}{refs}{ranges}};
}

sub set_ref_range {
    my ($git, $ref, $old_commit, $new_commit) = @_;
    $git->{more}{refs}{ranges}{$ref} = [$old_commit, $new_commit];
}

sub get_refs_commit_ids {
    my ($git) = @_;

    unless (exists $git->{more}{refs}{ids}) {
	my %ranges = $git->get_refs_ranges();

	my %refs;
	while (my ($ref, $range) = each %ranges) {
	    $refs{$ref} = [$git->command('rev-list' => join('..', @$range))];
	}
	$git->{more}{refs}{ids} = \%refs;
    }

    return %{$git->{more}{refs}{ids}};
}

sub grok_commits {
    my ($git, $start, $end) = @_;
    my @commits;
    my ($pipe, $ctx) = $git->command_output_pipe(
	'rev-list',
	# See 'git help rev-list' to understand the --pretty argument
	'--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%B%x00',
	"$start..$end");
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

sub get_refs_commits {
    my ($git) = @_;

    unless (exists $git->{more}{refs}{commits}) {
	my %ranges = $git->get_refs_ranges();

	my %refs;
	while (my ($ref, $range) = each %ranges) {
	    $refs{$ref} = $git->grok_commits(@$range);
	}
	$git->{more}{refs}{commits} = \%refs;
    }

    return %{$git->{more}{refs}{commits}};
}

sub get_commit_msg {
    my ($git, $commit) = @_;
    my $body = $git->command('rev-list' => '--format=%B', '--max-count=1', $commit);
    $body =~ s/^.*//m;    # strip first line, which contains the commit id
    $body =~ s/^\s+//gm;  # strip blank prefixes from all lines
    return $body;
}

1;
