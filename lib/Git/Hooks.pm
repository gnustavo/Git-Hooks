use strict;
use warnings;

package Git::Hooks;
# ABSTRACT: A framework for implementing Git hooks.

use File::Basename;
use File::Spec::Functions;
use Git;

use Exporter qw/import/;

my @hooks = qw/ applypatch_msg pre_applypatch post_applypatch
		pre_commit prepare_commit_msg commit_msg
		post_commit pre_rebase post_checkout post_merge
		pre_receive update post_receive post_update
		pre_auto_gc post_rewrite /;

our @EXPORT = (run_hook => @hooks);

our @Conf_Files;
our $Repo;
our %Hooks;

for my $hook (@hooks) {
    *Git::Hooks::$hook = sub (&) {
	my ($foo) = @_;
	$Hooks{$hook}{$foo} ||= sub { $foo->($Repo, @_); };
    };
}

sub run_hook {
    my ($hook_name, @args) = @_;

    $hook_name = basename $hook_name;

    $Repo = Git->repository();

    # Reload all configuration files
    unshift @Conf_Files, catfile('hooks', 'git-hooks.conf');
    foreach my $conf (@Conf_Files) {
	my $conffile = file_name_is_absolute($conf) ? $conf : catfile($Repo->repo_path(), $conf);
	next unless -e $conffile; # Configuration files are optional
	package main;
	unless (my $return = do $conffile) {
	    die "couldn't parse '$conffile': $@\n" if $@;
	    die "couldn't do '$conffile': $!\n"    unless defined $return;
	    die "couldn't run '$conffile'\n"       unless $return;
	}
    }

    foreach my $hook (values %{$Hooks{$hook_name}}) {
	if (ref $hook eq 'CODE') {
	    $hook->($Repo, @args);
	} elsif (ref $hook eq 'ARRAY') {
	    foreach my $h (@$hook) {
		$h->($Repo, @args);
	    }
	} else {
	    die "Git::Hooks: internal error!\n";
	}
    }

    return;
}

1; # End of SVN::Hooks
__END__

=for Pod::Coverage run_hook POST_COMMIT POST_LOCK POST_REVPROP_CHANGE POST_UNLOCK PRE_COMMIT PRE_LOCK PRE_REVPROP_CHANGE PRE_UNLOCK START_COMMIT

=head1 SYNOPSIS

A single script can implement several hooks:

	#!/usr/bin/env perl

	use Git::Hooks;

	PRE_COMMIT {
	    my ($repo) = @_;
	    # ...
	};

	COMMIT_MSG {
	    my ($repo, $msg_file) = @_;
	    # ...
	};

	run_hook($0, @ARGV);

Or you can use already implemented hooks via plugins:

	#!/usr/bin/env perl

	use Git::Hooks;
	use Git::Hooks::DenyFilenames;
	use Git::Hooks::DenyChanges;
	use Git::Hooks::CheckProperty;
	...

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
because they are, well, scripts and not binaries. And second, because
as each script is called in turn they have no memory of the scripts
called before and have to gather the information about the transaction
again and again, normally by calling the C<git> command, which spawns
yet another process.

=back

Git::Hooks is a framework for implementing Git hooks that tries to
solve these problems.

Instead of having separate scripts implementing different
functionality you may have a single script implementing all the
funcionality you need either directly or using some of the existing
plugins, which are implemented by Perl modules in the Git::Hooks::
namespace. This single script can be used to implement all standard
hooks, because each hook knows when to perform based on the context in
which the script was called.

=head1 USAGE

Go to the C<.git/hooks> directory under the directory where the
repository was created. You should see there the hook samples. Create
a script there using the Git::Hooks module.

	$ cd /path/to/repo/.git/hooks

	$ cat >git-hooks.pl <<END_OF_SCRIPT
	#!/usr/bin/env perl

	use Git::Hooks;

	run_hook($0, @ARGV);

	END_OF_SCRIPT

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

As is the script won't do anything. You have to implement some hooks or
use some of the existing ones implemented as plugins. Either way, the
script should end with a call to C<run_hooks> passing to it the name
with which it wass called (C<$0>) and all the arguments it received
(C<@ARGV>).

=head2 Implementing Hooks

Implement hooks using one of the hook I<directives> below. Each one of
them gets a single block (anonymous function) as argument. The block
will be called by C<run_hook> with proper arguments, as indicated
below. These arguments are the ones gotten from @ARGV, with the
exception of the ones identified by C<SVN::Look>. These are SVN::Look
objects which can be used to grok detailed information about the
repository and the current transaction. (Please, refer to the
L<SVN::Look> documentation to know how to use it.)

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

FIXME...

This is an example of a script implementing two hooks:

	#!/usr/bin/env perl

	use Git::Hooks;

	# ...

	START_COMMIT {
	    my ($repos_path, $username, $capabilities) = @_;

	    exists $committers{$username}
		or die "User '$username' is not allowed to commit.\n";

	    $capabilities =~ /mergeinfo/
		or die "Your Subversion client does not support mergeinfo capability.\n";
	};

	PRE_COMMIT {
	    my ($svnlook) = @_;

	    foreach my $added ($svnlook->added()) {
		$added !~ /\.(exe|o|jar|zip)$/
		    or die "Please, don't commit binary files such as '$added'.\n";
	    }
	};

	run_hook($0, @ARGV);

Note that the hook directives resemble function definitions but
they're not. They are function calls, and as such must end with a
semi-colon.

Most of the C<start-commit> and C<pre-*> hooks are used to check some
condition. If the condition holds, they must simply end without
returning anything. Otherwise, they must C<die> with a suitable error
message.

Also note that each hook directive can be called more than once if you
need to implement more than one specific hook.

=head2 Using Plugins

There are several hooks already implemented as plugin modules under
the namespace C<SVN::Hooks::>, which you can use. The main ones are
described succinctly below. Please, see their own documentation for
more details.

=over

=item SVN::Hooks::AllowPropChange

Allow only specified users make changes in revision properties.

=item SVN::Hooks::CheckCapability

Check if the Subversion client implements the required capabilities.

=item SVN::Hooks::CheckJira

Integrate Subversion with the JIRA
L<http://www.atlassian.com/software/jira/> ticketing system.

=item SVN::Hooks::CheckLog

Check if the log message in a commit conforms to a Regexp.

=item SVN::Hooks::CheckMimeTypes

Check if the files added to the repository have the C<svn:mime-type>
property set. Moreover, for text files, check if the properties
C<svn:eol-style> and C<svn:keywords> are also set.

=item SVN::Hooks::CheckProperty

Check for specific properties for specific kinds of files.

=item SVN::Hooks::CheckStructure

Check if the files and directories being added to the repository
conform to a specific structure.

=item SVN::Hooks::DenyChanges

Deny the addition, modification, or deletion of specific files and
directories in the repository. Usually used to deny modifications in
the C<tags> directory.

=item SVN::Hooks::DenyFilenames

Deny the addition of files which file names doesn't comply with a
Regexp. Usually used to disallow some characteres in the filenames.

=item SVN::Hooks::Notify

Sends notification emails after successful commits.

=item SVN::Hooks::UpdateConfFile

Allows you to maintain Subversion configuration files versioned in the
same repository where they are used. Usually used to maintain the
configuration file for the hooks and the repository access control
file.

=back

This is an example of a script using some plugins:

	#!/usr/bin/perl

	use SVN::Hooks;
	use SVN::Hooks::CheckProperty;
	use SVN::Hooks::DenyChanges;
	use SVN::Hooks::DenyFilenames;

	# Accept only letters, digits, underlines, periods, and hifens
	DENY_FILENAMES(qr/[^-\/\.\w]/i);

	# Disallow modifications in the tags directory
	DENY_UPDATE(qr:^tags:);

	# OpenOffice.org documents need locks
	CHECK_PROPERTY(qr/\.(?:od[bcfgimpst]|ot[ghpst])$/i => 'svn:needs-lock');

	run_hook($0, @ARGV);

Those directives are implemented and exported by the hooks. Note that
using hooks you don't need to be explicit about which one of the nine
hooks will be triggered by the directives. This is on purpose, because
some plugins can trigger more than one hook. The plugin documentation
should tell you which hooks can be triggered so that you know which
symbolic links you need to create in the F<hooks> repository
directory.

=head2 Configuration file

Before calling the hooks, the function C<run_hook> evaluates a file
called F<svn-hooks.conf> under the F<conf> directory in the
repository, if it exists. Hence, you can choose to put all the
directives in this file and not in the script under the F<hooks>
directory.

The advantage of this is that you can then manage the configuration
file with the C<SVN::Hooks::UpdateConfFile> and have it versioned
under the same repository that it controls.

One way to do this is to use this hook script:

	#!/usr/bin/perl

	use SVN::Hooks;
	use SVN::Hooks::UpdateConfFile;
	use ...

	UPDATE_CONF_FILE(
	    'conf/svn-hooks.conf' => 'svn-hooks.conf',
	    validator             => [qw(/usr/bin/perl -c)],
	    rotate                => 2,
	);

	run_hook($0, @ARGV);

Use this hook script and create a directory called F<conf> at the root
of the repository (besides the common F<trunk>, F<branches>, and
F<tags> directories). Add the F<svn-hooks.conf> file under the F<conf>
directory. Then, whenever you commit a new version of the file, the
pre-commit hook will validate it sintactically (C</usr/bin/perl -c>)
and copy its new version to the F<conf/svn-hooks.conf> file in the
repository. (Read the L<SVN::Hooks::UpdateConfFile> documentation to
understand it in details.)

Being a Perl script, it's possible to get fancy with the configuration
file, using variables, functions, and whatever. But for most purposes
it consists just in a series of configuration directives.

Don't forget to end it with the C<1;> statement, though, because it's
evaluated with a C<do> statement and needs to end with a true
expression.

Please, see the plugins documentation to know about the directives.

=head1 PLUGIN DEVELOPER TUTORIAL

Yet to do.

=head1 EXPORT

=head2 run_hook

This is responsible to invoke the right plugins depending on the
context in which it was called.

Its first argument must be the name of the hook that was
called. Usually you just pass C<$0> to it, since it knows to extract
the basename of the parameter.

Its second argument must be the path to the directory where the
repository was created.

The remaining arguments depend on the hook for which it's being
called, like this:

=over

=item * start-commit repo-path user capabilities

=item * pre-commit repo-path txn

=item * post-commit repo-path rev

=item * pre-lock repo-path path user

=item * post-lock repo-path user

=item * pre-unlock repo-path path user

=item * post-unlock repo-path user

=item * pre-revprop-change repo-path rev user propname action

=item * post-revprop-change repo-path rev user propname action

=back

But as these are exactly the arguments Subversion passes when it calls
the hooks, you usually call C<run_hook> like this:

	run_hook($0, @ARGV);
