package Git::Hooks::Test;
# ABSTRACT: Git::Hooks testing utilities

## no critic (RequireExplicitPackage)
## no critic (ErrorHandling::RequireCarping)
use 5.010;
use strict;
use warnings;
use Carp;
use Config;
use Exporter qw/import/;
use Path::Tiny;
use Git::Repository 'GitHooks';
use Test::More;

our @EXPORT_OK = qw/
        install_hooks
        new_commit
        newdir
        new_repos
        test_command
        test_nok
        test_nok_match
        test_ok
        test_ok_match
/;

our %EXPORT_TAGS = (
    all => \@EXPORT_OK
);

# Make sure the git messages come in English.
local $ENV{LC_ALL} = 'C';

my $cwd = Path::Tiny->cwd;

# It's better to perform all tests in a temporary directory because
# otherwise the author runs the risk of messing with its local
# Git::Hooks git repository.

my $T = Path::Tiny->tempdir(
    TEMPLATE => 'githooks.XXXXX',
    TMPDIR   => 1,
    CLEANUP  => exists $ENV{REPO_CLEANUP} ? $ENV{REPO_CLEANUP} : 1,
);

chdir $T or croak "Can't chdir $T: $!";
END { chdir '/' }

my $tmpldir = $T->child('templates');
mkdir $tmpldir, 0777 or BAIL_OUT("can't mkdir $tmpldir: $!");
{
    my $hooksdir = $tmpldir->child('hooks');
    mkdir $hooksdir, 0777 or BAIL_OUT("can't mkdir $hooksdir: $!");
}

my $git_version = eval { Git::Repository->version } || 'unknown';

sub newdir {
    my $num = 1 + Test::Builder->new()->current_test();
    my $dir = $T->child($num);
    mkdir $dir;
    return $dir;
}

sub install_hooks {
    my ($git, $extra_perl, @hooks) = @_;
    my $hooks_dir = path($git->git_dir())->child('hooks');
    my $hook_pl   = $hooks_dir->child('hook.pl');
    {
        ## no critic (RequireBriefOpen)
        open my $fh, '>', $hook_pl or BAIL_OUT("Can't create $hook_pl: $!");
        state $debug = $ENV{DBG} ? '-d' : '';
        state $bliblib = $cwd->child('blib', 'lib');
        print $fh <<EOS;
#!$Config{perlpath} $debug
use strict;
use warnings;
use lib '$bliblib';
EOS

        state $pathsep = $^O eq 'MSWin32' ? ';' : ':';
        if (defined $ENV{PERL5LIB} and length $ENV{PERL5LIB}) {
            foreach my $path (reverse split "$pathsep", $ENV{PERL5LIB}) {
                say $fh "use lib '$path';" if $path;
            }
        }

        print $fh <<EOS;
use Git::Hooks;
EOS

        print $fh $extra_perl if defined $extra_perl;

        # Not all hooks defined the GIT_DIR environment variable
        # (e.g., pre-rebase doesn't).
        print $fh <<EOS;
\$ENV{GIT_DIR}    = '.git' unless exists \$ENV{GIT_DIR};
\$ENV{GIT_CONFIG} = "\$ENV{GIT_DIR}/config";
EOS

        # Reset HOME to avoid reading ~/.gitconfig
        print $fh <<'EOS';
$ENV{HOME}       = '';
EOS

        # Hooks on Windows are invoked indirectly.
        if ($^O eq 'MSWin32') {
            print $fh <<'EOS';
my $hook = shift;
run_hook($hook, @ARGV);
EOS
        } else {
            print $fh <<'EOS';
run_hook($0, @ARGV);
EOS
        }
    }
    chmod 0755 => $hook_pl;

    @hooks = qw/ applypatch-msg pre-applypatch post-applypatch
        pre-commit prepare-commit-msg commit-msg
        post-commit pre-rebase post-checkout post-merge
        pre-receive update post-receive post-update
        pre-auto-gc post-rewrite /
            unless @hooks;

    foreach my $hook (@hooks) {
        my $hookfile = $hooks_dir->child($hook);
        if ($^O eq 'MSWin32') {
            (my $perl = $^X) =~ tr:\\:/:;
            $hook_pl =~ tr:\\:/:;
            my $d = $ENV{DBG} ? '-d' : '';
            my $script = <<EOS;
#!/bin/sh
$perl $d $hook_pl $hook \"\$@\"
EOS
            path($hookfile)->spew($script)
                or BAIL_OUT("can't path('$hookfile')->spew('$script')\n");
            chmod 0755 => $hookfile;
        } else {
            symlink 'hook.pl', $hookfile
                or BAIL_OUT("can't symlink '$hooks_dir', '$hook': $!");
        }
    }
    return;
}

sub new_repos {
    my $repodir  = $T->child('repo');
    my $filename = $repodir->child('file.txt');
    my $clonedir = $T->child('clone');

    # Remove the directories recursively to create new ones.
    $repodir->remove_tree({safe => 0});
    $clonedir->remove_tree({safe => 0});

    mkdir $repodir, 0777 or BAIL_OUT("can't mkdir $repodir: $!");
    {
        open my $fh, '>', $filename or croak BAIL_OUT("can't open $filename: $!");
        say $fh "first line";
        close $fh;
    }

    my $stderr = $T->child('stderr');

    my @result = eval {
        Git::Repository->run(qw/init -q/, "--template=$tmpldir", $repodir);

        my $repo = Git::Repository->new(work_tree => $repodir);

        $repo->run(qw/config user.email myself@example.com/);
        $repo->run(qw/config user.name/, 'My Self');

        {
            my $cmd = Git::Repository->command(
                qw/clone -q --bare --no-hardlinks/, "--template=$tmpldir", $repodir, $clonedir,
            );

            my $my_stderr = $cmd->stderr;

            open my $err_h, '>', $T->child('stderr')
                or croak "Can't open '@{[$T->child('stderr')]}' for writing: $!\n";
            while (<$my_stderr>) {
                $err_h->print($_);
            }
            close $err_h;

            $cmd->close();
            croak "Can't git-clone $repodir into $clonedir" unless $cmd->exit() == 0;
        }

        my $clone = Git::Repository->new(git_dir => $clonedir);

        $repo->run(qw/remote add clone/, $clonedir);

        return ($repo, $filename, $clone, $T);
    };

    if (my $E = $@) {
        my $exception = "$E";   # stringify it
        if (-s $stderr) {
            open my $err_h, '<', $stderr
                or croak "Can't open '$stderr' for reading: $!\n";
            local $/ = undef;   # slurp mode
            $exception .= 'STDERR=';
            $exception .= <$err_h>;
            close $err_h;
        }

        # The BAIL_OUT function can't show a message with newlines
        # inside. So, we have to make sure to get rid of any.
        $exception =~ s/\n/;/g;
        local $, = ':';
        BAIL_OUT("Error setting up repos for test: Exception='$exception'; CWD=$T; git-version=$git_version; \@INC=(@INC).\n");
        @result = ();
    };

    return @result;
}

sub new_commit {
    my ($git, $file, $msg) = @_;

    $file->append($msg || 'new commit');

    $git->run(add => $file);
    $git->run(qw/commit -q -m/, $msg || 'commit');

    return;
}


# Executes a git command with arguments and return a four-elements
# list containing: (a) a boolean indication of success, (b) the exit
# code, (c) the command's STDOUT, and (d) the command's STDERR.
sub test_command {
    my ($git, $command, @args) = @_;

    my $cmd = $git->command($command, @args);

    my $stdout = do { local $/ = undef; readline($cmd->stdout); };
    my $stderr = do { local $/ = undef; readline($cmd->stderr); };

    $cmd->close;

    return ($cmd->exit() == 0, $cmd->exit(), $stdout, $stderr);
}

sub test_ok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
        pass($testname);
    } else {
        fail($testname);
        diag(" exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
    }
    return $ok;
}

sub test_ok_match {
    my ($testname, $regex, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
        if ($stdout =~ $regex || $stderr =~ $regex) {
            pass($testname);
        } else {
            fail($testname);
            diag(" did not match regex ($regex)\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
        }
    } else {
        fail($testname);
        diag(" exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
    }
    return $ok;
}

sub test_nok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
        fail($testname);
        diag(" succeeded without intention\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
    } else {
        pass($testname);
    }
    return !$ok;
}

sub test_nok_match {
    my ($testname, $regex, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
        fail($testname);
        diag(" succeeded without intention\n exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
        return 0;
    } elsif ($stdout =~ $regex || $stderr =~ $regex) {
        pass($testname);
        return 1;
    } else {
        fail($testname);
        diag(" did not match regex ($regex)\n exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
        return 0;
    }
}

1;

=for Pod::Coverage install_hooks new_commit new_repos newdir test_command test_nok test_nok_match test_ok test_ok_match
