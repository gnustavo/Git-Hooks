use warnings;

package Git::Hooks;
# ABSTRACT: Framework for implementing Git (and Gerrit) hooks

use 5.016;
use utf8;
use Carp;
use Exporter qw/import/;
use Path::Tiny;
use Log::Any '$log';
use Git::Repository qw/GitHooks Log/;

our @EXPORT; ## no critic (Modules::ProhibitAutomaticExportation)

my %Hooks;

BEGIN {                         ## no critic (RequireArgUnpacking)
    my @directives =
        qw/ APPLYPATCH_MSG PRE_APPLYPATCH POST_APPLYPATCH
            PRE_COMMIT PREPARE_COMMIT_MSG COMMIT_MSG
            POST_COMMIT PRE_REBASE POST_CHECKOUT POST_MERGE
            PRE_PUSH PRE_RECEIVE UPDATE POST_RECEIVE POST_UPDATE
            PUSH_TO_CHECKOUT PRE_AUTO_GC POST_REWRITE

            REF_UPDATE PATCHSET_CREATED DRAFT_PUBLISHED
            COMMIT_RECEIVED SUBMIT
          /;

    my @drivers =
        qw/ GITHOOKS_CHECK_AFFECTED_REFS
            GITHOOKS_CHECK_PRE_COMMIT
            GITHOOKS_CHECK_PATCHSET
            GITHOOKS_CHECK_MESSAGE_FILE
          /;

    for my $directive (@directives) {
        my $hook = $directive;
        $hook =~ tr/A-Z_/a-z-/;
        no strict 'refs';       ## no critic (ProhibitNoStrict)
        *{"Git::Hooks::$directive"} = sub (&) {
            push @{$Hooks{$hook}}, {
                package => scalar(caller),
                sub     => shift(@_),
            };
        }
    }

    @EXPORT = (@directives, @drivers, 'run_hook');
}

sub GITHOOKS_CHECK_AFFECTED_REFS (&;$) {
    my ($check_ref, $options) = @_;
    $options //= {};
    my $caller = caller;

    my $hook = {
        package => $caller,
        sub     => sub {
            my ($git) = @_;

            $log->debug("$caller(GITHOOKS_CHECK_AFFECTED_REFS)");

            $options->{config}($git) if exists $options->{config};

            return 1 if $git->im_admin();

            my $errors = 0;

            foreach my $ref ($git->get_affected_refs()) {
                next unless $git->is_reference_enabled($ref);
                $errors += $check_ref->($git, $ref);
            }

            $options->{destroy}($git) if exists $options->{destroy};

            return $errors == 0;
        },
    };

    foreach my $name (qw/commit-received pre-receive ref-update submit update/) {
        push @{$Hooks{$name}}, $hook;
    }

    return;
}

sub GITHOOKS_CHECK_PRE_COMMIT (&;$) {
    my ($check_commit, $options) = @_;
    $options //= {};
    my $caller = caller;

    my $hook = {
        package => $caller,
        sub     => sub {
            my ($git) = @_;

            $log->debug("$caller(GITHOOKS_CHECK_COMMIT)");

            return 1 if $git->im_admin();

            $options->{config}($git) if exists $options->{config};

            my $current_branch = $git->get_current_branch();

            return 1 unless $git->is_reference_enabled($current_branch);

            my $errors = $check_commit->($git, $current_branch);

            $options->{destroy}($git) if exists $options->{destroy};

            return $errors == 0;
        },
    };

    foreach my $name (qw/pre-applypatch pre-commit/) {
        push @{$Hooks{$name}}, $hook;
    }

    return;
}

sub GITHOOKS_CHECK_PATCHSET (&;$) {
    my ($check_patchset, $options) = @_;
    $options //= {};
    my $caller = caller;

    my $hook = {
        package => $caller,
        sub     => sub {
            my ($git, $opts) = @_;

            $log->debug("$caller(GITHOOKS_CHECK_PATCHSET)");

            return 1 if $git->im_admin();

            $options->{config}($git) if exists $options->{config};

            my $sha1   = $opts->{'--commit'};
            my $commit = $git->get_commit($sha1);

            # The --branch argument contains the branch short-name if it's in the
            # refs/heads/ namespace. But we need to always use the branch long-name,
            # so we change it here.
            my $branch = $opts->{'--branch'};
            $branch = "refs/heads/$branch"
                unless $branch =~ m:^refs/:;

            return 1 unless $git->is_reference_enabled($branch);

            my $errors = $check_patchset->($git, $branch, $commit);

            $options->{destroy}($git) if exists $options->{destroy};

            return $errors == 0;
        },
    };

    foreach my $name (qw/draft-published patchset-created/) {
        push @{$Hooks{$name}}, $hook;
    }

    return;
}

sub GITHOOKS_CHECK_MESSAGE_FILE (&;$) {
    my ($check_message_file, $options) = @_;
    $options //= {};
    my $caller = caller;
    (my $cfg = $caller) =~ s/.*::/githooks./;

    my $hook = {
        package => $caller,
        sub     => sub {
            my ($git, $commit_msg_file) = @_;

            $log->debug("$caller(GITHOOKS_CHECK_MESSAGE_FILE)");

            return 1 if $git->im_admin();

            $options->{config}($git) if exists $options->{config};

            my $current_branch = $git->get_current_branch();

            return 1 unless $git->is_reference_enabled($current_branch);

            my $msg = eval {$git->read_commit_msg_file($commit_msg_file)};

            unless (defined $msg) {
                $git->fault(<<"EOS", {details => $@});
I cannot read the commit message file '$commit_msg_file'.
EOS
                return 0;
            }

            my $errors = $check_message_file->($git, $msg, $current_branch);

            $options->{destroy}($git) if exists $options->{destroy};

            return $errors == 0;
        },
    };

    foreach my $name (qw/applypatch-msg commit-msg/) {
        push @{$Hooks{$name}}, $hook;
    }

    return;
}

# This is the main routine of Git::Hooks. It gets the original hook
# name and arguments, sets up the environment, loads plugins and
# invokes the appropriate hook functions.

sub run_hook {
    my ($hook_name, @args) = @_;

    my $hook_basename = path($hook_name)->basename;

    # Contextualize the logs with the PID on server hooks. However, note that
    # the Log::Any::context method was implemented on Log::Any version 1.050.
    $log->context->{pid} = $$
        if $hook_basename =~ /^(?:(pre|post)?-receive|(post-)?update|push-to-checkout)$/
        && $log->can('context');

    $log->info("run_hook($hook_basename)", {args => \@args});

    my $git = Git::Repository->new();

    local $ENV{GITHOOKS_AUTHENTICATED_USER} = $git->authenticated_user();

    $git->prepare_hook($hook_name, \@args);

    $git->load_plugins();

    # Call every hook function installed by the hook scripts before.
    for my $hook (@{$Hooks{$hook_basename}}) {
        my $ok = eval { $hook->{sub}->($git, @args) };
        if (defined $ok) {
            # Modern hooks return a boolean value indicating their success.
            # If they fail they invoke
            # Git::Repository::Plugin::GitHooks::fault.
            unless ($ok) {
                # Let's see if there is a help-on-error message configured
                # specifically for this plugin.
                my $CFG = $hook->{package} =~ s/.*::/githooks./r;
                if (my $help = $git->get_config(lc $CFG => 'help-on-error')) {
                    $git->fault($help, {prefix => $hook->{package}});
                }
            }
        } elsif (length $@) {
            # Old hooks die when they fail...
            $git->fault("Hook failed", {
                prefix  => __PACKAGE__ . "($hook_basename)",
                details => $@,
            });
        } else {
            # ...and return undef when they succeed.
        }
    }

    # Invoke enabled external hooks. This doesn't work in Windows yet.
    $git->invoke_external_hooks(@args);

    # Some hooks want to do some post-processing
    foreach my $post_hook ($git->post_hooks) {
        $post_hook->($hook_basename, $git, @args);
    }

    if (my $faults = $git->get_faults()) {
        $log->debug(Environment => {ENV => \%ENV});
        $faults .= "\n" unless $faults =~ /\n$/;
        if (($hook_basename eq 'commit-msg' or $hook_basename eq 'pre-commit')
                and not $git->get_config_boolean(githooks => 'abort-commit')) {
            $log->warning(Warning => {faults => $faults});
            carp $faults;
        } else {
            $log->error(Error => {faults => $faults});
            croak $faults;
        }
    }

    return;
}


1; # End of Git::Hooks
__END__

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

        use 5.016;
        use warnings;
        use Git::Hooks;

        run_hook($0, @ARGV);

In fact, this module installs a script called F<githooks.pl> exactly like that,
so that all you have to do is to create symbolic links in your Git repository's
F<.git/hook> pointing to it.

=head1 INTRODUCTION

=over

"Git is a fast, scalable, distributed revision control system with an
unusually rich command set that provides both high-level operations
and full access to
internals. (L<Git README|https://github.com/gitster/git#readme>)"

=back

If you already know about L<Git|http://git-scm.org/> and hooks and simply
want to get on with business go straight to our
L<wiki|https://github.com/gnustavo/Git-Hooks/wiki> and read the relevant
tutorials.

In order to really understand what this is all about you need to
understand L<Git|http://git-scm.org/> and its hooks. You can read
everything about this in the
L<documentation|http://git-scm.com/documentation> references on that
site.

A L<Git hook|http://schacon.github.com/git/githooks.html> is a
specifically named program that is called by the git program during
the execution of some operations. At the last count, there were
17 different hooks. They must be kept under
the C<.git/hooks> directory in the repository. When you create a new
repository, you get some template files in this directory, all of them
having the C<.sample> suffix and helpful instructions inside
explaining how to convert them into working hooks.

When Git is performing a commit operation, for example, it calls these four
hooks in order: C<pre-commit>, C<prepare-commit-msg>, C<commit-msg>, and
C<post-commit>. The first can gather all sorts of information about the
specific commit being performed and decide to reject it in case it doesn't
comply to specified policies. The next two can be used to format or check
the commit message.  The C<post-commit> can be used to log or alert
interested parties about the commit just performed.

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
L<this|http://blog.gnustavo.com/2013/07/programming-languages-startup-times.html>.)
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
name space. This single script can be used to implement all standard
hooks, because each hook knows when to perform based on the context in
which the script was called.

If you already have some handy hooks and want to keep using them,
don't worry. Git::Hooks can drive external hooks very easily.

=head1 USAGE

Please, read the L<Git::Hooks::Tutorial> if you want an easy guide to start
using the framework. Most probably you can set it up in a few minutes with
it. Continue on if you want to get deeper in the Documentation.

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

        $ cat >git-hooks.pl <<'EOT'
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
symbolic links for all hooks, but this will make Git call the
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

A hook should return a Boolean value indicating if it was
successful. B<run_hook> dies after invoking all hooks if at least one
of them returned false.

B<run_hook> invokes the hooks inside an eval block to catch any
exception, such as if a B<die> is used inside them. When an exception
is detected the hook is considered to have failed and the exception
string (B<$@>) is showed to the user.

The best way to produce an error message is to invoke the
B<Git::Repository::Plugin::GitHooks::error> method passing a prefix and a
message for uniform formatting. Note that any hook invokes this method it
counts as a failure, even if it ultimately returns true!

For example:

    # Check if every added/updated file is smaller than a fixed limit.

    my $LIMIT = 10 * 1024 * 1024; # 10MB

    PRE_COMMIT {
        my ($git) = @_;

        my @changed = $git->filter_files_in_index('AM');

        my $errors = 0;

        foreach ($git->run(qw/ls-files -s/, @changed)) {
            my ($mode, $sha, $n, $name) = split ' ';
            my $size = $git->file_size(":0:$name");
            if ($size > $LIMIT) {
                $git->fault("File '$name' has $size bytes, more than our limit of $LIMIT",
                            {prefix => 'CheckSize'});
                ++$errors;
            }
        }

        return $errors == 0;
    };

    # Check if every added/changed Perl file respects Perl::Critic's code
    # standards.

    PRE_COMMIT {
        my ($git) = @_;
        my %violations;

        my @changed = grep {/\.p[lm]$/} $git->filter_files_in_index('AM');

        foreach ($git->run(qw/ls-files -s/, @changed)) {
            my ($mode, $sha, $n, $name) = split ' ';
            require Perl::Critic;
            state $critic = Perl::Critic->new(-severity => 'stern', -top => 10);
            my $contents = $git->run('cat-file', $sha);
            my @violations = $critic->critique(\$contents);
            $violations{$name} = \@violations if @violations;
        }

        if (%violations) {
            # FIXME: this is a lame way to format the output.
            require Data::Dumper;
            $git->fault('Violations', {
                 prefix  => 'Perl::Critic',
                 details => Data::Dumper::Dumper(\%violations),
            });
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

=item * L<Git::Hooks::CheckDiff>

Check if the differences introduced by new commits comply with specified
policies.

=item * L<Git::Hooks::CheckFile>

Check if the names and contents of added, modified, or deleted files comply with
specified policies.

=item * L<Git::Hooks::CheckJira>

Integrate Git with the L<JIRA|http://www.atlassian.com/software/jira/>
ticketing system by requiring that every commit message cites valid
JIRA issues.

=item * L<Git::Hooks::CheckCommit>

Check various aspects of commits like author and committer names and emails,
and signatures.

=item * L<Git::Hooks::CheckLog>

Check commit log messages formatting.

=item * L<Git::Hooks::CheckRewrite>

Check if a B<git rebase> or a B<git commit --amend> is safe, meaning
that no rewritten commit is contained by any other branch besides the
current one. This is useful, for instance, to prevent rebasing commits
already pushed.

=item * L<Git::Hooks::CheckReference>

Restrict who can do what (create, rewrite, update, or delete) to which
references (branches and tags are just the most common Git references).

=item * L<Git::Hooks::GerritChangeId>

Inserts a C<Change-Id> line in the commit log message to allow
integration with Gerrit's code review system.

=item * L<Git::Hooks::Notify>

Sends email notifications to interested parties about pushed commits affecting
specific files in the repository.

=item * L<Git::Hooks::PrepareLog>

Prepare commit log messages before they are opened by the editor. It can be used
to pre-format or to insert automatic information in the message before the user
is given a chance to edit it.

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

=head2 Implementing Plugins

Plugins are simply Perl modules inside the Git::Hooks name space. Choose a
descriptive name for it so that it can be installed by means of the
C<githooks.plugin> configuration option. The only requirement of a plugin is
that it record one of more functions as hooks using the HOOK DIRECTIVES or the
HOOK DRIVERS described below.

As an example of a bare-bones plugin we could transform the pre-commit hook
checking for file sizes that we implemented above into a proper plugin
simply by putting it inside a package and using the Git::Hooks module to
import the PRE_COMMIT directive, like this:

    package Git::Hooks::CheckFileSize;
    # ABSTRACT: Git::Hooks plugin for checking file sizes

    use Git::Hooks;

    # Check if every added/updated file is smaller than a fixed limit.

    my $LIMIT = 10 * 1024 * 1024; # 10MB

    PRE_COMMIT {
        my ($git) = @_;

        my @changed = $git->filter_files_in_index('AM');

        my $errors = 0;

        foreach ($git->run(qw/ls-files -s/, @changed)) {
            my ($mode, $sha, $n, $name) = split ' ';
            my $size = $git->file_size(":0:$name");
            if ($size > $LIMIT) {
                $git->fault("File '$name' has $size bytes, more than our limit of $LIMIT",
                            {prefix => 'CheckSize'});
                ++$errors;
            }
        }

        return $errors == 0;
    };

After having it installed where Perl can find it you can enable it by
putting this into your global or local Git config file:

  [githooks]
	plugin = CheckFileSize

By using some of the L<Git::Repository::Plugin::GitHooks> methods we can
make this check work for other hooks as well:

    package Git::Hooks::CheckFileSize;
    # ABSTRACT: Git::Hooks plugin for checking file sizes

    use Git::Hooks;

    # Check if every added/updated file is smaller than a fixed limit.

    my $LIMIT = 10 * 1024 * 1024; # 10MB

    sub check_new_files {
        my ($git, $commit, @files) = @_;

        my $errors = 0;

        foreach ($git->run(qw/ls-files -s/, @files)) {
            my ($mode, $sha, $n, $name) = split ' ';
            my $size = $git->file_size(":0:$name");
            if ($size > $LIMIT) {
                $git->fault("File '$name' has $size bytes, more than our limit of $LIMIT",
                            {prefix => 'CheckSize', commit => $commit});
                ++$errors;
            }
        }

        return $errors == 0;
    }

    sub check_commit {
        my ($git) = @_;

        return check_new_files($git, ':0', $git->filter_files_in_index('AM'));
    }

    # This routine can act both as an update or a pre-receive hook.
    sub check_affected_refs {
        my ($git) = @_;

        return 1 if $git->im_admin();

        my $errors = 0;

        foreach my $ref ($git->get_affected_refs()) {
            my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
            check_new_files($git, $new_commit, $git->filter_files_in_range('AM', $old_commit, $new_commit))
                or ++$errors;
        }

        return $errors == 0;
    }

    # Install hooks
    PRE_COMMIT       \&check_commit;
    UPDATE           \&check_affected_refs;
    PRE_RECEIVE      \&check_affected_refs;

Now it can check file sizes on the Git server, when the user pushes commits
to it.

With a few changes we could make this plugin more general and consistent with
the standard plugins. We just need to use the Hook Drivers like this:

    package Git::Hooks::CheckFileSize;
    # ABSTRACT: Git::Hooks plugin for checking file sizes

    use Git::Hooks;

    # Check if every added/updated file is smaller than a fixed limit.

    my $LIMIT = 10 * 1024 * 1024; # 10MB

    sub check_new_files {
        my ($git, $commit, @files) = @_;

        my $errors = 0;

        foreach ($git->run(qw/ls-files -s/, @files)) {
            my ($mode, $sha, $n, $name) = split ' ';
            my $size = $git->file_size(":0:$name");
            if ($size > $LIMIT) {
                $git->fault("File '$name' has $size bytes, more than our limit of $LIMIT",
                            {prefix => 'CheckSize', commit => $commit});
                ++$errors;
            }
        }

        return $errors;
    }

    sub check_commit {
        my ($git) = @_;

        return check_new_files($git, ':0', $git->filter_files_in_index('AM'));
    }

    sub check_ref {
        my ($git, $ref) = @_;

        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

        return check_new_files(
            $git,
            $new_commit,
            $git->filter_files_in_range('AM', $old_commit, $new_commit),
        );
    }

    # Install hooks
    GITHOOKS_CHECK_PRE_COMMIT        \&check_commit;
    GITHOOKS_CHECK_AFFECTED_REFS \&check_ref;

Plugins usually can be configured in their own configuration section. For
instance, we could allow the user to configure the size limit by putting
this on her configuration file:

    [githooks "checkfilesize"]
	limit = 10485760

We just have to change the check_new_files function:

    sub check_new_files {
        my ($git, $commit, @files) = @_;

        my $limit = $git->get_config_integer('githooks.checkfilesize', 'limit');

        return 1 unless defined $limit;   # By default there is no limit

        my $errors = 0;

        foreach ($git->run(qw/ls-files -s/, @files)) {
            my ($mode, $sha, $n, $name) = split ' ';
            my $size = $git->file_size(":0:$name");
            if ($size > $limit) {
                $git->fault("File '$name' has $size bytes, more than our limit of $limit",
                            {prefix => 'CheckSize', commit => $commit});
                ++$errors;
            }
        }

        return $errors == 0;
    }

Please, look at the implementation of the native Git::Hooks plugins for more
examples.

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

=head2 Gerrit Hooks

L<Gerrit|https://www.gerritcodereview.com/> is a web based code review and
project management for Git based projects. It's based on
L<JGit|http://www.eclipse.org/jgit/>, which is a pure Java implementation of
Git.

Gerrit doesn't support Git standard hooks. However, it implements its own
L<special
hooks|https://gerrit.googlesource.com/plugins/hooks/+/refs/heads/master/src/main/resources/Documentation/hooks.md>.
B<Git::Hooks> currently supports only a few of Gerrit hooks:

=head3 Synchronous hooks

These hooks are invoked synchronously so it is recommended that they not block.

Their purpose is the same as Git's B<update> hook, i.e. to block commits from
being integrated, and Git::Hooks's plugins usually support them all together.

=over

=item * ref-update

This is called when a ref update request (direct push, non-fast-forward update,
or ref deletion) is received by Gerrit. It allows a request to be rejected
before it is committed to the Gerrit repository.  If the hook fails the update
will be rejected.

=item * commit-received

This is called when a commit is received for review by Gerrit. It allows a push
to be rejected before the review is created. If the hook fails the push will be
rejected.

=item * submit

This is called when a user attempts to submit a change. It allows the submit to
be rejected. If the hook fails the submit will be rejected.

=back

=head3 Asynchronous hooks

These hooks are invoked asynchronously on a background thread.

=over

=item * patchset-created

The B<patchset-created> hook is executed asynchronously when a user
performs a push to one of Gerrit's virtual branches (refs/for/*) in
order to record a new review request. This means that one cannot stop
the request from happening just by dying inside the hook. Instead,
what one needs to do is to use Gerrit's API to accept or reject the
new patchset as a reviewer.

Git::Hooks does this using a C<Gerrit::REST> object. There are a few
configuration options to set up this Gerrit interaction, which are
described below.

This hook's purpose is usually to verify the project's policy
compliance. Plugins that implement C<pre-commit>, C<commit-msg>,
C<update>, or C<pre-receive> hooks usually also implement this Gerrit
hook.

Since draft patchsets are visible only by their owners, the
B<patchset-created> hook is unusable because it uses a fixed user to
authenticate. So, Git::Hooks exit prematurely when invoked as the
B<patchset-created> hook for a draft change.

=item * draft-published

The B<draft-published> hook is executed when the user publishes a draft
change, making it visible to other users. Since the B<patchset-created> hook
doesn't work for draft changes, the B<draft-published> hook is a good time
to work on them. All plugins that work on the B<patchset-created> also work
on the B<draft-published> hook to cast a vote when drafts are published.

=back

=head2 Logging

L<Git::Hooks> logs using the L<Log::Any> framework. You may tell where it should
log using any available L<Log::Any::Adapter> module.

For example, to log everything to a file you just have to add a line to your
hook script, like this:

        #!/usr/bin/env perl
        use Log::Any::Adapter (File => '/var/log/githooks.log');
        use Git::Hooks;
        run_hook($0, @ARGV);

This will produce copious logs. If you are interested only in the informational
messages, select the C<log_level> C<info>, like so:

        use Log::Any::Adapter (File => '/var/log/githooks.log', log_level => 'info');

Read the L<Log::Any> documentation to know what other options you have.

Note that several log messages contain context data, which is a feature that was
implemented on version 1.050 of L<Log::Any>, released on 2017-08-04. If you're
using an older version the context data will appear as a ref-scalar and won't
make much sense.

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
identified by 'GIT' which are C<Git::Repository> objects that can be used to
grok detailed information about the repository and the current
transaction. (Please, refer to C<Git::Repository> specific documentation to
know how to use them.)

Note that the hook directives resemble function definitions but they
aren't. They are function calls, and as such must end with a
semicolon.

Some hooks are invoked before an action (e.g., C<pre-commit>) so that
one can check some condition. If the condition holds, they must simply
end without returning anything. Otherwise, they should invoke the
C<error> method on the GIT object passing a suitable error message. On
some hooks, this will prevent Git from finishing its operation.

Other hooks are invoked after the action (e.g., C<post-commit>) so
that its outcome cannot affect the action. Those are usually used to
send notifications or to signal the completion of the action someway.

You may learn about every Git hook by invoking the command C<git help
hooks>. Gerrit hooks are documented in the L<project
site|https://gerrit-review.googlesource.com/Documentation/config-hooks.html>.

Also note that each hook directive can be called more than once if you
need to implement more than one specific hook.

=head2 APPLYPATCH_MSG(GIT, commit-msg-file)

=head2 PRE_APPLYPATCH(GIT)

=head2 POST_APPLYPATCH(GIT)

=head2 PRE_COMMIT(GIT)

=head2 PREPARE_COMMIT_MSG(GIT, commit-msg-file [, msg-src [, SHA1]])

=head2 COMMIT_MSG(GIT, commit-msg-file)

=head2 POST_COMMIT(GIT)

=head2 PRE_REBASE(GIT, upstream [, branch])

=head2 POST_CHECKOUT(GIT, prev-head-ref, new-head-ref, is-branch-checkout)

=head2 POST_MERGE(GIT, is-squash-merge)

=head2 PRE_PUSH(GIT, remote-name, remote-url)

The C<pre-push> hook was introduced in Git 1.8.2. The default hook
gets two arguments: the name and the URL of the remote which is being
pushed to. It also gets a variable number of arguments via STDIN with
lines of the form:

    <local ref> SP <local sha1> SP <remote ref> SP <remote sha1> LF

The information from these lines is read and can be fetched by the
hooks using the C<Git::Hooks::get_input_data> method.

=head2 PRE_RECEIVE(GIT)

The C<pre-receive> hook gets a variable number of arguments via STDIN
with lines of the form:

    <old-value> SP <new-value> SP <ref-name> LF

The information from these lines is read and can be fetched by the hooks
using the C<Git::Hooks::get_input_data> method or, perhaps more easily, by
using the C<Git::Repository::Plugin::GitHooks::get_affected_refs> and the
C<Git::Repository::Plugin::GitHooks::get_affected_ref_range> methods.

=head2 UPDATE(GIT, updated-ref-name, old-object-name, new-object-name)

=head2 POST_RECEIVE(GIT)

=head2 POST_UPDATE(GIT, updated-ref-name, ...)

=head2 PUSH_TO_CHECKOUT(GIT, SHA1)

The C<push-to-checkout> hook was introduced in Git 2.4.

=head2 PRE_AUTO_GC(GIT)

=head2 POST_REWRITE(GIT, command)

The C<post-rewrite> hook gets a variable number of arguments via STDIN
with lines of the form:

    <old sha1> SP <new sha1> SP <extra info> LF

The C<extra info> and the preceding SP are optional.

The information from these lines is read and can be fetched by the
hooks using the C<Git::Hooks::get_input_data> method.

=head2 REF_UPDATE(GIT, OPTS)

=head2 COMMIT_RECEIVED(GIT, OPTS)

=head2 SUBMIT(GIT, OPTS)

=head2 PATCHSET_CREATED(GIT, OPTS)

=head2 DRAFT_PUBLISHED(GIT, OPTS)

These are Gerrit-specific hooks. Gerrit invokes them passing a list of
option/value pairs which are converted into a hash, which is passed by
reference as the OPTS argument. In addition to the option/value pairs,
a C<Gerrit::REST> object is created and inserted in the OPTS hash with
the key 'gerrit'. This object can be used to interact with the Gerrit
server.  For more information, please, read the L</Gerrit Hooks>
section.

=head1 HOOK DRIVERS

As shown in the example above in the L</Implementing Plugins> section, the
methods in L<Git::Repository::Plugin::GitHooks> make it easy to implement checks
that can be associated with several hooks at once. For example, the standard
plugins L<Git::Hooks::CheckCommit>,
L<Git::Hooks::CheckDiff>, L<Git::Hooks::CheckFile>, L<Git::Hooks::CheckJira>,
L<Git::Hooks::CheckLog>, L<Git::Hooks::CheckReference>, and
L<Git::Hooks::CheckWhitespace> all implement their checks for the following
hooks: F<commit-received>, F<pre-receive>, F<ref-update>, F<submit>, and
F<update>. In order to make it easier for similar plugins to associate
themselves to the same hooks, and to make their behaviour more consistent,
Git::Hooks implements some HOOK DRIVERS, which are kind of "meta-directives"
used to register routines as several related hooks at once.

Each driver gets a routine-ref or a single block (anonymous routine) as a
required first argument. Optionally, they can get a hash-ref as its second
argument.

The first argument must be a routine to check the changes being performed by a
Git command. Each driver associates this check routine with a set of hooks,
invoking them passing a Git::Repository object and a few other arguments. The
routines passed to the drivers must all return zero if all checks pass or a
positive number if any check fails.

The second argument may contain one or more of the following extra options:

=over 4

=item * B<config>

This must map to another routine-ref which will be invoked once before the
routine passed as the first argument is invoked in order to setup the plugin
configuration options. It will be passed the Git::Repository as the sole
argument.

=item * B<destroy>

This must map to another routine-ref which will be invoked once after the
routine passed as the first argument is invoked in order to tear down any
resources acquired by the plugin. It will be passed the Git::Repository as the
sole argument.

=back

All drivers check the C<githooks.admin> configuration option and do not do
anything if the user performing the action is an admin.

=head2 GITHOOKS_CHECK_AFFECTED_REFS(SUB, [, OPTIONS])

This driver associates the routine SUB to the following hooks:
F<commit-received>, F<pre-receive>, F<ref-update>, F<submit>, and F<update>.

They will invoke SUB once for each affected reference, as long as it is enabled
as specified by the C<githooks.ref> and the C<githooks.noref> options.

The SUB routine will receive two arguments: a Git::Repository object and the
reference name.

=head2 GITHOOKS_CHECK_PRE_COMMIT(SUB [, OPTIONS])

This driver associates the routine SUB to the following hooks: F<pre-applypatch>
and F<pre-commit>.

They will invoke SUB once for the current branch, as long as it is enabled as
specified by the C<githooks.ref> and the C<githooks.noref> options.

The SUB routine will receive two arguments: a Git::Repository object and the
current branch name.

=head2 GITHOOKS_CHECK_PATCHSET(SUB [, OPTIONS])

This driver associates the routine SUB to the following hooks:
F<draft-published> and F<patchset-created>.

They will invoke SUB once for the current branch, as long as it is enabled as
specified by the C<githooks.ref> and the C<githooks.noref> options.

The SUB routine will receive two arguments: a Git::Repository object and a hash
containing the options the hook obtained from Gerrit.

=head2 GITHOOKS_CHECK_MESSAGE_FILE(SUB [, OPTIONS])

This driver associates the routine SUB to the following hooks: F<applypatch-msg>
and F<commit-msg>.

They will invoke SUB once for the current branch, as long as it is enabled as
specified by the C<githooks.ref> and the C<githooks.noref> options.

The SUB routine will receive three arguments: a Git::Repository object, the
commit message, and the current branch name.

=head1 CONFIGURATION

Git::Hooks is configured via Git's own configuration
infrastructure. There are a few global options which are described
below. Each plugin may define other specific options which are
described in their own documentation. The options specific to a plugin
usually are contained in a configuration subsection of section
C<githooks>, named after the plugin base name. For example, the
C<Git::Hooks::CheckFile> plugin has its options contained in the
configuration subsection C<githooks.checkfile>. Note that the subsection
name must be all in lowercase.

You should get comfortable with C<git config> command and the config file syntax
(read C<git help config>) to know how to configure Git::Hooks.

When you invoke C<run_hook>, the command C<git config --list> is
invoked to grok all configuration affecting the current
repository. Note that this will fetch all C<--system>, C<--global>,
and C<--local> options, in this order. You may use this mechanism to
define configuration global to a user or local to a repository.

Gerrit keeps its repositories in a hierarchy and its specific configuration
mechanism takes advantage of that to allow a configuration definition in a
parent repository to trickle down to its children repositories. Git::Hooks
uses Git's native configuration mechanisms and doesn't support Gerrit's
mechanism, which is based on configuration files kept in a detached
C<refs/meta/config> branch. But you can implement a hierarchy of
configuration files by using Git's inclusion mechanism. Please, read the
"Includes" section of C<git help config> to know how.

The sections below describe the options of the C<githooks> configuration
section.

=head2 plugin PLUGIN...

To enable one or more plugins you must add them to this configuration
option, like this:

    [githooks]
      plugin CheckFile CheckJira

You can add another list to the same variable to enable more plugins,
like this:

    [githooks]
      plugin CheckFile CheckJira
      plugin CheckLog

This is useful, for example, to enable some plugins globally and
others locally, per repository.

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

In the L<Git::Hooks> installation.

=back

The first match is taken as the desired plugin, which is executed (via
C<do>) and the search stops. So, you may want to copy one of the
standard plugins and change it to suit your needs better. (Don't shy
away from sending your changes back to the author, please.)

However, if you use the fully qualified module name of the plugin in
the configuration, then it will be simply C<required> as a normal
module. For example:

    [githooks]
      plugin = My::Hook::CheckSomething

=head2 disable PLUGIN...

This option disables plugins enabled by the C<githooks.plugin>
option. It's useful if you want to enable a plugin globally and only
disable it for some repositories. For example:

    # In ~/.gitconfig:
    [githooks]
      plugin = CheckJira

    # In .git/config:
    [githooks]
      disable = CheckJira

You may also temporarily disable a plugin by assigning to "0" an
environment variable with its name. This is useful sometimes, when you
are denied some perfectly fine commit by one of the check plugins. For
example, suppose you got an error from the CheckLog plugin because you
used an uncommon word that is not in the system's dictionary yet. If
you don't intend to use the word again you can bypass all CheckLog
checks this way:

    $ CheckLog=0 git commit

This works for every hook. For plugins specified by fully qualified
module names, the environment variable name has to match the last part
of it. For example, to disable the C<My::Hook::CheckSomething> plugin
you must define an environment variable called C<CheckSomething>.

Note, however, that this works for local hooks only. Remote hooks
(like B<update> or B<pre-receive>) are run on the server. You can set
up the server so that it defines the appropriate variable, but this
isn't so useful as for the local hooks, as it's intended for
once-in-a-while events.

=head2 plugins DIR

This option specify a list of directories where plugins are looked for
besides the default locations, as explained in the C<githooks.plugin>
option above.

=head2 externals BOOL

By default the driver script will look for external hooks after
executing every enabled plugins. You may disable external hooks
invocation by setting this option to 0.

=head2 hooks DIR

You can tell this plugin to look for external hooks in other
directories by specifying them with this option. The directories
specified here will be looked for after the default directory
C<.git/hooks.d>, so that you can use this option to have some global
external hooks shared by all of your repositories.

Please, see the plugins documentation to know about their own
configuration options.

=head2 groups GROUPSPEC

You can define user groups in order to make it easier to configure access
control plugins. A group is specified by a GROUPSPEC, which is a multi-line
string containing a sequence of group definitions, one per line. Each line
defines a group like this, where spaces are significant only between users
and group references:

    [githooks]
      groups = \
        groupA = userX \
        groupB = userA userB @groupA userC

Note that a group can reference other groups by name. To make a group
reference, simply prefix its name with an at sign (@). Group references must
reference groups previously defined.

A GROUPSPEC may be in the format C<file:PATH/TO/FILE>, which means that the
external text file C<PATH/TO/FILE> contains the group definitions. The path
may be absolute or relative to the hooks current directory, which is usually
the repository's root in the server. It's syntax is very simple. Blank lines
are skipped. The hash (#) character starts a comment that goes to the end of
the current line. The remaining lines must define groups in the same format
exemplified above.

The may be multiple definitions of this variable, each one defining
different groups. You can't redefine a group.

=head2 userenv STRING

When Git is performing its chores in the server to serve a push
request it's usually invoked via the SSH or a web service, which take
care of the authentication procedure. These services normally make the
authenticated user name available in an environment variable. You may
tell this hook which environment variable it is by setting this option
to the variable's name. If not set, the hook will try to get the
user's name from the C<GERRIT_USER_EMAIL> or the C<USER> environment
variable, in this order, and let it undefined if it can't figure it
out.

If the user name is not directly available in an environment variable
you may set this option to a code snippet by prefixing it with
C<eval:>. The code will be evaluated and its value will be used as the
user name.

For example, if the Gerrit user email is not what you want to use as
the user id, you can set the C<githooks.userenv> configuration option
to grok the user id from one of these environment variables. If the
user id is always identical to the part of the email before the at
sign, you can configure it like this:

    git config githooks.userenv \
      'eval:(exists $ENV{GERRIT_USER_EMAIL} && $ENV{GERRIT_USER_EMAIL} =~ /([^@]+)/) ? $1 : undef'

Git::Hooks defines the environment variable C<GITHOOKS_AUTHENTICATED_USER> to
the authenticated user, making it available for hooks and plugins.

The Gerrit hooks unfortunately do not have access to the user's
id. But they get the user's full name and email instead. Git:Hooks
takes care so that two environment variables are defined in the hooks,
as follows:

=over

=item * GERRIT_USER_NAME

This contains the user's full name, such as "User Name".

=item * GERRIT_USER_EMAIL

This contains the user's email, such as "user@example.net".

=back

This variable is useful for any hook that need to authenticate the
user performing the git action.

=head2 admin USERSPEC

There are several hooks that perform access control checks before
allowing a git action, such as the ones installed by the C<CheckFile>
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

=head2 ref REFSPEC

=head2 noref REFSPEC

These multi-valued options are meant to selectively enable/disable hook
processing for commits in particular references (usually branches). Hook
developers should use the C<is_reference_enabled> method
L<Git::Repository::Plugin> method to check it.

Local hooks should pass the current branch to the method and server hooks should
pass the names of the references affected by the push command.

The REFSPECs can be specified as complete ref names (e.g. "refs/heads/master")
or by regular expressions starting with a caret (C<^>), which is kept as part of
the regexp (e.g. "^refs/heads/(master|fix)").

=head2 abort-commit BOOL

This option is true by default, meaning that the C<pre-commit> and
the C<commit-msg> hooks will abort the commit if they detect anything
wrong in it. This may not be the best way to handle errors, because
you must remember to retrieve your carefully worded commit message
from the C<.git/COMMIT_EDITMSG> to try it again, and it is easy to
forget about it and lose it.

Setting this to false makes these hooks simply warn the user via
STDERR but let the commit succeed. This way, the user can correct any
mistake with a simple C<git commit --amend> and doesn't run the risk
of losing the commit message.

=head2 gerrit.url URL

=head2 gerrit.username USERNAME

=head2 gerrit.password PASSWORD

These three options are required if you enable Gerrit hooks. They are
used to construct the C<Gerrit::REST> object that is used to interact
with Gerrit.

=head2 gerrit.votes-to-approve VOTES

This option defines which votes should be cast in which
L<labels|https://gerrit-review.googlesource.com/Documentation/config-labels.html>
to B<approve> a review in the Gerrit change when all verification hooks
pass.

VOTES is a comma-separated list of LABEL and VOTE mappings, such as:

  Code-Review+2,Verification+1

Which means that the C<Code-Review> label should receive a +2 and the label
C<Verification> should receive a +1.

If not specified, the default VOTES is:

  Code-Review+1

=head2 gerrit.votes-to-reject VOTES

This option defines which votes should be cast in which
L<labels|https://gerrit-review.googlesource.com/Documentation/config-labels.html>
to B<reject> a review in the Gerrit change when some verification hooks
fail.

VOTES has the same syntax as described for the
C<githooks.gerrit.votes-to-approve> option above.

If not specified, the default VOTES is:

  Code-Review-1

=head2 gerrit.comment-ok COMMENT

By default, when approving a review Git::Hooks simply casts a positive vote
but does not add any comment to the change. If you set this option, it adds
a comment like this in addition to casting the vote:

  [Git::Hooks] COMMENT

You may want to use a simple comment like 'OK'.

=head2 gerrit.auto-submit BOOL

If this option is enabled, Git::Hooks will try to automatically submit a
change if all verification hooks pass.

Note that for the submission to succeed you must vote with
C<githooks.gerrit.votes-to-approve> so that the change has the necessary
votes to be submitted. Moreover, the C<username> and C<password> you
configured above must have the necessary rights to submit the change in
Gerrit.

This may be useful to provide a gentle introduction to Gerrit for people who
don't want to start doing code reviews but want to use Gerrit simply as a
Git server.

=head2 gerrit.notify WHO

Notify handling that defines to whom email notifications should be sent
after the review is stored.

Allowed values are NONE, OWNER, OWNER_REVIEWERS, and ALL.

If not set, the default is ALL.

=head2 error-prefix STRING

This option specifies a fixed string that will be inserted as a prefix to all
the lines in the error messages produced by the
L<Git::Repository::Plugin::GitHooks::fault> method.

It's useful, for instance, to produce error messages for
<Gitlab|https://docs.gitlab.com/ee/administration/server_hooks.html#custom-error-messages>
as in:

  [githooks]
    error-prefix = "GL-HOOK-ERR: "

=head2 error-header CMD

This option specifies a command that should produce a multi-line string
which will be used as a header prefixing the error messages, if there are
any. The command is invoked using Perl's C<qx{CMD}> operator, with no error
detection. Since the string will most probably appear at the user's terminal
their lines should have no more than 70 characters or so.

The following commands may give you an idea as to which commands to use:

=over

=item * L<fortune|https://en.wikipedia.org/wiki/Fortune_(Unix)>

=item * L<FIGlet|http://www.figlet.org/>

=item * L<cowsay|https://en.wikipedia.org/wiki/Cowsay>

=item * C<fortune -s | cowsay>

=item * C<GET 'http://api.icndb.com/jokes/random?limitTo=nerdy' | jq -r '.value.joke' | cowsay>

=back

=head2 error-footer CMD

This option is similar to the C<githooks.error-header> above, but produces a
footer to the error messages generated by Git::Hooks, if any.

=head2 help-on-error MESSAGE

This option allows you to specify a helpful message that will be shown if
any hook fails. This may be useful, for instance, to provide information to
users about how to get help from your site's Git gurus.

=head2 <PLUGIN>.help-on-error MESSAGE

You can also provide helpful messages specific to each enabled PLUGIN in its own
subsection.

=head2 color [never|auto|always]

This option tells if Git::Hooks's output should be colorized. It accepts the
same values as Git's own C<color.ui> option. If it's not set, the C<color.ui>
value is used by default. The meaning of each value is the following:

=over 4

=item B<never (or false)>

Do not use colors.

=item B<auto (or true)>

Use colors only if the messages go to a terminal. (This is the default value of
C<color.ui> since Git 1.8.4.)

=item B<always>

Do use colors.

=back

=head2 color.<slot> COLOR

Use customized colors for the Git::Hooks output colorization. B<< <slot> >>
specifies which part of the output to use the specified color, as shown below.

The COLOR value must comply with Git's color config type, which is explained in
the L<git(1)> manpage, under the C<CONFIGURATION FILE/Values/color> section.

The available I<slots> are the following:

=over 4

=item B<header>

The text output for the C<githooks.error-header> option. (Default value is "green".)

=item B<footer>

The text output for the C<githooks.error-footer> option. (Default value is "green".)

=item B<context>

The line containing the prefix and the context of error messages. (Default value is "red bold".)

=item B<message>

The error message proper. (Default value is "yellow".)

=item B<details>

The indented lines providing details for error messages. (Default value is empty.)

=back

=head1 GIT AND PERL VERSION COMPATIBILITY POLICY

Currently L<Git::Hooks> require Perl 5.16 and Git 1.8.3.

We try to be compatible with the Git and Perl native packages of the oldest
L<Ubuntu LTS|https://www.ubuntu.com/info/release-end-of-life> and
L<CentOS|https://wiki.centos.org/About/Product> Linux distributions still
getting maintenance updates.

  +-------------+-----------------------+------+--------+
  | End of Life | Distro                | Perl |   Git  |
  +-------------+-----------------------+------+--------+
  |   2021-04   | Ubuntu 16.04 (xenial) | 5.22 |  2.7.4 |
  |   2023-04   | Ubuntu 18.04 (bionic) | 5.26 | 2.15.1 |
  |   2024-07   | CentOS 7              | 5.16 |  1.8.3 |
  |   2025-04   | Ubuntu 20.04 (focal ) | 5.30 | 2.25.1 |
  |   2029-05   | CentOS 8              | 5.26 | 2.18.4 |
  +-------------+-----------------------+------+--------+

As you can see, we're kept behind mostly by the slow pace of CentOS (actually,
RHEL) releases.

There are a few features of Git::Hooks which require newer Gits. If they're used
with older Gits an appropriate error message tells the user to upgrade Git or to
disable the feature.

=head1 SEE ALSO

=over

=item * L<Git::Hooks::Tutorial>

Tutorials for Git users and administrators.

=item * L<Git::Repository>

Perl interface to Git repositories.

=item * L<Gerrit::REST>

A thin wrapper around Gerrit's REST API.

=back

=head1 REPOSITORY

L<https://github.com/gnustavo/Git-Hooks>

=cut
