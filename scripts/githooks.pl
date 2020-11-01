#!/usr/bin/env perl
# PODNAME: githooks.pl
# ABSTRACT: Git::Hooks driver script

use strict;
use warnings;
use Git::Hooks;

run_hook($0, @ARGV);
