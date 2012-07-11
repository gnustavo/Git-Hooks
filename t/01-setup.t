# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 1;

require "test-functions.pl";

eval {new_repos()};
if ($@) {
    fail('create repo and clone');
} else {
    pass('create repo and clone');
}
