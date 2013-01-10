# Copyright (C) 2012 by CPqD

use 5.010;
use strict;
use warnings;
use Cwd;
use File::Temp qw/tempdir/;
use File::Spec::Functions ':ALL';
use File::Copy;
use File::Slurp;
use URI::file;
use Config;
use Git::More;

# Make sure the git messages come in English.
$ENV{LC_MESSAGES} = 'C';

our $T;
our $HooksDir = catfile(rel2abs(curdir()), 'hooks');

our $git_version = do {
    my $GIT = ( defined $ENV{GIT_WRAPPER_GIT} ) ? $ENV{GIT_WRAPPER_GIT} : 'git';
    if (my $version = `$GIT version`) {
        chomp $version;
        $version =~ s/^git version //;
        $version;
    } else {
        'unknown';
    }
};

sub newdir {
    my $num = 1 + Test::Builder->new()->current_test();
    my $dir = catdir($T, $num);
    mkdir $dir;
    $dir;
}

sub debug_test {
    my ($git, $debug) = @_;
    $debug //= 1;
    my $hook_pl = catfile($git->git_dir(), 'hooks', 'hook.pl');
    my $pl = read_file($hook_pl);
    if (
	   ! $debug && $pl =~ s/^([^\n]+) -d\n/$1\n/s
	||   $debug && $pl =~ s/^([^\n]+)(?!-d)\n/$1 -d\n/s
    ) {
	write_file($hook_pl, $pl);
    }
}

sub install_hooks {
    my ($git, $extra_perl, @hooks) = @_;
    my $hooks_dir = catfile($git->git_dir(), 'hooks');
    my $hook_pl   = catfile($hooks_dir, 'hook.pl');
    {
	open my $fh, '>', $hook_pl or BAIL_OUT("Can't create $hook_pl: $!");
	state $debug = $ENV{DBG} ? '-d' : '';
	state $bliblib = catdir('blib', 'lib');
	print $fh <<EOF;
#!$Config{perlpath} $debug
use strict;
use warnings;
use lib '$bliblib';
EOF

	state $pathsep = $^O eq 'MSWin32' ? ';' : ':';
	if (defined $ENV{PERL5LIB} and length $ENV{PERL5LIB}) {
	    foreach my $path (reverse split "$pathsep", $ENV{PERL5LIB}) {
		say $fh "use lib '$path';" if $path;
	    }
	}

	print $fh <<EOF;
use Git::Hooks;
EOF

	print $fh $extra_perl if defined $extra_perl;

	print $fh <<EOF
\$ENV{GIT_CONFIG} = "\$ENV{GIT_DIR}/config";
run_hook(\$0, \@ARGV);
EOF
    }
	    chmod 0755 => $hook_pl;

    @hooks = qw/ applypatch-msg pre-applypatch post-applypatch
		 pre-commit prepare-commit-msg commit-msg
		 post-commit pre-rebase post-checkout post-merge
		 pre-receive update post-receive post-update
		 pre-auto-gc post-rewrite /
                     unless @hooks;

    foreach (@hooks) {
	symlink 'hook.pl', catfile($hooks_dir, $_)
	    or BAIL_OUT("can't symlink '$hooks_dir', '$_': $!");
    }
}

sub new_repos {
    my $cleanup = exists $ENV{REPO_CLEANUP} ? $ENV{REPO_CLEANUP} : 1;
    $T = tempdir('githooks.XXXXX', TMPDIR => 1, CLEANUP => $cleanup);

    my $repodir  = catfile($T, 'repo');
    my $filename = catfile($repodir, 'file.txt');
    my $clonedir = catfile($T, 'clone');

    mkdir $repodir, 0777 or BAIL_OUT("can't mkdir $repodir: $!");
    {
	open my $fh, '>', $filename or die BAIL_OUT("can't open $filename: $!");
	say $fh "first line";
    }

    my ($repo, $clone) = eval {
        # It would be easier to pass a directory argument to git-init
        # but it started to accept it only on v1.6.5. To support
        # previous gits we chdir to $repodir to avoid the need to pass
        # the argument. Then we have to go back to where we were.
        my $cwd = cwd();
        chdir $repodir or die "cannot chdir $repodir: $!\n";
	my ($ok, $exit, $stdout) = test_command(undef, 'init', '-q');
        chdir $cwd;
        die "'git init -q $repodir': exit=$exit, stdout=\n$stdout\n" unless $ok;

	my $repo = Git::More->new($repodir);
	$repo->config('user.mail', 'myself@example.com');
	$repo->config('user.name', 'My Self');
	$repo->add($filename);
	$repo->commit({m => 'x'});

	($ok, $exit, $stdout) = test_command(undef, 'clone', '-q', '--bare', '--no-hardlinks', $repodir, $clonedir);
        die "'git clone -q --bare --no-hardlinks $repodir $clonedir': exit=$exit, stdout=\n$stdout\n" unless $ok;

	my $clone = Git::More->new($clonedir);

	return ($repo, $clone);
    };

    if (my $E = $@) {
        my $ls = `find $T -ls`;	# FIXME: this is non-portable.
        diag("Error setting up repos for test: $E\nRepos parent directory listing:\n$ls\ngit-version=$git_version\n\@INC=@INC\n");
        BAIL_OUT('Cannot setup repos for testing');
    }

    return ($repo, $filename, $clone);
}

sub new_commit {
    my ($git, $file, $msg) = @_;

    append_file($file, $msg || 'new commit');

    $git->add({}, $file);
    $git->commit({q => 1, m => $msg || 'commit'});
}

sub test_command {
    my ($git, $cmd, @args) = @_;

    my $pid = open my $pipe, '-|';
    if (! defined $pid) {
	return (0, undef, "Can't fork: $!\n");
    } elsif ($pid) {
	# parent
	local $/ = undef;
	my $stdout = <$pipe>;
	my $exit = close $pipe;
	if ($exit) {
	    return (1, undef, $stdout);
	} else {
	    return (0, $!, $stdout);
	}
    } else {
	# child
	if (defined $git) {
	    local $ENV{'GIT_DIR'} = $git->git_dir();
            chdir $git->dir();
	}
	close STDERR;
	open STDERR, '>&', \*STDOUT;
	exec(git => $cmd, @args)
	    or BAIL_OUT("Can't exec git (version=$git_version) $cmd: $!\n");
    }
}

sub test_ok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout) = test_command(@args);
    if ($ok) {
	pass($testname);
    } else {
	fail($testname);
	diag(" exit=$exit\n stdout=$stdout\n git-version=$git_version\n");
    }
    return $ok;
}

sub test_nok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout) = test_command(@args);
    if ($ok) {
	fail($testname);
	diag(" succeeded without intention\n stdout=$stdout\n git-version=$git_version\n");
    } else {
	pass($testname);
    }
    return !$ok;
}

sub test_nok_match {
    my ($testname, $regex, @args) = @_;
    my ($ok, $exit, $stdout) = test_command(@args);
    if ($ok) {
	fail($testname);
	diag(" succeeded without intention\n stdout=$stdout\n git-version=$git_version\n");
	return 0;
    } elsif ($stdout =~ $regex) {
	pass($testname);
	return 1;
    } else {
	fail($testname);
	diag(" did not match regex ($regex)\n exit=$exit\n stdout=$stdout\n git-version=$git_version\n");
	return 0;
    }
}

1;
