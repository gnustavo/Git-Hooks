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
    $ENV{GIT_EDITOR} = "$^X -ne '\$match += 1 if /$regex/; warn \"\$.: \$_\"; END {die unless \$match}'";
    test_ok($testname, $repo, qw/commit --allow-empty --allow-empty-message/);
}

sub check_can_commit_not_prepared {
    my ($testname, $regex) = @_;

    # Use a Perl script as GIT_EDITOR to check if the commit message was
    # not prepared.
    $ENV{GIT_EDITOR} = "$^X -ne '\$match += 1 if /$regex/; END {die if \$match}'";
    test_ok($testname, $repo, qw/commit --allow-empty --allow-empty-message/);
}

sub check_cannot_commit {
    my ($testname, $regex) = @_;

    my $exit = $regex
        ? test_nok_match($testname, $regex, $repo, qw/commit --allow-empty --allow-empty-message/)
        : test_nok($testname, $repo, qw/commit --allow-empty --allow-empty-message/);

    return $exit;
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
