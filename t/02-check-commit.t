# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 26;
use Test::Requires::Git;
use Path::Tiny;

my ($repo, $file, $clone, $T) = new_repos();

sub setenvs {
    my ($aname, $amail, $cname, $cmail) = @_;
    $ENV{GIT_AUTHOR_NAME}     = $aname;
    $ENV{GIT_AUTHOR_EMAIL}    = $amail || "$ENV{GIT_AUTHOR_NAME}\@example.net";
    $ENV{GIT_COMMITTER_NAME}  = $cname || $ENV{GIT_AUTHOR_NAME};
    $ENV{GIT_COMMITTER_EMAIL} = $cmail || $ENV{GIT_AUTHOR_EMAIL};
    return;
}

sub check_can_commit {
    my ($testname, @envs) = @_;
    setenvs(@envs);

    $file->append($testname);
    $repo->run(add => $file);

    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex, @envs) = @_;
    setenvs(@envs);

    $file->append($testname);
    $repo->run(add => $file);

    my $exit = $regex
        ? test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname)
        : test_nok($testname, $repo, 'commit', '-m', $testname);
    $repo->run(rm => '--cached', $file);
    return $exit;
}

sub check_can_push {
    my ($testname, $branch, @envs) = @_;
    setenvs(@envs);

    new_commit($repo, $file, $testname);
    test_ok($testname, $repo, 'push', $clone->git_dir(), "HEAD:$branch");
}

sub check_cannot_push {
    my ($testname, $regex, $branch, @envs) = @_;
    setenvs(@envs);

    $repo->run(qw/branch -f mark/);
    new_commit($repo, $file, $testname);
    my $exit = test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), "HEAD:$branch");
    $repo->run(qw/reset --hard mark/);
    return $exit;
}


# Repo hooks

install_hooks($repo, undef, 'pre-commit');

$repo->run(config => "githooks.plugin", 'CheckCommit');

# name

$repo->run(qw/config githooks.checkcommit.name valid1/);

$repo->run(qw/config --add githooks.checkcommit.name valid2/);

check_can_commit('allow positive author name', 'valid2');

check_cannot_commit('deny positive author name', qr/does not match any positive/, 'none');

$repo->run(qw/config --add githooks.checkcommit.name !invalid/);

check_can_commit('allow negative author name', 'valid1');

check_cannot_commit('deny negative author name', qr/matches some negative/, 'invalid');

$repo->run(qw/config --remove-section githooks.checkcommit/);

# email

$repo->run(qw/config githooks.checkcommit.email valid1/);

$repo->run(qw/config --add githooks.checkcommit.email valid2/);

check_can_commit('allow positive author email', 'valid2');

check_cannot_commit('deny positive author email', qr/does not match any positive/, 'none');

$repo->run(qw/config --add githooks.checkcommit.email !invalid/);

check_can_commit('allow negative author email', 'valid1');

check_cannot_commit('deny negative author email', qr/matches some negative/, 'invalid');

$repo->run(qw/config --remove-section githooks.checkcommit/);

# canonical
SKIP: {
    test_requires_git skip => 4, version_ge => '1.8.5.3';

    my $mailmap = path($T)->child('mailmap');

    $mailmap->spew(<<'EOS');
Good Name <good@example.net> <bad@example.net>
Proper Name <proper@example.net>
EOS

    $repo->run(qw/config githooks.checkcommit.canonical/, $mailmap);

    check_can_commit(
        'allow canonical name and email',
        'Good Name',
        'good@example.net',
    );

    check_cannot_commit(
        'deny non-canonical email',
        qr/identity .*? isn't canonical/,
        'Good Name',
        'bad@example.net',
    );


    check_cannot_commit(
        'deny non-canonical name',
        qr/identity .*? isn't canonical/,
        'Improper Name',
        'proper@example.net',
    );

    check_can_commit(
        'allow non-specified email and name',
        'none',
        'none@example.net',
    );

    $repo->run(qw/config --remove-section githooks.checkcommit/);
}

# check-code repo

$repo->run(qw/config githooks.checkcommit.check-code/,
                'sub { my ($git, $commit) = @_; return $commit->{author_name} =~ /valid/; };');

check_can_commit('check-code commit ok', 'valid');

check_cannot_commit('check-code commit nok', qr/error while evaluating check-code/, 'other');

$repo->run(qw/config --remove-section githooks.checkcommit/);

# email-valid
SKIP: {
    unless (eval { require Email::Valid; }) {
        skip "Email::Valid module isn't installed", 2;
    }

    $repo->run(qw/config githooks.checkcommit.email-valid 1/);

    check_can_commit(
        'allow valid email',
        'name',
        'good@example.net',
    );

    check_cannot_commit(
        'deny invalid email',
        qr/failed rfc822 check/,
        'Good Name',
        'bad@example@net',
    );

    $repo->run(qw/config --remove-section githooks.checkcommit/);
}


# Clone hooks

($repo, $file, $clone, $T) = new_repos();

install_hooks($clone, undef, 'pre-receive');

$clone->run(config => "githooks.plugin", 'CheckCommit');

$clone->run(qw/config githooks.checkcommit.name valid1/);

check_can_push('allow positive author name (push)', 'master', 'valid1');

check_cannot_push('deny positive author name (push)', qr/does not match any positive/, 'master', 'none');

$clone->run(qw/config --remove-section githooks.checkcommit/);

# signature
SKIP: {
    skip "signature tests not implemented yet", 4;

    $clone->run(qw/config githooks.checkcommit.signature trusted/);

    check_cannot_push('deny no signature', qr/has NO signature/, 'master', 'name');

    $file->append('new commit');
    $repo->run(qw/commit -SFIXME -q -a -mcommit/);
    test_ok('allow with signature', $repo, 'push', $clone->git_dir(), 'master');

    $clone->run(qw/config --remove-section githooks.checkcommit/);
}

# check-code clone

$clone->run(qw/config githooks.checkcommit.check-code/,
                'sub { my ($git, $commit, $ref) = @_; $ref =~ s:.*/::; return $ref eq "valid"; };');

check_can_push('check-code push ok', 'valid', 'name');

check_cannot_push('check-code push nok', qr/error while evaluating check-code/, 'invalid', 'name');

$clone->run(qw/config --remove-section githooks.checkcommit/);

my $script  = $T->child('check-code.pl');
{
    open my $fh, '>', $script or die BAIL_OUT("can't open $script to write: $!");
    print $fh <<'EOT' or die  BAIL_OUT("can't write to $script: $!");
sub {
    my ($git, $commit, $ref) = @_;
    $ref =~ s:.*/::;
    return $ref eq "valid";
};
EOT
    close $fh;
}

$clone->run(qw/config githooks.checkcommit.check-code/, "file:$script");

check_can_push('check-code push file ok', 'valid', 'name');

check_cannot_push('check-code push file nok', qr/error while evaluating check-code/, 'invalid', 'name');

$clone->run(qw/config --remove-section githooks.checkcommit/);
