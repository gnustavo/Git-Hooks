# -*- cperl -*-

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Path::Tiny;
use Test::More tests => 8;
use Test::Requires::Git;

my ($repo, $clone, $T);

sub setup_repos {
    ($repo, undef, $clone, $T) = new_repos();

    install_hooks($repo, undef, qw/pre-commit/);
    install_hooks($clone, undef, qw/update pre-receive/);
}

sub modify_file {
    my ($testname, $file, $action, $data) = @_;
    my @path = split '/', $file;
    my $wcpath = path($repo->work_tree());
    my $filename = $wcpath->child(@path);

    unless (-e $filename) {
        pop @path;
        my $dirname  = $wcpath->child(@path);
        $dirname->mkpath;
    }

    if (! defined $action) {
        if ($filename->append($data || 'data')) {
            $repo->run(add => $filename);
        } else {
            fail($testname);
            diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot append to file: $filename; $!\n");
        }
    } elsif ($action eq 'truncate') {
        if ($filename->append({truncate => 1}, $data || 'data')) {
            $repo->run(add => $filename);
        } else {
            fail($testname);
            diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot write to file: $filename; $!\n");
        }
    } elsif ($action eq 'rm') {
        $repo->run(rm => $filename);
    } else {
        fail($testname);
        diag("[TEST FRAMEWORK INTERNAL ERROR] Invalid action: $action; $!\n");
    }

    return $filename;
}

sub check_can_commit {
    my ($testname, $file, $action, $data) = @_;
    modify_file($testname, $file, $action, $data);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex, $file, $action, $data) = @_;
    my $filename = modify_file($testname, $file, $action, $data);
    my $exit = $regex
        ? test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname)
        : test_nok($testname, $repo, 'commit', '-m', $testname);
    $repo->run(qw/reset --hard/);
    return $exit;
}

sub check_can_push {
    my ($testname, $file, $action, $data) = @_;
    modify_file($testname, $file, $action, $data);
    $repo->run(commit => '-m', $testname);
    test_ok($testname, $repo, 'push', $clone->git_dir(), 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $file, $action, $data) = @_;
    modify_file($testname, $file, $action, $data);
    my $head = $repo->run(qw/rev-parse --verify HEAD/);
    $repo->run(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), 'master');
    $repo->run(qw/reset --hard/, $head);
}


# PRE-COMMIT

setup_repos();

$repo->run(qw/config githooks.plugin CheckDiff/);

check_can_commit('commit sans configuration', 'file.txt');

$repo->run(qw/config githooks.checkdiff.shell/, 'true');

check_can_commit('commit true', 'file.txt');

$repo->run(qw/config --replace-all githooks.checkdiff.shell/, 'false');

check_cannot_commit('commit false', qr/failed with exit code/, 'file.txt');

$repo->run(qw/config --unset-all githooks.checkdiff.shell/);

$repo->run(qw/config githooks.checkdiff.shell/, 'grep THING');

check_cannot_commit('commit grep false', qr/failed with exit code/, 'file.txt', 'truncate', "NOTATALL\n");

check_can_commit('commit grep true', 'file.txt', 'truncate', "THING\n");

$repo->run(qw/config --remove-section githooks.checkdiff/);


# PRE-RECEIVE

setup_repos();

$clone->run(qw/config githooks.plugin CheckDiff/);

check_can_push('push sans configuration', 'file.txt');

$clone->run(qw/config githooks.checkdiff.shell/, 'true');

check_can_push('push true', 'file.txt');

$clone->run(qw/config --replace-all githooks.checkdiff.shell/, 'false');

check_cannot_push('push false', qr/failed with exit code/, 'file.txt');

$clone->run(qw/config --remove-section githooks.checkdiff/);
