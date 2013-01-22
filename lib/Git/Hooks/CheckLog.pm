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
use List::MoreUtils qw/uniq/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};
    $default->{'title-required'}  //= [1];
    $default->{'title-max-width'} //= [50];
    $default->{'title-period'}    //= ['deny'];
    $default->{'body-max-width'}  //= [72];

    return;
}

##########

# Return the message or undef.

sub read_msg_encoded {
    my ($git, $msgfile) = @_;

    my $encoding = $git->get_config(i18n => 'commitencoding') || 'utf-8';

    my $msg = eval { read_file($msgfile, { binmode => ":encoding($encoding)", err_mode => 'carp' }) };
    unless (defined $msg) {
        $git->error($PKG, "Cannot read message file '$msgfile' with encoding '$encoding': $@\n");
        return;
    }

    # Strip the patch data from the message.
    $msg =~ s:^diff --git a/.*::ms;

    # strip comment lines
    $msg =~ s/^#.*\n?//mg;

    return $msg;
}

# Return a Text::SpellChecker object or undef.

sub _spell_checker {
    my ($git, $msg) = @_;

    my %extra_options;

    if (my $lang = $git->get_config($CFG => 'spelling-lang')) {
        $extra_options{lang} = $lang;
    }

    unless (state $tried_to_check) {
        unless (eval { require Text::SpellChecker; }) {
            $git->error($PKG, "Could not require Text::SpellChecker module to spell messages.\n$@\n");
            return;
        }

        # Text::SpellChecker uses either Text::Hunspell or
        # Text::Aspell to perform the checks. But it doesn't try to
        # load those modules until we invoke its next_word method. So,
        # in order to detect errors in those modules we first create a
        # bogus Text::SpellChecker object and force it to spell a word
        # to see if it can go so far.

        my $checker = Text::SpellChecker->new(text => 'a', %extra_options);

        my $word = eval { $checker->next_word(); };
        length $@
            and $git->error($PKG, "Cannot spell check using Text::SpellChecker.\n$@\n")
                and return;

        $tried_to_check = 1;
    };

    return Text::SpellChecker->new(text => $msg, %extra_options);
}

sub check_spelling {
    my ($git, $id, $msg) = @_;

    return 1 unless $msg;

    return 1 unless $git->get_config($CFG => 'spelling');

    # Check all words comprised of at least three Unicode letters
    my $checker = _spell_checker($git, join("\n", uniq($msg =~ /\b(\p{Cased_Letter}{3,})\b/gi)))
        or return 0;

    my $errors = 0;

    foreach my $badword ($checker->next_word()) {
        unless ($errors++) {
            $git->error($PKG, "$id\'s log has the following spelling problems in it.\n");
        }
        my @suggestions = $checker->suggestions($badword);
        if (defined $suggestions[0]) {
            $git->error($PKG, "  $badword (suggestions: ", join(', ', @suggestions), ")\n");
        } else {
            $git->error($PKG, "  $badword (no suggestions)\n");
        }
    }

    return $errors == 0;
}

sub check_patterns {
    my ($git, $id, $msg) = @_;

    my $errors = 0;

    foreach my $match ($git->get_config($CFG => 'match')) {
        if ($match =~ s/^!\s*//) {
            $msg !~ /$match/m
                or $git->error($PKG, "$id\'s log SHOULD NOT match \Q$match\E.\n")
                    and $errors++;
        } else {
            $msg =~ /$match/m
                or $git->error($PKG, "$id\'s log SHOULD match \Q$match\E.\n")
                    and $errors++;
        }
    }

    return $errors == 0;
}

sub check_title {
    my ($git, $id, $title, $neck) = @_;

    return 1 unless $git->get_config($CFG => 'title-required');

    my $errors = 0;

    {
        my $title_lines = ($title =~ tr/\n/\n/);
        $title_lines += 1 if defined $neck;
        $title_lines == 1
            or $git->error($PKG, "$id\'s log title has $title_lines lines but should have only 1!\n")
                and $errors++;
    }

    # Here I was going to check the $neck length to make sure there is
    # only one blank line between the title and the body. However, I
    # soon realised that Git takes care of this and gets rid of any
    # extra blank line in the original message before passing it to
    # the commit-msg hook.

    if (my $max_width = $git->get_config($CFG => 'title-max-width')) {
        length($title) <= $max_width
            or $git->error($PKG, "$id\'s log title should be at most $max_width characters wide, but it has " . length($title) . "!\n")
                and $errors++;
    }

    if (my $period = $git->get_config($CFG => 'title-period')) {
        if ($period eq 'deny') {
            $title !~ /\.$/
                or $git->error($PKG, "$id\'s log title SHOULD NOT end in a period.\n")
                    and $errors++;
        } elsif ($period eq 'require') {
            $title =~ /\.$/
                or $git->error($PKG, "$id\'s log title SHOULD end in a period.\n")
                    and $errors++;
        } elsif ($period ne 'allow') {
            $git->error($PKG, "Invalid value for the $CFG.title-period option: '$period'.\n")
                and $errors++;
        }
    }

    return $errors == 0;
}

sub check_body {
    my ($git, $id, $body) = @_;

    return 1 unless $body;

    if (my $max_width = $git->get_config($CFG => 'body-max-width')) {
        while ($body =~ /^(.*)/gm) {
            my $line = $1;
            length($line) <= $max_width
                or $git->error($PKG, "$id\'s log body lines should be at most $max_width characters wide, but there is one with " . length($line) . "!\n")
                    and return 0;
        }
    }

    return 1;
}

sub check_message {
    my ($git, $commit, $msg) = @_;

    # assert(defined $msg)

    my $id = defined $commit ? substr($commit->{commit}, 0, 7) : 'commit';

    my $errors = 0;

    check_spelling($git, $id, $msg) or $errors++;

    check_patterns($git, $id, $msg) or $errors++;

    my ($title, $neck, $body) = split /(\n\n+)/s, $msg, 2;

    # If $msg is empty split makes $title undef
    $title = '' unless defined $title;

    check_title($git, $id, $title, $neck) or $errors++;

    check_body($git, $id, $body) or $errors++;

    return $errors == 0;
}

sub check_message_file {
    my ($git, $commit_msg_file) = @_;

    _setup_config($git);

    my $msg = read_msg_encoded($git, $commit_msg_file);

    return 0 unless defined $msg;

    return check_message($git, undef, $msg);
}

sub check_ref {
    my ($git, $ref) = @_;

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        check_message($git, $commit, $commit->{body})
            or $errors++;
    }

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if im_admin($git);

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref)
            or $errors++;
    }

    return $errors == 0;
}

# Install hooks
COMMIT_MSG  \&check_message_file;
UPDATE      \&check_affected_refs;
PRE_RECEIVE \&check_affected_refs;

1;


__END__
=for Pod::Coverage read_msg_encoded check_spelling check_patterns check_title check_body check_message check_ref

=head1 NAME

Git::Hooks::CheckLog - Git::Hooks plugin to enforce commit log policies.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to enforce
policies on the commit log messages.

=over

=item * B<commit-msg>

This hook is invoked during the commit, to check if the commit log
message complies.

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, to check if the commit log
messages of all commits being pushed comply.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
to check if the commit log messages of all commits being pushed
comply.

=back

Projects using Git, probably more than projects using any other
version control system, have a tradition of establishing policies on
the format of commit log messages. The REFERENCES section below lists
some of the more important ones.

This plugin allows one to enforce most of the more established
policies. The default configuration already enforces the most common
one.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckLog

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checklog.title-required [01]

The first line of a Git commit log message is usually called the
'title'. It must be separated by the rest of the message (it's 'body')
by one empty line. This option, which is 1 by default, makes the
plugin check if there is a proper title in the log message.

=head2 githooks.checklog.title-max-width N

This option specifies a limit to the width of the title's in
characters. It's 50 by default. If you set it to 0 the plugin imposes
no limit on the title's width.

=head2 githooks.checklog.title-period [deny|allow|require]

This option defines the policy regarding the title's ending in a
period (a.k.a. full stop ('.')). It can take three values:

=over

=item * B<deny>

This means that the title SHOULD NOT end in a period. This is the
default value of the option, as this is the most common policy.

=item * B<allow>

This means that the title MAY end in a period, i.e., it doesn't
matter.

=item * B<require>

This means that the title SHOULD end in a period.

=back

=head2 githooks.checklog.body-max-width N

This option specifies a limit to the width of the commit log message's
body lines, in characters. It's 72 by default. If you set it to 0 the
plugin imposes no limit on the body line's width.

=head2 githooks.checklog.match [!]REGEXP

This option may be specified more than once. It defines a list of
regular expressions that will be matched against the commit log
messages. If the '!' prefix isn't used, the log has to match the
REGEXP. Otherwise, the log must not match the REGEXP.

=head2 githooks.checklog.spelling [01]

This option makes the plugin spell check the commit log message using
C<Text::SpellChecker>. Any spell error will cause the commit or push
to abort.

Note that C<Text::SpellChecker> isn't required to install
C<Git::Hooks>. So, you may see errors when you enable this
check. Please, refer to the module's own documentation to see how to
install it and its own dependencies (which are C<Text::Hunspell> or
C<Text::Aspell>).

=head2 githooks.checklog.spelling-lang ISO

The Text::SpellChecker module uses defaults to infer which language is
must use to spell check the message. You can make it use a particular
language passing its ISO code to this option.

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

=item * B<git-commit(1) Manual Page>

(L<http://www.kernel.org/pub/software/scm/git/docs/git-commit.html>)
This Git manual page has a section called DISCUSSION which discusses
some common log message policies.

=item * B<Linus Torvalds GitHub rant>

(L<https://github.com/torvalds/linux/pull/17#issuecomment-5659933>) In
this note, Linus says why he dislikes GitHub's pull request interface,
mainly because it doesn't allow him to enforce log message formatting
policies.

=item * B<MediaWiki Git/Commit message guidelines>

(L<http://www.mediawiki.org/wiki/Git/Commit_message_guidelines>) This
document defines the MediaWiki's project commit log message guidelines.

=item * B<Proper Git Commit Messages and an Elegant Git History>

(L<http://ablogaboutcode.com/2011/03/23/proper-git-commit-messages-and-an-elegant-git-history/>)
This is a good discussion about commit log message formatting and the
reasons behind them.

=back
