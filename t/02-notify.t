# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use Path::Tiny 0.060;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 9;

my ($repo, $file, $clone, $T);

my $mailbox;

sub setup_repos {
    ($repo, $file, $clone, $T) = new_repos();

    $mailbox = $T->child('mailbox');

    $file->append("First line.\n");
    $repo->run(add => $file);
    $repo->run(qw/commit -minitial/);
    $repo->run(push => '-q', '--set-upstream', $clone->git_dir, 'master');

    install_hooks($clone, undef, qw/post-receive/);
}

sub do_push {
    my ($testname) = @_;
    $file->append("$testname\n");
    $repo->run(add => $file);
    $repo->run(commit => "-m${testname}");
    unlink $mailbox if -e $mailbox;
    my ($ok, $exit, $stdout, $stderr) = test_command($repo, 'push', $clone->git_dir());
    diag(" exit=$exit\n stdout=$stdout\n stderr=$stderr\n\n") unless $ok;
    return $ok;
}

sub check_push_notify {
    my ($testname, $regex) = @_;
    if (do_push($testname)) {
        if (-e $mailbox) {
            ok(scalar(grep {$_ =~ $regex} ($mailbox->lines)), $testname);
        } else {
            fail("$testname (no mailbox)");
        }
    } else {
        fail("$testname (push failed)");
    }
    return;
}

sub check_push_dont_notify {
    my ($testname) = @_;
    if (do_push($testname)) {
        ok(! -e $mailbox, $testname);
    } else {
        fail("$testname (push failed)");
    }
    return;
}


setup_repos();

$clone->run(qw{config githooks.plugin Notify});
$clone->run(qw{config githooks.notify.transport}, "Mbox filename=$mailbox");
$clone->run(qw{config githooks.notify.from from@example.net});
$clone->run(qw{config githooks.notify.rule to@example.net});

SKIP: {
    unless (eval { require Email::Sender::Transport::Mbox; }) {
        skip "Module Email::Sender::Transport::Mbox is needed to test but not installed", 9;
    }

    check_push_notify('default subject', qr/Subject: \[Git::Hooks::Notify\]/);

    $clone->run(qw{config githooks.notify.subject}, '%R, %B, %A');

    check_push_notify('subject replace all placeholders', qr@Subject: clone, master, $ENV{USER}@);

    check_push_notify('from header', qr/From: from\@example\.net/);

    check_push_notify('to header', qr/To: to\@example\.net/);

    $clone->run(qw{config githooks.notify.preamble}, "Custom preamble.");

    check_push_notify('preamble', qr/Custom preamble\./);

    $clone->run(qw{config githooks.notify.commit-url}, "https://example.net/%H");

    check_push_notify('commit-url', qr@https://example.net/[0-9a-f]{40}@);

    $clone->run(qw{config --replace-all githooks.notify.rule}, 'to@example.net -- nomatch');

    check_push_dont_notify('do not notify if do not match pathspec');

    my $basename = $file->basename;
    $clone->run(qw{config --replace-all githooks.notify.rule}, "to\@example.net -- $basename");

    check_push_notify('do notify if match pathspec', qr/$basename/);

    $clone->run(qw{config --replace-all githooks.notify.rule to@example.net});
    $clone->run(qw{config githooks.notify.html 1});

    check_push_notify('html', qr/href=/);
};
