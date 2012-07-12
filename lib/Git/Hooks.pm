use 5.010;
use strict;
use warnings;

package Git::Hooks;
# ABSTRACT: A framework for implementing Git hooks.

use Exporter qw/import/;
use Data::Util qw(:all);
use File::Basename;
use File::Spec::Functions;
use Git::More;

our $Git;
our %Hooks;
our (@EXPORT, @EXPORT_OK, %EXPORT_TAGS);

BEGIN {
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
    @EXPORT_OK   = qw/hook_config is_ref_enabled/;
    %EXPORT_TAGS = (utils => \@EXPORT_OK);
}

sub hook_config {
    my ($plugin) = @_;
    return $Git->get_config()->{$plugin};
}

sub is_ref_enabled {
    my ($specs, $ref) = @_;
    foreach (@$specs) {
	if (/^\^/) {
	    return 1 if $ref =~ qr/$_/;
	} else {
	    return 1 if $ref eq $_;
	}
    }
    return 0;
}

# This is an internal routine used to grok the affected refs of update
# and pre-receive hooks. They're kept in a common data structure so
# that those hooks can usually share code.

my %affected_refs;
sub grok_affected_refs {
    my ($hook_name) = @_;
    if ($hook_name eq 'update') {
	my ($ref, $old_commit, $new_commit) = @ARGV;
	$affected_refs{$ref}{range} = [$old_commit, $new_commit];
    } elsif ($hook_name eq 'pre-receive') {
	# pre-receive gets the list of affected commits via STDIN.
	while (<>) {
	    chomp;
	    my ($old_commit, $new_commit, $ref) = split;
	    $affected_refs{$ref}{range} = [$old_commit, $new_commit];
	}
    }
}

sub get_affected_refs {
    return keys %affected_refs;
}

sub get_affected_ref_range {
    my ($ref) = @_;

    exists $affected_refs{$ref}
	or die __PACKAGE__, ": internal error: no such affected ref ($ref)";
    return @{$affected_refs{$ref}{range}};
}

sub get_affected_ref_commit_ids {
    my ($ref) = @_;

    unless (exists $affected_refs{$ref}{ids}) {
	my $range = get_affected_ref_range($ref);
	$affected_refs{$ref}{ids} = [$Git->command('rev-list' => join('..', @$range))];
    }

    return $affected_refs{$ref}{ids};
}

sub get_affected_ref_commits {
    my ($ref) = @_;

    unless (exists $affected_refs{$ref}{commits}) {
	$affected_refs{$ref}{commits} = $Git->get_commits(get_affected_ref_range($ref));
    }

    return $affected_refs{$ref}{commits};
}

# This is an internal routine used to invoke external hooks, feed them
# the needed input and wait for them.

sub spawn_external_file {
    my ($file, $hook, @args) = @_;

    my $exit;
    if ($hook ne 'pre-receive') {
	$exit = system {$file} ($hook, @args);
    } else {
	my $pid = open my $pipe, '|-';
	if (! defined $pid) {
	    die __PACKAGE__, ": can't fork: $!\n";
	} elsif ($pid) {
	    # parent
	    foreach my $ref (get_affected_refs()) {
		my ($old, $new) = get_affected_ref_range($ref);
		say $pipe "$old $new $ref";
	    }
	    $exit = close $pipe;
	} else {
	    # child
	    exec {$file} ($hook, @args);
	    die __PACKAGE__, ": can't exec: $!\n";
	}
    }
    unless ($exit == 0) {
	die __PACKAGE__, ": failed to execute '$file': $!\n"
	    if $? == -1;
	die sprintf(__PACKAGE__, ": '$file' died with signal %d, %s coredump\n",
		    ($? & 127), ($? & 128) ? 'with' : 'without')
	    if $? & 127;
	die sprintf(__PACKAGE__, ": '$file' exited abnormally with value %d\n", $? >> 8);
    }
}

sub run_hook {
    my ($hook_name, @args) = @_;

    $hook_name = basename $hook_name;

    $Git = Git::More->repository();

    my $config = hook_config('githooks');

    # Some hooks (pre-receive and update) affect refs and associated
    # commit ranges. Let's grok them at once.
    grok_affected_refs($hook_name);

    # Invoke enabled plugins
    if (my $enabled_hooks = $config->{$hook_name}) {
	# Define the list of directories where we'll look for the hook
	# plugins. First the local directory 'githooks' under the
	# repository path, then the optional list of directories
	# specified by the githooks.plugins config option, and,
	# finally, the Git::Hooks standard hooks directory.
	unshift @{$config->{plugins}}, 'githooks';
	push    @{$config->{plugins}}, catfile(dirname($INC{'Git/Hooks.pm'}), 'Hooks');
	my @plugin_dirs = grep {-d} @{$config->{plugins}};

	foreach my $hook (@$enabled_hooks) {
	    my $found = 0;
	    foreach my $dir (@plugin_dirs) {
		my $script = catfile($dir, $hook);
		next unless -f $script;

		my $exit = do $script;
		unless ($exit) {
		    die __PACKAGE__, ": couldn't parse $script: $@\n" if $@;
		    die __PACKAGE__, ": couldn't do $script: $!\n"    unless defined $exit;
		    die __PACKAGE__, ": couldn't run $script\n"       unless $exit;
		}
		$found = 1;
	    }
	    die __PACKAGE__, ": can't find hook enabled hook $hook.\n" unless $found;
	}

	# Call every hook function installed by the hook scripts before.
	foreach my $hook (values %{$Hooks{$hook_name}}) {
	    $hook->($Git, @args);
	}
    }

    # Invoked enabled external hooks
    unless (exists $config->{externals} && ! $config->{externals}[-1]) {
	# By default, start looking for external hooks in the
	# '.git/hooks.d' directory.
	unshift @{$config->{hooks}}, catfile($Git->repo_path(), 'hooks.d');

	foreach my $dir (grep {-e} map {catfile($_, $hook_name)} @{$config->{hooks}}) {
	    opendir my $dh, $dir or die __PACKAGE__, ": cannot opendir $dir: $!\n";
	    foreach my $file (grep {-f && -x} map {catfile($dir, $_)} readdir $dh) {
		spawn_external_file($file, $hook_name, @args);
	    }
	}
    }
}


1; # End of Git::Hooks
__END__

=for Pod::Coverage grok_affected_refs spawn_external_file

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
internals. (L<https://github.com/gitster/git#readme>)"

In order to really understand what this is all about you need to
understand Git L<http://git-scm.org/> and its hooks. You can read
everything about this in the documentation references on that site
L<http://git-scm.com/documentation>.

A hook is a specifically named program that is called by the git
program during the execution of some operations. At the last count,
there were exactly 16 different hooks which can be used
(L<http://schacon.github.com/git/githooks.html>). They must reside
under the C<.git/hooks> directory in the repository. When you create a
new repository, you get some template files in this directory, all of
them having the C<.sample> suffix and helpful instructions inside
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

In order to integrate the funcionality of more than one script you
have to write a driver script that's called by Git and calls all the
other scripts in order, passing to them the arguments they
need. Moreover, some of those scripts may have configuration files to
read and you may have to maintain several of them.

=item B<Inefficiency>

This arrangement is inefficient in two ways. First because each script
runs as a separate process, which usually have a high startup cost
because they are, well, scripts and not binaries. (For a dissent view
on this, see
L<http://gnustavo.wordpress.com/2012/06/28/programming-languages-start-up-times/>.)
And second, because as each script is called in turn they have no
memory of the scripts called before and have to gather the information
about the transaction again and again, normally by calling the C<git>
command, which spawns yet another process.

=back

Git::Hooks is a framework for implementing Git and driving existing
external hooks in a way that tries to solve these problems.

Instead of having separate scripts implementing different
functionality you may have a single script implementing all the
funcionality you need either directly or using some of the existing
plugins, which are implemented by Perl scripts in the Git::Hooks::
namespace. This single script can be used to implement all standard
hooks, because each hook knows when to perform based on the context in
which the script was called.

If you already have some handy hooks and want to keep using them,
don't worry. Git::Hooks can drive external hooks very easily.

=head1 USAGE

Go to the C<.git/hooks> directory under the root of your Git
repository. You should see there a bunch of hook samples. Create a
script there using the Git::Hooks module.

	$ cd /path/to/repo/.git/hooks

	$ cat >git-hooks.pl <<EOT
	#!/usr/bin/env perl
	use Git::Hooks;
	run_hook($0, @ARGV);
	EOT

	$ chmod +x git-hooks.pl

This script will serve for any hook. Create symbolic links pointing to
it for each hook you are interested in. (You may create symbolic links
for all 16 hooks, but this will make Git call the script for all
hooked operations, even for those that you may not be interested
in. Nothing wrong will happen, but the server will be doing extra work
for nothing.)

	$ ln -s git-hooks.pl pre-receive
	$ ln -s git-hooks.pl commit-msg
	$ ln -s git-hooks.pl post-commit

As is, the script won't do anything. You have to implement some hooks
in it, use some of the existing plugins, or set up some external
plugins to be invoked properly. Either way, the script should end with
a call to C<run_hooks> passing to it the name with which it was called
(C<$0>) and all the arguments it received (C<@ARGV>).

=head2 Implementing Hooks

Implement hooks using one of the hook I<directives> described in the
MAIN METHODS section. For example:

    # Check if every added/updated file is smaller than a fixed limit.

    my $LIMIT = 10 * 1024 * 1024; # 10MB

    PRE_COMMIT {
        my ($git) = @_;

        my @changed = $git->command(qw/diff --cached --name-only --diff-filter=AM/);

        foreach ($git->command('ls-files' => '-s', @changed)) {
            chomp;
            my ($mode, $sha, $n, $name) = split / /;
            my $size = $git->command('cat-file' => '-s', $sha);
            $size <= $LIMIT
                or die "File '$name' has $size bytes, more than our limit of $LIMIT.\n";
        }
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
            die "Perl::Critic Violations:\n", Data::Dumper::Dumper(\%violations), "\n";
        }
    };

=head2 Using Plugins

There are several hooks already implemented as plugin modules under
the namespace C<Git::Hooks::>, which you can use. The main ones are
described succinctly below. Please, see their own documentation for
more details.

=over

=item Git::Hooks::check-acls.pl

Allow you to specify Access Control Lists to tell who can commit or
push to the repository and affect which Git refs.

=item Git::Hooks::check-jira.pl

Integrate Git with the JIRA L<http://www.atlassian.com/software/jira/>
ticketing system by requiring that every commit message cites valid
JIRA issues.

=back

Each plugin may be used in one or, sometimes, multiple hooks. Their
documentation is explicit about this.

=head2 Invoking external hooks

Since the default Git hook scripts are taken by the Git::Hooks driver
script, you must install your external hooks somewhere else. By
default, the external plugin will look for external hook scripts in
the directory C<.git/hooks.d> (which you must create) under the
repository. Below this directory you should have another level of
directories, named after the default hook names, under which you can
drop your external hooks.

For example, let's say you want to use some of the hooks in the
standard Git package
(L<https://github.com/gitster/git/blob/b12905140a8239ac687450ad43f18b5f0bcfb62e/contrib/hooks/update-paranoid>). You
should copy each of those scripts to a file under the appropriate hook
directory, like this:

=over

=item C<.git/hooks.d/pre-auto-gc/pre-auto-gc-battery>

=item C<.git/hooks.d/pre-commit/setgitperms.perl>

=item C<.git/hooks.d/post-receive/post-receive-email>

=item C<.git/hooks.d/update/update-paranoid>

=back

Note that you may install more than one script under the same
hook-named directory. The driver will execute all of them in a
non-specified order. If any of them exits abnormally, the driver will
exit with an appropriate error message.

=head1 CONFIGURATION

Git::Hooks is configured via Git's own configuration
infrastructure. The framework defines a few options which are
described below. Each plugin may define other specific options which
are described in their own documentation.

You should get comfortable with C<git config> command (read C<git help
config>) to know how to configure Git::Hooks.

When you invoke C<run_hook>, the command C<git config --list> is
invoked to grok all configuration affecting the current
repository. Note that this will fetch all C<--system>, C<--global>,
and C<--local> options, in this order. You may use this mechanism to
define configuration global to a user or local to a repository.

=head2 githooks.applypatch-msg     PLUGIN

=head2 githooks.pre-applypatch     PLUGIN

=head2 githooks.post-applypatch    PLUGIN

=head2 githooks.pre-commit         PLUGIN

=head2 githooks.prepare-commit-msg PLUGIN

=head2 githooks.commit-msg  	   PLUGIN

=head2 githooks.post-commit 	   PLUGIN

=head2 githooks.pre-rebase  	   PLUGIN

=head2 githooks.post-checkout      PLUGIN

=head2 githooks.post-merge         PLUGIN

=head2 githooks.pre-receive        PLUGIN

=head2 githooks.update             PLUGIN

=head2 githooks.post-receive       PLUGIN

=head2 githooks.post-update        PLUGIN

=head2 githooks.pre-auto-gc        PLUGIN

=head2 githooks.post-rewrite       PLUGIN

To enable a plugin you must register it with one of the above
options. For instance, if you want to enable the C<check-jira.pl>
plugin in the C<update> hook, you must do this:

    $ git config --add githooks.update check-jira.pl

Note that you may enable more than one plugin to the same hook. For
instance:

    $ git config --add githooks.update check-acls.pl

And you may enable the same plugin in more than one hook, if it makes
sense to do so. For instance:

    $ git config --add githooks.commit-msg check-jira.pl

=head2 githooks.plugins DIR

The plugins enabled for a hook are searched for in three places. First
they're are searched for in the C<githooks> directory under the
repository path (usually in C<.git/githooks>), so that you may have
repository specific hooks (or repository specific versions of a hook).

Then, they are searched for in every directory specified with the
C<githooks.plugins> option.  You may set it more than once if you
have more than one directory holding your hooks.

Finally, they are searched for in Git::Hooks installation.

The first match is taken as the desired plugin, which is executed and
the search stops. So, you may want to copy one of the standard plugins
and change it to suit your needs better. (Don't shy away from sending
your changes back to us, though.)

=head2 githooks.externals [01]

By default the driver script will look for external hooks after
executing every enabled plugins. You may disable external hooks
invokation by setting this option to 0.

=head2 githooks.hooks DIR

You can tell this plugin to look for external hooks in other
directories by specifying them with this option. The directories
specified here will be looked for after the default directory
C<.git/hooks.d>, so that you can use this option to have some global
external hooks shared by all of your repositories.

Please, see the plugins documentation to know about their own
configuration options.

=head1 MAIN METHOD

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

=head2 APPLYPATCH_MSG(GIT, commit-msg-file)

=head2 PRE_APPLYPATCH(GIT)

=head2 POST_APPLYPATCH(GIT)

=head2 PRE_COMMIT(GIT)

=head2 PREPARE_COMMIT_MSG(GIT, commit-msg-file [, msg-src [, SHA1]])

=head2 COMMIT_MSG(GIT, commit-msg-file)

=head2 POST_COMMIT(GIT)

=head2 PRE_REBASE(GIT)

=head2 POST_CHECKOUT(GIT, prev-head-ref, new-head-ref, is-branch-checkout)

=head2 POST_MERGE(GIT, is-squash-merge)

=head2 PRE_RECEIVE(GIT)

=head2 UPDATE(GIT, updated-ref-name, old-object-name, new-object-name)

=head2 POST_RECEIVE(GIT)

=head2 POST_UPDATE(GIT, updated-ref-name, ...)

=head2 PRE_AUTO_GC(GIT)

=head2 POST_REWRITE(GIT, command)

=head1 METHODS FOR PLUGIN DEVELOPERS

Plugins should start by importing the utility routines from
Git::Hooks:

    use Git::Hooks qw/:utils/;

Usually at the end, the plugin should use one or more of the hook
directives defined above to install its hook routines in the
apropriate hooks.

Every hook routine receives a Git::More object as its first
argument. You should use it to infer all needed information from the
Git repository.

Please, take a look at the code for the standard plugins under the
Git::Hooks:: namespace in order to get a better understanding about
this. Hopefully it's not that hard.

The utility routines implemented by Git::Hooks are the following:

=head2 hook_config(NAME)

This routine returns a hash-ref containing every configuration
variable for the section NAME. It's usually called with the name of
the plugin as argument, meaning that the plugin configuration is
contained in a section by its name.

=head2 is_ref_enabled(SPECS, REF)

This routine returns a boolean indicating if REF matches one of the
ref-specs in SPECS. REF is the complete name of a Git ref and SPECS is
a reference to an array of strings, each one specifying a rule for
matching ref names.

You may want to use it, for example, in an C<update> or in a
C<pre-receive> hook which may be enabled depending on the particular
refs being affected.

Each rule in SPECS may indicate the matching refs as the complete ref
name (e.g. "refs/heads/master") or by a regular expression starting
with a caret (C<^>), which is kept as part of the regexp.

=head2 get_affected_refs()

This routine returns a list of all the Git refs affected by the
current operation. During the C<update> hook it returns the single ref
passed via the command line. During the C<pre-receive> hook it returns
the list of refs passed via STDIN. During any other hook it returns
the empty list.

=head2 get_affected_ref_range(REF)

This routine returns the two-element list of commit ids representing
the OLDCOMMIT and the NEWCOMMIT of the affected REF.

=head2 get_affected_ref_commit_ids(REF)

This routine returns the list of commit ids leading from the affected
REF's NEWCOMMIT to OLDCOMMIT.

=head2 get_affected_ref_commits(REF)

This routine returns the list of commits leading from the affected
REF's NEWCOMMIT to OLDCOMMIT. The commits are represented by hashes,
as returned by C<Git::More::get_commits>.

=head1 SEE ALSO

C<Git::More>.
