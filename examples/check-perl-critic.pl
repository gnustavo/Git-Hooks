# Check if every added/changed Perl file respects Perl::Critic's code
# standards.

PRE_COMMIT {
    my ($git) = @_;
    my %violations;
    my $critic;

    my @changed = grep {/\.p[lm]$/} $git->command('diff' => qw/--cached --name-only --diff-filter=AM/);

    foreach my $info ($git->command('ls-files' => '-s', @changed)) {
	my ($mode, $sha, $n, $name) = split / /, $info;
	require Perl::Critic;
	$critic ||= Perl::Critic->new(-severity => 'stern', -top => 10);
	my $contents = $git->command('cat-file' => $sha);
	my @violations = $critic->critique(\$contents);
	$violations{$name} = \@violations if @violations;
    }

    if (%violations) {
	# FIXME: this is a lame way to format the output.
	require Data::Dumper;
	die "Perl::Critic Violations:\n", Data::Dumper::Dumper(\%violations), "\n";
    }
};

1;
