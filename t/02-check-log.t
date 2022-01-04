#!/usr/bin/env perl

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 33;
use Path::Tiny;

my ($repo, $file, $clone, $T) = new_repos();

my $msgfile = path($T)->child('msg.txt');

sub check_can_commit {
    my ($testname, $msg) = @_;
    $msgfile->spew($msg)
        or BAIL_OUT("check_can_commit: can't '$msgfile'->spew('$msg')\n");
    $file->append($testname)
        or BAIL_OUT("check_can_commit: can't '$file'->append('$testname')\n");
    $repo->run(add => $file);
    test_ok($testname, $repo, 'commit', '-F', $msgfile);
    return;
}

sub check_cannot_commit {
    my ($testname, $regex, $msg) = @_;
    $msgfile->spew($msg)
        or BAIL_OUT("check_cannot_commit: can't '$msgfile'->spew('$msg')\n");
    $file->append($testname)
        or BAIL_OUT("check_cannot_commit: can't '$file'->append('$testname')\n");
    $repo->run(add => $file);
    if ($regex) {
        test_nok_match($testname, $regex, $repo, 'commit', '-F', $msgfile);
    } else {
        test_nok($testname, $repo, 'commit', '-F', $msgfile);
    }
    return;
}

sub check_can_push {
    my ($testname, $ref) = @_;
    new_commit($repo, $file, $testname);
    test_ok($testname, $repo,
            'push', $clone->git_dir(), $ref || 'master');
    return;
}

sub check_cannot_push {
    my ($testname, $regex, $ref) = @_;
    new_commit($repo, $file, $testname);
    test_nok_match($testname, $regex, $repo,
                   'push', $clone->git_dir(), $ref || 'master');
    return;
}


install_hooks($repo, undef, 'commit-msg');

$repo->run(qw/config githooks.plugin CheckLog/);

# title-required

check_can_commit('allow normally', <<'EOF');
Title

Body
EOF

$repo->run(qw{config githooks.checklog.title-period deny});
check_cannot_commit('deny an invalid message', qr/SHOULD NOT end in a period/, 'Invalid.');

$repo->run(qw{config githooks.noref refs/heads/master});
check_can_commit('allow commit on non-enabled ref even when commit message is faulty', 'Invalid.');

$repo->run(qw/config --remove-section githooks.checklog/);
$repo->run(qw{config githooks.checklog.title-period deny});
$repo->run(qw{config githooks.noref refs/heads/master});
check_can_commit('allow commit on disabled ref even when commit message is faulty', 'Invalid.');

$repo->run(qw/config --remove-section githooks.checklog/);
$repo->run(qw{config githooks.checklog.title-period deny});
$repo->run(qw{config githooks.ref refs/heads/master});
check_cannot_commit('deny commit on enabled ref when commit message is faulty', qr/SHOULD NOT end in a period/, 'Invalid.');

$repo->run(qw/config --remove-section githooks.checklog/);

check_cannot_commit('deny without required title', qr/log message needs a title line/, <<'EOF');
No
Title
EOF

check_can_commit('allow with required title', <<'EOF');
Title

Body
EOF

check_can_commit('allow with required title only', <<'EOF');
Title
EOF

$repo->run(qw/config githooks.checklog.title-required 0/);

check_can_commit('allow without non-required title', <<'EOF');
No
Title
EOF

$repo->run(qw/config --remove-section githooks.checklog/);

# title-period

check_can_commit('allow without denied period', <<'EOF');
Title
EOF

check_cannot_commit('deny with denied period', qr/log message title SHOULD NOT end in a period/, <<'EOF');
Title.
EOF

$repo->run(qw/config githooks.checklog.title-period require/);

check_cannot_commit('deny without required period', qr/log message title SHOULD end in a period/, <<'EOF');
Title
EOF

check_can_commit('allow with required period', <<'EOF');
Title.
EOF

$repo->run(qw/config githooks.checklog.title-period allow/);

check_can_commit('allow without allowed period', <<'EOF');
Title
EOF

check_can_commit('allow with allowed period', <<'EOF');
Title.
EOF

$repo->run(qw/config githooks.checklog.title-period invalid/);

check_cannot_commit('deny due to invalid value', qr/error: invalid value/, <<'EOF');
Title
EOF

$repo->run(qw/config --remove-section githooks.checklog/);

# title-max-width

check_cannot_commit('deny large title', qr/It is 51 characters wide but should be at most 50,/, <<'EOF');
123456789012345678901234567890123456789012345678901

The above title has 51 characters.
EOF

$repo->run(qw/config githooks.checklog.title-max-width 0/);

check_can_commit('allow large title', <<'EOF');
123456789012345678901234567890123456789012345678901

The above title has 51 characters.
EOF

$repo->run(qw/config --remove-section githooks.checklog/);

# body-max-width

check_cannot_commit('deny large body',
                    qr/to 72 characters./, <<'EOF');
Title

Body first line.

1234567890123456789012345678901234567890123456789012345678901234567890123
The previous line has 73 characters.
EOF

check_can_commit('allow body with large quoted line', <<'EOF');
Title

Body first line.

    123456789012345678901234567890123456789012345678900123456789001234567890123
The previous line has 77 characters.
EOF

$repo->run(qw/config githooks.checklog.body-max-width 0/);

check_can_commit('allow large body', <<'EOF');
Title

Body first line.

123456789012345678901234567890123456789012345678900123456789001234567890123
The previous line has 73 characters.
EOF

$repo->run(qw/config --remove-section githooks.checklog/);

# match

$repo->run(qw/config githooks.checklog.match/, '^has to have');
$repo->run(qw/config --add githooks.checklog.match/, '!^must not have');

check_can_commit('allow if matches', <<'EOF');
Title

has to have
EOF

check_cannot_commit('deny if do not match positive regex', qr/log message SHOULD match/, <<'EOF');
Title

abracadabra
EOF

check_cannot_commit('deny if match negative regex', qr/log message SHOULD NOT match/, <<'EOF');
Title

has to have
must not have
EOF

$repo->run(qw/config --unset-all githooks.checklog.match/);

# signed-off-by

$repo->run(qw/config githooks.checklog.signed-off-by 1/);

check_cannot_commit('deny if no signed-off-by', qr/must have a Signed-off-by footer/, <<'EOF');
Title

Body
EOF

check_can_commit('allow if signed-off-by', <<'EOF');
Title

Body

Signed-off-by: Some One <someone@example.net>
EOF

$repo->run(qw/config --remove-section githooks.checklog/);

# title-match

$repo->run(qw/config githooks.checklog.title-match/, '].*\S');
$repo->run(qw/config --add githooks.checklog.title-match/, '!#$');

check_can_commit('allow if title matches', <<'EOF');
[JIRA-100] Title

Body
EOF

check_cannot_commit('deny if title does not match', qr/SHOULD match/, <<'EOF');
[JIRA-100]

Body
EOF

check_cannot_commit('deny if body matches but title does not', qr/SHOULD match/, <<'EOF');
Title

[1] Body
EOF

check_cannot_commit('deny if title matches negative regex', qr/SHOULD NOT match/, <<'EOF');
[JIRA-100] Title #

Body
EOF

check_can_commit('allow if only body matches negative title regex', <<'EOF');
[JIRA-100] Title

Body #
EOF

$repo->run(qw/config --remove-section githooks.checklog/);

# encoding

# spelling
SKIP: {
    use Git::Hooks::CheckLog;
    my $checker = eval {
        local $SIG{__WARN__} = sub {}; # supress warnings in this block
        Git::Hooks::CheckLog::_spell_checker($repo, 'word'); ## no critic (ProtectPrivateSubs)
    };

    skip "Text::SpellChecker isn't properly installed", 2 unless defined $checker;

    check_can_commit('allow misspelling without checking', <<'EOF');
xytxuythiswordshouldnotspell
EOF

    $repo->run(qw/config --add githooks.checklog.spelling 1/);

    check_cannot_commit('deny misspelling with checking', qr/log message has a misspelled word/, <<'EOF');
xytxuythiswordshouldnotspell
EOF

    $repo->run(qw/config --unset-all githooks.checklog.spelling/);
}

1;
