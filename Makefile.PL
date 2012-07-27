use strict;
use warnings;

##{ $perl_prereq ? qq[use $perl_prereq;] : ''; ##}

# Check if we have a proper git
chomp(my $git_version = `git version`);
if ($? == -1) {
    warn "Failed to execute 'git version': $!\n";
    exit 0;
} elsif ($? != 0) {
    warn "Command 'git version' died with exit code=$?\n";
    exit 0;
} elsif (my ($major, $minor) = ($git_version =~ /(\d+)\.(\d+)/)) {
    if ($major < 1 || $major == 1 && $minor < 5) {
	warn "Don't support gits older than 1.5. Your version is $git_version.\n";
	exit 0;
    }
} else {
    warn "Couldn't parse git version: '$git_version'\n";
    exit 0;
}

use ExtUtils::MakeMaker ##{ $eumm_version ##};

##{ $share_dir_code{preamble} || '' ##}

my %WriteMakefileArgs = (
##{ $plugin->get_default(keys %default_args) ##}
);

unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);

##{ $share_dir_code{postamble} || '' ##}

