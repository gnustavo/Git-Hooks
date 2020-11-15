use strict;
use warnings;

package Git::Hooks::CheckDiff;
# ABSTRACT: Git::Hooks plugin to enforce commit policies

use 5.010;
use utf8;
use Carp;
use Log::Any '$log';
use Git::Hooks;
use Path::Tiny;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

# Install hooks
GITHOOKS_CHECK_AFFECTED_REFS \&_check_ref;
GITHOOKS_CHECK_PRE_COMMIT    \&check_commit;
GITHOOKS_CHECK_PATCHSET      \&check_patchset;

sub check_commit {
    my ($git, $current_branch) = @_;

    return _check_everything($git, {ref => $current_branch}, qw/diff-index --cached HEAD/);
}

sub check_patchset {
    my ($git, $branch, $commit) = @_;

    return _check_everything($git, {ref => $branch, commit => $commit}, 'diff-tree', $commit);
}

sub _check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # If the reference is being deleted we have nothing to check
    return 0 if $new_commit eq $git->undef_commit;

    # If the reference is being created we have to calculate a proper
    # $old_commit to diff against.
    if ($old_commit eq $git->undef_commit) {
        my $last_log;
        my $log_iterator = $git->log($new_commit, qw/--not --all/);
        while (my $log = $log_iterator->next()) {
            $last_log = $log;
        }
        return 0 unless $last_log;
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

    return _check_everything($git, {ref => $ref}, 'diff-tree', $old_commit, $new_commit);
}

sub _check_everything {
    my ($git, $ctx, $git_cmd, @git_args) = @_;

    my $diff_text;
    my $diff = sub {
        $diff_text //= $git->run(
            $git_cmd, qw/-p -U0 --no-color --diff-filter=AM --no-prefix/, @git_args
        );
        return $diff_text;
    };

    return 0 == (
        _check_shell($git, $ctx, $diff) +
        _check_token($git, $ctx, $diff)
    )
}

sub _check_shell {
    my ($git, $ctx, $diff) = @_;

    my @commands = $git->get_config($CFG => 'shell');

    return 0 unless @commands;

    my $diff_file = _diff_file($diff);

    unless ($diff_file) {
        $git->fault("git diff failed", {%$ctx});
        return 1;
    }

    my $errors = 0;

    foreach my $command (@commands) {
        $errors += _check_command($git, $ctx, $command, $diff_file);
    }

    return $errors;
}

sub _diff_file {
    my ($diff) = @_;

    my $file = Path::Tiny->tempfile();

    $file->spew($diff->());

    return $file;
}

sub _check_command {
    my ($git, $ctx, $command, $input_file) = @_;

    # execute command and update $errors
    my ($exit, $output);
    {
        my $output_file = Path::Tiny->tempfile();

        ## no critic (RequireBriefOpen, RequireCarping)
        open(my $oldin,  '<&', \*STDIN) or croak "Can't dup STDIN: $!";
        open(STDIN    ,  '<' , $input_file) or croak "Can't redirect STDIN to \$input_file: $!";
        open(my $oldout, '>&', \*STDOUT) or croak "Can't dup STDOUT: $!";
        open(STDOUT    , '>' , $output_file) or croak "Can't redirect STDOUT to \$output_file: $!";
        open(my $olderr, '>&', \*STDERR) or croak "Can't dup STDERR: $!";
        open(STDERR    , '>&', \*STDOUT) or croak "Can't dup STDOUT for STDERR: $!";

        $exit = system('/bin/sh', '-c', $command);

        open(STDIN,  '<&', $oldin)  or croak "Can't dup \$oldin: $!";
        open(STDOUT, '>&', $oldout) or croak "Can't dup \$oldout: $!";
        open(STDERR, '>&', $olderr) or croak "Can't dup \$olderr: $!";
        ## use critic

        $output = $output_file->slurp;
    }

    if ($exit != 0) {
        my $message = do {
            if ($exit == -1) {
                "Command '$command' could not be executed: $!";
            } elsif ($exit & 127) {
                sprintf("Command '%s' was killed by signal %d, %s coredump",
                        $command, ($exit & 127), ($exit & 128) ? 'with' : 'without');
            } else {
                sprintf("Command '%s' failed with exit code %d", $command, $exit >> 8);
            }
        };

        $git->fault($message, {%$ctx, details => $output});
    } else {
        # FIXME: What should we do with eventual output from a
        # successful command?
    }

    return $exit != 0;
}

sub _check_token {
    my ($git, $ctx, $diff) = @_;

    my @deny_tokens = $git->get_config($CFG => 'deny-token')
        or return 0;

    if ($git->version_lt('1.7.4')) {
        $git->fault(<<'EOS', {option => 'deny-token'});
This option requires Git 1.7.4 or later but your Git is older.
Please, upgrade your Git or disable this option.
EOS
        return 1;
    }

    my $errors = 0;

    foreach my $deny_token (@deny_tokens) {
        my ($regex, $filters) = split /\s+--\s+/, $deny_token, 2;

        my $match_token = qr/^\+.*?$regex/; # FIXME: detect error

        my @filters;

        if ($filters) {
            foreach my $filter (split ' ', $filters) {
                my $negated;
                if ($filter =~ s/^\!//) {
                    $negated = 1;
                }
                if ($filter =~ m/^\^/) {
                    $filter = qr/$filter/;
                }
                push @filters, [$negated, $filter];
            }
        }

        my $file = '';
        my @matches;

      LINE:
        foreach (split /\n/, $diff->()) {
            if (/^\+\+\+ (.+)/) {
                $file = $1;
                if (@filters) {
                    foreach my $filter (@filters) {
                        if ($filter->[0] xor ## no critic (ProhibitDeepNests)
                                ((ref $filter->[1] and
                                  $file =~ $filter->[1]) or
                                  (not ref $filter->[1] and
                                   $filter->[1] eq substr($file, 0, length($filter->[1]))))) {
                            next LINE;
                        }
                    }
                    $file = '';
                }
            } elsif (length $file && $_ =~ $match_token) {
                push @matches, "$file: $_";
            }
        }

        if (@matches) {
            $git->fault(<<"EOS", {%$ctx, option => 'deny-token', details => join("\n", @matches)});
Invalid lines matching '$regex' below.
Please, rewrite them and try again.
EOS
            $errors += 1;
        }
    }

    return $errors;
}

1;


__END__
=for Pod::Coverage check_patchset check_commit

=head1 NAME

Git::Hooks::CheckDiff - Git::Hooks plugin to check commit diffs

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckDiff

    # These users are exempt from all checks
    admin = joe molly

  [githooks "checkdiff"]

    # Reject commits adding lines containing FIXME
    deny-token = \\bFIXME\\b

    # Reject commits adding lines containing TODO (ignoring case) but only on
    # files under the directories lib/ and t/.
    deny-token = (?i)\\bTODO\\b -- ^lib/ ^t/

    # Reject commits which change lines containing the string COPYRIGHT
    shell = /usr/bin/grep COPYRIGHT && false

    # Reject commits which add lines containing secrets
    shell = /path/to/script/find-secret-leakage-in-git-diff.pl

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to check commit diffs.

=over

=item * B<pre-commit>, B<pre-applypatch>

This hook is invoked before a commit is made to check the diffs that it would
record.

=item * B<update>

This hook is invoked multiple times in the remote repository during C<git push>,
once per branch being updated, to check the differences being committed in it.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>, to
check the differences being committed in all of of affected references.

=item * B<ref-update>

This hook is invoked when a direct push request is received by Gerrit Code
Review, to check the differences being committed.

=item * B<commit-received>

This hook is invoked when a push request is received by Gerrit Code Review to
create a change for review, to check the differences being committed.

=item * B<submit>

This hook is invoked when a change is submitted in Gerrit Code Review, to check
the differences being committed.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code Review for a
virtual branch (refs/for/*), to check the differences being committed.

=back

To enable this plugin you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckDiff

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checkdiff> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 deny-token REGEXP [-- FILTER...]

This directive rejects commits or pushes which add lines matching REGEXP, which
is a Perl regular expression. This is a multi-valued directive, i.e., you can
specify it multiple times to check several REGEXes.

It is useful to detect marks left by developers in the code while developing,
such as FIXME or TODO. These marks are usually a reminder to fix things before
commit, but as it so often happens, they end up being forgotten.

By default the token are looked for in all added lines in the whole commit or
commit sequence diff. Optional filters may be specified to restrict which files
should be considered. Only differences of affected files which names match at
least one filter are checked for tokens.

The REGEXP and the FILTERs are separated by two hyphens.

A FILTER is a string used to match file paths. It can be optionally initiated by
a '!' character, which reverses the matching logic, effectively selecting paths
not matching it. If the remaining string initiates with a '^' it's treated as a
Perl regular expression anchored at the beginning, which is used to match file
paths. Otherwise, the string matches files paths having it as a prefix.

Note that this option requires Git 1.7.4 or newer.

=head2 shell COMMAND

This directive invokes COMMAND as a single string passed to C</bin/sh -c>, which
means it can use shell operators such as pipes and redirections.

COMMAND must read from its STDIN the output of git-diff invoked like this:

  git diff* -p -U0 --no-color --diff-filter=AM --no-prefix

(The actual sub-command may be diff-index or diff-tree, depending on the actual
hook being invoked. The options above are meant to fix the output format.)

The output format of this command is something like this:

  diff --git Changes Changes
  index cbddd73..2679af9 100644
  --- Changes
  +++ Changes
  @@ -4,0 +5,6 @@ Revision history for perl module Git-Hooks. -*- text -*-
  +2.10.1    2018-12-20 21:33:27-02:00 America/Sao_Paulo
  +
  +[Fix]
  +
  +  - The hook-specific help-on-error config wasn't being used.
  +
  diff --git README.pod README.pod
  index ead2a0a..2ccfb4d 100644
  --- README.pod
  +++ README.pod
  @@ -72 +72 @@ plugins provided by the distribution are these:
  -For a gentler introduction you can read our L<Git::Hooks::Tutorial>. They have
  +For a gentler introduction you can read our L<Git::Hooks::Tutorial>. It has
  diff --git lib/Git/Hooks.pm lib/Git/Hooks.pm
  index c60d098..87fee38 100644
  --- lib/Git/Hooks.pm
  +++ lib/Git/Hooks.pm
  @@ -37 +37 @@ BEGIN {                         ## no critic (RequireArgUnpacking)
  -                package => scalar(caller(1)),
  +                package => scalar(caller),

It's up to COMMAND to check the diff and exit with a code telling if everything
is fine (0) or if there is something wrong in it (not 0). Any output from
COMMAND (STDOUT or STDERR) will end up being shown to the user.

The script F<find-secret-leakage-in-git-diff.pl>, which is part of the
Git::Hooks module, is a good example of a script which can detect problems in a
Git diff.
