# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 20;

require "test-functions.pl";

my ($repo, $file, $clone) = new_repos();

sub check_can_push {
    my ($testname, $ref) = @_;
    new_commit($repo, $file);
    test_ok($testname, $repo,
	    'push', $clone->repo_path(), $ref || 'master');
}

sub check_cannot_push {
    my ($testname, $ref) = @_;
    new_commit($repo, $file);
    test_nok_match($testname, qr/cannot change/, $repo,
		   'push', $clone->repo_path(), $ref || 'master');
}

# Enable plugin
$clone->command(config => 'githooks.update', 'check-acls.pl');

# Without any specific configuration all pushes are denied
check_cannot_push('deny by default');

# Configure admin environment variable
$clone->command(config => 'check-acls.userenv', 'ACL_ADMIN');
$clone->command(config => 'check-acls.admin', 'admin');

$ENV{'ACL_ADMIN'} = 'admin2';
check_cannot_push('deny if not admin');

$ENV{'ACL_ADMIN'} = 'admin';
check_can_push('allow if admin user');

$clone->command(config => '--replace-all', 'check-acls.admin', '^adm');
check_can_push('allow if admin matches regex');

# Configure groups
$clone->command(config => 'check-acls.groups', <<'EOF');
admins1 = admin
admins = @admins1
EOF

$clone->command(config => '--replace-all', 'check-acls.admin', '@admins');
check_can_push('allow if admin in group');

$clone->command(config => '--unset', 'check-acls.admin');

$clone->command(config => 'check-acls.acl', 'admin U master');
check_cannot_push('deny ACL master');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U heads/master');
check_can_push('allow ACL heads/master');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U heads/branch');
check_cannot_push('deny ACL other ref');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U refs/heads/master');
check_cannot_push('deny ACL refs/heads/master');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin U ^.*/master');
check_can_push('allow ACL regex ref');

$clone->command(config => '--replace-all', 'check-acls.acl', '^adm U heads/master');
check_can_push('allow ACL regex user');

$clone->command(config => '--replace-all', 'check-acls.acl', '@admins U heads/master');
check_can_push('allow ACL user in group ');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin DUR heads/fix');
$repo->command(checkout => '-b', 'fix');
check_cannot_push('deny ACL create ref', 'heads/fix');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin C heads/fix');
check_can_push('allow create ref', 'heads/fix');

$repo->command(checkout => 'master');
$repo->command(branch => '-D', 'fix');

check_cannot_push('deny ACL delete ref', ':refs/heads/fix');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin D heads/fix');
check_can_push('allow ACL delete ref', ':refs/heads/fix');

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin CDU heads/master');
$repo->command(reset => '--hard', 'HEAD^^'); # rewind fix locally
check_cannot_push('deny ACL rewrite ref', '+master:master'); # try to push it

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin R heads/master');
check_can_push('allow ACL rewrite ref', '+master:master'); # try to push it

$clone->command(config => '--replace-all', 'check-acls.acl', 'admin CRUD heads/master');
$repo->command(tag => '-a', '-mtag', 'objtag'); # object tag
check_cannot_push('deny ACL push tag');

$clone->command(config => 'check-acls.acl', 'admin CRUD ^tags/');
check_can_push('allow ACL push tag');
