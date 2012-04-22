# Check if every added/updated file is smaller than a fixed limit.

my $LIMIT = 10 * 1024 * 1024;	# 10MB

PRE_COMMIT {
    my ($git) = @_;

    my @changed = $git->command('diff' => qw/--cached --name-only --diff-filter=AM/);

    foreach my $info ($git->command('ls-files' => '-s', @changed)) {
	my ($mode, $sha, $n, $name) = split / /, $info;
	my $size = $git->command('cat-file' => '-s', $sha);
	die "File '$name' has $size bytes, which is more than our current limit of $LIMIT.\n"
	    if $size > $LIMIT;
    }
};

1;
