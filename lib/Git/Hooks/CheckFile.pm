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
    my ($git, $ctx, $commit, $file, $command) = @_;

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

        $git->fault($message, {%$ctx, details => $output});
        return;
    } else {
        # FIXME: What should we do with eventual output from a
        # successful command?
    }
    return 1;
}

sub check_new_files {
    my ($git, $ctx, $commit, $name2status) = @_;

    return 0 unless %$name2status; # No new file to check

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
    foreach my $file (sort keys %$name2status) {
        # We're only interested in new and modified files
        next unless $name2status->{$file} =~ /[AM]/;

        my $basename = path($file)->basename;

        if (any  {$basename =~ $_} @{$re_checks{basename}{deny}} and
            none {$basename =~ $_} @{$re_checks{basename}{allow}}) {
            $git->fault(<<EOS, {%$ctx, option => 'basename.{allow,deny}'});
The file '$file' basename is not allowed.
Please, check your configuration options.
EOS
            ++$errors;
            next FILE;          # Don't botter checking the contents of invalid files
        }

        if (any  {$file =~ $_} @{$re_checks{path}{deny}} and
            none {$file =~ $_} @{$re_checks{path}{allow}}) {
            $git->fault(<<EOS, {%$ctx, option => 'path.{allow,deny}'});
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
            $git->fault(<<EOS, {%$ctx, option => '[basename.]sizelimit'});
The file '$file' is too big.

It has $size bytes but the current limit is $file_sizelimit bytes.
Please, check your configuration options.
EOS
            ++$errors;
            next FILE;    # Don't botter checking the contents of huge files
        }

        foreach my $command (map {$_->[1]} grep {$basename =~ $_->[0]} @name_checks) {
            check_command($git, $ctx, $commit, $file, $command)
                or ++$errors;
        }

        my $mode;

        if (any {$basename =~ $_} @{$executable_checks{'executable'}}) {
            $mode = $git->file_mode($commit, $file);
            unless ($mode & 0b1) {
                $git->fault(<<EOS, {%$ctx, option => 'executable'});
The file '$file' is not executable but should be.
Please, check your configuration options.
EOS
                ++$errors;
            }
        }

        if (any {$basename =~ $_} @{$executable_checks{'not-executable'}}) {
            if (defined $mode) {
                git->fault(<<EOS, {%$ctx, option => '[not-]executable'});
Configuration error: The file '$file' matches a 'executable' and a
'not-executable' option simultaneously, which is inconsistent.
Please, fix your configuration so that it matches only one of these options.
EOS
                ++$errors;
            }
            $mode = $git->file_mode($commit, $file);
            if ($mode & 0b1) {
                $git->fault(<<EOS, {%$ctx, option => 'not-executable'});
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
    my ($git, $ctx, $commit, $name2status) = @_;

    return 0 unless $git->get_config_boolean($CFG => 'deny-case-conflict');

    # We're only interested in new file names
    my @names = sort grep {$name2status->{$_} =~ /[AC]/} keys %$name2status;

    return 0 unless @names;     # No new names to check

    # Grok the list of all files in the repository at $commit
    my @ls_files = split(
        /\0/,
        $git->run(qw/ls-tree -r -z --name-only --full-tree/,
                  $commit ne ':0' ? $commit : $git->get_head_or_empty_tree),
    );

    my $errors = 0;

    # Check if the new files conflict with each other
    for (my $i = 0; $i < $#names; ++$i) {
        for (my $j = $i + 1; $j <= $#names; ++$j) {
            if (lc($names[$i]) eq lc($names[$j]) && $names[$i] ne $names[$j]) {
                ++$errors;
                $git->fault(<<EOS, {%$ctx, option => 'deny-case-conflict'});
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
                $git->fault(<<EOS, {%$ctx, option => 'deny-case-conflict'});
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
    my ($git, $ctx, $commit) = @_;

    my $regex = $git->get_config($CFG => 'deny-token')
        or return 0;

    if ($git->version_lt('1.7.4')) {
        $git->fault(<<EOS, {option => 'deny-token'});
This option requires Git 1.7.4 or later but your Git is older.
Please, upgrade your Git or disable this option.
EOS
        return 1;
    }

    # Extract only the lines showing addition of the $regex
    my @diff = grep {/^\+.*?(?:$regex)/}
        ($commit ne ':0'
         ? $git->run(qw/diff-tree  -p --diff-filter=AM --ignore-submodules/,
                     "-G$regex", $commit)
         : $git->run(qw/diff-index --cached -p --diff-filter=AM --ignore-submodules/,
                     "-G$regex", $git->get_head_or_empty_tree));

    if (@diff) {
        $git->fault(<<EOS, {%$ctx, option => 'deny-token', details => join("\n", @diff)});
Invalid tokens detected in added lines.
This option rejects lines matching $regex.
Please, amend these lines and try again.
EOS
    }

    return scalar @diff;
}

# Assign meaningful names to action codes.
my %ACTION = (
    A => 'add',
    M => 'modify',
    D => 'delete',
);

sub check_acls {
    my ($git, $ctx, $name2status) = @_;

    my @acls = eval { $git->grok_acls($CFG, 'AMD') };
    if ($@) {
        $git->fault($@, $ctx);
        return 1;
    }

    return 0 unless @acls;

    # Collect the ACL errors and group them by ACL/ACTION so that we can produce
    # more compact error messages.
    my %acl_errors;

  FILE:
    foreach my $file (sort keys %$name2status) {
        my $statuses = $name2status->{$file};
        foreach my $acl (@acls) {
            next unless ref $acl->{spec} ? $file =~ $acl->{spec} : $file eq $acl->{spec};

            # $status is usually a single letter but it can be a string of
            # letters if we grokked affected files in a merge commit. So, we
            # consider a match if the intersection of the two strings ($statuses
            # and $acl->{action}) is not empty.
            next unless any {index($acl->{action}, $_) != -1} split //, $statuses;

            unless ($acl->{allow}) {
                my $action = $ACTION{$statuses} || $statuses;
                push @{$acl_errors{$acl->{acl}}{$action}}, $file;
            }

            next FILE;
        }
    }

    if (%acl_errors) {
        my $myself = $git->authenticated_user();
        my %context = (%$ctx, option => 'acl');
        while (my ($acl, $actions) = each %acl_errors) {
            while (my ($action, $files) = each %$actions) {
                my $these_files = scalar(@$files) > 1 ? 'these files' : 'this file';
                $git->fault(<<EOS, \%context);
Authorization error: you ($myself) cannot $action $these_files:

  @{[join("\n  ", @$files)]}

Due to the following acl:

  $acl
EOS
            }
        }
    }

    return scalar %acl_errors;
}

sub check_everything {
    my ($git, $ref, $commit, $extra) = @_;

    # The $extra information was generated by the --name-status --cc options to
    # git-log. It has one line for each file affected in the commit. Merge
    # commits only show files with conflicts. The format is "<S>+\t<FILE>".  <S>
    # is one letter indicating how the file was affected, as documented in the
    # --diff-filter option. <FILE> is the file path since the repository root,
    # without a leading slash.

    my %name2status;

    if (defined $extra) {
        foreach (split /\n/, $extra) {
            if (/^(?<status>[ACDMRTUXB0-9]+)\t(?<file>.+)/) {
                $name2status{$+{file}} = $+{status};
            }
        }
    }

    my %context = (ref => $ref);
    $context{commit} = $commit unless $commit eq ':0';

    return
        check_new_files($git, \%context, $commit, \%name2status) +
        check_acls($git, \%context, \%name2status) +
        deny_case_conflicts($git, \%context, $commit, \%name2status) +
        deny_token($git, \%context, $commit);
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        next unless $git->is_reference_enabled($ref);

        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

        my @commits = $git->get_commits(
            $old_commit,
            $new_commit,
            [qw/--name-status --ignore-submodules -r --cc/],
        );

        foreach my $commit (@commits) {
            $errors += check_everything($git, $ref, $commit->commit, $commit->extra);
        }
    }

    return $errors == 0;
}

sub check_commit {
    my ($git) = @_;

    _setup_config($git);

    my $current_branch = $git->get_current_branch();

    return 1 unless $git->is_reference_enabled($current_branch);

    return 0 == check_everything(
        $git,
        $current_branch,
        ':0',                   # mark to signify the index
        $git->run(qw/diff-index --name-status --ignore-submodules --no-commit-id --cached -r/,
                  $git->get_head_or_empty_tree));
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    # The --branch argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $branch = $opts->{'--branch'};
    $branch = "refs/heads/$branch"
        unless $branch =~ m:^refs/:;

    return 1 unless $git->is_reference_enabled($branch);

    my ($commit) = $git->get_commits(
        "$opts->{'--commit'}^",
        $opts->{'--commit'},
        [qw/-n 1 --name-status --ignore-submodules -r --cc/],
    );

    return 0 == check_everything($git, $branch, $commit->commit, $commit->extra);
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
=for Pod::Coverage check_command check_new_files deny_case_conflicts deny_token check_acls check_everything check_affected_refs check_commit check_patchset

=head1 NAME

CheckFile - Git::Hooks plugin for checking files

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckFile

    # These users are exempt from all checks
    admin = joe molly

    # These groups are used in ACL specs below
    groups = architects = tiago juliana
    groups = dbas       = joao maria

  [githooks "checkfile"]

    # Check specific files with specific commands
    name = *.p[lm] perlcritic --stern --verbose 10
    name = *.pp    puppet parser validate --verbose --debug
    name = *.pp    puppet-lint --no-variable_scope-check --no-documentation-check
    name = *.sh    bash -n
    name = *.sh    shellcheck --exclude=SC2046,SC2053,SC2086
    name = *.yml   yamllint
    name = *.js    eslint -c ~/.eslintrc.json

    # Reject files bigger than 1MiB
    sizelimit = 1M

    # Reject files with names that would conflict with other files in the
    # repository in case-insensitive filesystems, such as the ones on Windows.
    deny-case-conflict = true

    # Reject files containing the strings FIXME or TODO.
    deny-token = \\b(FIXME|TODO)\\b

    # Reject commits adding scripts without the executable bit set.
    executable = *.sh
    executable = *.csh
    executable = *.ksh
    executable = *.zsh

    # Reject commits adding source files with the executable bit set.
    not-executable = qr/\\.(?:c|cc|java|pl|pm|txt)$/

    # Only architects may add, modify, or delete pom.xml files.
    acl = deny  AMD ^(?i).*pom\\.xml
    acl = allow AMD ^(?i).*pom\\.xml by @architects

    # Only dbas may add or delete SQL files under database/
    acl = deny  AD ^database/.*\\.sql$
    acl = allow AD ^database/.*\\.sql$ by @dba

    # Reject new files containing dangerous characters, avoiding names which may
    # cause problems.
    acl = deny  A   ^.*[^a-zA-Z0-1/_.-]

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

    [githooks]
      plugin = CheckFile

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checkfile> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 name PATTERN COMMAND

This directive tells which COMMAND should be used to check files matching
PATTERN.

Only the file's basename is matched against PATTERN.

PATTERN is usually expressed with
L<globbing|https://metacpan.org/pod/File::Glob> to match files based on
their extensions, for example:

    [githooks "checkfile"]
      name = *.pl perlcritic --stern

If you need more power than globs can provide you can match using L<regular
expressions|http://perldoc.perl.org/perlre.html>, using the C<qr//>
operator, for example:

    [githooks "checkfile"]
      name = qr/xpto-\\d+.pl/ perlcritic --stern

COMMAND is everything that comes after the PATTERN. It is invoked once for
each file matching PATTERN with the name of a temporary file containing the
contents of the matching file passed to it as a last argument.  If the
command exits with any code different than 0 it is considered a violation
and the hook complains, rejecting the commit or the push.

If the filename can't be the last argument to COMMAND you must tell where in
the command-line it should go using the placeholder C<{}> (like the argument
to the C<find> command's C<-exec> option). For example:

    [githooks "checkfile"]
      name = *.xpto cmd1 --file {} | cmd2

COMMAND is invoked as a single string passed to C<system>, which means it
can use shell operators such as pipes and redirections.

Some real examples:

    [githooks "checkfile"]
      name = *.p[lm] perlcritic --stern --verbose 5
      name = *.pp    puppet parser validate --verbose --debug
      name = *.pp    puppet-lint --no-variable_scope-check
      name = *.sh    bash -n
      name = *.sh    shellcheck --exclude=SC2046,SC2053,SC2086
      name = *.erb   erb -P -x -T - {} | ruby -c

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

    [githooks "checkfile"]
      name = *.py mypylint.sh

And the F<mypylint.sh> script was something like this:

    #!/bin/bash

    # Create a temporary file do save the pylint.rc
    RC=$(tempfile)
    trap 'rm $RC' EXIT

    git cat-file $GIT_COMMIT:pylint.rc >$RC

    pylint --rcfile=$RC "$@"

=head2 sizelimit INT

This directive specifies a size limit (in bytes) for any file in the
repository. If set explicitly to 0 (zero), no limit is imposed, which is the
default. But it can be useful to override a global specification in a particular
repository.

=head2 basename.sizelimit BYTES REGEXP

This directive takes precedence over the C<githooks.checkfile.sizelimit> for
files which basename matches REGEXP.

=head2 deny-case-conflict BOOL

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

=head2 deny-token REGEXP

This directive rejects commits or pushes which diff (patch) matches REGEXP. This
is a multi-valued directive, i.e., you can specify it multiple times to check
several REGEXes.

It is useful to detect marks left by developers in the code while developing,
such as FIXME or TODO. These marks are usually a reminder to fix things before
commit, but as it so often happens, they end up being forgotten.

Note that this option requires Git 1.7.4 or newer.

=head2 executable PATTERN

This directive requires that all added or modified files with names matching
PATTERN must have the executable permission. This allows you to detect common
errors such as forgetting to set scripts as executable.

PATTERN is specified as described in the C<githooks.checkfile.name> directive
above.

You can specify this option multiple times so that all PATTERNs are considered.

=head2 non-executable PATTERN

This directive requires that all added or modified files with names matching
PATTERN must B<not> have the executable permission. This allows you to detect
common errors such as setting source code as executable.

PATTERN is specified as described in the C<githooks.checkfile.name> directive
above.

You can specify this option multiple times so that all PATTERNs are considered.

=head2 acl RULE

This multi-valued option specifies rules allowing or denying specific users to
perform specific actions on specific files. By default any user can perform any
action on any file. So, the rules are used to impose restrictions.

The acls are grokked by the L<Git::Repository::Plugin::GitHooks>'s C<grok_acls>
method. Please read its documentation for the general documentation.

A RULE takes three or four parts, like this:

  (allow|deny) [AMD]+ <filespec> (by <userspec>)?

Some parts are described below:

=over 4

=item * B<[AMD]+>

The second part specifies which actions are being considered by a combination of
letters: (A) for files added, (M) for files modified, and (D) for files
deleted. (These are the same letters used in the C<--diff-filter> option of the
C<git diff-tree> command.) You can specify one, two, or the three letters.

=item * B<< <filespec> >>

The third part specifies which files are being considered. In its simplest form,
a C<filespec> is a complete path beginning at the repository root, without a
leading slash (e.g. F<lib/Git/Hooks.pm>). These filespecs match a single file
exactly.

If the C<filespec> starts with a caret (^) it's interpreted as a Perl regular
expression, the caret being kept as part of the regexp. These filespecs match
potentially many files (e.g. F<^lib/.*\\.pm$>).

=back

See the L</SYNOPSIS> section for some examples.

=head2 [DEPRECATED] basename.deny REGEXP

This option is deprecated. Please, use an C<acl> option like this, instead:

  [githooks "checkfile"]
    acl = deny A ^.*<REGEXP>$

This directive denies files which basenames match REGEXP.

=head2 [DEPRECATED] basename.allow REGEXP

This option is deprecated. Please, use an C<acl> option like this, instead:

  [githooks "checkfile"]
    acl = allow A ^.*<REGEXP>$

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

=head2 [DEPRECATED] path.deny REGEXP

This option is deprecated. Please, use an C<acl> option like this, instead:

  [githooks "checkfile"]
    acl = deny A ^<REGEXP>

This directive denies files which full paths match REGEXP.

=head2 [DEPRECATED] path.allow REGEXP

This option is deprecated. Please, use an C<acl> option like this, instead:

  [githooks "checkfile"]
    acl = allow A ^<REGEXP>

This directive allows files which full paths match REGEXP. It's useful in
the same way that B<githooks.checkfile.basename.deny> is.

=cut
