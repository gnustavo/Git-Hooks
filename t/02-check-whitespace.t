# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test qw/:all/;
use Test::More tests => 4;
use Path::Tiny;

my ($repo, $clone);

sub setup_repos {
    ($repo, undef, $clone) = new_repos();

    install_hooks($repo, undef, qw/pre-commit/);
    install_hooks($clone, undef, qw/update pre-receive/);
}

sub add_file {
    my ($testname, $contents) = @_;
    my $filename = path($repo->work_tree())->child('file.txt');

    unless ($filename->spew($contents)) {
        fail($testname);
        diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot create file: $filename; $!\n");
    }

    $repo->run(add => $filename);
    return $filename;
}

sub check_can_commit {
    my ($testname, $contents) = @_;
    add_file($testname, $contents);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex, $contents) = @_;
    my $filename = add_file($testname, $contents);
    my $exit = $regex
        ? test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname)
        : test_nok($testname, $repo, 'commit', '-m', $testname);
    $repo->run(rm => '--cached', $filename);
    return $exit;
}

sub check_can_push {
    my ($testname, $contents) = @_;
    add_file($testname, $contents);
    $repo->run(commit => '-m', $testname);
    test_ok($testname, $repo, 'push', $clone->git_dir(), 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $contents) = @_;
    add_file($testname, $contents);
    $repo->run(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), 'master');
}


# PRE-COMMIT

setup_repos();

$repo->run(qw/config githooks.plugin CheckWhitespace/);

check_can_commit('commit ok', "ok\n");

check_cannot_commit(
    'commit end in space',
    qr/extra whitespaces in the changed files/,
    "end in space \n",
);

# PRE-RECEIVE

setup_repos();

$clone->run(qw/config githooks.plugin CheckWhitespace/);

check_can_push('push ok', "ok\n");

check_cannot_push(
    'push end in space',
    qr/extra whitespaces in the changed files/,
    "end in space \n",
);
