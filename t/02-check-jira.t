# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 24;
use File::Slurp;

BEGIN { require "test-functions.pl" };

my ($repo, $file, $clone, $T);

sub setup_repos_for {
    my ($reporef) = @_;

    ($repo, $file, $clone, $T) = new_repos();

    foreach my $git ($repo, $clone) {
	# Inject a fake JIRA::REST class definition in order to be able
	# to test this without a real JIRA server.

	install_hooks($git, <<'EOF', qw/commit-msg update pre-receive/);
package JIRA::REST;

sub new {
    my ($class, $jiraurl, $jirauser, $jirapass) = @_;
    die "JIRA::REST(fake): cannot connect or login\n" if $jirapass eq 'invalid';
    return bless {}, $class;
}

my %issues = (
    'GIT-1' => {key => 'GIT-1', fields => { resolution => 1,     assignee => { name => 'user'}}},
    'GIT-2' => {key => 'GIT-2', fields => { resolution => undef, assignee => { name => 'user'}}},
    'GIT-3' => {key => 'GIT-3', fields => { resolution => undef, assignee => { name => 'user'}}},
);

sub GET {
    my ($self, $endpoint) = @_;
    my $key;
    if ($endpoint =~ m:/issue/(.*):) {
        $key = $1;
    } else {
	die "JIRA::Client(fake): no such endpoint ($endpoint)\n";
    }
    if (exists $issues{$key}) {
	return $issues{$key};
    } else {
	die "JIRA::Client(fake): no such issue ($key)\n";
    }
}

package main;
$INC{'JIRA/REST.pm'} = 'fake';
EOF
    }

    $$reporef->command(config => "githooks.plugin", 'CheckJira');
    $$reporef->command(config => 'githooks.checkjira.jiraurl', 'fake://url/');
    $$reporef->command(config => 'githooks.checkjira.jirauser', 'user');
    $$reporef->command(config => 'githooks.checkjira.jirapass', 'valid');
}

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


setup_repos_for(\$repo);

check_cannot_commit('deny commit by default without JIRAs');

$repo->command(config => 'githooks.checkjira.ref', 'refs/heads/fix');
check_can_commit('allow commit on disabled ref even without JIRAs');

$repo->command(checkout => '-q', '-b', 'fix');
check_cannot_commit('deny commit on enabled ref without JIRAs', qr/must cite a JIRA/);

$repo->command(config => '--unset', 'githooks.checkjira.ref');
$repo->command(checkout => '-q', 'master');

$repo->command(config => 'githooks.checkjira.project', 'OTHER');
check_cannot_commit('deny commit citing non-allowed projects [GIT-0]',
		    qr/do not cite issue GIT-0/);

$repo->command(config => 'githooks.checkjira.require', '0');
check_can_commit('allow commit if JIRA is not required');
$repo->command(config => '--unset-all', 'githooks.checkjira.require');

$repo->command(config => '--replace-all', 'githooks.checkjira.project', 'GIT');

$repo->command(config => '--replace-all', 'githooks.checkjira.jirapass', 'invalid');
check_cannot_commit('deny commit if cannot connect to JIRA [GIT-0]',
		    qr/cannot connect to the JIRA server/);
$repo->command(config => '--replace-all', 'githooks.checkjira.jirapass', 'valid');

check_cannot_commit('deny commit if cannot get issue [GIT-0]',
		    qr/cannot get issue/);

check_cannot_commit('deny commit if issue is already resolved [GIT-1]',
		    qr/is already resolved/);

$repo->command(config => '--replace-all', 'githooks.checkjira.unresolved', 0);
check_can_commit('allow commit if issue can be resolved [GIT-1]');
$repo->command(config => '--unset-all', 'githooks.checkjira.unresolved');

$repo->command(config => '--replace-all', 'githooks.checkjira.by-assignee', 1);
$ENV{USER} = 'other';
check_cannot_commit('deny commit if not by-assignee [GIT-2]',
		    qr/should be assigned to 'other', not 'user'/);

$ENV{USER} = 'user';
check_can_commit('allow commit if by-assignee [GIT-2]');
$repo->command(config => '--unset-all', 'githooks.checkjira.by-assignee');

check_can_commit('allow commit if valid issue cited [GIT-2]');

my $codefile = catfile($T, 'codefile');
my $code = <<'EOF';
sub {
    my ($git, $commit_id, $jira, @issues) = @_;
    my $keys = join(', ', sort map {$_->{key}} @issues);
    return 1 if $keys eq 'GIT-2, GIT-3';
    die "You must cite issues GIT-2 and GIT-3 only: not '$keys'\n";
}
EOF
write_file($codefile, {err_mode => 'carp'}, $code)
    or BAIL_OUT("can't write_file('$codefile', <>code>)\n");

$repo->command(config => 'githooks.checkjira.check-code', "file:$codefile");

check_cannot_commit('deny commit if check_code does not pass [GIT-2]',
		    qr/You must cite issues GIT-2 and GIT-3 only/);

check_can_commit('allow commit if check_code does pass [GIT-2 GIT-3]');

$repo->command(config => '--unset-all', 'githooks.checkjira.check-code');

$repo->command(config => 'githooks.checkjira.matchlog', '(?s)^\[([^]]+)\]');

check_cannot_commit('deny commit if cannot matchlog [GIT-2]',
		    qr/must cite a JIRA/);

check_can_commit('[GIT-2] allow commit if can matchlog');

$repo->command(config => '--add', 'githooks.checkjira.matchlog', '(?im)^Bug:(.*)');

check_can_commit(<<'EOF');
allow commit if can matchlog twice

Bug: GIT-2
EOF

check_can_commit('[GIT-2] allow commit if can matchlog twice but first');

$repo->command(config => '--unset-all', 'githooks.checkjira.matchlog');


setup_repos_for(\$clone);

check_cannot_push('deny push by update by default without JIRAs',
		  qr/must cite a JIRA/);

setup_repos_for(\$clone);

check_can_push('allow push by update if valid issue cited [GIT-2]');


setup_repos_for(\$clone);

check_cannot_push('deny push by pre-receive by default without JIRAs',
		  qr/must cite a JIRA/);

setup_repos_for(\$clone);

check_can_push('allow push by pre-receive if valid issue cited [GIT-2]');


# Check commits in new branch
$repo->command(checkout => '-q', '-b', 'fix');
check_can_push('allow push in new branch [GIT-2]', 'fix');

$repo->command(checkout => '-q', 'master');
$repo->command(branch => '-D', 'fix');
check_can_push('allow push to delete a branch [GIT-2]', ':fix');

