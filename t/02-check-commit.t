#!/usr/bin/env perl

use v5.16.0;
use warnings;
use version;
use lib qw/t lib/;
use Git::Hooks::Test ':all';
use Test::More tests => 36;
use Test::Requires::Git;
use System::Command;
use Path::Tiny;

my ($repo, $file, $clone, $T) = new_repos();

sub setenvs {
    my ($aname, $amail, $cname, $cmail) = @_;
    ## no critic (RequireLocalizedPunctuationVars)
    $ENV{GIT_AUTHOR_NAME}     = $aname;
    $ENV{GIT_AUTHOR_EMAIL}    = $amail || "$ENV{GIT_AUTHOR_NAME}\@example.net";
    $ENV{GIT_COMMITTER_NAME}  = $cname || $ENV{GIT_AUTHOR_NAME};
    $ENV{GIT_COMMITTER_EMAIL} = $cmail || $ENV{GIT_AUTHOR_EMAIL};
    ## use critic
    return;
}

sub check_can_commit {
    my ($testname, @envs) = @_;
    setenvs(@envs);

    $file->append($testname);
    $repo->run(add => $file);

    test_ok($testname, $repo, 'commit', '-m', $testname);
    return;
}

sub check_cannot_commit {
    my ($testname, $regex, @envs) = @_;
    setenvs(@envs);

    $file->append($testname);
    $repo->run(add => $file);

    my $exit = $regex
        ? test_nok_match($testname, $regex, $repo, 'commit', '-m', $testname)
        : test_nok($testname, $repo, 'commit', '-m', $testname);
    $repo->run(qw/rm --cached/, $file);
    return $exit;
}

sub merge {
    my ($git, $testname) = @_;

    $git->run(qw/checkout -q -b xpto/);
    $git->run(qw/commit --allow-empty -m/, $testname);
    $git->run(qw/checkout -q master/);
    $git->run(qw/merge --no-ff xpto/);
    $git->run(qw/branch -d xpto/);
    return;
}

sub check_can_push_merge {
    my ($testname) = @_;

    merge($repo, $testname);

    return test_ok($testname, $repo, 'push', $clone->git_dir(), 'master');
}

sub check_cannot_push_merge {
    my ($testname, $regex) = @_;

    merge($repo, $testname);

    return $regex
        ? test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), 'master')
        : test_nok($testname, $repo, 'push', $clone->git_dir(), 'master');
}

sub check_can_push {
    my ($testname, $branch, @envs) = @_;
    setenvs(@envs);

    new_commit($repo, $file, $testname);
    test_ok($testname, $repo, 'push', $clone->git_dir(), "HEAD:$branch");
    return;
}

sub check_cannot_push {
    my ($testname, $regex, $branch, @envs) = @_;
    setenvs(@envs);

    $repo->run(qw/branch -f mark/);
    new_commit($repo, $file, $testname);
    my $exit = test_nok_match($testname, $regex, $repo, 'push', $clone->git_dir(), "HEAD:$branch");
    $repo->run(qw/reset --hard mark/);
    return $exit;
}


# Repo hooks

install_hooks($repo, undef, 'pre-commit');

$repo->run(qw/config githooks.plugin CheckCommit/);

# name

$repo->run(qw/config githooks.checkcommit.name valid1/);

$repo->run(qw/config --add githooks.checkcommit.name valid2/);

check_can_commit('allow positive author name', 'valid2');

check_cannot_commit('deny positive author name', qr/is invalid/, 'none');

$repo->run(qw/config --add githooks.checkcommit.name !invalid/);

check_can_commit('allow negative author name', 'valid1');

check_cannot_commit('deny negative author name', qr/matches some negative/, 'invalid');

$repo->run(qw/config --remove-section githooks.checkcommit/);

# email

$repo->run(qw/config githooks.checkcommit.email valid1/);

$repo->run(qw/config --add githooks.checkcommit.email valid2/);

check_can_commit('allow positive author email', 'valid2');

check_cannot_commit('deny positive author email', qr/is invalid/, 'none');

$repo->run(qw/config --add githooks.checkcommit.email !invalid/);

check_can_commit('allow negative author email', 'valid1');

check_cannot_commit('deny negative author email', qr/matches some negative/, 'invalid');

$repo->run(qw/config --remove-section githooks.checkcommit/);

# canonical
SKIP: {
    test_requires_git skip => 4, version_ge => '1.8.5.3';

    my $mailmap = path($T)->child('mailmap');

    $mailmap->spew(<<'EOS');
Good Name <good@example.net> <bad@example.net>
Proper Name <proper@example.net>
EOS

    $repo->run(qw/config githooks.checkcommit.canonical/, $mailmap);

    check_can_commit(
        'allow canonical name and email',
        'Good Name',
        'good@example.net',
    );

    check_cannot_commit(
        'deny non-canonical email',
        qr/identity isn't canonical/,
        'Good Name',
        'bad@example.net',
    );


    check_cannot_commit(
        'deny non-canonical name',
        qr/identity isn't canonical/,
        'Improper Name',
        'proper@example.net',
    );

    check_can_commit(
        'allow non-specified email and name',
        'none',
        'none@example.net',
    );

    $repo->run(qw/config --remove-section githooks.checkcommit/);
}

# check-code repo

$repo->run(qw/config githooks.checkcommit.check-code/,
                'sub { my ($git, $commit) = @_; return $commit->author_name =~ /valid/; };');

check_can_commit('check-code commit ok', 'valid');

check_cannot_commit('check-code commit nok', qr/Error detected while evaluating/, 'other');

$repo->run(qw/config --remove-section githooks.checkcommit/);

# email-valid
SKIP: {
    unless (eval { require Email::Valid; }) {
        skip "Email::Valid module isn't installed", 2;
    }

    $repo->run(qw/config githooks.checkcommit.email-valid 1/);

    check_can_commit(
        'allow valid email',
        'name',
        'good@example.net',
    );

    check_cannot_commit(
        'deny invalid email',
        qr/failed the rfc822 check/,
        'Good Name',
        'bad@example@net',
    );

    $repo->run(qw/config --remove-section githooks.checkcommit/);
}

# githooks.ref githooks.noref tests
$repo->run(qw/config githooks.checkcommit.name isvalid/);

$repo->run(qw:config githooks.noref refs/heads/master:);

check_can_commit('githooks.noref', 'invalid');

$repo->run(qw:config githooks.ref refs/heads/master:);

check_cannot_commit('githooks.ref', qr/is invalid/, 'invalid');

$repo->run(qw/config --unset-all githooks.ref/);

$repo->run(qw/config --unset-all githooks.noref/);

$repo->run(qw:config githooks.noref ^.*master:);

check_can_commit('githooks.noref regex', 'invalid');

$repo->run(qw:config githooks.ref ^.*master:);

check_cannot_commit('githooks.ref regex', qr/is invalid/, 'invalid');

$repo->run(qw/config --unset-all githooks.ref/);

$repo->run(qw/config --unset-all githooks.noref/);

$repo->run(qw/config --remove-section githooks.checkcommit/);


# Clone hooks

($repo, $file, $clone, $T) = new_repos();

install_hooks($clone, undef, 'pre-receive');

$clone->run(qw/config githooks.plugin CheckCommit/);

$clone->run(qw/config githooks.checkcommit.name valid1/);

check_can_push('allow positive author name (push)', 'master', 'valid1');

check_cannot_push('deny positive author name (push)', qr/is invalid/, 'master', 'none');

$clone->run(qw/config --remove-section githooks.checkcommit/);


# merges

$clone->run(qw/config githooks.userenv GITMERGER/);

local $ENV{GITMERGER} = 'user';
check_can_push_merge('allow merges by default');

$clone->run(qw/config githooks.checkcommit.merger merger/);

local $ENV{GITMERGER} = 'user';
check_cannot_push_merge('deny merges by non-mergers', qr/are not authorized to push/);

local $ENV{GITMERGER} = 'merger';
check_can_push_merge('allow merges by merger');

delete $ENV{GITMERGER};
$clone->run(qw/config --unset githooks.userenv/);
$clone->run(qw/config --remove-section githooks.checkcommit/);

# push-limit

$clone->run(qw/config githooks.checkcommit.push-limit 1/);

$repo->run(qw/commit --allow-empty -mempty/);
check_cannot_push('push-limit deny', qr/allows one to push at most/, 'master', 'name');

$clone->run(qw/config --remove-section githooks.checkcommit/);

# check-code clone

$clone->run(qw/config githooks.checkcommit.check-code/,
                'sub { my ($git, $commit, $ref) = @_; $ref =~ s:.*/::; return $ref eq "valid"; };');

check_can_push('check-code push ok', 'valid', 'name');

check_cannot_push('check-code push nok', qr/Error detected while evaluating/, 'invalid', 'name');

$clone->run(qw/config --remove-section githooks.checkcommit/);

my $script  = $T->child('check-code.pl');
{
    open my $fh, '>', $script or die BAIL_OUT("can't open $script to write: $!"), "\n";
    print $fh <<'EOT' or die  BAIL_OUT("can't write to $script: $!"), "\n";
sub {
    my ($git, $commit, $ref) = @_;
    $ref =~ s:.*/::;
    return $ref eq "valid";
};
EOT
    close $fh;
}

$clone->run(qw/config githooks.checkcommit.check-code/, "file:$script");

check_can_push('check-code push file ok', 'valid', 'name');

check_cannot_push('check-code push file nok', qr/Error detected while evaluating/, 'invalid', 'name');

$clone->run(qw/config --remove-section githooks.checkcommit/);

#
# Signature
#
# How to test for signature:
# 1. Check that we have `gpg` installed.
# 1.1. local $ENV{GNUPGHOME} = /tmp/**
# 1.2. local $ENV{PINENTRY_USER_DATA} = 'loopback';
# 2. Create a public/private keypair, save in /tmp: create "local" gpg dir.
# 3. Set up local and remote hooks.

sub is_gpg_available {
    my ($min_version) = @_;
    my $cmd = q{sh -c "command -v gpg"};
    my $rval = system $cmd;
    if( ! defined $min_version ) {
        return ! $rval;
    }
    $min_version = version->parse($min_version) unless ( ref $min_version eq 'version');
    my $out = `gpg --version`;
    my ($ver_line, @dummy) = split qr/\n/, $out;
    my ($ver_s) = $ver_line =~ m/^gpg \(GnuPG\) (.*)$/ms;
    my $ver = version->parse($ver_s);
    return $ver >= $min_version;
}

SKIP: {
    skip 'GPG (or high enough version) not available', 6 if( ! is_gpg_available( '2.2.27' ) );

    # Create a public/private keypair.
    my ($user_name, $user_email, $user_signingkey)
        = ('Example User', 'example.user@foo.bar', undef);
    my $T_gpg = $T->child('.gnupg');
    umask 0077; # Give access only to user, otherwise gpg will complain.
    $T_gpg->mkpath;
    diag 'Created temp dir ' . $T;
    local $ENV{GNUPGHOME} = $T_gpg;
    local $ENV{PINENTRY_USER_DATA} = 'loopback';

    my $sys_com_trace = q{3=} .  $T->child('system_command.log');
    # --quick-generate-key user-id [algo [usage [expire]]]
    # No expiration date, after all, the temp dir is deleted after use.
    my @gpg_general_opts = (
        # q{--quiet},
        q{--batch},
        q{--no-tty},
        q{--pinentry-mode}, q{loopback},
    );
    my @cmd_opts = (
        @gpg_general_opts,
        # q{--passphrase}, q{},
        # This is very misleading:
        # To create a key without passphrase, you give the flag --passphrase
        # but it has no parameter, not even empty string ''.
        # This is probably a bug, which is why we require the minimum version 2.2.27
        q{--passphrase},
        q{--quick-generate-key}, $user_email,
        q{future-default},
        q{default},
        q{never},
    );
    # diag 'Create a GPG key ...';
    my $cmd = System::Command->new( q{gpg}, @cmd_opts, { trace => $sys_com_trace });
    my $key_id;
    my $sub_get_key_id = sub {
        # gpg: key 978CD3B986D23275 marked as ultimately trusted
        if( $_[0] =~ m/^gpg: key ([A-F0-9]{1,}) marked as .*$/ms ) {
            ($key_id) = $_[0] =~ m/^gpg: key ([A-F0-9]{1,}) marked as .*$/ms;
            return 0;
        }
        return 1;
    };
    $cmd->loop_on( stdout => $sub_get_key_id, stderr => $sub_get_key_id );
    diag 'Created key ' . $key_id;
    # Created key always gets automatically ultimate ownertrust
    if( ! $key_id ) {
        BAIL_OUT 'Testing failure: Could not create a GPG public/private key pair';
    }

    # Set user signing key.
    $user_signingkey = $key_id;

    # Repo has worktree, clone is bare.
    ($repo, $file, $clone, $T) = new_repos();
    my $git = $repo;
    my $git_cmd;
    diag 'Git work_tree: ' . $git->work_tree;
    install_hooks($repo, undef, 'post-commit');
    $repo->run(qw/config githooks.plugin CheckCommit/);
    $repo->run(qw/config githooks.checkcommit.signature nocheck/);
    $repo->run(qw/config --local user.name/, $user_name);
    $repo->run(qw/config --local user.email/, $user_email);

    # Since this is a new repo, let's create a starting commit and push it.
    $git_cmd = System::Command->new( q{git}, q{commit},
        q{--no-gpg-sign}, q{--allow-empty}, q{-m}, q{Initial (empty) commit},
        { cwd => $git->work_tree, trace => $sys_com_trace });
    $git_cmd = System::Command->new( q{git}, q{push},
        q{--set-upstream}, q{clone}, q{master},
        { cwd => $git->work_tree, trace => $sys_com_trace });

    # Test
    my $testname = 'no_check_succeeds_without_gpg_signature';
    $git_cmd = System::Command->new( q{git}, q{commit},
        q{--no-gpg-sign}, q{--allow-empty}, q{-m}, $testname,
        { cwd => $git->work_tree, trace => $sys_com_trace });
    my ($stderr_out, $stdout_out)= (q{}, q{});
    $git_cmd->loop_on( stderr => sub { $stderr_out .= $_[0]; } );
    if( length $stderr_out ) {
        fail 'Test 2 failed: STDERR output produced: ' . $stderr_out;
    } else {
        pass $testname;
    }

    # Test
    $testname = 'check_fails_without_gpg_signature';
    $repo->run(qw/config githooks.checkcommit.signature good/);
    $git_cmd = System::Command->new( q{git}, q{commit},
        q{--no-gpg-sign}, q{--allow-empty}, q{-m}, $testname,
        { cwd => $git->work_tree, trace => $sys_com_trace });
    $stderr_out = q{};
    $git_cmd->loop_on( stderr => sub { $stderr_out .= $_[0]; } );
    diag $stderr_out;
    if( $stderr_out =~ m/^The commit has NO GPG signature\.$/ms ) {
        pass $testname;
    } else {
        fail $testname;
    }

    # Test
    $testname = 'check_succeeds_with_a_gpg_signature';
    $git_cmd = System::Command->new( q{git}, q{commit},
        qq{--gpg-sign=$user_signingkey}, q{--allow-empty}, q{-m}, $testname,
        { cwd => $git->work_tree, trace => $sys_com_trace });
    ($stderr_out, $stdout_out)= (q{}, q{});
    $git_cmd->loop_on(
        stderr => sub { $stdout_out .= $_[0]; },
        stderr => sub { $stderr_out .= $_[0]; } );
    if( length $stderr_out ) {
        fail 'Test 2 failed: STDERR output produced: ' . $stderr_out;
    } else {
        pass $testname;
    }

    # Test
    $testname = 'check_fails_with_an_untrusted_gpg_signature';
    @cmd_opts = (
        # Using --command-fd we force gpg to read from stdin instead of tty.
        q{--command-fd}, q{0},
        q{--edit-key}, $user_signingkey,
        q{trust},
        q{quit},
    );
    diag 'Downgrade ownertrust to not defined ...';
    $cmd = System::Command->new( q{gpg}, @cmd_opts, { trace => $sys_com_trace });
    print { $cmd->stdin() } "1\n";
    print { $cmd->stdin() } "y\n";
    ($stderr_out, $stdout_out)= (q{}, q{});
    $cmd->loop_on(
        stderr => sub { $stdout_out .= $_[0]; },
        stderr => sub { $stderr_out .= $_[0]; } );
    $repo->run(qw/config githooks.checkcommit.signature trusted/);
    $git_cmd = System::Command->new( q{git}, q{commit},
        qq{--gpg-sign=$user_signingkey}, q{--allow-empty}, q{-m}, $testname,
        { cwd => $repo->work_tree, trace => $sys_com_trace });
    $stderr_out = q{};
    $stdout_out = q{};
    $git_cmd->loop_on(
        stderr => sub { $stdout_out .= $_[0]; },
        stderr => sub { $stderr_out .= $_[0]; } );
    if( $stderr_out =~ m/^The commit has an UNTRUSTED GPG signature\.$/ms ) {
        pass $testname;
    } else {
        fail $testname;
    }

    # Let's remove the previous commits
    $repo->run(qw/reset --hard HEAD~4/);


    # SERVER SIDE
    install_hooks($clone, undef, 'update');

    # Test
    $testname = 'push_fails_with_an_untrusted_gpg_signature';
    $clone->run(qw/config githooks.plugin CheckCommit/);
    $clone->run(qw/config githooks.checkcommit.signature trusted/);

    # Make a commit. (while the GPG key is untrusted).
    $git_cmd = System::Command->new( q{git}, q{commit},
        qq{--gpg-sign=$user_signingkey}, q{--allow-empty}, q{-m}, $testname,
        { cwd => $repo->work_tree, trace => $sys_com_trace });
    $git_cmd->loop_on( stdout => sub { } );

    # Push to clone (bare)
    $git_cmd = System::Command->new( q{git}, q{push},
        { cwd => $repo->work_tree, trace => $sys_com_trace });
    ($stderr_out, $stdout_out) = (q{}, q{});
    $git_cmd->loop_on(
        stdout => sub { $stdout_out .= $_[0]; },
        stderr => sub { $stderr_out .= $_[0]; } );
    if( $stderr_out =~ m/The commit has an UNTRUSTED GPG signature\./ms ) {
        pass $testname;
    } else {
        fail $testname;
    }

    # Test
    $testname = 'check_succeeds_after_push_with_a_trusted_gpg_signature';

    # Fix the signing key's ownertrust to ultimate.
    @cmd_opts = (
        # Using --command-fd we force gpg to read from stdin instead of tty.
        q{--command-fd}, q{0},
        q{--edit-key}, $user_signingkey,
        q{trust},
        q{quit},
    );
    $cmd = System::Command->new( q{gpg}, @cmd_opts, { trace => $sys_com_trace });
    print { $cmd->stdin() } "5\n";
    print { $cmd->stdin() } "y\n";
    $cmd->loop_on( stdout => sub { }, stderr => sub { } );

    # Push to clone (bare)
    $git_cmd = System::Command->new( q{git}, q{push},
        { cwd => $repo->work_tree, trace => $sys_com_trace });
    ($stderr_out, $stdout_out) = (q{}, q{});
    $git_cmd->loop_on(
        stdout => sub { $stdout_out .= $_[0]; },
        stderr => sub { $stderr_out .= $_[0]; } );
    if( $stderr_out =~ m/remote: error:/ms ) {
        fail 'Test failed: STDERR output produced: ' . $stderr_out;
    } else {
        pass $testname;
    }
} # SKIP.

1;
