# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test qw/:all/;
use Test::More tests => 1;

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
