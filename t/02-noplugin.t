#!/usr/bin/env perl

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test qw/:all/;
use Test::More tests => 3;

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

1;


