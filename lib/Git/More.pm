package Git::More;
# ABSTRACT: An extension of App::gh::Git with some goodies for hook developers.
use parent 'App::gh::Git';

use strict;
use warnings;
use Error qw(:try);
use Carp;
use Git::Hooks qw/:utils/;

sub _compatibilize_config {
    my ($config) = @_;

    # Up to version 0.022 the plugins used flat names, such as
    # "check-acls.pl". These names were used as values for the
    # githooks.HOOK configuration variables and also as the name of
    # configuration sections specific of the plugins. In version 0.023
    # the three existing plugins (check-acls.pl, check-jira.pl, and
    # check-structure.pl) were converted to proper modules and renamed
    # to the usual CamelCase form of the names (i.e., CheckAcls.pm,
    # CheckJira.pm, and CheckStructure.pm). To preserve compatibility
    # with already configured hooks here we inject the old names in
    # the new names.

    foreach my $hook (qw/commit-msg pre-commit pre-receive post-receive update/) {
        if (exists $config->{githooks}{$hook}) {
            foreach (@{$config->{githooks}{$hook}}) {
                $_ = "Check\u$1" if /^check-(acls|jira|structure)(?:\.pl)?$/;
            }
        }
    }

    foreach my $name (
        ['check-acls'      => 'CheckAcls'],
        ['check-jira'      => 'CheckJira'],
        ['check-structure' => 'CheckStructure'],
    ) {
        if (exists $config->{$name->[0]} && ! exists $config->{$name->[1]}) {
            $config->{$name->[1]} = delete $config->{$name->[0]};
        }
    }

    # Up to version 0.020 the configuration variables 'admin' and
    # 'userenv' were defined for the CheckAcls and CheckJira
    # plugins. In version 0.021 they were both "promoted" to the
    # Git::Hooks module, so that they can be used by any access
    # control plugin. In order to maintain compatibility with their
    # previous usage, here we virtually "inject" the variables in the
    # "githooks" configuration section if they are undefined there and
    # are defined in the plugin sections.

    foreach my $var (qw/admin userenv/) {
        next if exists $config->{githooks}{$var};
        foreach my $plugin (qw/CheckAcls CheckJira/) {
            if (exists $config->{$plugin}{$var}) {
                $config->{githooks}{$var} = $config->{$plugin}{$var};
                next;
            }
        }
    }

    return;
}

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

        # Set default values for undefined ones.
        $config{githooks}{externals} //= [1];

        _compatibilize_config(\%config);

        $git->{more}{config} = \%config;
    }

    return $git->{more}{config};
}

sub config_scalar {
    my ($git, $section, $var) = @_;
    my $config = $git->get_config();
    return exists $config->{$section}{$var} ? $config->{$section}{$var}[-1] : undef;
}

sub config_list {
    my ($git, $section, $var) = @_;
    my $config = $git->get_config();
    return exists $config->{$section}{$var} ? @{$config->{$section}{$var}} : ();
}

sub cache {
    my ($git, $section) = @_;

    unless (exists $git->{more}{cache}{$section}) {
        $git->{more}{cache}{$section} = {};
    }

    return $git->{more}{cache}{$section};
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

    return @commits;
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

sub set_affected_ref {
    my ($git, $ref, $old_commit, $new_commit) = @_;
    $git->{more}{affected_refs}{$ref}{range} = [$old_commit, $new_commit];
    return;
}

# internal method
sub _get_affected_refs_hash {
    my ($git) = @_;

    return $git->{more}{affected_refs}
        or die __PACKAGE__, ": get_affected_refs(): no affected refs set\n";
}

sub get_affected_refs {
    my ($git) = @_;

    return keys %{$git->_get_affected_refs_hash()};
}

sub get_affected_ref_range {
    my ($git, $ref) = @_;

    my $affected = $git->_get_affected_refs_hash();

    exists $affected->{$ref}{range}
        or die __PACKAGE__, ": get_affected_ref_range($ref): no such affected ref\n";

    return @{$affected->{$ref}{range}};
}

sub get_affected_ref_commit_ids {
    my ($git, $ref) = @_;

    my $affected = $git->_get_affected_refs_hash();

    exists $affected->{$ref}
        or die __PACKAGE__, ": get_affected_ref_commit_ids($ref): no such affected ref\n";

    unless (exists $affected->{$ref}{ids}) {
        my @range = $git->get_affected_ref_range($ref);
        $affected->{$ref}{ids} = [$git->command('rev-list' => join('..', @range))];
    }

    return @{$affected->{$ref}{ids}};
}

sub get_affected_ref_commits {
    my ($git, $ref) = @_;

    my $affected = $git->_get_affected_refs_hash();

    exists $affected->{$ref}
        or die __PACKAGE__, ": get_affected_ref_commits($ref): no such affected ref\n";

    unless (exists $affected->{$ref}{commits}) {
        $affected->{$ref}{commits} = [$git->get_commits($git->get_affected_ref_range($ref))];
    }

    return @{$affected->{$ref}{commits}};
}

sub authenticated_user {
    my ($git) = @_;

    unless (exists $git->{more}{authenticated_user}) {
        if (my $userenv = $git->config_scalar(githooks => 'userenv')) {
            if ($userenv =~ /^eval:(.*)/) {
                $git->{more}{authenticated_user} = eval $1; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                die __PACKAGE__, ": error evaluating userenv value ($userenv): $@\n"
                    if $@;
            } elsif (exists $ENV{$userenv}) {
                $git->{more}{authenticated_user} = $ENV{$userenv};
            } else {
                die __PACKAGE__, ": option userenv environment variable ($userenv) is not defined.\n";
            }
        } else {
            $git->{more}{authenticated_user} = undef;
        }
    }

    return $git->{more}{authenticated_user};
}

sub get_current_branch {
    my ($git) = @_;
    foreach ($git->command(branch => '--no-color')) {
        return $1 if /^\* (.*)/;
    }
    return;
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

=head2 config_scalar SECTION VARIABLE

This method fetches the configuration option SECTION.VARIABLE as a
scalar. If the option has more than one value, the last one is
returned. If the option is undefined, it returns undef.

=head2 config_list SECTION VARIABLE

This method fetches the configuration option SECTION.VARIABLE as a
list. If the option is undefined, it returns the empty list.

=head2 cache SECTION

This method may be used by plugin developers to cache information in
the context of a Git::More object. SECTION is a string (usually a
plugin name) that is associated with a hash-ref. The method simply
returns the hash-ref, which can be used by the caller to store any
kind of information.

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

=head2 get_commit_msg COMMIT_ID

This method returns the commit message (a.k.a. body) of the commit
identified by COMMIT_ID. The result is a string.

=head2 get_diff_files DIFFARGS...

This method invokes the command C<git diff --name-status> with extra
options and arguments as passed to it. It returns a reference to a
hash mapping every affected files to their affecting status. Its
purpose is to make it easy to grok the names of files affected by a
commit or a sequence of commits. Please, read C<git help diff> to know
everything about its options.

A common usage is to grok every file added or modified in a pre-commit
hook:

    my $hash_ref = $git->get_diff_files('--diff-filter=AM', '--cached');

Another one is to grok every file added or modified in a pre-receive
hook:

    my $hash_ref = $git->get_diff_files('--diff-filter=AM', $old_commit, $new_commit);

=head2 set_affected_ref REF OLDCOMMIT NEWCOMMIT

This method should be used in the beginning of an C<update>,
C<pre-receive>, or C<post-receive> hook in order to record the
references that were affected by the push command. The information
recorded will be later used by the following C<get_affected_ref*>
methods.

=head2 get_affected_refs

This method returns the list of names of references that were affected
by the current push command, as they were set by calls to the
C<set_affected_ref> method.

=head2 get_affected_ref_range(REF)

This method returns the two-element list of commit ids representing
the OLDCOMMIT and the NEWCOMMIT of the affected REF.

=head2 get_affected_ref_commit_ids(REF)

This method returns the list of commit ids leading from the affected
REF's NEWCOMMIT to OLDCOMMIT.

=head2 get_affected_ref_commits(REF)

This routine returns the list of commits leading from the affected
REF's NEWCOMMIT to OLDCOMMIT. The commits are represented by hashes,
as returned by the C<get_commits> method.

=head2 authenticated_user

This method returns the username of the authenticated user performing
the Git action. It groks it from the C<githooks.userenv> configuration
variable specification, which is described in the C<Git::Hooks>
documentation. It's useful for most access control check plugins.

=head2 get_current_branch

This method returns the repository's current branch name, as indicated
by the C<git branch> command. Note that it's a ref short name, i.e.,
it's usually sub-intended to reside under the 'refs/heads/' ref scope.

=head1 SEE ALSO

C<App::gh::Git>
