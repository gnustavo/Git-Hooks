#!/usr/bin/env perl
# PODNAME: githooks.pl
# ABSTRACT: Git::Hooks driver script

use 5.016;
use warnings;
use Git::Hooks;

run_hook($0, @ARGV);
