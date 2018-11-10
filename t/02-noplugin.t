# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test qw/:all/;
use Test::More tests => 6;

my ($repo, $file, $clone) = new_repos();

install_hooks($repo, <<'EOF');
COMMIT_MSG {
    my ($git, $msg_file) = @_;
    die "commit-msg died!\n";
};
EOF

$file->append("new line\n");
$repo->run(add => $file);
test_nok('cannot commit', $repo,
         'commit', '-q', '-m', 'new commit');

$repo->run(qw/config githooks.error-header/, 'echo My Header');

test_nok_match('error-header', qr/My Header/, $repo, qw/commit -q -mheader/);

$repo->run(qw/config githooks.error-footer/, 'echo My Footer');

test_nok_match('error-footer', qr/My Footer/, $repo, qw/commit -q -mfooter/);

# Install a pre-commit hook that always succeed fast
install_hooks($repo, <<'EOF');
PRE_COMMIT {
    my ($git) = @_;
    return 1;
};
EOF

test_ok('succeed without timeout', $repo, qw/commit -q -madd/);

$repo->run(qw/config githooks.timeout 0/);

$file->append("new line\n");
$repo->run(add => $file);
test_ok('succeed with zero timeout', $repo, qw/commit -q -madd/);

# Install a pre-commit hook that never finishes
install_hooks($repo, <<'EOF');
PRE_COMMIT {
    my ($git) = @_;
    sleep;
    return 1;
};
EOF

$repo->run(qw/config githooks.timeout 1/);

$file->append("new line\n");
$repo->run(add => $file);
test_nok_match('fail by timeout', qr/timed out after/, $repo, qw/commit -q -madd/);
