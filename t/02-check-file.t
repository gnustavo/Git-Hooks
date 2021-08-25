#!/usr/bin/env perl

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Path::Tiny;
use Test::More tests => 36;
use Test::Requires::Git;

my ($repo, $clone, $T);

sub setup_repos {
    ($repo, undef, $clone, $T) = new_repos();

    install_hooks($repo, undef, qw/pre-commit/);
    install_hooks($clone, undef, qw/update pre-receive/);
    return;
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
    return;
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
    return;
}

sub check_cannot_push {
    my ($testname, $regex, $file, $action, $data) = @_;
    modify_file($testname, $file, $action, $data);
    my $head = $repo->run(qw/rev-parse --verify HEAD/);
    $repo->run(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), 'master');
    $repo->run(qw/reset --hard/, $head);
    return;
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

$repo->run(qw/config githooks.checkfile.acl/, 'deny AMD ^.*txt');

check_cannot_commit('deny basename', qr/cannot modify this file/, 'file.txt');

$repo->run(qw/config githooks.checkfile.acl/, 'allow AMD ^.*txt');

check_can_commit('allow basename', 'file.txt');

$repo->run(qw/config --remove-section githooks.checkfile/);

sub filesystem_is_case_sentitive {
    # Check using the technique described in
    # https://quickshiftin.com/blog/2014/09/filesystem-case-sensitive-bash/

    my $lowercase = $T->child('sensitive')->touch;
    my $uppercase = $T->child('SENSITIVE')->touch;
    $lowercase->remove;
    my $is_case_sensitive = $uppercase->exists;
    $uppercase->remove;
    return $is_case_sensitive;
}

SKIP: {
    skip "Checks for case-sensitive filesystems", 2 unless filesystem_is_case_sentitive;

    check_can_commit('Allow commit case conflict by default', 'FILE.TXT');

    $repo->run(qw/config githooks.checkfile.deny-case-conflict true/);

    check_cannot_commit('Deny commit case conflict',
                        qr/adds a file with a name that will conflict/,
                        'File.Txt');

    $repo->run(qw/reset --hard/);

    $repo->run(qw/config --remove-section githooks.checkfile/);
}

$repo->run(qw/config githooks.checkfile.deny-token FIXME/);

check_cannot_commit('Deny commit if match FIXME',
                    qr/Invalid tokens detected in added lines/,
                    'file.txt',
                    undef,
                    "FIXME: something\n",
                );

$repo->run(qw/reset --hard/);

$repo->run(qw/config --remove-section githooks.checkfile/);

$repo->run(qw/config githooks.checkfile.executable *.sh/);

$repo->run(qw/config githooks.checkfile.not-executable *.txt/);

my $wc = path($repo->work_tree);

$wc->child('script.sh')->touch()->chmod(0644);

check_cannot_commit('executable fail', qr/is not executable but should be/, 'script.sh');

$wc->child('script.sh')->touch()->chmod(0755);

check_can_commit('executable succeed', 'script.sh');

$wc->child('doc.txt')->touch()->chmod(0755);

check_cannot_commit('not-executable fail', qr/is executable but should not be/, 'doc.txt');

$wc->child('doc.txt')->touch()->chmod(0644);

check_can_commit('not-executable succeed', 'doc.txt');

# Deal with filenames containing unusual characters

$repo->run(qw/config --remove-section githooks.checkfile/);

$repo->run(qw/config githooks.checkfile.sizelimit 4/);

check_can_commit('filename with unusual characteres OK', '$al\v@ção', 'truncate', '12');

check_cannot_commit('filename with unusual characteres NOK', qr/the current limit is/,
                    '$al\v@ção', 'truncate', '12345');

# ACLs

$repo->run(qw/config --remove-section githooks.checkfile/);

$repo->run(qw/config githooks.checkfile.acl/, 'deny AMD thefile');
check_cannot_commit('deny AMD thefile', qr/Authorization error/, 'thefile');

$repo->run(qw/config --add githooks.checkfile.acl/, 'allow A thefile');
check_can_commit('allow A thefile', 'thefile');

check_cannot_commit('deny M thefile', qr/Authorization error/, 'thefile');

$repo->run(qw/config --add githooks.checkfile.acl/, 'allow M thefile');
check_can_commit('allow M thefile', 'thefile');

check_cannot_commit('deny D thefile', qr/Authorization error/, 'thefile', 'rm');

$repo->run(qw/config --add githooks.checkfile.acl/, 'allow D thefile');
check_can_commit('allow D thefile', 'thefile', 'rm');

$repo->run(qw/config --replace-all githooks.checkfile.acl/, 'WRONG ACL');
check_cannot_commit('deny ACL config error', qr/invalid acl syntax/, 'file');


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

$clone->run(qw/config --remove-section githooks.checkfile/);

SKIP: {
    skip "Case-sensitive filesystem checks", 2 if $^O =~ /MSWin32|darwin/;

    check_can_push('Allow push case conflict by default', 'FILE2.TXT');

    $clone->run(qw/config githooks.checkfile.deny-case-conflict true/);

    check_cannot_push('Deny push case conflict',
                      qr/adds a file with a name that will conflict/,
                      'File2.Txt');

    $clone->run(qw/config --remove-section githooks.checkfile/);
}

$clone->run(qw/config githooks.checkfile.deny-token FIXME/);

check_cannot_push('Deny push if match FIXME',
                  qr/Invalid tokens detected in added lines/,
                  'file.txt',
                  undef,
                  "FIXME: something\n",
              );

$clone->run(qw/config --remove-section githooks.checkfile/);

1;
