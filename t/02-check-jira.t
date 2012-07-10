# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 18;
use File::Slurp;

require "test-functions.pl";

my ($repo, $file, $clone) = new_repos();
foreach my $git ($repo, $clone) {
    # Inject a fake JIRA::Client class definition in order to be able
    # to test this without a real JIRA server.

    install_hooks($git, <<'EOF');
package JIRA::Client;

sub new {
    my ($class, $jiraurl, $jirauser, $jirapass) = @_;
    die "JIRA::Client(fake): cannot connect or login\n" if $jirapass eq 'invalid';
    return bless {}, $class;
}

my %issues = (
    'GIT-1' => {key => 'GIT-1', resolution => 1,     assignee => 'user'},
    'GIT-2' => {key => 'GIT-2', resolution => undef, assignee => 'user'},
    'GIT-3' => {key => 'GIT-3', resolution => undef, assignee => 'user'},
);

sub getIssue {
    my ($self, $key) = @_;
    if (exists $issues{$key}) {
	return $issues{$key};
    } else {
	die "JIRA::Client(fake): no such issue ($key)\n";
    }
}

package main;
$INC{'JIRA/Client.pm'} = 'fake';
EOF
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

new_commit($repo, $file, 'mark a valid commit to rewind here later [GIT-2]');
$repo->command(tag => 'v0');


# Enable in commit hook
$repo->command(config => 'githooks.commit-msg', 'check-jira.pl');

foreach my $git ($repo, $clone) {
    $git->command(config => 'check-jira.jiraurl', 'fake://url/');
    $git->command(config => 'check-jira.jirauser', 'user');
    $git->command(config => 'check-jira.jirapass', 'invalid');
}

check_cannot_commit('deny commit by default without JIRAs');

$repo->command(config => 'check-jira.ref', 'refs/heads/fix');
check_can_commit('allow commit on disabled ref even without JIRAs');

$repo->command(checkout => '-q', '-b', 'fix');
check_cannot_commit('deny commit on enabled ref without JIRAs', qr/does not cite any valid JIRA/);

$repo->command(config => '--unset', 'check-jira.ref');
$repo->command(checkout => '-q', 'master');

$repo->command(config => 'check-jira.project', 'OTHER');
check_cannot_commit('deny commit citing non-cared for projects [GIT-0]',
		    qr/does not cite any valid JIRA/);

$repo->command(config => 'check-jira.require', '0');
check_can_commit('allow commit if JIRA is not required');
$repo->command(config => '--unset-all', 'check-jira.require');

$repo->command(config => '--replace-all', 'check-jira.project', 'GIT');
check_cannot_commit('deny commit if cannot connect to JIRA [GIT-0]',
		    qr/cannot connect to the JIRA server/);

foreach my $git ($repo, $clone) {
    $git->command(config => '--replace-all', 'check-jira.jirapass', 'valid');
}

check_cannot_commit('deny commit if cannot get issue [GIT-0]',
		    qr/cannot get issue/);

check_cannot_commit('deny commit if issue is already resolved [GIT-1]',
		    qr/is already resolved/);

$repo->command(config => '--replace-all', 'check-jira.unresolved', 0);
check_can_commit('allow commit if issue can be resolved [GIT-1]');
$repo->command(config => '--unset-all', 'check-jira.unresolved');

$repo->command(config => '--replace-all', 'check-jira.by-assignee', 'JIRACMT');
check_cannot_commit('deny commit if cannot get committer [GIT-2]',
		    qr/Cannot get committer name/);

$ENV{JIRACMT} = 'otheruser';
check_cannot_commit('deny commit if not by-assignee [GIT-2]',
		    qr/but should be assigned to you/);
$repo->command(config => '--unset-all', 'check-jira.by-assignee');

check_can_commit('allow commit if valid issue cited [GIT-2]');

$repo->command(config => 'check-jira.check-code', <<'EOF');
sub {
    my ($git, $commit_id, $jira, @issues) = @_;
    my $keys = join(', ', sort map {$_->{key}} @issues);
    return if $keys eq 'GIT-2, GIT-3';
    die "You must cite issues GIT-2 and GIT-3 only: not '$keys'\n";
}
EOF

check_cannot_commit('deny commit if check_code does not pass [GIT-2]',
		    qr/You must cite issues GIT-2 and GIT-3 only/);

check_can_commit('allow commit if check_code does pass [GIT-2 GIT-3]');

$repo->command(config => '--unset-all', 'check-jira.check-code');

$repo->command(config => '--unset-all', 'githooks.commit-msg');

# Enable in update hook
$repo->command(reset => '--hard', 'v0'); # rewind to original valid state

$clone->command(config => 'githooks.update', 'check-jira.pl');

check_cannot_push('deny push by update by default without JIRAs',
		  qr/does not cite any valid JIRA/);

$repo->command(reset => '--hard', 'v0');

check_can_push('allow push by update if valid issue cited [GIT-2]');


# Enable in pre-receive hook
$clone->command(config => '--unset-all', 'githooks.update');
$clone->command(config => 'githooks.pre-receive', 'check-jira.pl');

check_cannot_push('deny push by pre-receive by default without JIRAs',
		  qr/does not cite any valid JIRA/);

$repo->command(reset => '--hard', 'HEAD~1');

check_can_push('allow push by pre-receive if valid issue cited [GIT-2]');

