# -*- cperl -*-

use 5.010;
use strict;
use warnings;
use lib 't';
use Test::More tests => 44;
use File::pushd;
use Path::Tiny;

BEGIN { require "test-functions.pl" };

use Git::Hooks::GerritChangeId;

my ($repo, $filename, undef, $T) = new_repos();

# Save Gerrit's standard shell commit-msg hook in our test temporary
# directory.
my $gerrit_script = $T->child('gerrit-commit-msg');
{
    local $/ = undef;
    $gerrit_script->spew(<DATA>)
        or BAIL_OUT("can't '$gerrit_script'->spew(<DATA>)\n");
    chmod 0755, $gerrit_script;
};


install_hooks($repo, undef, qw/commit-msg/);

sub last_log {
    return eval { $repo->get_commit_msg('HEAD') } || 'NO LOG FOR EMPTY REPO';
}

sub diag_last_log {
    my $last_log = last_log();
    diag(" LAST LOG[", length($last_log), "]<<<$last_log>>>\n");
}

my $msgfile = $T->child('msg.txt');

sub cannot_commit {
    my ($testname, $regex, $msg) = @_;
    $filename->append("new line\n");
    $repo->command(add => $filename);
    $msgfile->spew($msg)
        or BAIL_OUT("cannot_commit: can't '$msgfile'->spew('$msg')\n");
    unless (test_nok_match($testname, $regex, $repo, 'commit', '-F', $msgfile)) {
	diag_last_log();
    }
}

sub can_commit {
    my ($testname, $msg) = @_;
    $filename->append("new line\n");
    $repo->command(add => $filename);
    $msgfile->spew($msg)
        or BAIL_OUT("can_commit: can't '$msgfile'->spew('$msg')\n");
    return test_ok("$testname [commit]", $repo, 'commit', '-F', $msgfile);
}


$repo->command(config => "githooks.plugin", 'GerritChangeId');

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

    $msgfile->spew($msg)
        or BAIL_OUT("check_can_commit: can't '$msgfile'->spew('$msg')\n");

    my $dir = pushd($repo->repo_path());

    system('sh', $gerrit_script, $msgfile);

    return $msgfile->slurp;
}

sub produced {
    my ($msg) = @_;

    # Check how our hook change the message
    $msgfile->spew($msg)
        or BAIL_OUT("check_can_commit: can't '$msgfile'->spew('$msg')\n");
    Git::Hooks::GerritChangeId::rewrite_message($repo, $msgfile);
    $msgfile->slurp;
}

sub compare {
    my ($testname, $expected, $produced) = @_;
    $expected =~ s/\bI[0-9a-f]{40}\b/I0000000000000000000000000000000000000000/;
    $produced =~ s/\bI[0-9a-f]{40}\b/I0000000000000000000000000000000000000000/;
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

# Set these environment variables to make sure the change ids come out
# the same from our plugin and from the official Gerrit commit-msg
# hook.
$ENV{GIT_AUTHOR_DATE} = $ENV{GIT_COMMITTER_DATE} = '1356828164 -0200';

foreach my $test (
    [ 'no-CID',              "\n" ],
    [ 'single-line',         "\n\n$CID\n" ],
    [ 'multi-line',          "\n\nb\n\nc\n\n$CID\n" ],
    [ 'not-a-footer',        "\n\nb: not a footer\nc\nd\ne\n\nf\ng\nh\n\n$CID\n" ],
    [ 'single-line SOB',     "\n\n$CID\n$SOB1\n" ],
    [ 'multi-line SOB',      "\n\nb\n\nc\n\n$CID\n$SOB1\n" ],
    [ 'not-a-footer SOB',    "\n\nb: not a footer\nc\nd\ne\n\nf\ng\nh\n\n$CID\n$SOB1\n" ],
    [ 'note-in-middle',      "\n\nNOTE: This\ndoes not fix it.\n\n$CID\n" ],
    [ 'kernel-style-footer', "\n\n$CID\n$SOB1\n[ja: Fixed\n     the indentation]\n$SOB2\n" ],
    [ 'CID-after-Bug',       "\n\nBug: 42\n$CID\n$SOB1\n" ],
    [ 'CID-after-Issue',     "\n\nIssue: 42\n$CID\n$SOB1\n" ],
    [ 'commit-dashv',        "\n\n$SOB1\n$SOB2\n\n# on branch master\ndiff --git a/src b/src\nnew file mode 100644\nindex 0000000..c78b7f0\n" ],
    [ 'with-url http',       "\n\nhttp://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url https',      "\n\nhttps://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url ftp',        "\n\nftp://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-url git',        "\n\ngit://example.com/ fixes this\n\n$CID\n" ],
    [ 'with-false-tags',     "\n\nFakeLine:\n  foo\n  bar\n\n$CID\nRealTag: abc\n" ],
) {
    my $msg = join('', @$test);
    my $expected = expected($msg);
    my $produced = produced($msg);
    compare("compare: $test->[0]", $expected, $produced);
}


__DATA__
#!/bin/sh
#
# Part of Gerrit Code Review (http://code.google.com/p/gerrit/)
#
# Copyright (C) 2009 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

unset GREP_OPTIONS

CHANGE_ID_AFTER="Bug|Issue"
MSG="$1"

# Check for, and add if missing, a unique Change-Id
#
add_ChangeId() {
	clean_message=`sed -e '
		/^diff --git a\/.*/{
			s///
			q
		}
		/^Signed-off-by:/d
		/^#/d
	' "$MSG" | git stripspace`
	if test -z "$clean_message"
	then
		return
	fi

	# Does Change-Id: already exist? if so, exit (no change).
	if grep -i '^Change-Id:' "$MSG" >/dev/null
	then
		return
	fi

	id=`_gen_ChangeId`
	T="$MSG.tmp.$$"
	AWK=awk
	if [ -x /usr/xpg4/bin/awk ]; then
		# Solaris AWK is just too broken
		AWK=/usr/xpg4/bin/awk
	fi

	# How this works:
	# - parse the commit message as (textLine+ blankLine*)*
	# - assume textLine+ to be a footer until proven otherwise
	# - exception: the first block is not footer (as it is the title)
	# - read textLine+ into a variable
	# - then count blankLines
	# - once the next textLine appears, print textLine+ blankLine* as these
	#   aren't footer
	# - in END, the last textLine+ block is available for footer parsing
	$AWK '
	BEGIN {
		# while we start with the assumption that textLine+
		# is a footer, the first block is not.
		isFooter = 0
		footerComment = 0
		blankLines = 0
	}

	# Skip lines starting with "#" without any spaces before it.
	/^#/ { next }

	# Skip the line starting with the diff command and everything after it,
	# up to the end of the file, assuming it is only patch data.
	# If more than one line before the diff was empty, strip all but one.
	/^diff --git a/ {
		blankLines = 0
		while (getline) { }
		next
	}

	# Count blank lines outside footer comments
	/^$/ && (footerComment == 0) {
		blankLines++
		next
	}

	# Catch footer comment
	/^\[[a-zA-Z0-9-]+:/ && (isFooter == 1) {
		footerComment = 1
	}

	/]$/ && (footerComment == 1) {
		footerComment = 2
	}

	# We have a non-blank line after blank lines. Handle this.
	(blankLines > 0) {
		print lines
		for (i = 0; i < blankLines; i++) {
			print ""
		}

		lines = ""
		blankLines = 0
		isFooter = 1
		footerComment = 0
	}

	# Detect that the current block is not the footer
	(footerComment == 0) && (!/^\[?[a-zA-Z0-9-]+:/ || /^[a-zA-Z0-9-]+:\/\//) {
		isFooter = 0
	}

	{
		# We need this information about the current last comment line
		if (footerComment == 2) {
			footerComment = 0
		}
		if (lines != "") {
			lines = lines "\n";
		}
		lines = lines $0
	}

	# Footer handling:
	# If the last block is considered a footer, splice in the Change-Id at the
	# right place.
	# Look for the right place to inject Change-Id by considering
	# CHANGE_ID_AFTER. Keys listed in it (case insensitive) come first,
	# then Change-Id, then everything else (eg. Signed-off-by:).
	#
	# Otherwise just print the last block, a new line and the Change-Id as a
	# block of its own.
	END {
		unprinted = 1
		if (isFooter == 0) {
			print lines "\n"
			lines = ""
		}
		changeIdAfter = "^(" tolower("'"$CHANGE_ID_AFTER"'") "):"
		numlines = split(lines, footer, "\n")
		for (line = 1; line <= numlines; line++) {
			if (unprinted && match(tolower(footer[line]), changeIdAfter) != 1) {
				unprinted = 0
				print "Change-Id: I'"$id"'"
			}
			print footer[line]
		}
		if (unprinted) {
			print "Change-Id: I'"$id"'"
		}
	}' "$MSG" > $T && mv $T "$MSG" || rm -f $T
}
_gen_ChangeIdInput() {
	echo "tree `git write-tree`"
	if parent=`git rev-parse "HEAD^0" 2>/dev/null`
	then
		echo "parent $parent"
	fi
	echo "author `git var GIT_AUTHOR_IDENT`"
	echo "committer `git var GIT_COMMITTER_IDENT`"
	echo
	printf '%s' "$clean_message"
}
_gen_ChangeId() {
	_gen_ChangeIdInput |
	git hash-object -t commit --stdin
}


add_ChangeId
