#!/usr/bin/env perl

# Copyright (C) 2012 by CPqD

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Git::Hooks::CheckLog;
# ABSTRACT: Git::Hooks plugin to enforce commit log policies.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use File::Slurp;

(my $HOOK = __PACKAGE__) =~ s/.*:://;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $HOOK} //= {};

    my $default = $config->{lc $HOOK};
    $default->{'title-required'}  //= [1];
    $default->{'title-max-width'} //= [50];
    $default->{'title-period'}    //= ['deny'];
    $default->{'body-max-width'}  //= [72];

    return;
}

##########

sub read_msg_encoded {
    my ($git, $msgfile) = @_;

    my $encoding = $git->config(i18n => 'commitencoding') || 'utf-8';

    my $msg = read_file($msgfile, { binmode => ":encoding($encoding)", err_mode => 'carp' })
        or die "$HOOK: Cannot read message file '$msgfile' with encoding '$encoding'\n";

    # Strip the patch data from the message.
    $msg =~ s:^diff --git a/.*::ms;

    # strip comment lines
    $msg =~ s/^#.*\n?//mg;

    return $msg;
}

sub check_message {
    my ($git, $commit, $msg) = @_;

    my $id = defined $commit ? substr($commit->{commit}, 0, 7) : 'commit';

    foreach my $match ($git->config($HOOK => 'match')) {
        if ($match =~ s/^!\s*//) {
            $msg !~ /$match/m
                or die "$HOOK: $id\'s log SHOULD NOT match \Q$match\E.\n";
        } else {
            $msg =~ /$match/m
                or die "$HOOK: $id\'s log SHOULD match \Q$match\E.\n";
        }
    }

    # Check title
    if ($msg =~ s/^([^\n]+)(\n$|\n\n+)//s) {
        my ($title, $sep) = ($1, $2);
        length($msg) == 0 || length($sep) == 2
            or die "$HOOK: $id\'s log title and body are separated by ", (length($sep)-1), " blank lines, not 1!\n";
        if (my $max_width = $git->config($HOOK => 'title-max-width')) {
            length($title) <= $max_width
                or die "$HOOK: $id\'s log title is ", length($title), " characters long, more than $max_width!\n";
        }
        if (my $period = $git->config($HOOK => 'title-period')) {
            if ($period eq 'deny') {
                $title !~ /\.$/ or die "$HOOK: $id\'s log title SHOULD NOT end in a period.\n";
            } elsif ($period eq 'require') {
                $title =~ /\.$/ or die "$HOOK: $id\'s log title SHOULD end in a period.\n";
            } elsif ($period ne 'allow') {
                die "$HOOK: Invalid value for the $HOOK.title-period option: '$period'.\n";
            }
        }
    } elsif ($git->config($HOOK => 'title-required')) {
        die "$HOOK: $id\'s log SHOULD have a title.\n";
    }

    # Check body
    if (my $max_width = $git->config($HOOK => 'body-max-width')) {
        while ($msg =~ /^(.*)/gm) {
            my $line = $1;
            length($line) <= $max_width
                or die "$HOOK: $id\'s log body lines must be shorter than $max_width characters but there is one with ", length($line), "!\n";
        }
    }

    return;
}

sub check_message_file {
    my ($git, $commit_msg_file) = @_;

    _setup_config($git);

    check_message($git, undef, read_msg_encoded($git, $commit_msg_file));

    return;
}

sub check_ref {
    my ($git, $ref) = @_;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        check_message($git, $commit, $commit->{body});
    }

    return;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return if im_admin($git);

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref);
    }

    return;
}

# Install hooks
COMMIT_MSG  \&check_message_file;
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=for Pod::Coverage read_msg_encoded check_message check_ref

=head1 NAME

Git::Hooks::CheckLog - Git::Hooks plugin to enforce commit log policies.

=head1 DESCRIPTION

This Git::Hooks plugin can act as any of the below hooks to enforce
policies on the commit log messages.

=over

=item C<commit-msg>

This hook is invoked during the commit, to check if the commit log
message complies.

=item C<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, to check if the commit log
messages of all commits being pushed comply.

=item C<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
to check if the commit log messages of all commits being pushed
comply.

=back

Projects using Git, probably more than projects using any other
version control system, have a tradition of stablishing policies on
the format of commit log messages. The REFERENCES section below lists
some of the more important ones.

This plugin allows one to enforce most of the more stablished
policies. The default configuration already enforces the most common
one.

To enable the plugin you should define the appropriate Git
configuration option like one of these:

    git config --add githooks.commit-msg  CheckLog
    git config --add githooks.pre-receive CheckLog
    git config --add githooks.update      CheckLog

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 CheckLog.title-required [01]

The first line of a Git commit log message is usually called the
'title'. It must be separated by the rest of the message (it's 'body')
by one empty line. This option, which is 1 by default, makes the
plugin check if there is a proper title in the log message.

=head2 CheckLog.title-max-width N

This option specifies a limit to the width of the title's in
characters. It's 50 by default. If you set it to 0 the plugin imposes
no limit on the title's width.

=head2 CheckLog.title-period [deny|allow|require]

This option defines the policy regarding the title's ending in a
period (a.k.a. full stop ('.')). It can take three values:

=over

=item deny

This means that the title SHOULD NOT end in a period. This is the
default value of the option, as this is the most common policy.

=item allow

This means that the title MAY end in a period, i.e., it doesn't
matter.

=item require

This means that the title SHOULD end in a period.

=back

=head2 CheckLog.body-max-width N

This option specifies a limit to the width of the commit log message's
body lines, in characters. It's 72 by default. If you set it to 0 the
plugin imposes no limit on the body line's width.

=head2 CheckLog.match [!]REGEXP

This option may be specified more than once. It defines a list of
regular expressions that will be matched against the commit log
messages. If the '!' prefix isn't used, the log has to match the
REGEXP. Otherwise, the log must not match the REGEXP.

=head2 i18n.commitEncoding ENCODING

This is not a CheckLog option. In fact, this is a native option of
Git, which semantics is defined in C<git help config>. It tells Git
which character encoding the commit messages are stored in and
defaults to C<utf-8>.

When this plugin is used in the C<commit-msg> hook, the message file
is read and its contents are checked against the encoding specified by
this option.

=head1 EXPORTS

This module exports the following routines that can be used directly
without using all of Git::Hooks infrastructure.

=head2 check_message_file GIT, MSGFILE

This is the routine used to implement the C<commit-msg> hook. It needs
a C<Git::More> object and the name of a file containing the commit
message.

=head2 check_affected_refs GIT

This is the routing used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head1 REFERENCES

=over

=item git-commit(1) Manual Page

(L<http://www.kernel.org/pub/software/scm/git/docs/git-commit.html>)
This Git manual page has a section called DISCUSSION which discusses
some common log message policies.

=item Linus Torvalds GitHub rant

(L<https://github.com/torvalds/linux/pull/17#issuecomment-5659933>) In
this note, Linus says why he dislikes GitHub's pull request interface,
mainly because it doesn't allow him to enforce log message formatting
policies.

=item MediaWiki Git/Commit message guidelines

(L<http://www.mediawiki.org/wiki/Git/Commit_message_guidelines>) This
document defines the MediaWiki's project commit log message guidelines.

=item Proper Git Commit Messages and an Elegant Git History

(L<http://ablogaboutcode.com/2011/03/23/proper-git-commit-messages-and-an-elegant-git-history/>)
This is a good discussion about commit log message formatting and the
reasons behind them.

=back
