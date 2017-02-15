# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 19;
use Path::Tiny;

my ($repo, $clone);

sub setup_repos {
    ($repo, undef, $clone) = new_repos();

    install_hooks($repo, undef, qw/pre-commit/);
    install_hooks($clone, undef, qw/update pre-receive/);
}

sub setup_structure {
    my ($git, $structure, $kind) = @_;
    $kind //= 'file';
    my $filedef = path($git->repo_path())->child('hooks', "structure.$kind");
    open my $fh, '>', "$filedef" or die "Can't create $filedef: $!\n";
    $fh->print($structure);
    $git->command(config => '--replace-all', "githooks.checkstructure.$kind", "file:$filedef");
}

sub add_file {
    my ($testname, $file) = @_;
    my @path = split '/', $file;
    my $wcpath = path($repo->wc_path());
    my $filename = $wcpath->child(@path);
    if (-e $filename) {
	fail($testname);
	diag("[TEST FRAMEWORK INTERNAL ERROR] File already exists: $filename\n");
    }

    pop @path;
    my $dirname  = $wcpath->child(@path);
    $dirname->mkpath;

    unless ($filename->spew('data')) {
	fail($testname);
	diag("[TEST FRAMEWORK INTERNAL ERROR] Cannot create file: $filename; $!\n");
    }

    $repo->command(add => $filename);
    return $filename;
}

sub check_can_commit {
    my ($testname, $file) = @_;
    add_file($testname, $file);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex, $file) = @_;
    my $filename = add_file($testname, $file);
    if ($regex) {
	test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname);
    } else {
	test_nok($testname, $repo, 'commit', '-m', $testname);
    }
    $repo->command(rm => '--cached', $filename);
}

sub check_can_push {
    my ($testname, $file) = @_;
    add_file($testname, $file);
    $repo->command(commit => '-m', $testname);
    test_ok($testname, $repo, 'push', $clone->repo_path(), 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $file) = @_;
    add_file($testname, $file);
    $repo->command(commit => '-m', $testname);
    test_nok_match($testname, $regex, $repo, 'push', $clone->repo_path(), 'master');
}


# PRE-COMMIT

setup_repos();

$repo->command(config => "githooks.plugin", 'CheckStructure');

setup_structure($repo, <<'EOF');
{};
EOF
check_cannot_commit('commit syntax error: invalid reference', qr/syntax error: invalid reference/, 'error0');

setup_structure($repo, <<'EOF');
'UNKNOWN TYPE';
EOF
check_cannot_commit('commit syntax error: unknown string', qr/syntax error: unknown string spec/, 'error1');

setup_structure($repo, <<'EOF');
[1];
EOF
check_cannot_commit('commit syntax error: odd number', qr/syntax error: odd number of elements/, 'error2');

setup_structure($repo, <<'EOF');
[{} => 0];
EOF
check_cannot_commit('commit syntax error: invalid lhs', qr/syntax error: the left hand side of arrays in the structure spec must be scalars or/, 'error3');

setup_structure($repo, <<'EOF');
[0 => {}];
EOF
check_cannot_commit('commit syntax error: rhs of number', qr/syntax error: the right hand side of a number must be a string/, 'error4');

setup_structure($repo, <<'EOF');
[
    'file' => 'FILE',
    'dir'  => 'DIR',
    qr/\.pm$/ => 'FILE',
    'sub1'  => [
        'file' => 'FILE',
        'sub2' => [
        ],
        0 => 'custom error message',
    ],
];
EOF

check_can_commit('commit allow string => FILE', 'file');

check_can_commit('commit allow string => DIR', 'dir/file');

check_can_commit('commit allow regex => FILE', 'file.pm');

check_can_commit('commit allow sub file', 'sub1/file');

check_cannot_commit('commit deny file should be a DIR', qr/the component \(sub2\) should be a DIR/, 'sub1/sub2');

check_cannot_commit('commit deny no match', qr/the component \(xpto\) is not allowed in/, 'xpto');

check_cannot_commit('commit deny custom error message', qr/custom error message/, 'sub1/xpto');

# PRE-RECEIVE

setup_repos();

$clone->command(config => "githooks.plugin", 'CheckStructure');

setup_structure($clone, <<'EOF');
[
    'file' => 'FILE',
    'dir'  => 'DIR',
    qr/\.pm$/ => 'FILE',
    'sub1'  => [
        'file' => 'FILE',
        'sub2' => [
        ],
        0 => 'custom error message',
    ],
];
EOF

check_can_push('push allow string => FILE', 'file');

check_can_push('push allow string => DIR', 'dir/file');

check_can_push('push allow regex => FILE', 'file.pm');

check_can_push('push allow sub file', 'sub1/file');

check_cannot_push('push deny file should be a DIR', qr/the component \(sub2\) should be a DIR/, 'sub1/sub2');

check_cannot_push('push deny no match', qr/the component \(xpto\) is not allowed in/, 'xpto');

check_cannot_push('push deny custom error message', qr/custom error message/, 'sub1/xpto');
