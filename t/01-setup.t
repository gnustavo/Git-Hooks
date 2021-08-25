#!/usr/bin/env perl

use v5.16.0;
use warnings;
use lib qw/t lib/;
use Git::Hooks::Test qw/:all/;
use Test::More tests => 1;

if (eval {new_repos(); 1}) {
    pass('create repo and clone');
} else {
    fail('create repo and clone');
}

1;
