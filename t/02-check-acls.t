# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 27;

require "test-functions.pl";

my ($repo, $file, $clone) = new_repos();
foreach my $git ($repo, $clone) {
    install_hooks($git, undef, qw/update pre-receive/);
}

sub check_can_push {
    my ($testname, $ref) = @_;
    new_commit($repo, $file);
    test_ok($testname, $repo,
	    'push', '--tags', $clone->repo_path(), $ref || 'master');
}

sub check_cannot_push {
    my ($testname, $ref, $error) = @_;
    new_commit($repo, $file);
    test_nok_match($testname, $error || qr/\) cannot \S+ ref /, $repo,
		   'push', '--tags', $clone->repo_path(), $ref || 'master');
}

# Enable plugin
$clone->command(config => 'githooks.update', 'check-acls');

# Without any specific configuration all pushes are denied
$ENV{USER} //= 'someone';	# guarantee that the user is known, at least.
check_cannot_push('deny by default');

# Check if disabling by ENV is working
$ENV{CheckAcls} = 0;
check_can_push('allow if plugin is disabled by ENV');
delete $ENV{CheckAcls};

# Configure admin environment variable
$clone->command(config => 'check-acls.userenv', 'ACL_ADMIN');
$clone->command(config => 'check-acls.admin', 'admin');

$ENV{'ACL_ADMIN'} = 'admin2';
check_cannot_push('deny if not admin');

$ENV{'ACL_ADMIN'} = 'admin';
check_can_push('allow if admin user');

$clone->command(config => '--replace-all', 'check-acls.admin', '^adm');
check_can_push('allow if admin matches regex');

$clone->command(config => '--replace-all', 'check-acls.userenv', 'eval:x y z');
check_cannot_push('disallow if userenv cannot eval', 'master', qr/error evaluating userenv value/);

$clone->command(config => '--replace-all', 'check-acls.userenv', 'eval:"nouser"');
check_cannot_push('disallow if userenv eval to nouser');

$clone->command(config => '--replace-all', 'check-acls.userenv', 'eval:$ENV{ACL_ADMIN}');
check_can_push('allow if userenv can eval');

# Configure groups
$clone->command(config => 'githooks.groups', <<'EOF');
admins1 = admin
admins = @admins1
EOF

$clone->command(config => '--replace-all', 'check-acls.admin', '@admins');
check_can_push('allow if admin in group');

$clone->command(config => '--unset', 'check-acls.admin');

$clone->command(config => 'check-acls.acl', 'admin U master');
check_cannot_push('deny ACL master');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U refs/heads/master');
check_can_push('allow ACL refs/heads/master');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U refs/heads/branch');
check_cannot_push('deny ACL other ref');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U ^.*/master');
check_can_push('allow ACL regex ref');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U !master');
check_cannot_push('deny ACL negated regex ref');

$clone->command(config => '--replace-all', 'check-acls.acl', '^adm U refs/heads/master');
check_can_push('allow ACL regex user');

delete $ENV{VAR};
$clone->command(config => '--replace-all', 'check-acls.acl', '^adm U refs/heads/{VAR}');
check_cannot_push('deny ACL non-interpolated ref');

$ENV{VAR} = 'master';
$clone->command(config => '--replace-all', 'check-acls.acl', '^adm U refs/heads/{VAR}');
check_can_push('allow ACL interpolated ref');

$clone->command(config => '--replace-all', 'check-acls.acl', '@admins U refs/heads/master');
check_can_push('allow ACL user in group ');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin DUR refs/heads/fix');
$repo->command(checkout => '-q', '-b', 'fix');
check_cannot_push('deny ACL create ref', 'heads/fix');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin C refs/heads/fix');
check_can_push('allow create ref', 'heads/fix');

$repo->command(checkout => '-q', 'master');
$repo->command(branch => '-D', 'fix');

check_cannot_push('deny ACL delete ref', ':refs/heads/fix');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin D refs/heads/fix');
check_can_push('allow ACL delete ref', ':refs/heads/fix');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U refs/heads/master');
check_can_push('allow ACL refs/heads/master again, to force a successful push');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin CDU refs/heads/master');
$repo->command(reset => '--hard', 'HEAD~2'); # rewind fix locally
check_cannot_push('deny ACL rewrite ref', '+master:master'); # try to push it

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin R refs/heads/master');
check_can_push('allow ACL rewrite ref', '+master:master'); # try to push it

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin CRUD refs/heads/master');
$repo->command(tag => '-a', '-mtag', 'objtag'); # object tag
check_cannot_push('deny ACL push tag');

$clone->command(config => '--add', 'check-acls.acl', 'admin CRUD ^refs/tags/');
check_can_push('allow ACL push tag');
