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
    my $filename = path($repo->wc_path())->child('file.txt');

    unless ($filename->spew($contents)) {
	fail($testname);
	diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot create file: $filename; $!\n");
    }

    $repo->command(add => $filename);
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
    if ($regex) {
	test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname);
    } else {
	test_nok($testname, $repo, 'commit', '-m', $testname);
    }
    $repo->command(rm => '--cached', $filename);
}

sub check_can_push {
    my ($testname, $contents) = @_;
    add_file($testname, $contents);
    $repo->command(commit => '-m', $testname);
    test_ok($testname, $repo, 'push', $clone->repo_path(), 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $contents) = @_;
    add_file($testname, $contents);
    $repo->command(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->repo_path(), 'master');
}


# PRE-COMMIT

setup_repos();

$repo->command(config => "githooks.plugin", 'CheckWhitespace');

check_can_commit('commit ok', "ok\n");

check_cannot_commit(
    'commit end in space',
    qr/whitespace errors in the changed files/,
    "end in space \n",
);

# PRE-RECEIVE

setup_repos();

$clone->command(config => "githooks.plugin", 'CheckWhitespace');

check_can_push('push ok', "ok\n");

check_cannot_push(
    'push end in space',
    qr/whitespace errors in the changed files/,
    "end in space \n",
);
