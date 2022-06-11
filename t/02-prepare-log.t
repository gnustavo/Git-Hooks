#!/usr/bin/env perl

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 6;
use Test::Requires::Git;

my ($repo, $file, $clone, $T) = new_repos();

sub check_can_commit_prepared {
    my ($testname, $regex) = @_;

    # Use a Perl script as GIT_EDITOR to check if the commit message was
    # prepared.

    local $ENV{GIT_EDITOR} = "$^X -ne '\$c .= \$_; \$match += 1 if /^[^#]*$regex/; END {die \"did not match:\$c:\" unless \$match}'";

    # NOTE: We use a 'bogus' non-empty message to guarantee it's not empty. We
    # could use the --allow-empty-message option, but it was implemented on Git
    # 1.7.2 and we still need to support Git 1.7.1.
    test_ok($testname, $repo, qw/commit --allow-empty -mbogus -e/);
    return;
}

sub check_can_commit_not_prepared {
    my ($testname) = @_;

    # Use a Perl script as GIT_EDITOR to check if the commit message was
    # not prepared.

    local $ENV{GIT_EDITOR} = "$^X -ne 'die if /^[^#]*JIRA-10/'";

    # NOTE: We use a 'bogus' non-empty message to guarantee it's not empty. We
    # could use the --allow-empty-message option, but it was implemented on Git
    # 1.7.2 and we still need to support Git 1.7.1.
    test_ok($testname, $repo, qw/commit --allow-empty -mbogus -e/);
    return;
}


# Repo hooks

install_hooks($repo, undef, 'prepare-commit-msg');

$repo->run(qw/config githooks.plugin PrepareLog/);

check_can_commit_not_prepared('do not prepare by default');

$repo->run(qw/config githooks.preparelog.issue-branch-regex [A-Z]+-\\d+/);

check_can_commit_not_prepared('do not prepare if do not match branch');

$repo->run(qw/checkout -q -b JIRA-10/);

check_can_commit_prepared('prepare if do match branch', 'JIRA-10');

check_can_commit_prepared('prepare in title by default', '^\\[JIRA-10\\] ');

$repo->run(qw/config githooks.preparelog.issue-place/, 'title %T (%I)');

check_can_commit_prepared('prepare in title with different format', ' \\(JIRA-10\\)$');

SKIP: {
    test_requires_git skip => 1, version_ge => '2.8.0';

    $repo->run(qw/config githooks.preparelog.issue-place/, 'trailer Jira');

    check_can_commit_prepared('prepare in trailer', '^Jira: JIRA-10$');
}

1;
