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
our @EXPORT;

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
	    'Git::Hooks',
	    $installer => sub (&) {
		my ($foo) = @_;
		$Hooks{$hook}{$foo} ||= sub { $foo->(@_); };
	    }
	);
    }

    @EXPORT = (@installers, 'hook_config', 'is_hook_enabled_for_ref', 'run_hook');
}

sub hook_config {
    my ($plugin) = @_;
    return $Git->get_config()->{$plugin};
}

sub is_hook_enabled_for_ref {
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

sub run_hook {
    my ($hook_name, @args) = @_;

    $hook_name = basename $hook_name;

    $Git = Git::More->repository();

    # If there's no githooks options we are disabled.
    my $config = hook_config('githooks') or return;

    # Grok the enabled hooks. Return if there is none.
    my $enabled_hooks = $config->{$hook_name} or return;

    # Some hooks affect lists of commits. Let's grok them at once.
    if ($hook_name eq 'update') {
	my ($ref, $old_commit, $new_commit) = @ARGV;
	$Git->set_ref_range($ref, $old_commit, $new_commit);
    } elsif ($hook_name eq 'pre-receive') {
	# pre-receive gets the list of affected commits via STDIN.
	while (<>) {
	    chomp;
	    my ($old_commit, $new_commit, $ref) = split;
	    $Git->set_ref_range($ref, $old_commit, $new_commit);
	}
    }

    # Grok the directories where we'll look for the hook scripts.

    my @hooksdir;
    # First the local directory 'hooks.d' under the repository path
    push @hooksdir, 'hooks.d';
    # Then, the optional list of directories specified by the hooksdir
    # config option
    push @hooksdir, @{$config->{hooksdir}} if exists $config->{hooksdir};
    # And finally, the Git::Hooks standard hooks directory
    push @hooksdir, catfile(dirname($INC{'Git/Hooks.pm'}), 'Hooks');

    # Execute every enabled script found in the @hooksdir directories
    foreach my $hook (@$enabled_hooks) {
	my $found = 0;
	foreach my $dir (grep {-d} @hooksdir) {
	    my $script = catfile($dir, $hook);
	    next unless -f $script;

	    my $exit = do $script;
	    unless ($exit) {
		die "Git::Hooks: couldn't parse $script: $@\n" if $@;
		die "Git::Hooks: couldn't do $script: $!\n"    unless defined $exit;
		die "Git::Hooks: couldn't run $script\n"       unless $exit;
	    }
	    $found = 1;
	}
	die "Git::Hooks: can't find hook enabled hook $hook.\n" unless $found;
    }

    # Call every hook function installed by the hook scripts before.
    foreach my $hook (values %{$Hooks{$hook_name}}) {
	$hook->($Git, @args);
    }

    return;
}


1; # End of Git::Hooks
__END__

=for Pod::Coverage applypatch_msg pre_applypatch post_applypatch pre_commit prepare_commit_msg commit_msg post_commit pre_rebase post_checkout post_merge pre_receive update post_receive post_update pre_auto_gc post_rewrite

=head1 SYNOPSIS

A single script can implement several hooks:

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

Or you can use already implemented hooks which are installed in the
Git/Hooks directory, in the Git/Hooks.pm installation. These hooks are
enabled by Git configuration options. (More on this later.) If you're
only using Git::Hooks standard hooks, all you need is the following
script:

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

Git::Hooks is a framework for implementing Git hooks that tries to
solve these problems.

Instead of having separate scripts implementing different
functionality you may have a single script implementing all the
funcionality you need either directly or using some of the existing
plugins, which are implemented by Perl scripts in the Git::Hooks::
namespace. This single script can be used to implement all standard
hooks, because each hook knows when to perform based on the context in
which the script was called.

=head1 USAGE

Go to the C<.git/hooks> directory under the directory where the
repository was created. You should see there the hook samples. Create
a script there using the Git::Hooks module.

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

	$ ln -s git-hooks.pl start-commit
	$ ln -s git-hooks.pl prepare-commit-msg
	$ ln -s git-hooks.pl commit-msg
	$ ln -s git-hooks.pl post-commit

As is, the script won't do anything. You have to implement some hooks
or use some of the existing ones implemented as plugins. Either way,
the script should end with a call to C<run_hooks> passing to it the
name with which it was called (C<$0>) and all the arguments it
received (C<@ARGV>).

=head2 Implementing Hooks

Implement hooks using one of the hook I<directives> below. Each one of
them gets a single block (anonymous function) as argument. The block
will be called by C<run_hook> with proper arguments, as indicated
below. These arguments are the ones gotten from @ARGV, with the
exception of the ones identified by C<Git>. These are Git::More
objects which can be used to grok detailed information about the
repository and the current transaction. (Please, refer to the
L<Git::More> documentation to know how to use it.)

=over

=item * APPLYPATCH_MSG(Git, commit-msg-file)

=item * PRE_APPLYPATCH(Git)

=item * POST_APPLYPATCH(Git)

=item * PRE_COMMIT(Git)

=item * PREPARE_COMMIT_MSG(Git, commit-msg-file [, msg-src [, SHA1]])

=item * COMMIT_MSG(Git, commit-msg-file)

=item * POST_COMMIT(Git)

=item * PRE_REBASE(Git)

=item * POST_CHECKOUT(Git, prev-head-ref, new-head-ref, is-branch-checkout)

=item * POST_MERGE(Git, is-squash-merge)

=item * PRE_RECEIVE(Git)

=item * UPDATE(Git, updated-ref-name, old-object-name, new-object-name)

=item * POST_RECEIVE(Git)

=item * POST_UPDATE(Git, updated-ref-name, ...)

=item * PRE_AUTO_GC(Git)

=item * POST_REWRITE(Git, command)

=back

Note that the hook directives resemble function definitions but
they're not. They are function calls, and as such must end with a
semi-colon.

Most of the hooks are used to check some condition. If the condition
holds, they must simply end without returning anything. Otherwise,
they must C<die> with a suitable error message. This will prevent Git
from finishing its operation.

Also note that each hook directive can be called more than once if you
need to implement more than one specific hook.

=head2 Using Plugins

There are several hooks already implemented as plugin modules under
the namespace C<Git::Hooks::>, which you can use. The main ones are
described succinctly below. Please, see their own documentation for
more details.

=over

=item Git::Hooks::check-acls.pl

Allow you to specify who can commit or push to the repository and
affect which Git refs.

=item Git::Hooks::check-jira.pl

Integrate Git with the JIRA L<http://www.atlassian.com/software/jira/>
ticketing system.

=back

=head2 Configuration

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

=over

=item githooks.HOOK

To enable a plugin you must register it with the appropriate
C<githooks.HOOK> option. For instance, if you want to enable the
C<check-jira.pl> plugin in the C<update> hook, you must do this:

    $ git config githooks.update check-jira.pl

Note that you may enable more than one plugin to the same hook. For
instance:

    $ git config githooks.update check-acls.pl

And you may enable the same plugin in more than one hook, if it makes
sense to do so. For instance:

    $ git config githooks.commit-msg check-jira.pl

=item githooks.hooksdir

The plugins enabled for a hook are searched for in three places. First
they're are searched for in the C<hooks.d> directory under the
repository path (usually in C<.git/hooks.d>).

Then, they are searched for in every directory specified with the
C<githooks.hooksdir> option.  You may set it more than once if you
have more than one directory holding your hooks.

Finally, they are searched for in Git::Hooks installation.

The first match is taken as the desired plugin, which is executed and
the search stops.

=back

Please, see the plugins documentation to know about their own
configuration options.

=head1 PLUGIN DEVELOPER TUTORIAL

Yet to do.

=head1 EXPORT

=head2 config PLUGIN

This function is used by plugin developers, to try to uniformize the
way plugins grok their own configuration options. It simply invokes
C<Git::More::get_config>, to grok all configuration options for the
repository and returns the hash-ref containing the options for the
section called PLUGIN.

=head2 run_hook

This is responsible to invoke the right plugins depending on the
context in which it was called.

Its first argument must be the name of the hook that was
called. Usually you just pass C<$0> to it, since it knows to extract
the basename of the parameter.

The remaining arguments depend on the hook for which it's being
called. Usually you just pass C<@ARGV> to it. And that's it. Mostly.

	run_hook($0, @ARGV);
