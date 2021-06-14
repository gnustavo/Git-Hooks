#!/usr/bin/env perl
# PODNAME: githooks.pl
# ABSTRACT: Git::Hooks driver script

use v5.16.0;
use warnings;
use Git::Hooks;

run_hook($0, @ARGV);
