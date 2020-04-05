#!/usr/bin/env perl
# PODNAME: githooks.pl

use strict;
use warnings;
use Git::Hooks;

run_hook($0, @ARGV);
