# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Config;
use Path::Tiny;
use Test::More;
if ($^O eq 'MSWin32') {
    plan skip_all => 'External hooks are not implemented for Windows yet.';
} else {
    plan tests => 5;
}

BEGIN { require "test-functions.pl" };

my ($repo, $file, $clone) = new_repos();
install_hooks($repo, undef, qw/pre-commit/);

sub check_can_commit {
    my ($testname) = @_;
    $file->append($testname);
    $repo->command(add => $file);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex) = @_;
    $file->append($testname);
    $repo->command(add => $file);
    if ($regex) {
	test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname);
    } else {
	test_nok($testname, $repo, 'commit', '-m', $testname);
    }
}

# install a hook that succeeds
my $hooksd = path($repo->repo_path())->child('hooks.d');
mkdir $hooksd or die "Can't mkdir $hooksd: $!";
my $hookd  = $hooksd->child('pre-commit');
mkdir $hookd or die "Can't mkdir $hookd: $!";
my $hook   = $hookd->child('script.pl');
my $mark   = $hooksd->child('mark');

my $hook_script = <<"EOF";
#!$Config{perlpath}
open FH, '>', '$mark' or die "Can't create mark: \$!";
print FH "line\\n";
close FH;
exit 0;
EOF
$hook->spew($hook_script)
    or BAIL_OUT("can't '$hook'->spew(<hook_script 1>)\n");

chmod 0755, $hook or die "Cannot chmod $hook: $!\n";

ok(! -f $mark, 'mark does not exist yet');

check_can_commit('execute a hook that succeeds');

ok(-f $mark, 'mark exists now');

# install a hook that fails
$hook_script = <<"EOF";
#!$Config{perlpath}
die "external hook failure\n";
EOF
# We have to use append instead of spew to keep the $hook file modes.
$hook->append({truncate => 1}, $hook_script)
    or BAIL_OUT("can't '$hook'->spew(<hook_script 2>)\n");

check_cannot_commit('execute a hook that fails', qr/external hook failure/);

# Disable external hooks
$repo->command(config => 'githooks.externals', 0);

check_can_commit('do not execute disabled hooks');
