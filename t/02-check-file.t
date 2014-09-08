# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 10;
use File::Path 2.08 qw'make_path';
use File::Slurp;

BEGIN { require "test-functions.pl" };

my ($repo, $clone);

sub setup_repos {
    ($repo, undef, $clone) = new_repos();

    install_hooks($repo, undef, qw/pre-commit/);
    install_hooks($clone, undef, qw/update pre-receive/);
}

sub modify_file {
    my ($testname, $file) = @_;
    my @path = split '/', $file;
    my $filename = catfile($repo->wc_path(), @path);

    unless (-e $filename) {
        pop @path;
        my $dirname  = catfile($repo->wc_path(), @path);
        make_path($dirname);
    }

    unless (append_file($filename, {err_mode => 'carp'}, 'data')) {
	fail($testname);
	diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot write to file: $filename; $!\n");
    }

    $repo->command(add => $filename);
    return $filename;
}

sub check_can_commit {
    my ($testname, $file) = @_;
    modify_file($testname, $file);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex, $file) = @_;
    my $filename = modify_file($testname, $file);
    if ($regex) {
	test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname);
    } else {
	test_nok($testname, $repo, 'commit', '-m', $testname);
    }
    $repo->command(reset => 'HEAD', $filename);
}

sub check_can_push {
    my ($testname, $file) = @_;
    modify_file($testname, $file);
    $repo->command(commit => '-m', $testname);
    test_ok($testname, $repo, 'push', $clone->repo_path(), 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $file) = @_;
    modify_file($testname, $file);
    $repo->command(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->repo_path(), 'master');
}


# PRE-COMMIT

setup_repos();

$repo->command(config => "githooks.plugin", 'CheckFile');

check_can_commit('commit sans configuration', 'file.txt');

$repo->command(config => "githooks.checkfile.name", '*.other true');

check_can_commit('commit miss', 'file.txt');

$repo->command(config => "githooks.checkfile.name", '*.txt true');

check_can_commit('commit hit/pass', 'file.txt');

$repo->command(config => '--replace-all', "githooks.checkfile.name", '*.txt false');

check_cannot_commit('commit hit/fail', qr/failed \(exit/, 'file.txt');

$repo->command(config => '--replace-all', "githooks.checkfile.name", 'qr/\.txt$/ false');

check_cannot_commit('commit hit/regexp', qr/failed \(exit/, 'file.txt');

check_cannot_commit('commit add hit', qr/failed \(exit/, 'file2.txt');

$repo->command(config => '--replace-all', "githooks.checkfile.name", '*.txt test -f {} && true');

check_can_commit('commit hit {}', 'file.txt');

# PRE-RECEIVE

setup_repos();

$clone->command(config => "githooks.plugin", 'CheckFile');

check_can_push('push sans configuration', 'file.txt');

$clone->command(config => "githooks.checkfile.name", '*.txt true');

check_can_push('commit hit/pass', 'file.txt');

$clone->command(config => '--replace-all', "githooks.checkfile.name", '*.txt false');

check_cannot_push('commit hit/fail', qr/failed \(exit/, 'file.txt');
