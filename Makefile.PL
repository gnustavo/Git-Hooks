use strict;
use warnings;
use File::Spec::Functions;
use File::Slurp;

##{ $perl_prereq ? qq[use $perl_prereq;] : ''; ##}

if ($^O eq 'MSWin32') {
    warn "I do not support Windows yet. Sorry.\n";
    exit 0;
}

sub git {
    my ($args) = @_;
    my $output = `git $args`;
    if ($? == -1) {
        warn "Failed to execute 'git $args': $!\n";
        exit 0;
    } elsif ($? != 0) {
        warn "Command 'git $args' died with exit code=$?\n";
        exit 0;
    }
    return $output;
}

# Check if we have a proper git
chomp(my $git_version = git('version'));
if (my ($major, $minor) = ($git_version =~ /(\d+)\.(\d+)/)) {
    if ($major < 1 || $major == 1 && $minor < 5) {
	warn "Don't support gits older than 1.5. Your version is $git_version.\n";
	exit 0;
    }
} else {
    warn "Couldn't parse git version: '$git_version'\n";
    exit 0;
}

# Check if we can use Git.pm
# See http://git.661346.n2.nabble.com/better-way-to-find-Git-pm-officially-td7416362.html
my $pathsep = $^O eq 'MSWin32' ? ';' : ':';
unshift @INC, split("$pathsep", $ENV{GITPERLLIB}) if exists $ENV{GITPERLLIB};
my $INC = join ' ', @INC;
my $require = eval {require Git};
shift @INC if exists $ENV{GITPERLLIB};

unless (defined $require) {
    warn <<"EOF";

I can't find Git.pm in your \@INC: ( $INC ).

The Git module is distributed with git and is not at CPAN yet. So,
Git::Hooks can't depend on it directly. Since I already detected that
you have git you most probably have Git installed somewhere.

Once you find Git.pm, you have to make it available to your Perl in
order to install Git::Hooks and to use it. Here are a few options to
do that:

* Move it to one of the directories already in \@INC above.

* Add the directory where you found it to the PERL5LIB environment
  variable.

* Add the directory where you found it to the GITPERLLIB environment
  variable. This method is arguably better than the previous one
  because GITPERLLIB is used specifically to find Git.pm whereas
  PERL5LIB directories are used to find any required/used module in
  your program.

EOF

    my @inc;                    # other places to find it

    # Try to grok it from a git perl script.
    chomp(my $exec_path = git('--exec-path'));
    my $gitsvn = catfile($exec_path, 'git-svn');
    if (open my $fh, '<', $gitsvn) {
        my $line;
        $line = <$fh> for 1..2; # read the second line
        if ($line =~ m:^use lib .*? \|\| "([^"]+)":) {
            push @inc, $1;
        }
    }

    # Usual places for some OSs
    if ($^O eq 'linux') {
        push @inc, '/usr/share/perl5';
    } elsif ($^O eq 'MSWin32') {
        my $pfiles = exists $ENV{'ProgramFiles(x86)'} ? $ENV{'ProgramFiles(x86)'} : 'C:\Program Files (x86)';
        push @inc, "$pfiles\\Git\\lib\\perl5\\site_perl";
    }

    my $found;

    foreach my $inc (@inc) {
        my $git_pm = catfile($inc, 'Git.pm');
        if (-r $git_pm) {
            write_file(catfile(qw/t GITPERLLIB/), $inc);
            warn <<"EOF";
Hey, you're lucky. I just found it at:

    $git_pm

I'm going to use this during the tests and allow you to install
Git::Hooks. But you'll still have to make Git available to your own
scripts following the instructions above.

EOF
            $found = 1;
            last;
        }
    }

    exit 0 unless $found;
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

