# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 5;
use Config;
use File::Slurp;

BEGIN { require "test-functions.pl" };

my ($repo, $file, $clone) = new_repos();
install_hooks($repo, undef, qw/pre-commit/);

sub check_can_commit {
    my ($testname) = @_;
    append_file($file, $testname);
    $repo->command(add => $file);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex) = @_;
    append_file($file, $testname);
    $repo->command(add => $file);
    if ($regex) {
	test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname);
    } else {
	test_nok($testname, $repo, 'commit', '-m', $testname);
    }
}

# install a hook that succeeds
my $hooksd = catfile($repo->repo_path(), 'hooks.d');
mkdir $hooksd or die "Can't mkdir $hooksd: $!";
my $hookd  = catfile($hooksd, 'pre-commit');
mkdir $hookd or die "Can't mkdir $hookd: $!";
my $hook   = catfile($hookd, 'script.pl');
my $mark   = catfile($hooksd, 'mark');

write_file($hook, <<"EOF");
#!$Config{perlpath}
open FH, '>', '$mark' or die "Can't create mark: \$!";
print FH "line\\n";
close FH;
exit 0;
EOF

chmod 0755, $hook or die "Cannot chmod $hook: $!\n";

ok(! -f $mark, 'mark does not exist yet');

check_can_commit('execute a hook that succeeds');

ok(-f $mark, 'mark exists now');

# install a hook that fails
write_file($hook, <<"EOF");
#!$Config{perlpath}
die "external hook failure\n";
EOF

check_cannot_commit('execute a hook that fails', qr/external hook failure/);

# Disable external hooks
$repo->command(config => 'githooks.externals', 0);

check_can_commit('do not execute disabled hooks');
