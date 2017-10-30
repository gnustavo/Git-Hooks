# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 4;

my ($repo, $file, $clone);

sub setup_repos {
    ($repo, $file, $clone) = new_repos();

    $file->append("First line.\n");
    $repo->run(add => $file);
    $repo->run(qw/commit -minitial/);
    $repo->run(push => '-q', '--set-upstream', $clone->git_dir, 'master');

    install_hooks($clone, undef, qw/post-receive/);
}

sub check_can_push {
    my ($testname) = @_;
    $file->append("$testname\n");
    $repo->run(add => $file);
    $repo->run(commit => "-m${testname}");
    test_ok($testname, $repo, 'push', $clone->git_dir());
}

sub check_cannot_push {
    my ($testname) = @_;
    $file->append("$testname\n");
    $repo->run(add => $file);
    $repo->run(commit => "-m${testname}");
    test_nok_match($testname, qr/not allowed/, $repo, 'push', $clone->git_dir());
}


setup_repos();

SKIP: {
    skip "Skipping non-implemented tests.", 4;

    $clone->run(qw/config githooks.plugin Notify/);
    $clone->run(qw{config githooks.notify.from git-hooks-notify@example.net});
    $clone->run(qw{config githooks.notify.include gustavo@cpan.org});

    check_can_push('succeed by default');

    $clone->run(qw{config githooks.notify.subject [Git::Hooks::Notify]-SMTP});
    $clone->run(qw{config githooks.notify.transport smtp});
    $clone->run(qw{config githooks.notify.smtp-host smtp.example.net});

    check_can_push('succeed via smtp.cpqd.com.br');

    $clone->run(qw{config githooks.notify.subject [Git::Hooks::Notify]-SMTPS});
    $clone->run(qw{config githooks.notify.smtp-host smtp.gmail.com});
    $clone->run(qw{config githooks.notify.smtp-ssl ssl});

    check_can_push('succeed via smtp.gmail.com ssl');

    $clone->run(qw{config githooks.notify.subject [Git::Hooks::Notify]-SMTPTLS});
    $clone->run(qw{config githooks.notify.smtp-ssl starttls});

    check_can_push('succeed via smtp.gmail.com starttls');
}
