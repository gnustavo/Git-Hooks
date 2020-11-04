# -*- cperl -*-

use 5.016;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test qw/:all/;
use Test::More tests => 1;

eval {new_repos()};
if ($@) {
    fail('create repo and clone');
} else {
    pass('create repo and clone');
}
