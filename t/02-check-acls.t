# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 26;

require "test-functions.pl";

my ($repo, $file, $clone) = new_repos();
foreach my $git ($repo, $clone) {
    install_hooks($git, undef, qw/update pre-receive/);
}

sub check_can_push {
    my ($testname, $ref) = @_;
    new_commit($repo, $file);
    test_ok($testname, $repo,
	    'push', '--tags', $clone->dir(), $ref || 'master');
}

sub check_cannot_push {
    my ($testname, $ref, $error) = @_;
    new_commit($repo, $file);
    test_nok_match($testname, $error || qr/\) cannot \S+ ref /, $repo,
		   'push', '--tags', $clone->dir(), $ref || 'master');
}

# Enable plugin
$clone->config('githooks.update', 'check-acls');

# Without any specific configuration all pushes are denied
$ENV{USER} //= 'someone';	# guarantee that the user is known, at least.
check_cannot_push('deny by default');

# Configure admin environment variable
$clone->config('check-acls.userenv', 'ACL_ADMIN');
$clone->config('check-acls.admin', 'admin');

$ENV{'ACL_ADMIN'} = 'admin2';
check_cannot_push('deny if not admin');

$ENV{'ACL_ADMIN'} = 'admin';
check_can_push('allow if admin user');

$clone->config({replace_all => 1}, 'check-acls.admin', '^adm');
check_can_push('allow if admin matches regex');

$clone->config({replace_all => 1}, 'check-acls.userenv', 'eval:x y z');
check_cannot_push('disallow if userenv cannot eval', 'master', qr/error evaluating userenv value/);

$clone->config({replace_all => 1}, 'check-acls.userenv', 'eval:"nouser"');
check_cannot_push('disallow if userenv eval to nouser');

$clone->config({replace_all => 1}, 'check-acls.userenv', 'eval:$ENV{ACL_ADMIN}');
check_can_push('allow if userenv can eval');

# Configure groups
$clone->config('githooks.groups', <<'EOF');
admins1 = admin
admins = @admins1
EOF

$clone->config({replace_all => 1}, 'check-acls.admin', '@admins');
check_can_push('allow if admin in group');

$clone->config('--unset', 'check-acls.admin');

$clone->config('check-acls.acl', 'admin U master');
check_cannot_push('deny ACL master');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin U refs/heads/master');
check_can_push('allow ACL refs/heads/master');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin U refs/heads/branch');
check_cannot_push('deny ACL other ref');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin U ^.*/master');
check_can_push('allow ACL regex ref');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin U !master');
check_cannot_push('deny ACL negated regex ref');

$clone->config({replace_all => 1}, 'check-acls.acl', '^adm U refs/heads/master');
check_can_push('allow ACL regex user');

delete $ENV{VAR};
$clone->config({replace_all => 1}, 'check-acls.acl', '^adm U refs/heads/{VAR}');
check_cannot_push('deny ACL non-interpolated ref');

$ENV{VAR} = 'master';
$clone->config({replace_all => 1}, 'check-acls.acl', '^adm U refs/heads/{VAR}');
check_can_push('allow ACL interpolated ref');

$clone->config({replace_all => 1}, 'check-acls.acl', '@admins U refs/heads/master');
check_can_push('allow ACL user in group ');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin DUR refs/heads/fix');
$repo->checkout({q => 1, b => 'fix'});
check_cannot_push('deny ACL create ref', 'heads/fix');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin C refs/heads/fix');
check_can_push('allow create ref', 'heads/fix');

$repo->checkout({q => 1}, 'master');
$repo->branch({D => 1}, 'fix');

check_cannot_push('deny ACL delete ref', ':refs/heads/fix');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin D refs/heads/fix');
check_can_push('allow ACL delete ref', ':refs/heads/fix');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin U refs/heads/master');
check_can_push('allow ACL refs/heads/master again, to force a successful push');

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin CDU refs/heads/master');
$repo->reset({hard => 1}, 'HEAD~2'); # rewind fix locally
check_cannot_push('deny ACL rewrite ref', '+master:master'); # try to push it

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin R refs/heads/master');
check_can_push('allow ACL rewrite ref', '+master:master'); # try to push it

$clone->config({replace_all => 1}, 'check-acls.acl', 'admin CRUD refs/heads/master');
$repo->tag({a => 1, m => 'tag'}, 'objtag'); # object tag
check_cannot_push('deny ACL push tag');

$clone->config({add => 1}, 'check-acls.acl', 'admin CRUD ^refs/tags/');
check_can_push('allow ACL push tag');
