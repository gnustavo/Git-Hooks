# -*- cperl -*-

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Path::Tiny;
use Test::More tests => 8;

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
    my ($testname, $reference, $error) = @_;
    $repo->run(branch => $reference, 'master');
    if ($error) {
        $error = qr/$error/;
    } else {
        $error = qr/not allowed/;
    }
    test_nok_match($testname, $error, $repo,
                   'push', $clone->git_dir(), "$reference:$reference");
}


# PRE-RECEIVE

setup_repos();

$clone->run(qw/config githooks.plugin CheckReference/);

check_can_push('allow by default', 'allow-anything');

$repo->run(qw/tag mytag HEAD/);
test_ok('can push lightweight tag by default', $repo, 'push', $clone->git_dir(), 'tag', 'mytag');

$clone->run(qw{config githooks.checkreference.require-annotated-tags true});

$repo->run(qw/tag mytag2 HEAD/);
test_nok_match('require-annotated-tag deny lightweight tag',
               qr/recreate your tag as an annotated tag/,
               $repo, 'push', $clone->git_dir(), 'tag', 'mytag2');

$repo->run(qw/tag -f -a -mmessage mytag2 HEAD/);
test_ok('require-annotated-tag allow annotated', $repo, 'push', $clone->git_dir(), 'tag', 'mytag2');

# Check ACLs

$clone->run(qw/config --remove-section githooks.checkreference/);

$clone->run(qw/config githooks.checkreference.acl/, 'deny CRUD ^refs/');
check_cannot_push('deny CRUD ^refs/', 'any');

$ENV{USER} = 'pusher';
$clone->run(qw/config githooks.userenv USER/);

$clone->run(qw/config --add githooks.checkreference.acl/, 'allow CRUD ^refs/heads/user/{USER}/');
check_can_push('allow CRUD ^refs/heads/user/{USER}/', 'user/pusher/master');

$clone->run(qw/config --add githooks.checkreference.acl/, 'allow CRUD ^refs/heads/other$ by other');
check_cannot_push('allow CRUD ^refs/heads/other$ by other', 'other');

$clone->run(qw/config --add githooks.checkreference.acl/, 'allow CRUD refs/heads/pusher by pusher');
check_can_push('allow CRUD refs/heads/pusher by pusher', 'pusher');

