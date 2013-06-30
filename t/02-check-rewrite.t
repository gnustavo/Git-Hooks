# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 6;
use File::Slurp;

BEGIN { require "test-functions.pl" };

my ($repo, $file, $clone) = new_repos();

# We'll change $file on master and another file on the branch to avoid
# conflicts.
my $bfile = "$file.txt";

sub commit_on_master {
    $repo->command(checkout => '-q', 'master');
    append_file($file, 'xxx');
    $repo->command(add => $file);
    $repo->command(commit => '-m', "commit on master");
}

sub commit_on_branch {
    $repo->command(checkout => '-q', 'fork');
    append_file($bfile, 'xxx');
    $repo->command(add => $bfile);
    $repo->command(commit => '-m', "commit on branch");
}

# Since the hook cannot abort the commit --amend but just generate a
# suitable error message on stderr we need to check for this message
# instead.

sub check_can_amend {
    my ($testname) = @_;
    append_file($file, $testname);
    $repo->command(add => $file);

    test_ok_match($testname, qr/^\[master /s, $repo, 'commit', '--amend', '-m', $testname);
}

sub check_cannot_amend {
    my ($testname, $regex) = @_;
    append_file($file, $testname);
    $repo->command(add => $file);

    test_ok_match($testname, $regex, $repo, 'commit', '--amend', '-m', $testname);
}

sub check_can_rebase {
    my ($testname) = @_;
    test_ok($testname, $repo, 'rebase', 'master', 'fork');
}

sub check_cannot_rebase {
    my ($testname, $regex) = @_;
    test_nok_match($testname, $regex, $repo, 'rebase', 'master');
}


install_hooks($repo, undef, qw/pre-commit post-commit pre-rebase/);

$repo->command(qw/config githooks.plugin CheckRewrite/);

# Create a first commit in master
commit_on_master();

# Create a branch and a commit in it
$repo->command(qw/branch fork master/);
commit_on_branch();

# Create a new branch on master to diverge from fork
commit_on_master();

# CHECK AMEND
check_can_amend('allow amend on tip');

my $ammend_message = qr/unsafe "git commit --amend"/;

$repo->command(qw/branch  x/);
check_cannot_amend('deny amend with a local branch pointing to HEAD', $ammend_message);

$repo->command(qw/branch -D x/);
$repo->command(qw/push -q clone master/);
check_cannot_amend('deny amend of an already pushed commit', $ammend_message);

$repo->command(checkout => $file);

# CHECK REBASE
check_can_rebase('allow clean rebase');

my $rebase_message = qr/unsafe rebase/;

commit_on_master();

$repo->command(qw/checkout -q -b x fork/);
check_cannot_rebase('deny rebase with a local branch pointing to HEAD', $rebase_message);

$repo->command(qw/checkout -q fork/);
$repo->command(qw/branch -D x/);
$repo->command(qw/push -q clone fork/);
check_cannot_rebase('deny rebase of an already pushed branch', $rebase_message);
