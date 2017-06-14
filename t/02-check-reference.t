# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Path::Tiny;
use Test::More tests => 6;

my ($repo, $clone);

sub setup_repos {
    ($repo, undef, $clone) = new_repos();

    $repo->run(qw/commit --allow-empty -minitial/);
    $repo->run(push => '-q', $clone->git_dir, 'master:master');

    install_hooks($clone, undef, qw/pre-receive/);
}

sub check_can_push {
    my ($testname, $reference) = @_;
    $repo->run(branch => $reference, 'master');
    test_ok($testname, $repo, 'push', $clone->git_dir(), "$reference:$reference");
}

sub check_cannot_push {
    my ($testname, $reference) = @_;
    $repo->run(branch => $reference, 'master');
    test_nok_match($testname, qr/not allowed/, $repo,
                   'push', $clone->git_dir(), "$reference:$reference");
}


# PRE-RECEIVE

setup_repos();

$clone->run(qw/config githooks.plugin CheckReference/);

check_can_push('allow by default', 'allow-anything');

$clone->run(qw{config githooks.checkreference.deny ^refs/heads/});

check_cannot_push('deny anything', 'deny-anything');

$clone->run(qw{config githooks.checkreference.allow ^refs/heads/(?:feature|release|hotfix)});

check_can_push('allow feature', 'feature/x');

check_can_push('allow release', 'release/1.0');

check_can_push('allow hotfix', 'hotfix/bug');

check_cannot_push('deny anything else', 'xpto');
