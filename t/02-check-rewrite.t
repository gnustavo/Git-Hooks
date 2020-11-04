# -*- cperl -*-

use 5.01;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 6;
use Path::Tiny;

my ($repo, $ofile, $clone) = new_repos();

sub commit_on {
    my ($branch) = @_;
    $repo->run(checkout => '-q', $branch);
    my $file = path("$ofile.$branch");
    $file->append('xxx');
    $repo->run(add => "$file");
    $repo->run(commit => '-m', "commit on $branch");
}

# Since the hook cannot abort the commit --amend but just generate a
# suitable error message on stderr we need to check for this message
# instead.

sub check_can_amend {
    my ($testname) = @_;
    my $branch = $repo->get_current_branch();
    $branch =~ s:.*/::;
    my $file = path("$ofile.$branch");
    $file->append($testname);
    $repo->run(add => "$file");

    test_ok_match($testname, qr/^\[master /s, $repo, 'commit', '--amend', '-m', $testname);
}

sub check_cannot_amend {
    my ($testname, $regex) = @_;
    my $branch = $repo->get_current_branch();
    $branch =~ s:.*/::;
    my $file = path("$ofile.$branch");
    $file->append($testname);
    $repo->run(add => "$file");

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

$repo->run(qw/config githooks.plugin CheckRewrite/);

# Create a first commit in master
$repo->run(qw/commit --allow-empty -mx/);
commit_on('master');

# Create a branch and a commit in it
$repo->run(qw/branch fork master/);
commit_on('fork');

# Create a new commit on master to diverge from fork
commit_on('master');

# CHECK AMEND
check_can_amend('allow amend on tip');

my $ammend_message = qr/unsafe "git commit --amend"/;

$repo->run(qw/branch x/);
check_cannot_amend('deny amend with a local branch pointing to HEAD', $ammend_message);

$repo->run(qw/branch -D x/);
$repo->run(qw/push -q clone master/);
check_cannot_amend('deny amend of an already pushed commit', $ammend_message);

$repo->run(qw/reset --hard HEAD/);

# CHECK REBASE
check_can_rebase('allow clean rebase');

my $rebase_message = qr/unsafe rebase/;

commit_on('master');

$repo->run(qw/checkout -q -b x fork/);
check_cannot_rebase('deny rebase with a local branch pointing to HEAD', $rebase_message);

$repo->run(qw/checkout -q fork/);
$repo->run(qw/branch -D x/);
$repo->run(qw/push -q clone fork/);
check_cannot_rebase('deny rebase of an already pushed branch', $rebase_message);
