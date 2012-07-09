# Copyright (C) 2012 by CPqD

use 5.010;
use strict;
use warnings;
use Cwd;
use File::Temp qw/tempdir/;
use File::Spec::Functions ':ALL';
use File::Path;
use File::Copy;
use URI::file;
use Config;
use Git::More;
use Error qw(:try);

# Make sure the git messages come in English.
$ENV{LC_MESSAGES} = 'C';

our $T;
our $HooksDir = catfile(rel2abs(curdir()), 'hooks');

sub newdir {
    my $num = 1 + Test::Builder->new()->current_test();
    my $dir = catdir($T, $num);
    mkdir $dir;
    $dir;
}

sub install_hooks {
    foreach my $git (@_) {
	my $hooks_dir = catfile($git->repo_path(), 'hooks');
	my $hook_pl   = catfile($hooks_dir, 'hook.pl');
	{
	    open my $fh, '>', $hook_pl or die "Can't create $hook_pl: $!\n";
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
		    say $fh "use lib '$path';";
		}
	    }

	    print $fh <<EOF
use Git::Hooks;

run_hook(\$0, \@ARGV);
EOF
	}
	chmod 0755 => $hook_pl;
	foreach (qw/ applypatch-msg pre-applypatch post-applypatch
		     pre-commit prepare-commit-msg commit-msg
		     post-commit pre-rebase post-checkout post-merge
		     pre-receive update post-receive post-update
		     pre-auto-gc post-rewrite /) {
	    symlink 'hook.pl', catfile($hooks_dir, $_)
		or die "can't symlink '$hooks_dir', '$_': $!\n";
	}
    }
}

sub new_repos {
    my $cleanup = exists $ENV{REPO_CLEANUP} ? $ENV{REPO_CLEANUP} : 1;
    $T = tempdir('t.XXXX', DIR => getcwd(), CLEANUP => $cleanup);

    my $repodir  = catfile($T, 'repo');
    my $filename = catfile($repodir, 'file.txt');
    my $clonedir = catfile($T, 'clone');

    mkdir $repodir, 0777 or die "can't mkdir $repodir: $!";
    {
	open my $fh, '>', $filename or die "can't open $filename: $!";
	say $fh "first line";
    }

    Git::command(init => '-q', $repodir);

    my $repo = Git::More->repository(Directory => $repodir);
    $repo->command(add => $filename);
    $repo->command(commit => '-mx');

    Git::command(clone => '-q', '--bare', '--no-hardlinks', $repodir, $clonedir);

    my $clone = Git::More->repository(Directory => $clonedir);

    install_hooks($repo, $clone);

    return ($repo, $filename, $clone);
}

sub new_commit {
    my ($git, $file) = @_;

    open my $fh, '>>', $file or die "can't open $file: $!";
    say $fh "commit line";
    close $fh;

    $git->command(add => $file);
    $git->command(commit => '-q', '-mcommit');
}

#my ($last_stdout, $last_stderr);
#sub test_command_old {
#    my ($git, @args) = @_;
#    open my $fh, '>', \$last_stderr or die "can't open to write to a string: $!";
#    try {
#	warn "enter try\n";
#	$last_stdout = $git->command([@args], {STDERR => $fh});
#	warn "leave try\n";
#	return 1;
#    } catch Git::Error::Command with {
#	my $E = shift;
#	use Data::Dumper;
#	warn "enter catch ($E)", ref($E), "|", Dumper($E), "\n";
#	$last_stdout = $E->cmd_output();
#	warn "leave catch ($E)($last_stdout)($last_stderr)\n";
#	return 0;
#    };
#    warn "end command\n";
#}

sub test_command {
    my ($git, $cmd, @args) = @_;

    my $pid = open my $pipe, '-|';
    if (! defined $pid) {
	return (0, undef, undef, "Can't fork: $!\n");
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
	if ($git->repo_path()) {
	    local $ENV{'GIT_DIR'} = $git->repo_path();
	    if ($git->wc_path()) {
		local $ENV{'GIT_WORK_TREE'} = $git->wc_path();
		chdir($git->wc_path());
	    }
	    if ($git->wc_subdir()) {
		chdir($git->wc_subdir());
	    }
	}
	close STDERR;
	open STDERR, '>&', \*STDOUT;
	exec git => $cmd, @args;
	die "Can't exec git $cmd: $!\n";
    }
}

sub test_ok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout) = test_command(@args);
    if ($ok) {
	pass($testname);
    } else {
	fail($testname);
	diag(" exit=$exit\n stdout=$stdout\n");
    }
}

sub test_nok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout) = test_command(@args);
    if ($ok) {
	fail($testname);
	diag(" stdout=$stdout\n");
    } else {
	pass($testname);
    }
}

sub test_nok_match {
    my ($testname, $regex, @args) = @_;
    my ($ok, $exit, $stdout) = test_command(@args);
    if ($ok) {
	fail($testname);
	diag(" succeeded without intention\n stdout=$stdout\n");
    } elsif ($stderr =~ $regex) {
	pass($testname);
    } else {
	fail($testname);
	diag(" did not match regex ($regex) for stderr\n exit=$exit\n stdout=$stdout\n");
    }
}

1;
