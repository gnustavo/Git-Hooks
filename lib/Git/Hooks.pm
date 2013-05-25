package Git::Hooks;
# ABSTRACT: A framework for implementing Git hooks.

use 5.010;
use strict;
use warnings;
use Exporter qw/import/;
use Data::Util qw(:all);
use File::Slurp;
use File::Basename;
use File::Spec::Functions;
use List::MoreUtils qw/uniq/;

our (@EXPORT, @EXPORT_OK, %EXPORT_TAGS); ## no critic (Modules::ProhibitAutomaticExportation)
my %Hooks;

BEGIN {                ## no critic (Subroutines::RequireArgUnpacking)
    my @installers =
        qw/ APPLYPATCH_MSG PRE_APPLYPATCH POST_APPLYPATCH
            PRE_COMMIT PREPARE_COMMIT_MSG COMMIT_MSG
            POST_COMMIT PRE_REBASE POST_CHECKOUT POST_MERGE
            PRE_RECEIVE UPDATE POST_RECEIVE POST_UPDATE
            PRE_AUTO_GC POST_REWRITE /;

    for my $installer (@installers) {
        my $hook = lc $installer;
        $hook =~ tr/_/-/;
        install_subroutine(
            __PACKAGE__,
            $installer => sub (&) {
                my ($foo) = @_;
                $Hooks{$hook}{$foo} ||= sub { $foo->(@_); };
            }
        );
    }

    @EXPORT      = (@installers, 'run_hook');

    @EXPORT_OK = qw/is_ref_enabled im_memberof match_user im_admin
                    eval_gitconfig /;

    %EXPORT_TAGS = (utils => \@EXPORT_OK);
}

use Git::More;

sub is_ref_enabled {
    my ($ref, @specs) = @_;

    return 1 if ! defined $ref || @specs == 0;

    foreach (@specs) {
        if (/^\^/) {
            return 1 if $ref =~ qr/$_/;
        } else {
            return 1 if $ref eq $_;
        }
    }

    return 0;
}

# This is an internal routine used to invoke external hooks, feed them
# the needed input and wait for them.

sub spawn_external_file {
    my ($git, $file, $hook, @args) = @_;

    if ($hook !~ /^(?:pre|post)-receive$/) {

        my $exit = system {$file} ($hook, @args);

        if ($exit == 0) {
            return 1;
        } elsif ($exit == -1) {
            $git->error(__PACKAGE__, ": failed to execute '$file': $!\n");
        } elsif ($exit & 127) {
            $git->error(__PACKAGE__, sprintf("'$file' died with signal %d, %s coredump\n",
                                             ($exit & 127), ($exit & 128) ? 'with' : 'without'));
        } else {
            $git->error(__PACKAGE__, sprintf("'$file' exited abnormally with value %d\n", $exit >> 8));
        }

        return 0;

    } else {

        my $pid = open my $pipe, '|-'; ## no critic (InputOutput::RequireBriefOpen)

        if (! defined $pid) {
            die __PACKAGE__, ": can't fork: $!\n";
        } elsif ($pid) {
            # parent
            foreach my $ref ($git->get_affected_refs()) {
                my ($old, $new) = $git->get_affected_ref_range($ref);
                say $pipe "$old $new $ref";
            }
            if (close $pipe) {
                return 1;
            } elsif ($!) {
                die __PACKAGE__, ": Error closing pipe to external hook '$file': $!\n";
            } else {
                die __PACKAGE__, ": External hook '$file' exited with $?\n";
            }
        } else {
            # child
            exec {$file} ($hook, @args);
            die __PACKAGE__, ": can't exec: $!\n";
        }
    }
}

sub grok_groups_spec {
    my ($specs, $source) = @_;
    my %groups;
    foreach (@$specs) {
        s/\#.*//;               # strip comments
        next unless /\S/;       # skip blank lines
        /^\s*(\w+)\s*=\s*(.+?)\s*$/
            or die __PACKAGE__, ": invalid line in group file '$source': $_\n";
        my ($groupname, $members) = ($1, $2);
        exists $groups{"\@$groupname"}
            and die __PACKAGE__, ": redefinition of group ($groupname) in '$source': $_\n";
        foreach my $member (split / /, $members) {
            if ($member =~ /^\@/) {
                # group member
                $groups{"\@$groupname"}{$member} = $groups{$member}
                    or die __PACKAGE__, ": unknown group ($member) cited in '$source': $_\n";
            } else {
                # user member
                $groups{"\@$groupname"}{$member} = undef;
            }
        }
    }
    return \%groups;
}

sub grok_groups {
    my ($git) = @_;

    my $cache = $git->cache('githooks');

    unless (exists $cache->{groups}) {
        my $groups = $git->get_config(githooks => 'groups')
            or die __PACKAGE__, ": you have to define the githooks.groups option to use groups.\n";

        if (my ($groupfile) = ($groups =~ /^file:(.*)/)) {
            my @groupspecs = read_file($groupfile);
            defined $groupspecs[0]
                or die __PACKAGE__, ": can't open groups file ($groupfile): $!\n";
            $cache->{groups} = grok_groups_spec(\@groupspecs, $groupfile);
        } else {
            my @groupspecs = split /\n/, $groups;
            $cache->{groups} = grok_groups_spec(\@groupspecs, "githooks.groups");
        }
    }

    return $cache->{groups};
}

sub im_memberof {
    my ($git, $myself, $groupname) = @_;

    my $groups = grok_groups($git);

    exists $groups->{$groupname}
        or die __PACKAGE__, ": group $groupname is not defined.\n";

    my $group = $groups->{$groupname};
    return 1 if exists $group->{$myself};
    while (my ($member, $subgroup) = each %$group) {
        next     unless defined $subgroup;
        return 1 if     im_memberof($git, $myself, $member);
    }
    return 0;
}

sub match_user {
    my ($git, $spec) = @_;

    if (my $myself = $git->authenticated_user()) {
        if ($spec =~ /^\^/) {
            return 1 if $myself =~ $spec;
        } elsif ($spec =~ /^@/) {
            return 1 if im_memberof($git, $myself, $spec);
        } else {
            return 1 if $myself eq $spec;
        }
    }

    return 0;
}

sub im_admin {
    my ($git) = @_;
    foreach my $spec ($git->get_config(githooks => 'admin')) {
        return 1 if match_user($git, $spec);
    }
    return 0;
}

sub eval_gitconfig {
    my ($config) = @_;

    my $value;

    if ($config =~ s/^file://) {
        $value = do $config;
        unless ($value) {
            die "couldn't parse '$config': $@\n" if $@;
            die "couldn't do '$config': $!\n"    unless defined $value;
            die "couldn't run '$config'\n"       unless $value;
        }
    } elsif ($config =~ s/^eval://) {
        $value = eval $config; ## no critic (BuiltinFunctions::ProhibitStringyEval)
        die "couldn't parse '$config':\n$@\n" if $@;
    } else {
        $value = $config;
    }

    return $value;
}

##############
# The following routines prepare the arguments for some hooks to make
# it easier to deal with them later on.

# The pre-receive and post-receive hooks get the list of affected
# commits via STDIN. This routine gets them all and set all affected
# refs in the Git object.

sub _prepare_receive {
    my ($git) = @_;
    while (<STDIN>) { ## no critic (InputOutput::ProhibitExplicitStdin)
        chomp;
        my ($old_commit, $new_commit, $ref) = split;
        $git->set_affected_ref($ref, $old_commit, $new_commit);
    }
    return;
}

# The update hook get three arguments telling which reference is being
# updated, from which commit, to which commit. Here we use these
# arguments to set the affected ref in the Git object.

sub _prepare_update {
    my ($git, $args) = @_;
    $git->set_affected_ref(@$args);
    return;
}

# The %prepare_hook hash maps hook names to the routine that must be
# invoked in order to "prepare" their arguments.

my %prepare_hook = (
    'update'       => \&_prepare_update,
    'pre-receive'  => \&_prepare_receive,
    'post-receive' => \&_prepare_receive,
);

################
# This routine loads every plugin configured in the githooks.plugin
# option.

sub _load_plugins {
    my ($git) = @_;

    my @enabled_plugins = $git->get_config(githooks => 'plugin');

    return () unless @enabled_plugins; # no one configured

    # Define the list of directories where we'll look for the hook
    # plugins. First the local directory 'githooks' under the
    # repository path, then the optional list of directories
    # specified by the githooks.plugins config option, and,
    # finally, the Git::Hooks standard hooks directory.
    my @plugin_dirs = grep {-d} (
        'githooks',
        $git->get_config(githooks => 'plugins'),
        catfile(dirname($INC{'Git/Hooks.pm'}), 'Hooks'),
    );

    foreach my $plugin (uniq @enabled_plugins) {
        my $prefix = '';
        if ($plugin =~ s/(.+::)//) {
            $prefix = $1;
        }
        next if exists $ENV{$plugin} && ! $ENV{$plugin}; # disabled by user
        my $exit = do {
            if ($prefix) {
                # It must be a module name

                ## no critic (ErrorHandling::RequireCheckingReturnValueOfEval, Modules::RequireBarewordIncludes)
                eval {require "$prefix$plugin"};
                ## use critic

            } else {
                # Otherwise, it's a basename that we must look for
                # in @plugin_dirs
                $plugin .= '.pm' unless $plugin =~ /\.p[lm]$/i;
                my @scripts = grep {-f} map {catfile($_, $plugin)} @plugin_dirs;
                my $script = shift @scripts
                    or die __PACKAGE__, ": can't find enabled hook $plugin.\n";
                $plugin = $script; # for the error messages below
                do $script;
            }
        };
        unless ($exit) {
            die __PACKAGE__, ": couldn't parse $plugin: $@\n" if $@;
            die __PACKAGE__, ": couldn't do $plugin: $!\n"    unless defined $exit;
            die __PACKAGE__, ": couldn't run $plugin\n";
        }
    }

    return;
}

# This is the main routine of Git::Hooks. It gets the original hook
# name and arguments, sets up the environment, loads plugins and
# invokes the appropriate hook functions.

sub run_hook {
    my ($hook_name, @args) = @_;

    $hook_name = basename $hook_name;

    my $git = Git::More->repository();

    # Some hooks need some argument munging before we invoke them
    if (my $prepare = $prepare_hook{$hook_name}) {
        $prepare->($git, \@args);
    }

    _load_plugins($git);

    # Call every hook function installed by the hook scripts before.
    foreach my $hook (values %{$Hooks{$hook_name}}) {
        my $ok = eval { $hook->($git, @args) };
        if (defined $ok) {
            # Modern hooks return a boolean value indicating their success.
            # If they fail they invoke Git::More::error.
        } elsif (length $@) {
            # Old hooks die when they fail...
            $git->error(__PACKAGE__ . "($hook_name)", $@);
        } else {
            # ...and return undef when they succeed.
        }
    }

    # Invoke enabled external hooks. This doesn't work in Windows yet.
    if ($^O ne 'MSWin32' && $git->get_config(githooks => 'externals')) {
        foreach my $dir (
            grep {-e} map {catfile($_, $hook_name)}
                ($git->get_config(githooks => 'hooks'), catfile($git->repo_path(), 'hooks.d'))
        ) {
            opendir my $dh, $dir
                or $git->error(__PACKAGE__, ": cannot opendir $dir: $!\n")
                    and next;
            foreach my $file (grep {-f && -x} map {catfile($dir, $_)} readdir $dh) {
                spawn_external_file($git, $file, $hook_name, @args)
                    or $git->error(__PACKAGE__, ": error in external hook '$file'\n");
            }
        }
    }

    die "\n" if scalar($git->get_errors());

    return;
}


1; # End of Git::Hooks
__END__

=for Pod::Coverage spawn_external_file grok_groups_spec grok_groups

=head1 SYNOPSIS

A single script can implement several Git hooks:

        #!/usr/bin/env perl

        use Git::Hooks;

        PRE_COMMIT {
            my ($git) = @_;
            # ...
        };

        COMMIT_MSG {
            my ($git, $msg_file) = @_;
            # ...
        };

        run_hook($0, @ARGV);

Or you can use Git::Hooks plugins or external hooks, driven by the
single script below. These hooks are enabled by Git configuration
options. (More on this later.)

        #!/usr/bin/env perl

        use Git::Hooks;

        run_hook($0, @ARGV);

=head1 INTRODUCTION

"Git is a fast, scalable, distributed revision control system with an
unusually rich command set that provides both high-level operations
and full access to
internals. (L<Git README|https://github.com/gitster/git#readme>)"

In order to really understand what this is all about you need to
understand L<Git|http://git-scm.org/> and its hooks. You can read
everything about this in the
L<documentation|http://git-scm.com/documentation> references on that
site.

A L<Git hook|http://schacon.github.com/git/githooks.html> is a
specifically named program that is called by the git program during
the execution of some operations. At the last count, there were
exactly 16 different hooks which can be used. They must reside under
the C<.git/hooks> directory in the repository. When you create a new
repository, you get some template files in this directory, all of them
having the C<.sample> suffix and helpful instructions inside
explaining how to convert them into working hooks.

When Git is performing a commit operation, for example, it calls these
four hooks in order: C<pre-commit>, C<prepare-commit-msg>,
C<commit-msg>, and C<post-commit>. The first three can gather all
sorts of information about the specific commit being performed and
decide to reject it in case it doesn't comply to specified
policies. The C<post-commit> can be used to log or alert interested
parties about the commit just done.

There are several useful hook scripts available elsewhere, e.g.
L<https://github.com/gitster/git/tree/master/contrib/hooks> and
L<http://google.com/search?q=git+hooks>. However, when you try to
combine the functionality of two or more of those scripts in a single
hook you normally end up facing two problems.

=over

=item B<Complexity>

In order to integrate the functionality of more than one script you
have to write a driver script that's called by Git and calls all the
other scripts in order, passing to them the arguments they
need. Moreover, some of those scripts may have configuration files to
read and you may have to maintain several of them.

=item B<Inefficiency>

This arrangement is inefficient in two ways. First because each script
runs as a separate process, which usually have a high start up cost
because they are, well, scripts and not binaries. (For a dissent view
on this, see
L<this|http://gnustavo.wordpress.com/2012/06/28/programming-languages-start-up-times/>.)
And second, because as each script is called in turn they have no
memory of the scripts called before and have to gather the information
about the transaction again and again, normally by calling the C<git>
command, which spawns yet another process.

=back

Git::Hooks is a framework for implementing Git hooks and driving
existing external hooks in a way that tries to solve these problems.

Instead of having separate scripts implementing different
functionality you may have a single script implementing all the
functionality you need either directly or using some of the existing
plugins, which are implemented by Perl scripts in the Git::Hooks::
namespace. This single script can be used to implement all standard
hooks, because each hook knows when to perform based on the context in
which the script was called.

If you already have some handy hooks and want to keep using them,
don't worry. Git::Hooks can drive external hooks very easily.

=head1 USAGE

There are a few simple steps you should do in order to set up
Git::Hooks so that you can configure it to use some predefined plugins
or start coding your own hooks.

The first step is to create a generic script that will be invoked by
Git for every hook. If you are implementing hooks in your local
repository, go to its C<.git/hooks> sub-directory. If you are
implementing the hooks in a bare repository in your server, go to its
C<hooks> sub-directory.

You should see there a bunch of files with names ending in C<.sample>
which are hook examples. Create a three-line script called, e.g.,
C<git-hooks.pl>, in this directory like this:

        $ cd /path/to/repo/.git/hooks

        $ cat >git-hooks.pl <<EOT
        #!/usr/bin/env perl
        use Git::Hooks;
        run_hook($0, @ARGV);
        EOT

        $ chmod +x git-hooks.pl

Now you should create symbolic links pointing to it for each hook you
are interested in. For example, if you are interested in a
C<commit-msg> hook, create a symbolic link called C<commit-msg>
pointing to the C<git-hooks.pl> file. This way, Git will invoke the
generic script for all hooks you are interested in. (You may create
symbolic links for all 16 hooks, but this will make Git call the
script for all hooked operations, even for those that you may not be
interested in. Nothing wrong will happen, but the server will be doing
extra work for nothing.)

        $ ln -s git-hooks.pl commit-msg
        $ ln -s git-hooks.pl post-commit
        $ ln -s git-hooks.pl pre-receive

As is, the script won't do anything. You have to implement some hooks
in it, use some of the existing plugins, or set up some external
plugins to be invoked properly. Either way, the script should end with
a call to C<run_hook> passing to it the name with which it was called
(C<$0>) and all the arguments it received (C<@ARGV>).

=head2 Implementing Hooks

You may implement your own hooks using one of the hook I<directives>
described in the HOOK DIRECTIVES section below. Your hooks may be
implemented in the generic script you have created. They must be
defined after the C<use Git::Hooks> line and before the C<run_hook()>
line.

A hook should return a boolean value indicating if it was
successful. B<run_hook> dies after invoking all hooks if at least one
of them returned false.

B<run_hook> invokes the hooks inside an eval block to catch any
exception, such as if a B<die> is used inside them. When an exception
is detected the hook is considered to have failed and the exception
string (B<$@>) is showed to the user.

The best way to produce an error message is to invoke the
B<Git::More::error> method passing a prefix and a message for uniform
formating.

For example:

    # Check if every added/updated file is smaller than a fixed limit.

    my $LIMIT = 10 * 1024 * 1024; # 10MB

    PRE_COMMIT {
        my ($git) = @_;

        my @changed = $git->command(qw/diff --cached --name-only --diff-filter=AM/);

        my $errors = 0;

        foreach ($git->command('ls-files' => '-s', @changed)) {
            chomp;
            my ($mode, $sha, $n, $name) = split / /;
            my $size = $git->command('cat-file' => '-s', $sha);
            $size <= $LIMIT
                or $git-error('CheckSize', "File '$name' has $size bytes, more than our limit of $LIMIT.\n"
                    and $errors++;
        }

        return $errors == 0;
    };

    # Check if every added/changed Perl file respects Perl::Critic's code
    # standards.

    PRE_COMMIT {
        my ($git) = @_;
        my %violations;

        my @changed = grep {/\.p[lm]$/} $git->command(qw/diff --cached --name-only --diff-filter=AM/);

        foreach ($git->command('ls-files' => '-s', @changed)) {
            chomp;
            my ($mode, $sha, $n, $name) = split / /;
            require Perl::Critic;
            state $critic = Perl::Critic->new(-severity => 'stern', -top => 10);
            my $contents = $git->command('cat-file' => $sha);
            my @violations = $critic->critique(\$contents);
            $violations{$name} = \@violations if @violations;
        }

        if (%violations) {
            # FIXME: this is a lame way to format the output.
            require Data::Dumper;
            $git->error('Perl::Critic Violations', Data::Dumper::Dumper(\%violations));
            return 0;
        }

        return 1;
    };

Note that you may define several hooks for the same operation. In the
above example, we've defined two PRE_COMMIT hooks. Both are going to
be executed when Git invokes the generic script during the pre-commit
phase.

You may implement different kinds of hooks in the same generic
script. The function C<run_hook()> will activate just the ones for
the current Git phase.

=head2 Using Plugins

There are several hooks already implemented as plugin modules, which
you can use. Some are described succinctly below. Please, see their
own documentation for more details.

=over

=item * Git::Hooks::CheckAcls

Allow you to specify Access Control Lists to tell who can commit or
push to the repository and affect which Git refs.

=item * Git::Hooks::CheckJira

Integrate Git with the L<JIRA|http://www.atlassian.com/software/jira/>
ticketing system by requiring that every commit message cites valid
JIRA issues.

=item * Git::Hooks::CheckLog

Check commit log messages formatting.

=item * Git::Hooks::CheckRewrite

Check if a B<git rebase> or a B<git commit --amend> is safe, meaning
that no rewritten commit is contained by any other branch besides the
current one. This is useful, for instance, to prevent rebasing commits
already pushed.

=item * Git::Hooks::CheckStructure

Check if newly added files and references (branches and tags) comply
with specified policies, so that you can impose a strict structure to
the repository's file and reference hierarchies.

=item * Git::Hooks::GerritChangeId

Inserts a C<Change-Id> line in the commit log message to allow
integration with Gerrit's code review system.

=back

Each plugin may be used in one or, sometimes, multiple hooks. Their
documentation is explicit about this.

These plugins are configured by Git's own configuration framework,
using the C<git config> command or by directly editing Git's
configuration files. (See C<git help config> to know more about Git's
configuration infrastructure.)

To enable a plugin you must add it to the C<githooks.plugin>
configuration option.

The CONFIGURATION section below explains this in more detail.

=head2 Invoking external hooks

Since the default Git hook scripts are taken by the symbolic links to
the Git::Hooks generic script, you must install any other hooks
somewhere else. By default, the C<run_hook> routine will look for
external hook scripts in the directory C<.git/hooks.d> (which you must
create) under the repository. Below this directory you should have
another level of directories, named after the default hook names,
under which you can drop your external hooks.

For example, let's say you want to use some of the hooks in the
L<standard Git
package|https://github.com/gitster/git/blob/b12905140a8239ac687450ad43f18b5f0bcfb62e/contrib/hooks/>).
You should copy each of those scripts to a file under the appropriate
hook directory, like this:

=over

=item * C<.git/hooks.d/pre-auto-gc/pre-auto-gc-battery>

=item * C<.git/hooks.d/pre-commit/setgitperms.perl>

=item * C<.git/hooks.d/post-receive/post-receive-email>

=item * C<.git/hooks.d/update/update-paranoid>

=back

Note that you may install more than one script under the same
hook-named directory. The driver will execute all of them in a
non-specified order.

If any of them exits abnormally, B<run_hook> dies with an appropriate
error message.

=head1 CONFIGURATION

Git::Hooks is configured via Git's own configuration
infrastructure. There are a few global options which are described
below. Each plugin may define other specific options which are
described in their own documentation. The options specific to a plugin
usually are contained in a configuration subsection of section
C<githooks>, named after the plugin base name. For example, the
C<Git::Hooks::CheckAcls> plugin has its options contained in the
configuration subsection C<githooks.checkacls>.

You should get comfortable with C<git config> command (read C<git help
config>) to know how to configure Git::Hooks.

When you invoke C<run_hook>, the command C<git config --list> is
invoked to grok all configuration affecting the current
repository. Note that this will fetch all C<--system>, C<--global>,
and C<--local> options, in this order. You may use this mechanism to
define configuration global to a user or local to a repository.

=head2 githooks.plugin PLUGIN

To enable a plugin you must add it to this configuration option, like
this:

    $ git config --add githooks.plugin CheckAcls

To enable more than one plugin, simply repeat the command for the next
one:

    $ git config --add githooks.plugin CheckJira

A plugin may hook itself to one or more hooks. C<CheckJira>, for
example, hook itself to three: C<commit-msg>, C<pre-receive>, and
C<update>. It's important that the corresponding symbolic links be
created pointing from the hook names to the generic script so that the
hooks are effectively invoked.

In the previous examples, the plugins were referred to by their short
names. In this case they are looked for in three places, in this
order:

=over

=item 1.

In the C<githooks> directory under the repository path (usually in
C<.git/githooks>), so that you may have repository specific hooks (or
repository specific versions of a hook).

=item 2.

In every directory specified with the C<githooks.plugins> option.  You
may set it more than once if you have more than one directory holding
your hooks.

=item 3.

In Git::Hooks installation.

=back

The first match is taken as the desired plugin, which is executed (via
C<do>) and the search stops. So, you may want to copy one of the
standard plugins and change it to suit your needs better. (Don't shy
away from sending your changes back to the author, please.)

However, if you use the fully qualified module name of the plugin in
the configuration, then it will be simply C<required> as a normal
module. For example:

    $ git config --add githooks.plugin My::Hook::CheckSomething

Finally, you may temporarily disable a plugin by assigning to "0" an
environment variable with its name. This is useful sometimes, when you
are denied some perfectly fine commit by one of the check plugins. For
example, suppose you got an error from the CheckLog plugin because you
used an uncommon word that is not in the system's dictionary yet. If
you don't intend to use the word again you can bypass all CheckLog
checks this way:

    $ CheckLog=0 git commit

This works for every hook. The environment variable name has to match
exactly the plugin name as configured.

Note, however, that this works for local hooks only. Remote hooks
(like B<update> or B<pre-receive>) are run on the server. You can set
up the server so that it defines the appropriate variable, but this
isn't so useful as for the local hooks, as it's intended for
once-in-a-while events.

=head2 githooks.plugins DIR

This option specify a list of directories where plugins are looked for
besides the default locations, as explained in the C<githooks.plugin>
option above.

=head2 githooks.externals [01]

By default the driver script will look for external hooks after
executing every enabled plugins. You may disable external hooks
invocation by setting this option to 0.

=head2 githooks.hooks DIR

You can tell this plugin to look for external hooks in other
directories by specifying them with this option. The directories
specified here will be looked for after the default directory
C<.git/hooks.d>, so that you can use this option to have some global
external hooks shared by all of your repositories.

Please, see the plugins documentation to know about their own
configuration options.

=head2 githooks.groups GROUPSPEC

You can define user groups in order to make it easier to configure
access control plugins. Use this option to tell where to find group
definitions in one of these ways:

=over

=item * file:PATH/TO/FILE

As a text file named by PATH/TO/FILE, which may be absolute or
relative to the hooks current directory, which is usually the
repository's root in the server. It's syntax is very simple. Blank
lines are skipped. The hash (#) character starts a comment that goes
to the end of the current line. Group definitions are lines like this:

    groupA = userA userB @groupB userC

Each group must be defined in a single line. Spaces are significant
only between users and group references.

Note that a group can reference other groups by name. To make a group
reference, simple prefix its name with an at sign (@). Group
references must reference groups previously defined in the file.

=item * GROUPS

If the option's value doesn't start with any of the above prefixes, it
must contain the group definitions itself.

=back

=head2 githooks.userenv STRING

When Git is performing its chores in the server to serve a push
request it's usually invoked via the SSH or a web service, which take
care of the authentication procedure. These services normally make the
authenticated user name available in an environment variable. You may
tell this hook which environment variable it is by setting this option
to the variable's name. If not set, the hook will try to get the
user's name from the C<USER> environment variable and let it undefined
if it can't figure it out.

If the user name is not directly available in an environment variable
you may set this option to a code snippet by prefixing it with
C<eval:>. The code will be evaluated and its value will be used as the
user name. For example, L<RhodeCode's|http://rhodecode.org/> up to
version 1.3.6 used to pass the authenticated user name in the
C<RHODECODE_USER> environment variable. From version 1.4.0 on it
stopped using this variable and started to use another variable with
more information in it. Like this:

    RHODECODE_EXTRAS='{"username": "rcadmin", "scm": "git", "repository": "git_intro/hooktest", "make_lock": null, "ip": "172.16.2.251", "locked_by": [null, null], "action": "push"}'

To grok the user name from this variable, one may set this option like
this:

    git config check-acls.userenv \
      'eval:(exists $ENV{RHODECODE_EXTRAS} && $ENV{RHODECODE_EXTRAS} =~ /"username":\s*"([^"]+)"/) ? $1 : undef'

This variable is useful for any hook that need to authenticate the
user performing the git action.

=head2 githooks.admin USERSPEC

There are several hooks that perform access control checks before
allowing a git action, such as the ones installed by the C<CheckAcls>
and the C<CheckJira> plugins. It's useful to allow some people (the
"administrators") to bypass those checks. These hooks usually allow
the users specified by this variable to do whatever they want to the
repository. You may want to set it to a group of "super users" in your
team so that they can "fix" things more easily.

The value of each option is interpreted in one of these ways:

=over

=item * username

A C<username> specifying a single user. The username specification
must match "/^\w+$/i" and will be compared to the authenticated user's
name case sensitively.

=item * @groupname

A C<groupname> specifying a single group.

=item * ^regex

A C<regex> which will be matched against the authenticated user's name
case-insensitively. The caret is part of the regex, meaning that it's
anchored at the start of the username.

=back

=head1 MAIN FUNCTION

=head2 run_hook(NAME, ARGS...)

This is the main routine responsible to invoke the right hooks
depending on the context in which it was called.

Its first argument must be the name of the hook that was
called. Usually you just pass C<$0> to it, since it knows to extract
the basename of the parameter.

The remaining arguments depend on the hook for which it's being
called. Usually you just pass C<@ARGV> to it. And that's it. Mostly.

        run_hook($0, @ARGV);

=head1 HOOK DIRECTIVES

Hook directives are routines you use to register routines as hooks.
Each one of the hook directives gets a routine-ref or a single block
(anonymous routine) as argument. The routine/block will be called by
C<run_hook> with proper arguments, as indicated below. These arguments
are the ones gotten from @ARGV, with the exception of the ones
identified by GIT. These are C<Git::More> objects which can be used to
grok detailed information about the repository and the current
transaction. (Please, refer to the L<Git::More> documentation to know
how to use them.)

Note that the hook directives resemble function definitions but they
aren't. They are function calls, and as such must end with a
semi-colon.

Most of the hooks are used to check some condition. If the condition
holds, they must simply end without returning anything. Otherwise,
they must C<die> with a suitable error message. On some hooks, this
will prevent Git from finishing its operation.

Also note that each hook directive can be called more than once if you
need to implement more than one specific hook.

=over

=item * APPLYPATCH_MSG(GIT, commit-msg-file)

=item * PRE_APPLYPATCH(GIT)

=item * POST_APPLYPATCH(GIT)

=item * PRE_COMMIT(GIT)

=item * PREPARE_COMMIT_MSG(GIT, commit-msg-file [, msg-src [, SHA1]])

=item * COMMIT_MSG(GIT, commit-msg-file)

=item * POST_COMMIT(GIT)

=item * PRE_REBASE(GIT, upstream [, branch])

=item * POST_CHECKOUT(GIT, prev-head-ref, new-head-ref, is-branch-checkout)

=item * POST_MERGE(GIT, is-squash-merge)

=item * PRE_RECEIVE(GIT)

=item * UPDATE(GIT, updated-ref-name, old-object-name, new-object-name)

=item * POST_RECEIVE(GIT)

=item * POST_UPDATE(GIT, updated-ref-name, ...)

=item * PRE_AUTO_GC(GIT)

=item * POST_REWRITE(GIT, command)

=back

=head1 METHODS FOR PLUGIN DEVELOPERS

Plugins should start by importing the utility routines from
Git::Hooks:

    use Git::Hooks qw/:utils/;

Usually at the end, the plugin should use one or more of the hook
directives defined above to install its hook routines in the
appropriate hooks.

Every hook routine receives a Git::More object as its first
argument. You should use it to infer all needed information from the
Git repository.

Please, take a look at the code for the standard plugins under the
Git::Hooks:: namespace in order to get a better understanding about
this. Hopefully it's not that hard.

The utility routines implemented by Git::Hooks are the following:

=head2 is_ref_enabled(REF, SPEC, ...)

This routine returns a boolean indicating if REF matches one of the
ref-specs in SPECS. REF is the complete name of a Git ref and SPECS is
a list of strings, each one specifying a rule for matching ref names.

As a special case, it returns true if REF is undef or if there is no
SPEC whatsoever, meaning that by default all refs/commits are enabled.

You may want to use it, for example, in an C<update>, C<pre-receive>,
or C<post-receive> hook which may be enabled depending on the
particular refs being affected.

Each SPEC rule may indicate the matching refs as the complete ref
name (e.g. "refs/heads/master") or by a regular expression starting
with a caret (C<^>), which is kept as part of the regexp.

=head2 im_memberof(GIT, USER, GROUPNAME)

This routine tells if USER belongs to GROUPNAME. The groupname is
looked for in the specification given by the C<githooks.groups>
configuration variable.

=head2 match_user(GIT, SPEC)

This routine checks if the authenticated user (as returned by the
C<Git::More::authenticated_user> method) matches the specification,
which may be given in one of the three different forms acceptable for
the C<githooks.admin> configuration variable above, i.e., as a
username, as a @group, or as a ^regex.

=head2 im_admin(GIT)

This routine checks if the authenticated user (again, as returned by
the C<Git::More::authenticated_user> method) matches the
specifications given by the C<githooks.admin> configuration variable.

=head2 eval_gitconfig(VALUE)

This routine makes it easier to grok config values as Perl code. If
C<VALUE> is a string beginning with C<eval:>, the remaining of it is
evaluated as a Perl expression and the resulting value is returned. If
C<VALUE> is a string beginning with C<file:>, the remaining of it is
treated as a file name which contents are evaluated as Perl code and
the resulting value is returned. Otherwise, C<VALUE> itself is
returned.

=head1 SEE ALSO

C<Git::More>.
