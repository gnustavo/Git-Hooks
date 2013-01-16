# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 20;
use File::Slurp;
use File::Spec::Functions 'catfile';

require "test-functions.pl";

my ($repo, $file, $clone, $T) = new_repos();

my $msgfile = catfile($T, 'msg.txt');

sub check_can_commit {
    my ($testname, $msg) = @_;
    write_file($msgfile, $msg);
    append_file($file, $testname);
    $repo->command(add => $file);
    test_ok($testname, $repo, 'commit', '-F', $msgfile);
}

sub check_cannot_commit {
    my ($testname, $regex, $msg) = @_;
    write_file($msgfile, $msg);
    append_file($file, $testname);
    $repo->command(add => $file);
    if ($regex) {
	test_nok_match($testname, $regex, $repo, 'commit', '-F', $msgfile);
    } else {
	test_nok($testname, $repo, 'commit', '-F', $msgfile);
    }
}

sub check_can_push {
    my ($testname, $ref) = @_;
    new_commit($repo, $file, $testname);
    test_ok($testname, $repo,
	    'push', $clone->repo_path(), $ref || 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $ref) = @_;
    new_commit($repo, $file, $testname);
    test_nok_match($testname, $regex, $repo,
		   'push', $clone->repo_path(), $ref || 'master');
}


install_hooks($repo, undef, 'commit-msg');

$repo->command(config => "githooks.commit-msg", 'CheckLog');

# title-required

check_cannot_commit('deny without required title', qr/log title has 2 lines but should have only 1/, <<'EOF');
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

$repo->command(config => 'CheckLog.title-required', 0);

check_can_commit('allow without non-required title', <<'EOF');
No
Title
EOF

$repo->command(config => 'CheckLog.title-required', 1);

# title-period

check_can_commit('allow without denied period', <<'EOF');
Title
EOF

check_cannot_commit('deny with denied period', qr/log title SHOULD NOT end in a period/, <<'EOF');
Title.
EOF

$repo->command(config => 'CheckLog.title-period', 'require');

check_cannot_commit('deny without required period', qr/log title SHOULD end in a period/, <<'EOF');
Title
EOF

check_can_commit('allow with required period', <<'EOF');
Title.
EOF

$repo->command(config => 'CheckLog.title-period', 'allow');

check_can_commit('allow without allowed period', <<'EOF');
Title
EOF

check_can_commit('allow with allowed period', <<'EOF');
Title.
EOF

$repo->command(config => 'CheckLog.title-period', 'invalid');

check_cannot_commit('deny due to invalid value', qr/Invalid value for the/, <<'EOF');
Title
EOF

$repo->command(config => 'CheckLog.title-period', 'deny');

# title-max-width

check_cannot_commit('deny large title', qr/log title should be at most 50 characters wide, but it has 51/, <<'EOF');
123456789012345678901234567890123456789012345678901

The above title has 51 characters.
EOF

$repo->command(config => 'CheckLog.title-max-width', 0);

check_can_commit('allow large title', <<'EOF');
123456789012345678901234567890123456789012345678901

The above title has 51 characters.
EOF

$repo->command(config => 'CheckLog.title-max-width', 50);

# body-max-width

check_cannot_commit('deny large body', qr/log body lines should be at most 72 characters wide, but there is one with 73/, <<'EOF');
Title

Body first line.

1234567890123456789012345678901234567890123456789012345678901234567890123
The previous line has 73 characters.
EOF

$repo->command(config => 'CheckLog.body-max-width', 0);

check_can_commit('allow large body', <<'EOF');
Title

Body first line.

123456789012345678901234567890123456789012345678900123456789001234567890123
The previous line has 73 characters.
EOF

$repo->command(config => 'CheckLog.body-max-width', 72);

# match

$repo->command(config => 'CheckLog.match', '^has to have');
$repo->command(config => '--add', 'CheckLog.match', '!^must not have');

check_can_commit('allow if matches', <<'EOF');
Title

has to have
EOF

check_cannot_commit('deny if do not match positive regex', qr/log SHOULD match/, <<'EOF');
Title

abracadabra
EOF

check_cannot_commit('deny if match negative regex', qr/log SHOULD NOT match/, <<'EOF');
Title

has to have
must not have
EOF

$repo->command(config => '--unset-all', 'CheckLog.match');

# encoding

# spelling
SKIP: {
    use Git::Hooks::CheckLog;
    my $checker = eval { Git::Hooks::CheckLog::_spell_checker($repo, 'word'); };

    skip "Text::SpellChecker isn't properly installed", 2 unless $checker;

    check_can_commit('allow misspelling without checking', <<'EOF');
xytxuythiswordshouldnotspell
EOF

    $repo->command(config => '--add', 'CheckLog.spelling', 1);

    check_cannot_commit('deny misspelling with checking', qr/log has the following spelling problems in it/, <<'EOF');
xytxuythiswordshouldnotspell
EOF

    $repo->command(config => '--unset-all', 'CheckLog.spelling');
}

