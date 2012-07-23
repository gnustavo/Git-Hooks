use strict;
use warnings;

##{ $perl_prereq ? qq[use $perl_prereq;] : ''; ##}

# Check if we have Git installed
unless (system(qw/git version/) == 0) {
    warn "Can't find git in PATH.\n";
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

