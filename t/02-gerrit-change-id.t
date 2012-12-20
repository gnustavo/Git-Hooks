# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 44;
use Cwd;
use File::Slurp;
use File::Temp qw/tmpnam/;
use Git::Hooks::GerritChangeId;

require "test-functions.pl";

my ($repo, $filename) = new_repos();

install_hooks($repo, undef, qw/commit-msg/);

sub last_log {
    return $repo->get_commit_msg('HEAD');
}

sub diag_last_log {
    my $last_log = last_log();
    diag(" LAST LOG[", length($last_log), "]<<<$last_log>>>\n");
}

my $msgfile = tmpnam();

sub cannot_commit {
    my ($testname, $regex, $msg) = @_;
    append_file($filename, "new line\n");
    $repo->command(add => $filename);
    write_file($msgfile, $msg);
    unless (test_nok_match($testname, $regex, $repo, 'commit', '-F', $msgfile)) {
	diag_last_log();
    }
}

sub can_commit {
    my ($testname, $msg) = @_;
    append_file($filename, "new line\n");
    $repo->command(add => $filename);
    write_file($msgfile, $msg);
    return test_ok("$testname [commit]", $repo, 'commit', '-F', $msgfile);
}


$repo->command(config => "githooks.commit-msg", 'GerritChangeId');

# test EmptyMessages
foreach my $test (
    [ empty     => "" ],
    [ space     => " " ],
    [ newline   => "\n" ],
    [ newlines  => "\n\n" ],
    [ sp_nl_sp  => " \n " ],
) {
    cannot_commit("empty: $test->[0]", qr/Aborting commit due to empty commit message/, $test->[1]);
}

# test CommentOnlyMessages
foreach my $test (
    [ comment   => "#" ],
    [ com_nl    => "#\n" ],
    [ comments  => "# on branch master\n# Untracked files:\n" ],
    [ nl_coms   => "\n# on branch master\n# Untracked files:\n" ],
    [ nlnl_coms => "\n\n# on branch master\n# Untracked files:\n" ],
    [ patch     => "\n# on branch master\ndiff --git a/src b/src\nnew file mode 100644\nindex 0000000..c78b7f0\n" ],
) {
    if (can_commit("comment: $test->[0]", $test->[1])) {
	if (last_log() !~ /Change-Id:/i) {
	    pass("comment: $test->[0] (msg ok)");
	} else {
	    fail("comment: $test->[0] (msg ok)");
	    diag_last_log();
	}
    } else {
	fail("comment: $test->[0] (msg fail)");
    }
}

# test ChangeIdAlreadySet
foreach my $test (
    [ 'set a'             => "a\n\nChange-Id: Iaeac9b4149291060228ef0154db2985a31111335\n" ],
    [ 'set fix'           => "fix: this thing\n\nChange-Id: I388bdaf52ed05b55e62a22d0a20d2c1ae0d33e7e\n" ],
    [ 'set fix-a-widget:' => "fix-a-widget: this thing\n\nChange-Id: Id3bc5359d768a6400450283e12bdfb6cd135ea4b\n" ],
    [ 'set FIX'           => "FIX: this thing\n\nChange-Id: I1b55098b5a2cce0b3f3da783dda50d5f79f873fa\n" ],
    [ 'set Fix-A-Widget'  => "Fix-A-Widget: this thing\n\nChange-Id: I4f4e2e1e8568ddc1509baecb8c1270a1fb4b6da7\n" ],
) {
    if (can_commit("preset: $test->[0]", $test->[1])) {
	if (last_log() eq $test->[1]) {
	    pass("preset: $test->[0] (msg ok)");
	} else {
	    fail("preset: $test->[0] (msg ok)");
	    diag_last_log();
	}
    } else {
	fail("preset: $test->[0] (msg fail)");
    }
}


# Check how the official hook change the message
sub expected {
    my ($msg) = @_;

    write_file($msgfile, $msg);

    my $dir = getcwd;
    chdir $repo->repo_path();
    system(catfile($dir, 't', 'gerrit-commit-msg.sh'), $msgfile);
    chdir $dir;

    return read_file($msgfile);
}

sub produced {
    my ($msg) = @_;

    # Check how our hook change the message
    write_file($msgfile, $msg);
    Git::Hooks::GerritChangeId::rewrite_message($repo, $msgfile);
    read_file($msgfile);
}

sub compare {
    my ($testname, $expected, $produced) = @_;
    if ($produced eq $expected) {
	pass($testname);
    } else {
	fail($testname);
	diag("Expected=<<<$expected>>>\nProduced=<<<$produced>>>");
    }
}

my $CID  = 'Change-Id: I7fc3876fee63c766a2063df97fbe04a2dddd8d7c';
my $SOB1 = 'Signed-off-by: J Author <ja@example.com>';
my $SOB2 = 'Signed-off-by: J Committer <jc@example.com>';

foreach my $test (
    [ 'no-CID',              "a\n" ],
    [ 'single-line',         "a\n\n$CID\n" ],
    [ 'multi-line',          "a\n\nb\n\nc\n\n$CID\n" ],
    [ 'not-a-footer',        "a\n\nb: not a footer\nc\nd\ne\n\nf\ng\nh\n\n$CID\n" ],
    [ 'single-line SOB',     "a\n\n$CID\n$SOB1\n" ],
    [ 'multi-line SOB',      "a\n\nb\n\nc\n\n$CID\n$SOB1\n" ],
    [ 'not-a-footer SOB',    "a\n\nb: not a footer\nc\nd\ne\n\nf\ng\nh\n\n$CID\n$SOB1\n" ],
    [ 'note-in-middle',      "a\n\nNOTE: This\ndoes not fix it.\n\n$CID\n" ],
    [ 'kernel-style-footer', "a\n\n$CID\n$SOB1\n[ja: Fixed\n     the indentation]\n$SOB2\n" ],
    [ 'CID-after-Bug',       "a\n\nBug: 42\n$CID\n$SOB1\n" ],
    [ 'CID-after-Issue',     "a\n\nIssue: 42\n$CID\n$SOB1\n" ],
    [ 'commit-dashv',        "a\n\n$SOB1\n$SOB2\n\n# on branch master\ndiff --git a/src b/src\nnew file mode 100644\nindex 0000000..c78b7f0\n" ],
    [ 'with-url http',       "a\n\nhttp://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url https',      "a\n\nhttps://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url ftp',        "a\n\nftp://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url git',        "a\n\ngit://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-false-tags',     "foo\n\nFakeLine:\n  foo\n  bar\n\n$CID\nRealTag: abc\n" ],
) {
    my $expected = expected($test->[1]);
    my $produced = produced($test->[1]);
    compare("compare: $test->[0]", $expected, $produced);
}
