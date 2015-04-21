package Git::More;
# ABSTRACT: A Git extension with some goodies for hook developers

use strict;
use warnings;

use parent 'Git';

use Error qw(:try);
use Carp;
use Path::Tiny;
use Git::Hooks qw/:utils/;

# This package variable tells get_config which character encoding is used in
# the output of the git-config command. Usually none, and decoding isn't
# necessary. But sometimes it is...
our $CONFIG_ENCODING = undef;

# The UNDEF_COMMIT is a special SHA-1 used by Git in the update and
# pre-receive hooks to signify that a reference either was just created (as
# the old commit) or has been just deleted (as the new commit).
our $UNDEF_COMMIT = '0000000000000000000000000000000000000000';

# The EMPTY_COMMIT represents a commit with an empty tree.
our $EMPTY_COMMIT = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

sub get_config {
    my ($git, $section, $var) = @_;

    unless (exists $git->{more}{config}) {
        my %config;

        exists $ENV{HOME}
            or die __PACKAGE__, <<'EOT';
The HOME environment variable is undefined.

We need it to read Git's global configuration from $HOME/.gitconfig.

If you really don't want to read the global configuration, define HOME as an
empty string in your hook script like this before invoking run_hook():

  $ENV{HOME} = '';

Note that if you're using Gerrit as a Git server it runs with HOME undefined
by default when started by a boot script. In this case you should define
HOME in your hook script to point to the directory holding your .gitconfig
file. For example:

  $ENV{HOME} = '/home/gerrit';

EOT

        my $config = do {
           local $/ = "\c@";
           $git->command(config => '--null', '--list');
        };

        if (defined $CONFIG_ENCODING) {
            require Encode;
            $config = Encode::decode($CONFIG_ENCODING, $config);
        }

        if (defined $config) {
            while ($config =~ /([^\cJ]+)\cJ([^\c@]*)\c@/sg) {
                my ($option, $value) = ($1, $2);
                if ($option =~ /(.+)\.(.+)/) {
                    push @{$config{lc $1}{lc $2}}, $value;
                } else {
                    die __PACKAGE__, ": Cannot grok config variable name '$option'.\n";
                }
            }
        }

        # Set default values for undefined ones.
        $config{githooks}{externals}       //= [1];
        $config{githooks}{gerrit}{enabled} //= [1];
        $config{githooks}{'abort-commit'}  //= [1];

        $git->{more}{config} = \%config;
    }

    my $config = $git->{more}{config};

    $section = lc $section if defined $section;

    if (! defined $section) {
        return $config;
    } elsif (! defined $var) {
        $config->{$section} = {} unless exists $config->{$section};
        return $config->{$section};
    } elsif (exists $config->{$section}{$var}) {
        return wantarray ? @{$config->{$section}{$var}} : $config->{$section}{$var}[-1];
    } else {
        return wantarray ? () : undef;
    }
}

sub cache {
    my ($git, $section) = @_;

    unless (exists $git->{more}{cache}{$section}) {
        $git->{more}{cache}{$section} = {};
    }

    return $git->{more}{cache}{$section};
}

sub clean_cache {
    my ($git, $section) = @_;
    delete $git->{more}{cache}{$section};
    return;
}

sub get_commit {
    my ($git, $commit) = @_;

    my $cache = $git->cache('commits');

    unless (exists $cache->{$commit}) {
        local $/ = "\c@\cJ";
        my ($pipe, $ctx) = $git->command_output_pipe(
            'rev-list',
            '--no-walk',
            # See 'git help rev-list' to understand the --pretty argument
            '--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%G? %GK%n%s%n%n%b%x00',
            '--encoding=UTF-8',
            $commit,
        );

        while (<$pipe>) {
            chomp;
            my %commit;
            @commit{qw/header commit tree parent
                       author_name author_email author_date
                       commmitter_name committer_email committer_date
                       signature body/} = split "\cJ", $_, 12;
            $cache->{$commit} = \%commit;
        }

        $git->command_close_pipe($pipe, $ctx);
    }

    return $cache->{$commit};
}

sub get_commits {
    my ($git, $old_commit, $new_commit) = @_;

    my $cache = $git->cache('ranges');

    my $range = "$old_commit:$new_commit";

    unless (exists $cache->{$range}) {
        # We're interested in all commits reachable from $new_commit but not
        # reachable from $old_commit. We're going to use the "git rev-list"
        # command for that. As you can read on its documentation, the usual
        # syntax to specify this set of commits is this: "$new_commit
        # ^$old_commit".

        # However, there are two special cases: when a new branch is created
        # and when an old branch is deleted.

        # When an old branch is deleted $new_commit is null (i.e.,
        # '0'x40'). In this case previous commits are being forgotten and
        # the hooks usually don't need to check them. So, in this situation
        # we simply return an empty list of commits.

        return if $new_commit eq $UNDEF_COMMIT;

        # When a new branch is created $old_commit is null (i.e.,
        # '0'x40). In this case we want all commits reachable from
        # $new_commit but not reachable from any other branch. The syntax
        # for this is "$new_commit ^$b1 ^$b2 ... ^$bn", i.e., $new_commit
        # followed by every other branch name prefixed by carets. We can get
        # at their names using the technique described in, e.g.,
        # http://stackoverflow.com/questions/3511057/git-receive-update-hooks-and-new-branches.

        # The @excludes variable will hold the list of commits that will be
        # prefixed with carets in the git rev-list command invokation.

        my @excludes =
            $old_commit eq $UNDEF_COMMIT
                ? grep {$_ ne $new_commit} $git->command(qw:for-each-ref --format=%(objectname) refs/heads/:)
                    : $old_commit;

        # The commit list to be returned
        my @commits;

        local $/ = "\c@\cJ";
        my ($pipe, $ctx) = $git->command_output_pipe(
            'rev-list',
            # See 'git help rev-list' to understand the --pretty argument
            '--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%G? %GK%n%s%n%n%b%x00',
            '--encoding=UTF-8',
            $new_commit,
            map {"^$_"} @excludes,
        );

        while (<$pipe>) {
            my %commit;
            @commit{qw/header commit tree parent
                       author_name author_email author_date
                       commmitter_name committer_email committer_date
                       signature body/} = split "\cJ", $_, 12;
            push @commits, \%commit;
        }

        $git->command_close_pipe($pipe, $ctx);

        $cache->{$range} = \@commits;
    }

    return @{$cache->{$range}};
}

sub get_commit_msg {
    my ($git, $commit) = @_;

    # We want to use the %B format to grok the commit message, but it
    # was implemented only in Git v1.7.2. If we try to use it with
    # rev-list in previous Gits we get back the same format
    # unexpanded. In this case, we try the second best option which is
    # to use the format %s%n%n%b. The difference is that this format
    # unfolds the first sequence of non-empty lines in a single line
    # which is considered the message's subject (or title).
    foreach my $format (qw/%B %s%n%n%b/) {
        my $body = $git->command('rev-list' => "--format=$format", '--max-count=1', $commit);
        $body =~ s/^[^\n]*\n//; # strip first line, which contains the commit id
        chomp $body;            # strip last newline
        next if $body eq $format;
        return $body;
    }
    die __PACKAGE__, "::get_commit_msg: cannot get commit msg.\n";
}

sub read_commit_msg_file {
    my ($git, $msgfile) = @_;

    my $encoding = $git->get_config(i18n => 'commitencoding') || 'utf-8';

    my $msg = path($msgfile)->slurp({binmode => ":encoding($encoding)"});

    # Truncate the message just before the diff, if any.
    $msg =~ s:\ndiff --git .*::s;

    # The comments in the following lines were taken from the "git
    # help stripspace" documentation to guide the
    # implementation. Previously we invoked the "git stripspace -s"
    # external command via Git::command_bidi_pipe to do the cleaning
    # but it seems that it doesn't work on FreeBSD. So, we reimplement
    # its functionality here.

    for ($msg) {
        # Skip and remove all lines starting with comment character
        # (default #).
        s/^#.*//gm;

        # remove trailing whitespace from all lines
        s/[ \t\f]+$//gm;

        # collapse multiple consecutive empty lines into one empty line
        s/\n{3,}/\n\n/gs;

        # remove empty lines from the beginning and end of the input
        # add a missing \n to the last line if necessary.
        s/^\n+//s;
        s/\n*$/\n/s;

        # In the case where the input consists entirely of whitespace
        # characters, no output will be produced.
        s/^\s+$//s;
    }

    return $msg;
}

sub write_commit_msg_file {
    my ($git, $msgfile, @msg) = @_;

    my $encoding = $git->get_config(i18n => 'commitencoding') || 'utf-8';

    path($msgfile)->spew({binmode => ":encoding($encoding)"}, @msg);

    return;
}

sub filter_files_in_index {
    my ($git, $filter) = @_;
    my $output = $git->command(
        qw/diff-index --name-only --no-commit-id --cached -r -z/,
        "--diff-filter=$filter", $git->get_head_or_empty_tree(),
    );
    return split /\0/, $output;
}

sub filter_files_in_range {
    my ($git, $filter, $from, $to) = @_;
    $from = $EMPTY_COMMIT if $from eq $UNDEF_COMMIT;
    my $output = $git->command(
        qw/diff-tree --name-only --no-commit-id -r -z/,
        "--diff-filter=$filter", $from, $to,
    );
    return split /\0/, $output;
}

sub filter_files_in_commit {
    my ($git, $filter, $commit) = @_;
    my $output = $git->command(
        qw/diff-tree --name-only -m -r -z/,
        "--diff-filter=$filter", $commit,
    );
    my $num_parents = 0;
    my %files;
    foreach my $name (split /\0/, $output) {
        if ($name =~ /^[0-9a-f]{40}$/) {
            ++$num_parents;
        } else {
            ++$files{$name};
        }
    }
    return grep { $files{$_} == $num_parents } keys %files;
}

sub set_affected_ref {
    my ($git, $ref, $old_commit, $new_commit) = @_;
    $git->{more}{affected_refs}{$ref}{range} = [$old_commit, $new_commit];
    return;
}

# internal method
sub _get_affected_refs_hash {
    my ($git) = @_;

    $git->{more}{affected_refs}
        or die __PACKAGE__, ": get_affected_refs(): no affected refs set\n";

    return $git->{more}{affected_refs};
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
        $affected->{$ref}{ids} = [ map { $_->{'commit'} } $git->get_affected_ref_commits($ref) ];
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

sub push_input_data {
    my ($git, $data) = @_;
    push @{$git->{more}{input_data}}, $data;
    return;
}

sub get_input_data {
    my ($git) = @_;
    return $git->{more}{input_data} || [];
}

sub set_authenticated_user {
    my ($git, $user) = @_;
    return $git->{more}{authenticated_user} = $user;
}

sub authenticated_user {
    my ($git) = @_;

    unless (exists $git->{more}{authenticated_user}) {
        if (my $userenv = $git->get_config(githooks => 'userenv')) {
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
            $git->{more}{authenticated_user} = $ENV{GERRIT_USER_EMAIL} || $ENV{USER} || undef;
        }
    }

    return $git->{more}{authenticated_user};
}

sub get_current_branch {
    my ($git) = @_;
    my $branch;
    try {
        $branch = $git->command_oneline([qw/symbolic-ref HEAD/], {STDERR => 0});
    } otherwise {
        # In dettached head state
    };
    return $branch;
}

sub get_sha1 {
    my ($git, $rev) = @_;

    return $git->command_oneline(['rev-parse', '--verify', $rev], {STDERR => 0});
}

sub get_head_or_empty_tree {
    my ($git) = @_;

    my $head = 'HEAD';
    try {
        scalar($git->command_oneline([qw/rev-parse --verify HEAD/], {STDERR => 0}));
    } otherwise {
        # Initial commit: return the empty tree object
        $head = $EMPTY_COMMIT;
    };
    return $head;
}

sub blob {
    my ($git, $rev, $file, @args) = @_;

    my $cache = $git->cache('blob');

    my $blob = "$rev:$file";

    unless (exists $cache->{$blob}) {
        $cache->{tmpdir} //= Path::Tiny->tempdir(@args);

        my $path = path($file);

        # Calculate temporary file path
        (my $revdir  = $rev) =~ s/^://; # remove ':' from ':0' because Windows don't like ':' in filenames
        my $filepath = $cache->{tmpdir}->child($revdir, $path);

        # Create directory path for the temporary file.
        $filepath->parent->mkpath;

        # Create temporary file and copy contents to it
        open my $tmp, '>:', $filepath ## no critic (RequireBriefOpen)
            or git->error(__PACKAGE__, "Internal error: can't create file '$filepath': $!")
                and return;
        my ($pipe, $ctx) = $git->command_output_pipe(qw/cat-file blob/, $blob);
        my $read;
        while ($read = sysread $pipe, my $buffer, 64 * 1024) {
            my $length = length $buffer;
            my $offset = 0;
            while ($length) {
                my $written = syswrite $tmp, $buffer, $length, $offset;
                defined $written
                    or $git->error(__PACKAGE__, "Internal error: can't write to '$filepath': $!")
                        and return;
                $length -= $written;
                $offset += $written;
            }
        }
        defined $read
            or $git->error(__PACKAGE__, "Internal error: can't read from git cat-file pipe: $!")
                and return;
        $git->command_close_pipe($pipe, $ctx);
        $tmp->close();
        $cache->{$blob} = $filepath;
    }

    return $cache->{$blob}->stringify;
}

sub file_size {
    my ($git, $rev, $file) = @_;

    chomp(my $size = $git->command('cat-file', '-s', "$rev:$file"));

    return $size;
}

sub error {
    my ($git, $prefix, $message, $details) = @_;
    $message =~ s/\n*$//s;    # strip trailing newlines
    my $fmtmsg = "\n[$prefix] $message";
    if ($details) {
        # The details may have been generated by Carp::croak, in which case
        # it will contain a suffix telling where the error
        # occurred. Sometimes you may not want this. For instance, if the
        # user is going to receive the error message produced by a server
        # hook he/she won't be able to use that information. So, we may have
        # to strip the context from the details.
        $details =~ s/ at .*? line \d+(?: thread \d+)?\.?$//s
            if $git->{more}{nocarp};

        $details =~ s/\n*$//s; # strip trailing newlines
        $details =~ s/^/  /gm; # prefix each line with two spaces
        $fmtmsg .= ":\n\n$details\n";
    }
    $fmtmsg .= "\n";            # end in a newline
    push @{$git->{more}{errors}}, $fmtmsg;
    if ($git->{more}{nocarp}) {
        warn $fmtmsg;           ## no critic (RequireCarping)
    } else {
        carp $fmtmsg;
    }
    return 1;
}

sub get_errors {
    my ($git) = @_;

    return exists $git->{more}{errors} ? @{$git->{more}{errors}} : ();
}

sub nocarp {
    my ($git) = @_;
    $git->{more}{nocarp} = 1;
    return;
}


1; # End of Git::More
__END__

=head1 SYNOPSIS

    use Git::More;

    my $git = Git::More->repository();

    my $config  = $git->get_config();
    my $branch  = $git->get_current_branch();
    my @commits = $git->get_commits($oldcommit, $newcommit);
    my $message = $git->get_commit_msg('HEAD');

    my $files_modified_by_commit = $git->filter_files_in_index('AM');
    my $files_modified_by_push   = $git->filter_files_in_range('AM', $oldcommit, $newcommit);

=head1 DESCRIPTION

This is an extension of the C<Git> class. It's meant to implement a
few extra methods commonly needed by Git hook developers.

In particular, it's used by the standard hooks implemented by the
C<Git::Hooks> framework.

=head1 CONFIGURATION VARIABLES

=head2 CONFIG_ENCODING

Git configuration files usually contain just ASCII characters, but values
and sub-section names may contain any characters, except newline. If your
config files have non-ASCII characters you should ensure that they are
properly decoded by specifying their encoding like this:

    $Git::More::CONFIG_ENCODING = 'UTF-8';

The acceptable values for this variable are all the encodings supported by
the C<Encode> module.

=head1 METHODS

=head2 get_config [SECTION [VARIABLE]]

This method groks the configuration options for the repository by
invoking C<git config --list>. The configuration is cached during the
first invokation in the object C<Git::More> object. So, if the
configuration is changed afterwards, the method won't notice it. This
is usually ok for hooks, though.

With no arguments, the options are returned as a hash-ref pointing to
a two-level hash. For example, if the config options are these:

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
        'section2.x' => {
            'a' => ['A'],
            'b' => ['B', 'C'],
        },
    }

The first level keys are the part of the option names before the last
dot. The second level keys are everything after the last dot in the
option names. You won't get more levels than two. In the example
above, you can see that the option "section2.x.a" is split in two:
"section2.x" in the first level and "a" in the second.

The values are always array-refs, even it there is only one value to a
specific option. For some options, it makes sense to have a list of
values attached to them. But even if you expect a single value to an
option you may have it defined in the global scope and redefined in
the local scope. In this case, it will appear as a two-element array,
the last one being the local value.

So, if you want to treat an option as single-valued, you should fetch
it like this:

    $h->{section1}{a}[-1]
    $h->{'section2.x'}{a}[-1]

If the SECTION argument is passed, the method returns the second-level
hash for it. So, following the example above, this call:

    $git->get_config('section1');

This call would return this hash:

    {
        'a' => [1],
        'b' => [2, 3],
    }

If the section doesn't exist an empty hash is returned. Any key/value
added to the returned hash will be available in subsequent invokations
of C<get_config>.

If the VARIABLE argument is also passed, the method returns the
value(s) of the configuration option C<SECTION.VARIABLE>. In list
context the method returns the list of all values or the empty list,
if the variable isn't defined. In scalar context, the method returns
the variable's last value or C<undef>, if it's not defined.

=head2 cache SECTION

This method may be used by plugin developers to cache information in
the context of a Git::More object. SECTION is a string (usually a
plugin name) that is associated with a hash-ref. The method simply
returns the hash-ref, which can be used by the caller to store any
kind of information.

=head2 clean_cache SECTION

This method deletes the cache entry for SECTION. It may be used by
hooks just before returning to B<Git::Hooks::run_hooks> in order to
get rid of any value kept in the SECTION's cache.

=head2 get_commit COMMIT

This method returns a hash representing COMMIT. It obtains this information
by invoking C<git rev-list --no-walk --encoding=UTF-8 COMMIT>.

The returned hash has the following structure (the codes are explained in
the C<git help rev-list> document):

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
        signature       => %G? %GK: commit signature check status and key
        body            => %B:  raw body (aka commit message)
    }

All character data is UTF-8 encoded.

=head2 get_commits OLDCOMMIT NEWCOMMIT

This method returns a list of hashes representing every commit
reachable from NEWCOMMIT but not from OLDCOMMIT. It obtains this
information by invoking C<git rev-list NEWCOMMIT ^OLDCOMMIT>.

There are two special cases, though:

If NEWCOMMIT is the null SHA-1, i.e.,
'0000000000000000000000000000000000000000', this means that a branch,
pointing to OLDCOMMIT, has been removed. In this case the method
returns an empty list, meaning that no new commit has been created.

If OLDCOMMIT is the null SHA-1, this means that a new branch poiting
to NEWCOMMIT is being created. In this case we want all commits
reachable from NEWCOMMIT but not reachable from any other branch. The
syntax for this is NEWCOMMIT ^B1 ^B2 ... ^Bn", i.e., NEWCOMMIT
followed by every other branch name prefixed by carets. We can get at
their names using the technique described in, e.g., L<this
discussion|http://stackoverflow.com/questions/3511057/git-receive-update-hooks-and-new-branches>.

=head2 get_commit_msg COMMIT_ID

This method returns the commit message (a.k.a. body) of the commit
identified by COMMIT_ID. The result is a string.

=head2 read_commit_msg_file FILENAME

This method returns the relevant contents of the commit message file
called FILENAME. It's useful during the C<commit-msg> and the
C<prepare-commit-msg> hooks.

The file is read using the character encoding defined by the
C<i18n.commitencoding> configuration option or C<utf-8> if not
defined.

Some non-relevant contents are stripped off the file. Specifically:

=over

=item * diff data

Sometimes, the commit message file contains the diff data for the
commit. This data begins with a line starting with the fixed string
C<diff --git a/>. Everything from such a line on is stripped off the
file.

=item * comment lines

Every line beginning with a C<#> character is stripped off the file.

=item * trailing spaces

Any trailing space is stripped off from all lines in the file.

=item * trailing empty lines

Any empty line at the end is stripped off from the file, making sure
it ends in a single newline.

=back

All this cleanup is performed to make it easier for different plugins
to analyse the commit message using a canonical base.

=head2 write_commit_msg_file FILENAME, MSG, ...

This method writes the list of strings C<MSG> to FILENAME. It's useful
during the C<commit-msg> and the C<prepare-commit-msg> hooks.

The file is written to using the character encoding defined by the
C<i18n.commitencoding> configuration option or C<utf-8> if not
defined.

An empty line (C<\n\n>) is inserted between every pair of MSG
arguments, if there is more than one, of course.

=head2 filter_files_in_index FILTER

This method returns a list of the names of the files that are changed in the
index (staging area) compared to the HEAD commit. It's useful in the
C<pre-commit> hook when you want to know which files are being modified in
the upcoming commit.

FILTER specifies in which kind of changes you're interested in. It's passed
as the argument to the C<--diff-filter> option of C<git diff-index>, which
is documented like this:

  --diff-filter=[(A|C|D|M|R|T|U|X|B)...[*]]

    Select only files that are Added (A), Copied (C), Deleted (D), Modified
    (M), Renamed (R), have their type (i.e. regular file, symlink,
    submodule, ...) changed (T), are Unmerged (U), are Unknown (X), or have
    had their pairing Broken (B). Any combination of the filter characters
    (including none) can be used. When * (All-or-none) is added to the
    combination, all paths are selected if there is any file that matches
    other criteria in the comparison; if there is no file that matches other
    criteria, nothing is selected.

=head2 filter_files_in_range FILTER, FROM, TO

This method returns a list of the names of the files that are changed
between FROM and TO commits. It's useful in the C<update> and the
C<pre-receive> hooks when you want to know which files are being modified in
the commits being received by a C<git push> command.

FILTER specifies in which kind of changes you're interested in. Please, read
the C<filter_files_in_index> documetation above.

FROM and TO are revision parameters (see C<git help revisions>) specifying
two commits. They're passed as arguments to C<git diff-tree> in order to
compare them and grok the files that differ between them.

=head2 filter_files_in_commit FILTER, COMMIT

This method returns a list of the names of the files that are changed in
COMMIT. It's useful in the C<patchset-created> and the C<draft-published>
hooks when you want to know which files are being modified in the single
commit being received by a C<git push> command.

FILTER specifies in which kind of changes you're interested in. Please, read
the C<filter_files_in_index> documetation above.

COMMIT is a revision parameter (see C<git help revisions>) specifying the
commit. It's passed a argument to C<git diff-tree> in order to compare it to
its parents and grok the files that changed in it.

Merge commits are treated specially. Only files that are changed in COMMIT
with respect to all of its parents are returned. The reasoning behind this
is that if a file isn't changed with respect to one or more of COMMIT's
parents, then it must have been checked already in those commits and we
don't need to check it again.

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

=head2 push_input_data DATA

This method gets a single value and tucks it in an internal list so
that every piece of data can be gotten later with the
C<get_input_data> method below.

It's used by C<Git::Hooks> to save arguments read from STDIN by some
Git hooks like pre-receive, post-receive, pre-push, and post-rewrite.

=head2 get_input_data

This method returns an array-ref pointing to a list of all pieces of
data saved by calls to C<push_input_data> method above.

=head2 set_authenticated_user USERNAME

This method can be used to set the username of the authenticated user
when the default heristics defined above aren't enough. The name will
be cached so that subsequent invokations of B<authenticated_user> will
return this.

=head2 get_current_branch

This method returns the repository's current branch name, as indicated
by the C<git symbolic-ref HEAD> command.

If the repository is in a dettached head state, i.e., if HEAD points
to a commit instead of to a branch, the method returns undef.

=head2 get_sha1 REV

This method returns the SHA1 of the commit represented by REV, using the
command

  git rev-parse --verify REV

It's useful, for instance, to grok the HEAD's SHA1 so that you can pass it
to the get_commit method.

=head2 get_head_or_empty_tree

This method returns the string "HEAD" if the repository already has
commits. Otherwise, if it is a brand new repository, it returns the SHA1
representing the empty tree. It's useful to come up with the correct
argument for, e.g., C<git diff> during a pre-commit hook. (See the default
pre-commit.sample script which comes with Git to understand how this is
used.)

=head2 blob REV, FILE, ARGS...

This method returns the name of a temporary file into which the contents of
the file FILE in revision REV has been copied.

It's useful for hooks that need to read the contents of changed files in
order to check anything in them.

These objects are cached so that if more than one hook needs to get at them
they're created only once.

By default, all temporary files are removed when the Git::More object is
destroyed.

Any remaining ARGS are passed as arguments to C<File::Temp::newdir> so that you
can have more control over the temporary file creation.

=head2 file_size REV FILE

This method returns the size (in bytes) of FILE (a path relative to the
repository root) in revision REV.

=head2 error PREFIX MESSAGE [DETAILS]

This method should be used by plugins to record consistent error or warning
messages. It gets two or three arguments. The PREFIX is usually the plugin's
package name. The MESSAGE is a oneline string. These two arguments are
combined to produce a single line like this:

  [PREFIX] MESSAGE

DETAILS is an optional string. If present, it is appended to the line above,
separated by an empty line, and with its lines prefixed by two spaces, like
this:

  [PREFIX] MESSAGE

    DETAILS
    MORE DETAILS...

The method simply records the formatted error message and returns. It
doesn't die.

=head2 get_errors

This method returns a list of all error messages recorded with the
C<error> method.

=head2 nocarp

By default all errors produced by Git::Hooks use L<Carp::croak>, so that
they contain a suffix telling where the error occurred. Sometimes you may
not want this. For instance, if the user is going to receive the error
message produced by a server hook he/she won't be able to use that
information.

This method makes B<error> strip any such suffixes from its DETAILS argument
and to produce its own message with B<warn> instead of B<carp>.

=head1 SEE ALSO

C<Git>
