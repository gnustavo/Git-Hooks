# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Path::Tiny;
use Test::More tests => 19;

my ($repo, $clone);

sub setup_repos {
    ($repo, undef, $clone) = new_repos();

    install_hooks($repo, undef, qw/pre-commit/);
    install_hooks($clone, undef, qw/update pre-receive/);
}

sub modify_file {
    my ($testname, $file, $truncate, $data) = @_;
    my @path = split '/', $file;
    my $wcpath = path($repo->work_tree());
    my $filename = $wcpath->child(@path);

    unless (-e $filename) {
        pop @path;
        my $dirname  = $wcpath->child(@path);
        $dirname->mkpath;
    }

    if ($truncate) {
        unless ($filename->spew($data || 'data')) {
            fail($testname);
            diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot write to file: $filename; $!\n");
        }
    } else {
        unless ($filename->append($data || 'data')) {
            fail($testname);
            diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot append to file: $filename; $!\n");
        }
    }

    $repo->run(add => $filename);
    return $filename;
}

sub check_can_commit {
    my ($testname, $file, $truncate, $data) = @_;
    modify_file($testname, $file, $truncate, $data);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex, $file, $truncate, $data) = @_;
    my $filename = modify_file($testname, $file, $truncate, $data);
    my $exit = $regex
	? test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname)
        : test_nok($testname, $repo, 'commit', '-m', $testname);
    $repo->run(rm => '--cached', $filename);
    return $exit;
}

sub check_can_push {
    my ($testname, $file, $truncate, $data) = @_;
    modify_file($testname, $file, $truncate, $data);
    $repo->run(commit => '-m', $testname);
    test_ok($testname, $repo, 'push', $clone->git_dir(), 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $file, $truncate, $data) = @_;
    modify_file($testname, $file, $truncate, $data);
    $repo->run(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), 'master');
}


# PRE-COMMIT

setup_repos();

$repo->run(qw/config githooks.plugin CheckFile/);

check_can_commit('commit sans configuration', 'file.txt');

$repo->run(qw/config githooks.checkfile.name/, '*.other true');

check_can_commit('commit miss', 'file.txt');

$repo->run(qw/config githooks.checkfile.name/, '*.txt true');

check_can_commit('commit hit/pass', 'file.txt');

$repo->run(qw/config --replace-all githooks.checkfile.name/, '*.txt false');

check_cannot_commit('commit hit/fail', qr/failed with exit code/, 'file.txt');

$repo->run(qw/config --replace-all githooks.checkfile.name/, 'qr/\.txt$/ false');

check_cannot_commit('commit hit/regexp', qr/failed with exit code/, 'file.txt');

check_cannot_commit('commit add hit', qr/failed with exit code/, 'file2.txt');

$repo->run(qw/config --replace-all githooks.checkfile.name/, '*.txt test -f {} && true');

check_can_commit('commit hit {}', 'file.txt');

$repo->run(qw/config --unset-all githooks.checkfile.name/);

$repo->run(qw/config githooks.checkfile.sizelimit 4/);

check_can_commit('small file', 'file.txt', 'truncate', '12');

check_cannot_commit('big file', qr/the current limit is/, 'file.txt', 'truncate', '123456789');

$repo->run(qw/config githooks.checkfile.basename.sizelimit/, '2 \.txt$');

check_cannot_commit('basename big file', qr/the current limit is 2 bytes/, 'file.txt', 'truncate', '123');

$repo->run(qw/config --unset-all githooks.checkfile.sizelimit/);

$repo->run(qw/config --unset-all githooks.checkfile.basename.sizelimit/);

$repo->run(qw/config githooks.checkfile.basename.deny txt/);

check_cannot_commit('deny basename', qr/basename is not allowed/, 'file.txt');

$repo->run(qw/config githooks.checkfile.basename.allow txt/);

check_can_commit('allow basename', 'file.txt');

$repo->run(qw/config --unset-all githooks.checkfile.basename.deny/);
$repo->run(qw/config --unset-all githooks.checkfile.basename.allow/);


$repo->run(qw/config githooks.checkfile.path.deny txt/);

check_cannot_commit('deny path', qr/path is not allowed/, 'file.txt');

$repo->run(qw/config githooks.checkfile.path.allow txt/);

check_can_commit('allow path', 'file.txt');

$repo->run(qw/config --unset-all githooks.checkfile.path.deny/);
$repo->run(qw/config --unset-all githooks.checkfile.path.allow/);

# PRE-RECEIVE

setup_repos();

$clone->run(qw/config githooks.plugin CheckFile/);

check_can_push('push sans configuration', 'file.txt');

$clone->run(qw/config githooks.checkfile.name/, '*.txt true');

check_can_push('commit hit/pass', 'file.txt');

$clone->run(qw/config --replace-all githooks.checkfile.name/, '*.txt false');

check_cannot_push('commit hit/fail', qr/failed with exit code/, 'file.txt');

$clone->run(qw/config --unset-all githooks.checkfile.name/);

$clone->run(qw/config githooks.checkfile.sizelimit 4/);

check_can_push('small file', 'file.txt', 'truncate', '12');

check_cannot_push('big file', qr/the current limit is/, 'file.txt', 'truncate', '123456789');
