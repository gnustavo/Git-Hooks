package Git::Repository::Plugin::GitHooks;
# ABSTRACT: A Git::Repository plugin with some goodies for hook developers

use strict;
use warnings;

use Git::Repository::Plugin;
our @ISA = qw/Git::Repository::Plugin/;

sub _keywords {

    return qw/

                 prepare_hook load_plugins invoke_external_hooks
                 cache post_hook post_hooks

                 get_config

                 undef_commit empty_commit get_commit get_commits
                 get_commit_msg read_commit_msg_file write_commit_msg_file
                 get_sha1

                 get_affected_refs get_affected_ref_range
                 get_affected_ref_commits

                 set_authenticated_user authenticated_user

                 get_current_branch

                 error get_errors

                 match_user im_admin grok_groups_spec grok_groups im_memberof

                 push_input_data get_input_data

                 filter_files_in_index filter_files_in_range filter_files_in_commit

                 blob file_size

                 get_head_or_empty_tree is_ref_enabled

                 redirect_output restore_output

                 file_temp

             /;
}

use Carp;
use Path::Tiny;

# This package variable tells get_config which character encoding is used in
# the output of the git-config command. Usually none, and decoding isn't
# necessary. But sometimes it is...
our $CONFIG_ENCODING = undef;

sub undef_commit {
    return '0000000000000000000000000000000000000000';
}

sub empty_commit {
    return '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
}

sub get_config {
    my ($git, $section, $var) = @_;

    unless (exists $git->{_plugin_githooks}{config}) {
        my %config;

        exists $ENV{HOME}
            or die __PACKAGE__, <<'EOT';
The HOME environment variable is undefined.

We need it to read Git's global configuration from $HOME/.gitconfig.

If you really don't want to read the global configuration, define HOME as an
empty string in your hook script like this before invoking run_hook():

  $ENV{HOME} = '';

Note that if you're using Gerrit as a Git server it runs with HOME undefined
by default when started by a boot script. In this case you should define
HOME in your hook script to point to the directory holding your .gitconfig
file. For example:

  $ENV{HOME} = '/home/gerrit';

EOT

        my $config = do {
           local $/ = "\c@";
           $git->run(qw/config --null --list/);
        };

        if (defined $CONFIG_ENCODING) {
            require Encode;
            $config = Encode::decode($CONFIG_ENCODING, $config);
        }

        if (defined $config) {
            while ($config =~ /([^\cJ]+)\cJ([^\c@]*)\c@/sg) {
                my ($option, $value) = ($1, $2);
                if ($option =~ /(.+)\.(.+)/) {
                    push @{$config{lc $1}{lc $2}}, $value;
                } else {
                    die __PACKAGE__, ": Cannot grok config variable name '$option'.\n";
                }
            }
        }

        # Set default values for undefined ones.
        $config{githooks}{externals}       //= [1];
        $config{githooks}{gerrit}{enabled} //= [1];
        $config{githooks}{'abort-commit'}  //= [1];

        $git->{_plugin_githooks}{config} = \%config;
    }

    my $config = $git->{_plugin_githooks}{config};

    $section = lc $section if defined $section;

    if (! defined $section) {
        return $config;
    } elsif (! defined $var) {
        $config->{$section} = {} unless exists $config->{$section};
        return $config->{$section};
    } elsif (exists $config->{$section}{$var}) {
        return wantarray ? @{$config->{$section}{$var}} : $config->{$section}{$var}[-1];
    } else {
        return;
    }
}

sub cache {
    my ($git, $section) = @_;

    unless (exists $git->{_plugin_githooks}{cache}{$section}) {
        $git->{_plugin_githooks}{cache}{$section} = {};
    }

    return $git->{_plugin_githooks}{cache}{$section};
}

sub get_commit {
    my ($git, $commit) = @_;

    my $cache = $git->cache('commits');

    unless (exists $cache->{$commit}) {
        local $/ = "\c@\cJ";

        my $cmd = $git->command(
            'rev-list',
            '--no-walk',
            # See 'git help rev-list' to understand the --pretty argument
            '--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%s%n%n%b%x00',
            '--encoding=UTF-8',
            $commit,
        );

        my $stdout = $cmd->stdout;

        while (<$stdout>) {
            chomp;
            my %commit;
            @commit{qw/header commit tree parent
                       author_name author_email author_date
                       committer_name committer_email committer_date
                       body/} = split "\cJ", $_, 11;
            $cache->{$commit} = \%commit;
        }

        $cmd->close;
    }

    return $cache->{$commit};
}

sub get_commits {
    my ($git, $old_commit, $new_commit) = @_;

    my $cache = $git->cache('ranges');

    my $range = "$old_commit:$new_commit";

    unless (exists $cache->{$range}) {
        # We're interested in all commits reachable from $new_commit but
        # neither reachable from $old_commit nor from any other existing
        # reference.

        # We're going to use the "git rev-list" command for that. As you can
        # read on its documentation, the syntax to specify this set of
        # commits is this: "--not --all $new_commit ^$old_commit".

        # However, there are some special cases...

        # When an old branch is deleted $new_commit is null (i.e.,
        # '0'x40). In this case previous commits are being forgotten and the
        # hooks usually don't need to check them. So, in this situation we
        # simply return an empty list of commits.

        return if $new_commit eq $git->undef_commit;

        # When we're called in a post-receive or post-update hook, the
        # pushed references already point to $new_commit. So, in these cases
        # the "--not --all" options to git-rev-list would exclude from the
        # results all commits reachable from $new_commit, which is exactly
        # what we don't want... In order to avoid that we can't use these
        # options directly with git-rev-list. Instead, we use the
        # git-rev-parse command to get a list of all commits directly
        # reachable by existing references. Then we'll see if we have to
        # remove any commit from that list.

        my @excludes = $git->run(qw/rev-parse --not --all/);

        if ($git->{_plugin_githooks}{hookname} =~ /^post-(?:receive|update)$/) {
            # We can't simply remove $new_commit from @excludes because it
            # can be reachable by other references. This can happen, for
            # instance, when one creates a new branch and pushes it before
            # making any commits to it. So, we only remove it if it's
            # reachable by a single reference, which must be the reference
            # being pushed.

            my @new_commit_refs = $git->run(
                qw/for-each-ref --format %(refname) --count 2 --points-at/, $new_commit,
            );
            if (@new_commit_refs == 1) {
                @excludes = grep {$_ ne "^$new_commit"} @excludes;
            }
        }

        # And we have to make sure $old_commit is on the list, as --not
        # --all wouldn't bring it when we're being called in a post-receive
        # or post-update hook.

        push @excludes, "^$old_commit" unless $old_commit eq $git->undef_commit;

        # The commit list to be returned
        my @commits;

        local $/ = "\c@\cJ";

        my $cmd = $git->command(
            'rev-list',
            # See 'git help rev-list' to understand the --pretty argument
            '--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%s%n%n%b%x00',
            '--encoding=UTF-8',
            $new_commit,
            @excludes,
        );

        my $stdout = $cmd->stdout;

        while (<$stdout>) {
            my %commit;
            @commit{qw/header commit tree parent
                       author_name author_email author_date
                       committer_name committer_email committer_date
                       body/} = split "\cJ", $_, 11;
            push @commits, \%commit;
        }

        $cmd->close;

        $cache->{$range} = \@commits;
    }

    return @{$cache->{$range}};
}

sub get_commit_msg {
    my ($git, $commit) = @_;

    # We want to use the %B format to grok the commit message, but it
    # was implemented only in Git v1.7.2. If we try to use it with
    # rev-list in previous Gits we get back the same format
    # unexpanded. In this case, we try the second best option which is
    # to use the format %s%n%n%b. The difference is that this format
    # unfolds the first sequence of non-empty lines in a single line
    # which is considered the message's subject (or title).
    foreach my $format (qw/%B %s%n%n%b/) {
        my $body = $git->run('rev-list' => "--format=$format", '--max-count=1', $commit);
        $body =~ s/^[^\n]*\n//; # strip first line, which contains the commit id
        chomp $body;            # strip last newline
        next if $body eq $format;
        return $body;
    }
    die __PACKAGE__, "::get_commit_msg: cannot get commit msg.\n";
}

sub read_commit_msg_file {
    my ($git, $msgfile) = @_;

    my $encoding = $git->get_config(i18n => 'commitencoding') || 'utf-8';

    my $msg = path($msgfile)->slurp({binmode => ":encoding($encoding)"});

    # Truncate the message just before the diff, if any.
    $msg =~ s:\ndiff --git .*::s;

    # The comments in the following lines were taken from the "git
    # help stripspace" documentation to guide the
    # implementation. Previously we invoked the "git stripspace -s"
    # external command via Git::command_bidi_pipe to do the cleaning
    # but it seems that it doesn't work on FreeBSD. So, we reimplement
    # its functionality here.

    for ($msg) {
        # Skip and remove all lines starting with comment character
        # (default #).
        s/^#.*//gm;

        # remove trailing whitespace from all lines
        s/[ \t\f]+$//gm;

        # collapse multiple consecutive empty lines into one empty line
        s/\n{3,}/\n\n/gs;

        # remove empty lines from the beginning and end of the input
        # add a missing \n to the last line if necessary.
        s/^\n+//s;
        s/\n*$/\n/s;

        # In the case where the input consists entirely of whitespace
        # characters, no output will be produced.
        s/^\s+$//s;
    }

    return $msg;
}

sub write_commit_msg_file {
    my ($git, $msgfile, @msg) = @_;

    my $encoding = $git->get_config(i18n => 'commitencoding') || 'utf-8';

    path($msgfile)->spew({binmode => ":encoding($encoding)"}, @msg);

    return;
}

sub filter_files_in_index {
    my ($git, $filter) = @_;
    my $output = $git->run(
        qw/diff-index --name-only --ignore-submodules --no-commit-id --cached -r -z/,
        "--diff-filter=$filter", $git->get_head_or_empty_tree(),
    );
    return split /\0/, $output;
}

sub filter_files_in_range {
    my ($git, $filter, $from, $to) = @_;
    $from = $git->empty_commit if $from eq $git->undef_commit;
    my $output = $git->run(
        qw/diff-tree --name-only --ignore-submodules --no-commit-id -r -z/,
        "--diff-filter=$filter", $from, $to,
    );
    return split /\0/, $output;
}

sub filter_files_in_commit {
    my ($git, $filter, $commit) = @_;
    my $output = $git->run(
        qw/diff-tree --name-only --ignore-submodules -m -r -z/,
        "--diff-filter=$filter", $commit,
    );
    my $num_parents = 0;
    my %files;
    foreach my $name (split /\0/, $output) {
        if ($name =~ /^[0-9a-f]{40}$/) {
            ++$num_parents;
        } else {
            ++$files{$name};
        }
    }
    return grep { $files{$_} == $num_parents } keys %files;
}

# Internal funtion to set the affected references in an update or
# pre-receive hook.

sub _set_affected_ref {
    my ($git, $ref, $old_commit, $new_commit) = @_;
    $git->{_plugin_githooks}{affected_refs}{$ref}{range} = [$old_commit, $new_commit];
    return;
}

# internal method
sub _get_affected_refs_hash {
    my ($git) = @_;

    $git->{_plugin_githooks}{affected_refs}
        or die __PACKAGE__, ": get_affected_refs(): no affected refs set\n";

    return $git->{_plugin_githooks}{affected_refs};
}

sub get_affected_refs {
    my ($git) = @_;

    return keys %{_get_affected_refs_hash($git)};
}

sub get_affected_ref_range {
    my ($git, $ref) = @_;

    my $affected = _get_affected_refs_hash($git);

    exists $affected->{$ref}{range}
        or die __PACKAGE__, ": get_affected_ref_range($ref): no such affected ref\n";

    return @{$affected->{$ref}{range}};
}

sub get_affected_ref_commits {
    my ($git, $ref) = @_;

    my $affected = _get_affected_refs_hash($git);

    exists $affected->{$ref}
        or die __PACKAGE__, ": get_affected_ref_commits($ref): no such affected ref\n";

    unless (exists $affected->{$ref}{commits}) {
        $affected->{$ref}{commits} = [$git->get_commits($git->get_affected_ref_range($ref))];
    }

    return @{$affected->{$ref}{commits}};
}

sub push_input_data {
    my ($git, $data) = @_;
    push @{$git->{_plugin_githooks}{input_data}}, $data;
    return;
}

sub get_input_data {
    my ($git) = @_;
    return $git->{_plugin_githooks}{input_data} || [];
}

sub set_authenticated_user {
    my ($git, $user) = @_;
    return $git->{_plugin_githooks}{authenticated_user} = $user;
}

sub authenticated_user {
    my ($git) = @_;

    unless (exists $git->{_plugin_githooks}{authenticated_user}) {
        if (my $userenv = $git->get_config(githooks => 'userenv')) {
            if ($userenv =~ /^eval:(.*)/) {
                $git->{_plugin_githooks}{authenticated_user} = eval $1; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                die __PACKAGE__, ": error evaluating userenv value ($userenv): $@\n"
                    if $@;
            } elsif (exists $ENV{$userenv}) {
                $git->{_plugin_githooks}{authenticated_user} = $ENV{$userenv};
            } else {
                die __PACKAGE__, ": option userenv environment variable ($userenv) is not defined.\n";
            }
        } else {
            $git->{_plugin_githooks}{authenticated_user} = $ENV{GERRIT_USER_EMAIL} || $ENV{USER} || undef;
        }
    }

    return $git->{_plugin_githooks}{authenticated_user};
}

sub get_current_branch {
    my ($git) = @_;
    my $cmd = $git->command(qw/symbolic-ref HEAD/);

    # Return undef if we're in dettached head state
    return eval { $cmd->final_output } || undef;
}

sub get_sha1 {
    my ($git, $rev) = @_;

    return $git->run('rev-parse', '--verify', $rev)->final_output;
}

sub get_head_or_empty_tree {
    my ($git) = @_;

    my $cmd = $git->command(qw/rev-parse --verify HEAD/);

    # Return the empty tree object if in the initial commit
    return eval { $cmd->final_output } || $git->empty_commit;
}

sub blob {
    my ($git, $rev, $file, @args) = @_;

    my $cache = $git->cache('blob');

    my $blob = "$rev:$file";

    unless (exists $cache->{$blob}) {
        $cache->{tmpdir} //= Path::Tiny->tempdir(@args);

        my $path = path($file);

        # Calculate temporary file path
        (my $revdir  = $rev) =~ s/^://; # remove ':' from ':0' because Windows don't like ':' in filenames
        my $filepath = $cache->{tmpdir}->child($revdir, $path);

        # Create directory path for the temporary file.
        $filepath->parent->mkpath;

        # Create temporary file and copy contents to it
        open my $tmp, '>:', $filepath ## no critic (RequireBriefOpen)
            or die "Internal error: can't create file '$filepath': $!";

        my $cmd = $git->command(qw/cat-file blob/, $blob);
        my $stdout = $cmd->stdout;
        my $read;
        while ($read = sysread $stdout, my $buffer, 64 * 1024) {
            my $length = length $buffer;
            my $offset = 0;
            while ($length) {
                my $written = syswrite $tmp, $buffer, $length, $offset;
                defined $written
                    or die "Internal error: can't write to '$filepath': $!";
                $length -= $written;
                $offset += $written;
            }
        }
        defined $read
            or die "Internal error: can't read from git cat-file pipe: $!";
        $cmd->close;

        $tmp->close;

        $cache->{$blob} = $filepath;
    }

    return $cache->{$blob}->stringify;
}

sub file_size {
    my ($git, $rev, $file) = @_;

    chomp(my $size = $git->run('cat-file', '-s', "$rev:$file"));

    return $size;
}

sub error {
    my ($git, $prefix, $message, $details) = @_;
    $message =~ s/\n*$//s;    # strip trailing newlines
    my $fmtmsg = "\n[$prefix] $message";
    my $nocarp = $git->get_config(githooks => 'nocarp');
    if ($details) {
        # The details may have been generated by Carp::croak, in which case
        # it will contain a suffix telling where the error
        # occurred. Sometimes you may not want this. For instance, if the
        # user is going to receive the error message produced by a server
        # hook he/she won't be able to use that information. So, we may have
        # to strip the context from the details.
        $details =~ s/ at .*? line \d+(?: thread \d+)?\.?$//s if $nocarp;
        $details =~ s/\n*$//s; # strip trailing newlines
        $details =~ s/^/  /gm; # prefix each line with two spaces
        $fmtmsg .= ":\n\n$details\n";
    }
    $fmtmsg .= "\n";            # end in a newline
    push @{$git->{_plugin_githooks}{errors}}, $fmtmsg;
    if ($nocarp) {
        warn $fmtmsg;           ## no critic (RequireCarping)
    } else {
        carp $fmtmsg;
    }
    return 1;
}

sub get_errors {
    my ($git) = @_;

    return exists $git->{_plugin_githooks}{errors} ? @{$git->{_plugin_githooks}{errors}} : ();
}

##############
# The following routines are invoked after all hooks have been
# processed. Some hooks may need to take a global action depending on
# the overall result of all hooks.

sub post_hook {
    my ($git, $sub) = @_;
    push @{$git->{_plugin_githooks}{post_hooks}}, $sub;
    return;
}

sub post_hooks {
    my ($git) = @_;
    return @{$git->{_plugin_githooks}{post_hooks}};
}

sub is_ref_enabled {
    my ($git, $ref, @specs) = @_;

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

# The routine redirect_output redirects STDOUT and STDERR to a temporary
# file and returns a reference that should be passed to the routine
# restore_output to restore the handles to their original state.

sub redirect_output {
    my ($git) = @_;
    ## no critic (RequireBriefOpen, RequireCarping)
    open(my $oldout, '>&', \*STDOUT)  or die "Can't dup STDOUT: $!";
    open(my $olderr, '>&', \*STDERR)  or die "Can't dup STDERR: $!";
    my $tempfile = Path::Tiny->tempfile(UNLINK => 1);
    open(STDOUT    , '>' , $tempfile) or die "Can't redirect STDOUT to \$tempfile: $!";
    open(STDERR    , '>&', \*STDOUT)  or die "Can't dup STDOUT for STDERR: $!";
    ## use critic
    return [$oldout, $olderr, $tempfile];
}

# This routine gets a reference returned by redirect_output, restores STDOUT
# and STDERR to their previous state and returns a string containing every
# output since the previous call to redirect_output.

sub restore_output {
    my ($git, $saved) = @_;
    my ($oldout, $olderr, $tempfile) = @$saved;
    ## no critic (RequireCarping)
    open(STDOUT, '>&', $oldout) or die "Can't dup \$oldout: $!";
    open(STDERR, '>&', $olderr) or die "Can't dup \$olderr: $!";
    ## use critic
    return $tempfile->slurp;
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

sub file_temp {
    my ($git, $rev, $file, @args) = @_;

    carp 'Invoking deprecated routine ', __PACKAGE__, '::file_temp. Please, see documentation.';

    return $git->blob($rev, $file, @args);
}

sub grok_groups_spec {
    my ($groups, $specs, $source) = @_;
    foreach (@$specs) {
        s/\#.*//;               # strip comments
        next unless /\S/;       # skip blank lines
        /^\s*(\w+)\s*=\s*(.+?)\s*$/
            or die __PACKAGE__, ": invalid line in '$source': $_\n";
        my ($groupname, $members) = ($1, $2);
        exists $groups->{"\@$groupname"}
            and die __PACKAGE__, ": redefinition of group ($groupname) in '$source': $_\n";
        foreach my $member (split / /, $members) {
            if ($member =~ /^\@/) {
                # group member
                $groups->{"\@$groupname"}{$member} = $groups->{$member}
                    or die __PACKAGE__, ": unknown group ($member) cited in '$source': $_\n";
            } else {
                # user member
                $groups->{"\@$groupname"}{$member} = undef;
            }
        }
    }
    return;
}

sub grok_groups {
    my ($git) = @_;

    my $cache = $git->cache('githooks');

    unless (exists $cache->{groups}) {
        my @groups = $git->get_config(githooks => 'groups')
            or die __PACKAGE__, ": you have to define the githooks.groups option to use groups.\n";

        my $groups = {};
        foreach my $spec (@groups) {
            if (my ($groupfile) = ($spec =~ /^file:(.*)/)) {
                my @groupspecs = path($groupfile)->lines;
                defined $groupspecs[0]
                    or die __PACKAGE__, ": can't open groups file ($groupfile): $!\n";
                grok_groups_spec($groups, \@groupspecs, $groupfile);
            } else {
                my @groupspecs = split /\n/, $spec;
                grok_groups_spec($groups, \@groupspecs, "githooks.groups");
            }
        }
        $cache->{groups} = $groups;
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

##############
# The following routines prepare the arguments for some hooks to make
# it easier to deal with them later on.

# Some hooks get information from STDIN as text lines with
# space-separated fields. This routine reads up all of STDIN and tucks
# that information in the Git::Repository object.

sub _prepare_input_data {
    my ($git) = @_;
    while (<STDIN>) { ## no critic (InputOutput::ProhibitExplicitStdin)
        chomp;
        $git->push_input_data([split]);
    }
    return;
}

# The pre-receive and post-receive hooks get the list of affected
# commits via STDIN. This routine gets them all and set all affected
# refs in the Git object.

sub _prepare_receive {
    my ($git) = @_;
    _prepare_input_data($git);
    foreach (@{$git->get_input_data()}) {
        my ($old_commit, $new_commit, $ref) = @$_;
        _set_affected_ref($git, $ref, $old_commit, $new_commit);
    }
    return;
}

# The update hook get three arguments telling which reference is being
# updated, from which commit, to which commit. Here we use these
# arguments to set the affected ref in the Git object.

sub _prepare_update {
    my ($git, $args) = @_;
    _set_affected_ref($git, @$args);
    return;
}

# Gerrit hooks get a list of option/value pairs. Here we convert the
# list into a hash and change the original argument list into a single
# hash-ref. We also record information about the user performing the
# push. Based on:
# https://gerrit-review.googlesource.com/Documentation/config-hooks.html

sub _prepare_gerrit_args {
    my ($git, $args) = @_;

    my %opt = @$args;

    # Each Gerrit hook receive the full name and email of the user
    # performing the hooked operation via a specific option in the
    # format "User Name (email@example.net)". Here we grok it.
    my $user =
        $opt{'--uploader'}  ||
        $opt{'--author'}    ||
        $opt{'--submitter'} ||
        $opt{'--abandoner'} ||
        $opt{'--restorer'}  ||
        $opt{'--reviewer'}  ||
        undef;

    # Here we make the name and email available in two environment variables
    # (GERRIT_USER_NAME and GERRIT_USER_EMAIL) so that
    # Git::Repository::Plugin::GitHooks::authenticated_user can more easily
    # grok the userid from them later.
    if ($user && $user =~ /([^\(]+)\s+\(([^\)]+)\)/) {
        $ENV{GERRIT_USER_NAME}  = $1; ## no critic (Variables::RequireLocalizedPunctuationVars)
        $ENV{GERRIT_USER_EMAIL} = $2; ## no critic (Variables::RequireLocalizedPunctuationVars)
    }

    # Now we create a Gerrit::REST object connected to the Gerrit
    # server and tack it to the hook arguments so that Gerrit plugins
    # can interact with it.

    # We 'require' the module instead of 'use' it because it's only
    # used if one sets up Gerrit hooks, which may not be the most
    # common usage of Git::Hooks.
    eval {require Gerrit::REST}
        or die __PACKAGE__, ": Please, install the Gerrit::REST module to use Gerrit hooks.\n";

    $opt{gerrit} = do {
        my %info;
        foreach my $arg (qw/url username password/) {
            $info{$arg} = $git->get_config('githooks.gerrit' => $arg)
                or die __PACKAGE__, ": Missing githooks.gerrit.$arg configuration variable.\n";
        }

        Gerrit::REST->new(@info{qw/url username password/});
    };

    @$args = (\%opt);

    return;
}

# The ref-update Gerrit hook is invoked synchronously when a user
# pushes commits to a branch. So, it acts much like Git's standard
# 'update' hook. This routine prepares the options as usual and sets
# the affected ref accordingly. The documented arguments for the hook
# are these:

# ref-update --project <project name> --refname <refname> --uploader \
# <uploader> --oldrev <sha1> --newrev <sha1>

sub _prepare_gerrit_ref_update {
    my ($git, $args) = @_;

    _prepare_gerrit_args($git, $args);

    # The --refname argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $refname = $args->[0]{'--refname'};
    $refname = "refs/heads/$refname"
        unless $refname =~ m:^refs/:;

    _set_affected_ref($git, $refname, @{$args->[0]}{qw/--oldrev --newrev/});
    return;
}

# The following routine is the post_hook used by the Gerrit hooks
# patchset-created and draft-published. It basically casts a vote on the
# patchset based on the errors found during the hook processing.

sub _gerrit_patchset_post_hook {
    my ($hook_name, $git, $args) = @_;

    for my $arg (qw/project branch change patchset/) {
        exists $args->{"--$arg"}
            or die __PACKAGE__, ": Missing --$arg argument to Gerrit's $hook_name hook.\n";
    }

    # We have to use the most complete form of Gerrit change ids because
    # it's the only unanbiguous one. Vide:
    # https://gerrit.cpqd.com.br/Documentation/rest-api-changes.html#change-id.

    # Up to Gerrit 2.12 the argument --change passed the change's Change-Id
    # code. So, we had to build the complete change id using the information
    # passed on the arguments --project and --branch. From Gerrit 2.13 on
    # the --change argument already contains the complete change id. So we
    # have to figure out if we need to build it or not.

    # Also, for the old Gerrit we have to url-escape the change-id because
    # the project name may contain slashes (and perhaps other reserved
    # characters). This is possibly not a complete solution. Vide:
    # http://mark.stosberg.com/blog/2010/12/percent-encoding-uris-in-perl.html.

    require URI::Escape;
    my $id = $args->{'--change'} =~ /~/
        ? $args->{'--change'}
        : URI::Escape::uri_escape(join('~', @{$args}{qw/--project --branch --change/}));

    my $patchset = $args->{'--patchset'};

    # Grok all configuration options at once to make it easier to deal with them below.
    my %cfg = map {$_ => $git->get_config('githooks.gerrit' => $_) || undef}
        qw/review-label vote-nok vote-ok votes-to-approve votes-to-reject comment-ok auto-submit/;

    # Convert DEPRECATED configuration options to new ones.
    if (any {defined $cfg{$_}} qw/review-label vote-nok vote-ok/) {
        if (any {defined $cfg{$_}} qw/votes-to-approve votes-to-reject/) {
            die __PACKAGE__ . ": Mixing deprecated githooks.gerrit configuration options (review-label vote-nok vote-ok) with new ones (votes-to-approve votes-to-reject) is not permited. Please, convert the deprecated ones.\n"
        }
        $cfg{'votes-to-approve'} = $cfg{'votes-to-reject'} = $cfg{'review-label'} || 'Code-Review';
        $cfg{'votes-to-reject'} .= $cfg{'vote-nok'} || '-1';
        $cfg{'votes-to-approve'} .= $cfg{'vote-ok'}  || '+1';
    }

    # https://gerrit-documentation.storage.googleapis.com/Documentation/2.13.1/rest-api-changes.html#set-review
    my %review_input;
    my $auto_submit = 0;

    if (my @errors = $git->get_errors()) {
        $review_input{labels}  = $cfg{'votes-to-reject'} || 'Code-Review-1';
        $review_input{message} = join("\n\n", @errors);
    } else {
        $review_input{labels}  = $cfg{'votes-to-approve'} || 'Code-Review+1';
        $review_input{message} = "[Git::Hooks] $cfg{'comment-ok'}"
            if $cfg{'comment-ok'};
        $auto_submit = 1 if $cfg{'auto-submit'};
    }

    # Convert, e.g., 'LabelA-1,LabelB+2' into { LabelA => '-1', LabelB => '+2' }
    $review_input{labels} = { map {/^([-\w]+)([-+]\d+)$/i} split(',', $review_input{labels}) };

    if (my $notify = $git->get_config('githooks.gerrit' => 'notify')) {
        $review_input{notify} = $notify;
    }

    # Cast review
    eval { $args->{gerrit}->POST("/changes/$id/revisions/$patchset/review", \%review_input) }
        or die __PACKAGE__ . ": error in Gerrit::REST::POST(/changes/$id/revisions/$patchset/review): $@\n";

    # Auto submit if requested and passed verification
    if ($auto_submit) {
        eval { $args->{gerrit}->POST("/changes/$id/submit", {wait_for_merge => 'true'}) }
            or die __PACKAGE__ . ": I couldn't submit the change. Perhaps you have to rebase it manually to resolve a conflict. Please go to its web page to check it out. The error message follows: $@\n";
    }

    return;
}

# Gerrit's patchset-created hook is invoked when a commit is pushed to a
# refs/for/* branch for revision. It's invoked asynchronously, i.e., it
# can't stop the push to happen. Instead, if it detects any problem, we must
# reject the commit via Gerrit's own revision process. So, we prepare a post
# hook action in which we see if there were errors that should be signaled
# via a code review action. Note, however, that draft changes can only be
# accessed by their respective owners and usually can't be voted on by the
# hook. So, draft changes aren't voted on and we exit the hook prematurely.
# The arguments for the hook are these:

# patchset-created --change <change id> --is-draft <boolean> \
# --kind <change kind> --change-url <change url> \
# --change-owner <change owner> --project <project name> \
# --branch <branch> --topic <topic> --uploader <uploader>
# --commit <sha1> --patchset <patchset id>

# Gerrit's draft-published hook is invoked when a draft change is
# published. In this state they're are visible by the hook and can be voted
# on. The arguments for the hook are these:

# draft-published --change <change id> --change-url <change url> \
# --change-owner <change owner> --project <project name> \
# --branch <branch> --topic <topic> --uploader <uploader> \
# --commit <sha1> --patchset <patchset id>

sub _prepare_gerrit_patchset {
    my ($git, $args) = @_;

    _prepare_gerrit_args($git, $args);

    exit(0) if exists $args->[0]{'--is-draft'} and $args->[0]{'--is-draft'} eq 'true';

    $git->post_hook(\&_gerrit_patchset_post_hook);

    return;
}

# The %prepare_hook hash maps hook names to the routine that must be
# invoked in order to "prepare" their arguments.

my %prepare_hook = (
    'update'           => \&_prepare_update,
    'pre-push'         => \&_prepare_input_data,
    'post-rewrite'     => \&_prepare_input_data,
    'pre-receive'      => \&_prepare_receive,
    'post-receive'     => \&_prepare_receive,
    'ref-update'       => \&_prepare_gerrit_ref_update,
    'patchset-created' => \&_prepare_gerrit_patchset,
    'draft-published'  => \&_prepare_gerrit_patchset,
);

sub prepare_hook {
    my ($git, @args) = @_;

    $git->{_plugin_githooks}{arguments} = \@args; # for debugging purposes
    my $hook_name = shift @args;
    my $basename  = path($hook_name)->basename;
    $git->{_plugin_githooks}{hookname} = $basename;

    # Some hooks need some argument munging before we invoke them
    if (my $prepare = $prepare_hook{$basename}) {
        $prepare->($git, \@args);
    }

    return $basename;
}

sub load_plugins {
    my ($git) = @_;

    my %enabled_plugins  = map {($_ => undef)} map {split} $git->get_config(githooks => 'plugin');

    return unless %enabled_plugins; # no one configured

    my %disabled_plugins = map {($_ => undef)} map {split} $git->get_config(githooks => 'disable');

    # Remove disabled plugins from the list of enabled ones
    foreach my $plugin (keys %enabled_plugins) {
        my ($prefix, $basename) = ($plugin =~ /^(.+::)?(.+)/);

        if (   exists $disabled_plugins{$plugin}
            || exists $disabled_plugins{$basename}
            || exists $ENV{$basename} && ! $ENV{$basename}
        ) {
            delete $enabled_plugins{$plugin};
        } else {
            $enabled_plugins{$plugin} = [$prefix, $basename];
        }
    }

    # Define the list of directories where we'll look for the hook
    # plugins. First the local directory 'githooks' under the
    # repository path, then the optional list of directories
    # specified by the githooks.plugins config option, and,
    # finally, the Git::Hooks standard hooks directory.
    my @plugin_dirs = grep {-d} (
        'githooks',
        $git->get_config(githooks => 'plugins'),
        path($INC{'Git/Hooks.pm'})->parent->child('Hooks'),
    );

    # Load remaining enabled plugins
    while (my ($key, $plugin) = each %enabled_plugins) {
        my ($prefix, $basename) = @$plugin;
        my $exit = do {
            if ($prefix) {
                # It must be a module name
                ## no critic (ProhibitStringyEval, RequireCheckingReturnValueOfEval)
                eval "require $prefix$basename";
            } else {
                # Otherwise, it's a basename we must look for in @plugin_dirs
                $basename .= '.pm' unless $basename =~ /\.p[lm]$/i;
                my @scripts = grep {!-d} map {path($_)->child($basename)} @plugin_dirs;
                $basename = shift @scripts
                    or die __PACKAGE__, ": can't find enabled hook $basename.\n";
                do $basename;
            }
        };
        unless ($exit) {
            die __PACKAGE__, ": couldn't parse $basename: $@\n" if $@;
            die __PACKAGE__, ": couldn't do $basename: $!\n"    unless defined $exit;
            die __PACKAGE__, ": couldn't run $basename\n";
        }
    }

    return;
}

# This is an internal routine used by the method invoke_external_hook
# below.

sub _invoke_external_hook {
    my ($git, $file, $hook, @args) = @_;

    my $prefix  = '[' . __PACKAGE__ . '(' . path($file)->basename . ')]';
    my $saved_output = $git->redirect_output();

    if ($hook =~ /^(?:pre-receive|post-receive|pre-push|post-rewrite)$/) {

        # These hooks receive information via STDIN that we read once
        # before invoking any hook. Now, we must regenerate the same
        # information and output it to the external hooks we invoke.

        my $stdin = join("\n", map {join(' ', @$_)} @{$git->get_input_data}) . "\n";

        my $pid = open my $pipe, '|-'; ## no critic (InputOutput::RequireBriefOpen)

        if (! defined $pid) {
            $git->restore_output($saved_output);
            $git->error($prefix, "can't fork: $!");
        } elsif ($pid) {
            # parent
            print $pipe $stdin;
            my $exit = close $pipe;
            my $output = $git->restore_output($saved_output);
            if ($exit) {
                warn $output, "\n" if length $output;
                return 1;
            } elsif ($!) {
                $git->error($prefix, "Error closing pipe to external hook: $!", $output);
            } else {
                $git->error($prefix, "External hook exited with code $?", $output);
            }
        } else {
            # child
            { exec {$file} ($hook, @args) }
            $git->restore_output($saved_output);
            die "$prefix: can't exec: $!\n";
        }

    } else {

        if (@args && ref $args[0]) {
            # This is a Gerrit hook and we need to expand its arguments
            @args = %{$args[0]};
        }

        my $exit = system {$file} ($hook, @args);

        my $output = $git->restore_output($saved_output);

        if ($exit == 0) {
            warn $output, "\n" if length $output;
            return 1;
        } else {
            my $message = do {
                if ($exit == -1) {
                    "failed to execute external hook: $!";
                } elsif ($exit & 127) {
                    sprintf("external hook died with signal %d, %s coredump",
                            ($exit & 127), ($exit & 128) ? 'with' : 'without');
                } else {
                    sprintf("'$file' exited abnormally with value %d", $exit >> 8);
                }
            };
            $git->error($prefix, $message, $output);
        }
    }

    return 0;
}

sub invoke_external_hooks {
    my ($git, @args) = @_;

    return if $^O eq 'MSWin32' || ! $git->get_config(githooks => 'externals');

    my $hookname = $git->{_plugin_githooks}{hookname};

    foreach my $dir (
        grep {-e}
        map  {path($_)->child($hookname)}
        ($git->get_config(githooks => 'hooks'), path($git->git_dir())->child('hooks.d'))
    ) {
        opendir my $dh, $dir
            or $git->error(__PACKAGE__, ": cannot opendir '$dir'", $!)
            and next;
        foreach my $file (grep {!-d && -x} map {path($dir)->child($_)} readdir $dh) {
            _invoke_external_hook($git, $file, $hookname, @args)
                or $git->error(__PACKAGE__, ": error in external hook '$file'");
        }
    }
    return;
}


1; # End of Git::Repository::Plugin::GitHooks
__END__

=for Pod::Coverage grok_groups_spec grok_groups

=head1 NAME

Git::Repository::Plugin::GitHooks - Add useful methods for hooks to Git::Repository

=head1 SYNOPSIS

    # load the plugin
    use Git::Repository 'GitHooks';

    my $git = Git::Repository->new();

    my $config  = $git->get_config();
    my $branch  = $git->get_current_branch();
    my @commits = $git->get_commits($oldcommit, $newcommit);
    my $message = $git->get_commit_msg('HEAD');

    my $files_modified_by_commit = $git->filter_files_in_index('AM');
    my $files_modified_by_push   = $git->filter_files_in_range('AM', $oldcommit, $newcommit);

=head1 DESCRIPTION

This module adds several methods useful to implement Git hooks to
B<Git::Repository>.

In particular, it is used by the standard hooks implemented by the
C<Git::Hooks> framework.

=head1 CONFIGURATION VARIABLES

=head2 CONFIG_ENCODING

Git configuration files usually contain just ASCII characters, but values
and sub-section names may contain any characters, except newline. If your
config files have non-ASCII characters you should ensure that they are
properly decoded by specifying their encoding like this:

    $Git::Repository::Plugin::GitHooks::CONFIG_ENCODING = 'UTF-8';

The acceptable values for this variable are all the encodings supported by
the C<Encode> module.

=head1 METHODS

=head2 undef_commit

The undefined commit is a special SHA-1 used by Git in the update and
pre-receive hooks to signify that a reference either was just created (as
the old commit) or has been just deleted (as the new commit).

=head2 empty_commit

The empty commit represents a commit with an empty tree.

=head2 im_admin(GIT)

This routine checks if the authenticated user (again, as returned by the
C<authenticated_user> method) matches the specifications given by the
C<githooks.admin> configuration variable.

=head2 redirect_output

This routine redirects STDOUT and STDERR to a temporary file and returns a
reference that should be passed to the routine C<restore_output> to restore
the handles to their original state.

=head2 restore_output REF

This routine gets a reference returned by C<redirect_output>, restores
STDOUT and STDERR to their previous state and returns a string containing
every output since the previous call to redirect_output.

=head2 file_temp REV, FILE, ARGS...

This routine is DEPRECATED and has been replaced by the C<blob> method.

This routine returns the name of a temporary file into which the contents of
the file FILE in revision REV has been copied.

It's useful for hooks that need to read the contents of changed files in
order to check anything in them.

These files are cached so that if more than one hook needs to get at them
they're created only once.

By default, all temporary files are removed when the hook exits.

Any remaining ARGS are passed as arguments to C<Path::Tiny::tempfile> so
that you can have more control over the temporary file creation.

=head2 post_hook SUB

Plugin developers may be interested in performing some action
depending on the overall result of every check made by every other
hook. As an example, Gerrit's C<patchset-created> hook is invoked
asynchronously, meaning that the hook's exit code doesn't affect the
action that triggered the hook. The proper way to signal the hook
result for Gerrit is to invoke it's API to make a review. But we want
to perform the review once, at the end of the hook execution, based on
the overall result of all enabled checks.

To do that plugin developers can use this routine to register
callbacks that are invoked at the end of C<run_hooks>. The callbacks
are called with the following arguments:

=over

=item * HOOK_NAME

The basename of the invoked hook.

=item * GIT

The Git::Repository object that was passed to the plugin hooks.

=item * ARGS...

The remaining arguments that were passed to the plugin hooks.

=back

The callbacks may see if there were any errors signalled by the plugin
hook by invoking the C<get_errors> method on the GIT object. They may
be used to signal the hook result in any way they want, but they
should not die or they will prevent other post hooks to run.

=head2 post_hooks

Returns the list of post hook functions registered with the post_hook method
above.

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
C<authenticated_user> method) matches the specification, which may be given
in one of the three different forms acceptable for the C<githooks.admin>
configuration variable above, i.e., as a username, as a @group, or as a
^regex.

=head2 prepare_hook NAME, ARGS...

This method is invoked by G::H::run_hooks to make some preparations for
specific Git hooks before invoking the associated plugins.

=head2 load_plugins

This method loads every plugin configured in the githooks.plugin option.

=head2 get_config [SECTION [VARIABLE]]

This method groks the configuration options for the repository by
invoking C<git config --list>. The configuration is cached during the
first invokation in the object C<Git::Repository> object. So, if the
configuration is changed afterwards, the method won't notice it. This
is usually ok for hooks, though.

With no arguments, the options are returned as a hash-ref pointing to
a two-level hash. For example, if the config options are these:

    section1.a=1
    section1.b=2
    section1.b=3
    section2.x.a=A
    section2.x.b=B
    section2.x.b=C

Then, it'll return this hash:

    {
        'section1' => {
            'a' => [1],
            'b' => [2, 3],
        },
        'section2.x' => {
            'a' => ['A'],
            'b' => ['B', 'C'],
        },
    }

The first level keys are the part of the option names before the last
dot. The second level keys are everything after the last dot in the
option names. You won't get more levels than two. In the example
above, you can see that the option "section2.x.a" is split in two:
"section2.x" in the first level and "a" in the second.

The values are always array-refs, even it there is only one value to a
specific option. For some options, it makes sense to have a list of
values attached to them. But even if you expect a single value to an
option you may have it defined in the global scope and redefined in
the local scope. In this case, it will appear as a two-element array,
the last one being the local value.

So, if you want to treat an option as single-valued, you should fetch
it like this:

    $h->{section1}{a}[-1]
    $h->{'section2.x'}{a}[-1]

If the SECTION argument is passed, the method returns the second-level
hash for it. So, following the example above, this call:

    $git->get_config('section1');

This call would return this hash:

    {
        'a' => [1],
        'b' => [2, 3],
    }

If the section doesn't exist an empty hash is returned. Any key/value
added to the returned hash will be available in subsequent invokations
of C<get_config>.

If the VARIABLE argument is also passed, the method returns the
value(s) of the configuration option C<SECTION.VARIABLE>. In list
context the method returns the list of all values or the empty list,
if the variable isn't defined. In scalar context, the method returns
the variable's last value or C<undef>, if it's not defined.

=head2 cache SECTION

This method may be used by plugin developers to cache information in
the context of a Git::Repository object. SECTION is a string (usually a
plugin name) that is associated with a hash-ref. The method simply
returns the hash-ref, which can be used by the caller to store any
kind of information.

=head2 get_commit COMMIT

This method returns a hash representing COMMIT. It obtains this information
by invoking C<git rev-list --no-walk --encoding=UTF-8 COMMIT>.

The returned hash has the following structure (the codes are explained in
the C<git help rev-list> document):

    {
        commit          => %H:  commit hash
        tree            => %T:  tree hash
        parent          => %P:  parent hashes (space separated)
        author_name     => %aN: author name
        author_email    => %aE: author email
        author_date     => %ai: author date in ISO8601 format
        committer_name  => %cN: committer name
        committer_email => %cE: committer email
        committer_date  => %ci: committer date in ISO8601 format
        body            => %B:  raw body (aka commit message)
    }

All character data is UTF-8 encoded.

=head2 get_commits OLDCOMMIT NEWCOMMIT

This method returns a list of hashes representing every commit
reachable from NEWCOMMIT but not from OLDCOMMIT. It obtains this
information by invoking C<git rev-list NEWCOMMIT ^OLDCOMMIT>.

There are two special cases, though:

If NEWCOMMIT is the null SHA-1, i.e.,
'0000000000000000000000000000000000000000', this means that a branch,
pointing to OLDCOMMIT, has been removed. In this case the method
returns an empty list, meaning that no new commit has been created.

If OLDCOMMIT is the null SHA-1, this means that a new branch poiting
to NEWCOMMIT is being created. In this case we want all commits
reachable from NEWCOMMIT but not reachable from any other branch. The
syntax for this is NEWCOMMIT ^B1 ^B2 ... ^Bn", i.e., NEWCOMMIT
followed by every other branch name prefixed by carets. We can get at
their names using the technique described in, e.g., L<this
discussion|http://stackoverflow.com/questions/3511057/git-receive-update-hooks-and-new-branches>.

=head2 get_commit_msg COMMIT_ID

This method returns the commit message (a.k.a. body) of the commit
identified by COMMIT_ID. The result is a string.

=head2 read_commit_msg_file FILENAME

This method returns the relevant contents of the commit message file
called FILENAME. It's useful during the C<commit-msg> and the
C<prepare-commit-msg> hooks.

The file is read using the character encoding defined by the
C<i18n.commitencoding> configuration option or C<utf-8> if not
defined.

Some non-relevant contents are stripped off the file. Specifically:

=over

=item * diff data

Sometimes, the commit message file contains the diff data for the
commit. This data begins with a line starting with the fixed string
C<diff --git a/>. Everything from such a line on is stripped off the
file.

=item * comment lines

Every line beginning with a C<#> character is stripped off the file.

=item * trailing spaces

Any trailing space is stripped off from all lines in the file.

=item * trailing empty lines

Any empty line at the end is stripped off from the file, making sure
it ends in a single newline.

=back

All this cleanup is performed to make it easier for different plugins
to analyse the commit message using a canonical base.

=head2 write_commit_msg_file FILENAME, MSG, ...

This method writes the list of strings C<MSG> to FILENAME. It's useful
during the C<commit-msg> and the C<prepare-commit-msg> hooks.

The file is written to using the character encoding defined by the
C<i18n.commitencoding> configuration option or C<utf-8> if not
defined.

An empty line (C<\n\n>) is inserted between every pair of MSG
arguments, if there is more than one, of course.

=head2 filter_files_in_index FILTER

This method returns a list of the names of the files that are changed in the
index (staging area) compared to the HEAD commit. It's useful in the
C<pre-commit> hook when you want to know which files are being modified in
the upcoming commit.

FILTER specifies in which kind of changes you're interested in. It's passed
as the argument to the C<--diff-filter> option of C<git diff-index>, which
is documented like this:

  --diff-filter=[(A|C|D|M|R|T|U|X|B)...[*]]

    Select only files that are Added (A), Copied (C), Deleted (D), Modified
    (M), Renamed (R), have their type (i.e. regular file, symlink,
    submodule, ...) changed (T), are Unmerged (U), are Unknown (X), or have
    had their pairing Broken (B). Any combination of the filter characters
    (including none) can be used. When * (All-or-none) is added to the
    combination, all paths are selected if there is any file that matches
    other criteria in the comparison; if there is no file that matches other
    criteria, nothing is selected.

=head2 filter_files_in_range FILTER, FROM, TO

This method returns a list of the names of the files that are changed
between FROM and TO commits. It's useful in the C<update> and the
C<pre-receive> hooks when you want to know which files are being modified in
the commits being received by a C<git push> command.

FILTER specifies in which kind of changes you're interested in. Please, read
the C<filter_files_in_index> documetation above.

FROM and TO are revision parameters (see C<git help revisions>) specifying
two commits. They're passed as arguments to C<git diff-tree> in order to
compare them and grok the files that differ between them.

=head2 filter_files_in_commit FILTER, COMMIT

This method returns a list of the names of the files that are changed in
COMMIT. It's useful in the C<patchset-created> and the C<draft-published>
hooks when you want to know which files are being modified in the single
commit being received by a C<git push> command.

FILTER specifies in which kind of changes you're interested in. Please, read
the C<filter_files_in_index> documetation above.

COMMIT is a revision parameter (see C<git help revisions>) specifying the
commit. It's passed a argument to C<git diff-tree> in order to compare it to
its parents and grok the files that changed in it.

Merge commits are treated specially. Only files that are changed in COMMIT
with respect to all of its parents are returned. The reasoning behind this
is that if a file isn't changed with respect to one or more of COMMIT's
parents, then it must have been checked already in those commits and we
don't need to check it again.

=head2 get_affected_refs

This method returns the list of names of references that were affected by
the current push command.

=head2 get_affected_ref_range(REF)

This method returns the two-element list of commit ids representing
the OLDCOMMIT and the NEWCOMMIT of the affected REF.

=head2 get_affected_ref_commits(REF)

This routine returns the list of commits leading from the affected
REF's NEWCOMMIT to OLDCOMMIT. The commits are represented by hashes,
as returned by the C<get_commits> method.

=head2 authenticated_user

This method returns the username of the authenticated user performing
the Git action. It groks it from the C<githooks.userenv> configuration
variable specification, which is described in the C<Git::Hooks>
documentation. It's useful for most access control check plugins.

=head2 push_input_data DATA

This method gets a single value and tucks it in an internal list so
that every piece of data can be gotten later with the
C<get_input_data> method below.

It's used by C<Git::Hooks> to save arguments read from STDIN by some
Git hooks like pre-receive, post-receive, pre-push, and post-rewrite.

=head2 get_input_data

This method returns an array-ref pointing to a list of all pieces of
data saved by calls to C<push_input_data> method above.

=head2 set_authenticated_user USERNAME

This method can be used to set the username of the authenticated user
when the default heristics defined above aren't enough. The name will
be cached so that subsequent invokations of B<authenticated_user> will
return this.

=head2 get_current_branch

This method returns the repository's current branch name, as indicated
by the C<git symbolic-ref HEAD> command.

If the repository is in a dettached head state, i.e., if HEAD points
to a commit instead of to a branch, the method returns undef.

=head2 get_sha1 REV

This method returns the SHA1 of the commit represented by REV, using the
command

  git rev-parse --verify REV

It's useful, for instance, to grok the HEAD's SHA1 so that you can pass it
to the get_commit method.

=head2 get_head_or_empty_tree

This method returns the string "HEAD" if the repository already has
commits. Otherwise, if it is a brand new repository, it returns the SHA1
representing the empty tree. It's useful to come up with the correct
argument for, e.g., C<git diff> during a pre-commit hook. (See the default
pre-commit.sample script which comes with Git to understand how this is
used.)

=head2 blob REV, FILE, ARGS...

This method returns the name of a temporary file into which the contents of
the file FILE in revision REV has been copied.

It's useful for hooks that need to read the contents of changed files in
order to check anything in them.

These objects are cached so that if more than one hook needs to get at them
they're created only once.

By default, all temporary files are removed when the Git::Repository object
is destroyed.

Any remaining ARGS are passed as arguments to C<File::Temp::newdir> so that you
can have more control over the temporary file creation.

If REV:FILE does not exist or if there is any other error while trying to
fetch its contents the method throws a Git::Simple or a Git::Error::Command
exception.

=head2 file_size REV FILE

This method returns the size (in bytes) of FILE (a path relative to the
repository root) in revision REV.

=head2 error PREFIX MESSAGE [DETAILS]

This method should be used by plugins to record consistent error or warning
messages. It gets two or three arguments. The PREFIX is usually the plugin's
package name. The MESSAGE is a oneline string. These two arguments are
combined to produce a single line like this:

  [PREFIX] MESSAGE

DETAILS is an optional string. If present, it is appended to the line above,
separated by an empty line, and with its lines prefixed by two spaces, like
this:

  [PREFIX] MESSAGE

    DETAILS
    MORE DETAILS...

The method simply records the formatted error message and returns. It
doesn't die.

=head2 get_errors

This method returns a list of all error messages recorded with the
C<error> method.

=head2 invoke_external_hooks ARGS...

This method is used by Git::Hooks::run_hooks to invoke external hooks.

=head1 SEE ALSO

C<Git::Repository::Plugin>, C<Git::Hooks>.

