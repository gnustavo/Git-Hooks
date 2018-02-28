# -*- cperl -*-

use 5.010;
use strict;
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

    # NOTE: We insert a bogus 'x' in the message's first line to guarantee
    # that it's not empty. We could use the --allow-empty-message option, but it
    # was implemented on Git 1.7.2 and we still want to support Git 1.7.1.
    local $ENV{GIT_EDITOR} = "$^X -i -pe '\$match += 1 if /$regex/; \$_ = 'x' if \$. == 1; END {die unless \$match}'";
    test_ok($testname, $repo, qw/commit --allow-empty/);
}

sub check_can_commit_not_prepared {
    my ($testname, $regex) = @_;

    # Use a Perl script as GIT_EDITOR to check if the commit message was
    # not prepared.
    local $ENV{GIT_EDITOR} = "$^X -i -pe '\$match += 1 if /$regex/; \$_ = 'x' if \$. == 1; END {die if \$match}'";
    test_ok($testname, $repo, qw/commit --allow-empty/);
}


# Repo hooks

install_hooks($repo, undef, 'prepare-commit-msg');

$repo->run(qw/config githooks.plugin PrepareLog/);

check_can_commit_not_prepared('do not prepare by default', '^\\s*[^#\\s]');

$repo->run(qw/config githooks.preparelog.issue-branch-regex [A-Z]+-\\d+/);

check_can_commit_not_prepared('do not prepare if do not match branch', '^\\s*[^#\\s]');

$repo->run(qw/checkout -q -b JIRA-10/);

check_can_commit_prepared('prepare if do match branch', 'JIRA-10');

check_can_commit_prepared('prepare in title by default', '^\\[JIRA-10\\] ');

$repo->run(qw/config githooks.preparelog.issue-place/, 'title %T (%I)');

check_can_commit_prepared('prepare in title with different format', ' \\(JIRA-10\\)$');

SKIP: {
    test_requires_git skip => 1, version_ge => '2.8.0';

    $repo->run(qw/config githooks.preparelog.issue-place/, 'trailer JIRA');

    check_can_commit_prepared('prepare in trailer', '^Jira: JIRA-10$');
}
