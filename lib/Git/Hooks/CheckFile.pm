#!/usr/bin/env perl

package Git::Hooks::CheckFile;
# ABSTRACT: Git::Hooks plugin for checking files

use 5.010;
use utf8;
use strict;
use warnings;
use Carp;
use Git::Hooks;
use Text::Glob qw/glob_to_regex/;
use Path::Tiny;
use List::MoreUtils qw/any none/;

(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};

    $default->{sizelimit} //= [0];

    return;
}

sub check_command {
    my ($git, $commit, $file, $command) = @_;

    my $tmpfile = $git->blob($commit, $file)
        or return;

    # interpolate filename in $command
    (my $cmd = $command) =~ s/\{\}/\'$tmpfile\'/g;

    # execute command and update $errors
    my ($exit, $output);
    {
        my $tempfile = Path::Tiny->tempfile(UNLINK => 1);

        ## no critic (RequireBriefOpen, RequireCarping)
        open(my $oldout, '>&', \*STDOUT)  or croak "Can't dup STDOUT: $!";
        open(STDOUT    , '>' , $tempfile) or croak "Can't redirect STDOUT to \$tempfile: $!";
        open(my $olderr, '>&', \*STDERR)  or croak "Can't dup STDERR: $!";
        open(STDERR    , '>&', \*STDOUT)  or croak "Can't dup STDOUT for STDERR: $!";

        # Let the external command know the commit that's being checked in
        # case it needs to grok something from Git.
        local $ENV{GIT_COMMIT} = $commit;
        $exit = system $cmd;

        open(STDOUT, '>&', $oldout) or croak "Can't dup \$oldout: $!";
        open(STDERR, '>&', $olderr) or croak "Can't dup \$olderr: $!";
        ## use critic

        $output = $tempfile->slurp;
    }

    if ($exit != 0) {
        $command =~ s/\{\}/\'$file\'/g;
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

        # Replace any instance of the $tmpfile name in the output by
        # $file to avoid confounding the user.
        $output =~ s/\Q$tmpfile\E/$file/g;

        $git->fault($message, {commit => $commit, details => $output});
        return;
    } else {
        # FIXME: What should we do with eventual output from a
        # successful command?
    }
    return 1;
}

sub check_new_files {
    my ($git, $commit, @files) = @_;

    return 1 unless @files;     # No new file to check

    # Construct a list of command checks from the
    # githooks.checkfile.name configuration. Each check in the list is a
    # pair containing a regex and a command specification.
    my @name_checks;
    foreach my $check ($git->get_config($CFG => 'name')) {
        my ($pattern, $command) = split / /, $check, 2;
        if ($pattern =~ m/^qr(.)(.*)\g{1}/) {
            $pattern = qr/$2/;
        } else {
            $pattern = glob_to_regex($pattern);
        }
        $command .= ' {}' unless $command =~ /\{\}/;
        push @name_checks, [$pattern => $command];
    }

    # See if we have to check a file size limit
    my $sizelimit = $git->get_config_integer($CFG => 'sizelimit');

    # Grok all REGEXP checks
    my %re_checks;
    foreach my $name (qw/basename path/) {
        foreach my $check (qw/deny allow/) {
            $re_checks{$name}{$check} = [map {qr/$_/} $git->get_config("$CFG.$name" => $check)];
        }
    }
    foreach ($git->get_config("$CFG.basename" => 'sizelimit')) {
        my ($bytes, $regexp) = split ' ', $_, 2;
        unshift @{$re_checks{basename}{sizelimit}}, [qr/$regexp/, $bytes];
    }

    # Grok the list of patterns to check for executable permissions
    my %executable_checks;
    foreach my $check (qw/executable not-executable/) {
        foreach my $pattern ($git->get_config($CFG => $check)) {
            if ($pattern =~ m/^qr(.)(.*)\g{1}/) {
                $pattern = qr/$2/;
            } else {
                $pattern = glob_to_regex($pattern);
            }
            push @{$executable_checks{$check}}, $pattern;
        }
    }

    # Now we iterate through every new file and apply to them the matching
    # commands.
    my $errors = 0;

  FILE:
    foreach my $file (@files) {
        my $basename = path($file)->basename;

        if (any  {$basename =~ $_} @{$re_checks{basename}{deny}} and
            none {$basename =~ $_} @{$re_checks{basename}{allow}}) {
            $git->fault(<<EOS, {commit => $commit, option => 'basename.{allow,deny}'});
The file '$file' basename is not allowed.
Please, check your configuration options.
EOS
            ++$errors;
            next FILE;          # Don't botter checking the contents of invalid files
        }

        if (any  {$file =~ $_} @{$re_checks{path}{deny}} and
            none {$file =~ $_} @{$re_checks{path}{allow}}) {
            $git->fault(<<EOS, {commit => $commit, option => 'path.{allow,deny}'});
The file '$file' path is not allowed.
Please, check your configuration options.
EOS
            ++$errors;
            next FILE;          # Don't botter checking the contents of invalid files
        }

        my $size = $git->file_size($commit, $file);

        my $file_sizelimit = $sizelimit;
        foreach my $spec (@{$re_checks{basename}{sizelimit}}) {
            if ($basename =~ $spec->[0]) {
                $file_sizelimit = $spec->[1];
                last;
            }
        }

        if ($file_sizelimit && $file_sizelimit < $size) {
            $git->fault(<<EOS, {commit => $commit, option => '[basename.]sizelimit'});
The file '$file' is too big.

It has $size bytes but the current limit is $file_sizelimit bytes.
Please, check your configuration options.
EOS
            ++$errors;
            next FILE;    # Don't botter checking the contents of huge files
        }

        foreach my $command (map {$_->[1]} grep {$basename =~ $_->[0]} @name_checks) {
            check_command($git, $commit, $file, $command)
                or ++$errors;
        }

        my $mode;

        if (any {$basename =~ $_} @{$executable_checks{'executable'}}) {
            $mode = $git->file_mode($commit, $file);
            unless ($mode & 0b1) {
                $git->fault(<<EOS, {commit => $commit, option => 'executable'});
The file '$file' is not executable but should be.
Please, check your configuration options.
EOS
                ++$errors;
            }
        }

        if (any {$basename =~ $_} @{$executable_checks{'not-executable'}}) {
            if (defined $mode) {
                git->fault(<<EOS, {commit => $commit, option => '[not-]executable'});
Configuration error: The file '$file' matches a 'executable' and a
'not-executable' option simultaneously, which is inconsistent.
Please, fix your configuration so that it matches only one of these options.
EOS
                ++$errors;
            }
            $mode = $git->file_mode($commit, $file);
            if ($mode & 0b1) {
                $git->fault(<<EOS, {commit => $commit, option => 'not-executable'});
The file '$file' is executable but should not be.
Please, check your configuration options.
EOS
                ++$errors;
            }
        }
    }

    return $errors;
}

sub deny_case_conflicts {
    my ($git, $commit, $get_names_sub) = @_;

    return 0 unless $git->get_config_boolean($CFG => 'deny-case-conflict');

    # $get_names_sub is a reference to a function which returns the list of
    # names of files added in $commit. We get a sub-ref instead of the actual
    # list to avoid calling a git command before making sure above that we
    # really need to check this. (NOTE: This may be premature optimization,
    # which is the root of all evil, but I'm leaving it in for now.)
    my @names = $get_names_sub->();

    return 0 unless @names;     # No new names to check

    # Grok the list of all files in the repository at $commit
    my @ls_files = split /\0/, $git->run(qw/ls-tree -r -z --name-only --full-tree/,
                                         $commit eq ':0' ? 'HEAD' : $commit);

    my $errors = 0;

    # Check if the new files conflict with each other
    for (my $i = 0; $i < $#names; ++$i) {
        for (my $j = $i + 1; $j <= $#names; ++$j) {
            if (lc($names[$i]) eq lc($names[$j]) && $names[$i] ne $names[$j]) {
                ++$errors;
                $git->fault(<<EOS, {commit => $commit, option => 'deny-case-conflict'});
This commit adds two files with names that will conflict
with each other in the repository in case-insensitive
filesystems:

  $names[$i]
  $names[$j]

Please, rename the added files to avoid the conflict and amend your commit.
EOS
            }
        }
    }

    # Check if the new files conflict with already existing files
    foreach my $file (@ls_files) {
        my $lc_file = lc $file;
        foreach my $name (@names) {
            my $lc_name = lc $name;
            if ($lc_name eq $lc_file && $name ne $file) {
                ++$errors;
                $git->fault(<<EOS, {commit => $commit, option => 'deny-case-conflict'});
This commit adds a file with a name that will conflict
with the name of another file already existing in the repository
in case-insensitive filesystems:

  ADDED:    $name
  EXISTING: $file

Please, rename the added file to avoid the conflict and amend your commit.
EOS
            }
        }
    }

    return $errors;
}

sub deny_token {
    my ($git, $new_commit, $old_commit) = @_;

    my $regex = $git->get_config($CFG => 'deny-token')
        or return 0;

    if ($git->version_lt('1.7.4')) {
        $git->fault(<<EOS, {option => 'deny-token'});
This option requires Git 1.7.4 or later but your Git is older.
Please, upgrade your Git or disable this option.
EOS
        return 1;
    }

    my @diff;

    if (! defined $new_commit) {
        die 'Internal error: $new_commit must be defined';
    } elsif ($new_commit eq ':0') {
        @diff = $git->run(qw/diff-index -p --diff-filter=AM --ignore-submodules/,
                          "-G$regex", 'HEAD');
    } elsif (! defined $old_commit) {
        @diff = $git->run(qw/diff-tree -p --diff-filter=AM --ignore-submodules/,
                          "-G$regex", $new_commit);
    } else {
        @diff = $git->run(qw/diff-tree -p --diff-filter=AM --ignore-submodules/,
                          "-G$regex", $old_commit, $new_commit);
    }

    # Extract only the lines showing addition of the $regex
    @diff = grep {/^+.*?(?:$regex)/} @diff;

    if (@diff) {
        $git->fault(<<EOS, {option => 'deny-token', details => join("\n", @diff)});
Invalid tokens detected in added lines.
This option rejects lines matching $regex.
Please, amend these lines and try again.
EOS
    }

    return scalar @diff;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
        $errors += check_new_files($git, $new_commit, $git->filter_files_in_range('AM', $old_commit, $new_commit));
        $errors += deny_case_conflicts($git, $new_commit, sub { $git->filter_files_in_range('ACR', $old_commit, $new_commit) });
        $errors += deny_token($git, $new_commit, $old_commit);
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    _setup_config($git);

    my $errors = 0;

    $errors += check_new_files($git, ':0', $git->filter_files_in_index('AM'));
    $errors += deny_case_conflicts($git, ':0', sub { $git->filter_files_in_index('ACR') });
    $errors += deny_token($git, ':0');

    return $errors == 0;
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    $errors += check_new_files($git, $opts->{'--commit'}, $git->filter_files_in_commit('AM', $opts->{'--commit'}));
    $errors += deny_case_conflicts($git, $opts->{'--commit'}, sub { $git->filter_files_in_commit('ACR', $opts->{'--commit'}) });
    $errors += deny_token($git, $opts->{'--commit'});

    return $errors == 0;
}

INIT: {
    # Install hooks
    PRE_APPLYPATCH   \&check_commit;
    PRE_COMMIT       \&check_commit;
    UPDATE           \&check_affected_refs;
    PRE_RECEIVE      \&check_affected_refs;
    REF_UPDATE       \&check_affected_refs;
    PATCHSET_CREATED \&check_patchset;
    DRAFT_PUBLISHED  \&check_patchset;
}

1;

__END__
=for Pod::Coverage check_command check_new_files deny_case_conflicts deny_token check_affected_refs check_commit check_patchset

=head1 NAME

CheckFile - Git::Hooks plugin for checking files

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]
    plugin = CheckFile
    admin = joe molly

  [githooks "checkfile"]
    name = *.p[lm] perlcritic --stern --verbose 10
    name = *.pp    puppet parser validate --verbose --debug
    name = *.pp    puppet-lint --no-variable_scope-check --no-documentation-check
    name = *.sh    bash -n
    name = *.sh    shellcheck --exclude=SC2046,SC2053,SC2086
    name = *.yml   yamllint
    name = *.js    eslint -c ~/.eslintrc.json

    sizelimit = 1M

    path.deny = ^.
    path.allow = ^[a-zA-Z0-1/_.-]$

    deny-case-conflict = true

    deny-token = \\b(FIXME|TODO)\\b

    executable = *.sh
    executable = *.csh
    executable = *.ksh
    executable = *.zsh
    not-executable = qr/\\.(?:c|cc|java|pl|pm|txt)$/

The first section enables the plugin and defines the users C<joe> and C<molly>
as administrators, effectivelly exempting them from any restrictions the plugin
may impose.

The second instance enables C<some> of the options specific to this plugin.

The C<name> options associate filenames with commands so that any file added or
modified in the commit which name maches the glob pattern is checked with the
associated command. The commands usually check the files's syntax and style.

The C<sizelimit> option denies the addition or modification of any file bigger
than 1MiB, preventing careless users to commit huge binary files.

The C<path.deny> and C<path.allow> options conspire to only allow the addition
of files which names comprised of only a small set of characters, avoiding names
which may cause problems.

The C<deny-case-conflict> option rejects commits which add files with names that
would conflict with each other or with the names of other files already in the
repository in case-insensitive filesystems, such as the ones on Windows.

The C<deny-token> option rejects commits which introduces lines
containing the strings C<FIXME> or C<TODO>, as they are often committed by
mistake.

The C<executable> option rejects commits adding or modifying scripts (filenames
with extensions F<.sh>, F<.csh>, F<.ksh>, and F<.zsh>) B<without> the executable
permission, which is a common source of errors.

The C<not-executable> option rejects commits adding or modifying source files
(filenames with extensions F<.c>, F<.cc>, F<.java>, F<.pl>, F<.pm>, and F<.txt>)
B<with> the executable permission.

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to check if the
names and contents of files added to or modified in the repository meet
specified constraints. If they don't, the commit/push is aborted.

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

    git config --add githooks.plugin CheckFile

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkfile.name PATTERN COMMAND

This directive tells which COMMAND should be used to check files matching
PATTERN.

Only the file's basename is matched against PATTERN.

PATTERN is usually expressed with
L<globbing|https://metacpan.org/pod/File::Glob> to match files based on
their extensions, for example:

    git config githooks.checkfile.name *.pl perlcritic --stern

If you need more power than globs can provide you can match using L<regular
expressions|http://perldoc.perl.org/perlre.html>, using the C<qr//>
operator, for example:

    git config githooks.checkfile.name qr/xpto-\\d+.pl/ perlcritic --stern

COMMAND is everything that comes after the PATTERN. It is invoked once for
each file matching PATTERN with the name of a temporary file containing the
contents of the matching file passed to it as a last argument.  If the
command exits with any code different than 0 it is considered a violation
and the hook complains, rejecting the commit or the push.

If the filename can't be the last argument to COMMAND you must tell where in
the command-line it should go using the placeholder C<{}> (like the argument
to the C<find> command's C<-exec> option). For example:

    git config githooks.checkfile.name *.xpto cmd1 --file {} | cmd2

COMMAND is invoked as a single string passed to C<system>, which means it
can use shell operators such as pipes and redirections.

Some real examples:

    git config --add githooks.checkfile.name *.p[lm] perlcritic --stern --verbose 5
    git config --add githooks.checkfile.name *.pp    puppet parser validate --verbose --debug
    git config --add githooks.checkfile.name *.pp    puppet-lint --no-variable_scope-check
    git config --add githooks.checkfile.name *.sh    bash -n
    git config --add githooks.checkfile.name *.sh    shellcheck --exclude=SC2046,SC2053,SC2086
    git config --add githooks.checkfile.name *.erb   erb -P -x -T - {} | ruby -c

COMMAND may rely on the B<GIT_COMMIT> environment variable to identify the
commit being checked according to the hook being used, as follows.

=over

=item * B<pre-commit>

This hook does not check a complete commit, but the index tree. So, in this
case the variable is set to F<:0>. (See C<git help revisions>.)

=item * B<update, pre-receive, ref-updated>

In these hooks the variable is set to the SHA1 of the new commit to which
the reference has been updated.

=item * B<patchset-created, draft-published>

In these hooks the variable is set to the argument of the F<--commit> option
(a SHA1) passed to them by Gerrit.

=back

The reason that led to the introduction of the GIT_COMMIT variable was to
enable one to invoke an external command to check files which needed to grok
some configuration from another file in the repository. Specifically, we
wanted to check Python scripts with the C<pylint> command passing to its
C<--rcfile> option the configuration file F<pylint.rc> sitting on the
repository root. So, we configured CheckFile like this:

    git config --add githooks.checkfile.name *.py mypylint.sh

And the F<mypylint.sh> script was something like this:

    #!/bin/bash

    # Create a temporary file do save the pylint.rc
    RC=$(tempfile)
    trap 'rm $RC' EXIT

    git cat-file $GIT_COMMIT:pylint.rc >$RC

    pylint --rcfile=$RC "$@"

=head2 githooks.checkfile.sizelimit INT

This directive specifies a size limit (in bytes) for any file in the
repository. If set explicitly to 0 (zero), no limit is imposed, which is the
default. But it can be useful to override a global specification in a particular
repository.

=head2 githooks.checkfile.basename.deny REGEXP

This directive denies files which basenames match REGEXP.

=head2 githooks.checkfile.basename.allow REGEXP

This directive allows files which basenames match REGEXP. Since by default
all basenames are allowed this directive is useful only to prevent a
B<githooks.checkfile.basename.deny> directive to deny the same basename.

The basename checks are evaluated so that a file is denied only if it's
basename matches any B<basename.deny> directive and none of the
B<basename.allow> directives.  So, for instance, you would apply it like
this to allow the versioning of F<.gitignore> file while denying any other
file with a name beginning with a dot.

    [githooks "checkfile"]
        basename.allow ^\\.gitignore
        basename.deny  ^\\.

=head2 githooks.checkfile.basename.sizelimit BYTES REGEXP

This directive takes precedence over the C<githooks.checkfile.sizelimit> for
files which basename matches REGEXP.

=head2 githooks.checkfile.path.deny REGEXP

This directive denies files which full paths match REGEXP.

=head2 githooks.checkfile.path.allow REGEXP

This directive allows files which full paths match REGEXP. It's useful in
the same way that B<githooks.checkfile.basename.deny> is.

=head2 githooks.checkfile.deny-case-conflict BOOL

This directive checks for newly added files that would conflict in
case-insensitive filesystems.

Git itself is case-sensitive with regards to file names. Many operating system's
filesystems are case-sensitive too, such as Linux, macOS, and other Unix-derived
systems. But Windows's filesystems are notoriously case-insensitive. So, if you
want your repository to be absolutely safe for Windows users you don't want to
add two files which filenames differ only in a case-sensitive manner. Enable
this option to be safe

Note that this check have to check the newly added files against all files
already in the repository. It can be a little slow for large repositories. Take
heed!

=head2 githooks.checkfile.deny-token REGEXP

This directive rejects commits or pushes which diff (patch) matches REGEXP. This
is a multi-valued directive, i.e., you can specify it multiple times to check
several REGEXes.

It is useful to detect marks left by developers in the code while developing,
such as FIXME or TODO. These marks are usually a reminder to fix things before
commit, but as it so often happens, they end up being forgotten.

Note that this option requires Git 1.7.4 or newer.

=head2 githooks.checkfile.executable PATTERN

This directive requires that all added or modified files with names matching
PATTERN must have the executable permission. This allows you to detect common
errors such as forgetting to set scripts as executable.

PATTERN is specified as described in the C<githooks.checkfile.name> directive
above.

You can specify this option multiple times so that all PATTERNs are considered.

=head2 githooks.checkfile.non-executable PATTERN

This directive requires that all added or modified files with names matching
PATTERN must B<not> have the executable permission. This allows you to detect
common errors such as setting source code as executable.

PATTERN is specified as described in the C<githooks.checkfile.name> directive
above.

You can specify this option multiple times so that all PATTERNs are considered.

