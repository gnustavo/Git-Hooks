# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 18;
use File::Slurp;

require "test-functions.pl";

my ($repo, $file, $clone);

sub setup_repos_for {
    my ($reporef, $hook) = @_;

    ($repo, $file, $clone) = new_repos();

    foreach my $git ($repo, $clone) {
	# Inject a fake JIRA::Client class definition in order to be able
	# to test this without a real JIRA server.

	install_hooks($git, <<'EOF', qw/commit-msg update pre-receive/);
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

    $$reporef->config("githooks.$hook", 'check-jira');
    $$reporef->config('check-jira.jiraurl', 'fake://url/');
    $$reporef->config('check-jira.jirauser', 'user');
    $$reporef->config('check-jira.jirapass', 'valid');
}

sub check_can_commit {
    my ($testname) = @_;
    append_file($file, $testname);
    $repo->add($file);
    test_ok($testname, $repo, 'commit', '-m', $testname);
}

sub check_cannot_commit {
    my ($testname, $regex) = @_;
    append_file($file, $testname);
    $repo->add($file);
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
	    'push', $clone->dir(), $ref || 'master');
}

sub check_cannot_push {
    my ($testname, $regex, $ref) = @_;
    new_commit($repo, $file, $testname);
    test_nok_match($testname, $regex, $repo,
		   'push', $clone->dir(), $ref || 'master');
}


setup_repos_for(\$repo, 'commit-msg');

check_cannot_commit('deny commit by default without JIRAs');

$repo->config('check-jira.ref', 'refs/heads/fix');
check_can_commit('allow commit on disabled ref even without JIRAs');

$repo->checkout({q => 1, b => 'fix'});
check_cannot_commit('deny commit on enabled ref without JIRAs', qr/does not cite any JIRA/);

$repo->config({unset => 1}, 'check-jira.ref');
$repo->checkout({q => 1}, 'master');

$repo->config('check-jira.project', 'OTHER');
check_cannot_commit('deny commit citing non-cared for projects [GIT-0]',
		    qr/does not cite any JIRA/);

$repo->config('check-jira.require', '0');
check_can_commit('allow commit if JIRA is not required');
$repo->config({unset_all => 1}, 'check-jira.require');

$repo->config({replace_all => 1}, 'check-jira.project', 'GIT');

$repo->config({replace_all => 1}, 'check-jira.jirapass', 'invalid');
check_cannot_commit('deny commit if cannot connect to JIRA [GIT-0]',
		    qr/cannot connect to the JIRA server/);
$repo->config({replace_all => 1}, 'check-jira.jirapass', 'valid');

check_cannot_commit('deny commit if cannot get issue [GIT-0]',
		    qr/cannot get issue/);

check_cannot_commit('deny commit if issue is already resolved [GIT-1]',
		    qr/is already resolved/);

$repo->config({replace_all => 1}, 'check-jira.unresolved', 0);
check_can_commit('allow commit if issue can be resolved [GIT-1]');
$repo->config({unset_all => 1}, 'check-jira.unresolved');

$repo->config({replace_all => 1}, 'check-jira.by-assignee', 1);
$ENV{USER} = 'other';
check_cannot_commit('deny commit if not by-assignee [GIT-2]',
		    qr/is currently assigned to 'user' but should be assigned to you \(other\)/);

$ENV{USER} = 'user';
check_can_commit('allow commit if by-assignee [GIT-2]');
$repo->config({unset_all => 1}, 'check-jira.by-assignee');

check_can_commit('allow commit if valid issue cited [GIT-2]');

$repo->config('check-jira.check-code', <<'EOF');
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

$repo->config({unset_all => 1}, 'check-jira.check-code');


setup_repos_for(\$clone, 'update');

check_cannot_push('deny push by update by default without JIRAs',
		  qr/does not cite any JIRA/);

setup_repos_for(\$clone, 'update');

check_can_push('allow push by update if valid issue cited [GIT-2]');


setup_repos_for(\$clone, 'pre-receive');

check_cannot_push('deny push by pre-receive by default without JIRAs',
		  qr/does not cite any JIRA/);

setup_repos_for(\$clone, 'pre-receive');

check_can_push('allow push by pre-receive if valid issue cited [GIT-2]');

