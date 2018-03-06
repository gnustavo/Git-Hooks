#!/usr/bin/env perl

package Git::Hooks::CheckLog;
# ABSTRACT: Git::Hooks plugin to enforce commit log policies

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks;
use Git::Message;
use List::MoreUtils qw/uniq/;

(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};
    $default->{'title-required'}  //= ['true'];
    $default->{'title-max-width'} //= [50];
    $default->{'title-period'}    //= ['deny'];
    $default->{'body-max-width'}  //= [72];

    return;
}

##########

# Return a Text::SpellChecker object or undef.

sub _spell_checker {
    my ($git, $msg) = @_;

    my %extra_options;

    if (my $lang = $git->get_config($CFG => 'spelling-lang')) {
        $extra_options{lang} = $lang;
    }

    unless (state $tried_to_check) {
        unless (eval { require Text::SpellChecker; }) {
            $git->fault(<<EOS, {option => 'spelling', details => $@});
I could not load the Text::SpellChecker Perl module.

I need it to spell check your commit's messages as requested by this
configuration option.

Please, install the module or disable the option to proceed.
EOS
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
            and $git->fault(<<EOS, {option => 'spelling', details => $@})
There was an error while I tried to spell check your commits using the
Text::SpellChecker module. If you cannot fix it consider disabling this
your configuration option.
EOS
                and return;

        $tried_to_check = 1;
    }

    return Text::SpellChecker->new(text => $msg, %extra_options);
}

sub spelling_errors {
    my ($git, $id, $msg) = @_;

    return 0 unless $msg;

    return 0 unless $git->get_config_boolean($CFG => 'spelling');

    # Check all words comprised of at least three Unicode letters
    my $checker = _spell_checker($git, join("\n", uniq($msg =~ /\b(\p{Cased_Letter}{3,})\b/gi)))
        or return 1;

    my $errors = 0;

    foreach my $badword ($checker->next_word()) {
        my @suggestions = $checker->suggestions($badword);
        my %info = (option => 'spelling');
        $info{details} = join("\n  ", 'SUGGESTIONS:', @suggestions)
            if defined $suggestions[0];
        $git->fault("The commit $id log message has a misspelled word: '$badword'", \%info);
        ++$errors;
    }

    return $errors;
}

##########
# Perform a single pattern check and return the number of errors.

sub _pattern_error {
    my ($git, $text, $match, $what, $id) = @_;

    if ($match =~ s/^!\s*//) {
        $text !~ /$match/m
            or $git->fault("The commit log $what SHOULD NOT match '\Q$match\E'",
                           {commit => $id, option => 'match'})
            and return 1;
    }
    else {
        $text =~ /$match/m
            or $git->fault("The commit log $what SHOULD match '\Q$match\E'",
                           {commit => $id, option => 'match'})
            and return 1;
    }

    return 0;
}

sub pattern_errors {
    my ($git, $id, $msg) = @_;

    my $errors = 0;

    foreach my $match ($git->get_config($CFG => 'match')) {
        $errors += _pattern_error($git, $msg, $match, 'message', $id);
    }

    return $errors;
}

sub revert_errors {
    my ($git, $id, $msg) = @_;

    if ($git->get_config_boolean($CFG => 'deny-merge-revert')) {
        if ($msg =~ /This reverts commit ([0-9a-f]{40})/s) {
            my $reverted_commit = $git->get_commit($1);
            if ($reverted_commit->parent() > 1) {
                $git->fault(<<EOS, {commit => $id, option => 'deny-merge-revert'});
This commit reverts a merge commit, which is not allowed
by your configuration option.
EOS
                return 1;
            }
        }
    }

    return 0;
}

sub title_errors {
    my ($git, $id, $title) = @_;

    unless (defined $title and length $title) {
        if ($git->get_config_boolean($CFG => 'title-required')) {
            $git->fault(<<EOS, {commit => $id, option => 'title-required'});
This commit log message needs a title line.
This is required your configuration option.
Please, amend your commit to add one.
EOS
            return 1;
        } else {
            return 0;
        }
    }

    ($title =~ tr/\n/\n/) == 1
        or $git->fault(<<EOS, {commit => $id})
This commit log message title must have just one line.
Please amend your commit and edit its log message so that its first line
is separated from the rest by an empty line.
EOS
            and return 1;

    my $errors = 0;

    if (my $max_width = $git->get_config_integer($CFG => 'title-max-width')) {
        my $tlen = length($title) - 1; # discount the newline
        $tlen <= $max_width
            or $git->fault(<<EOS, {commit => $id, option => 'title-max-width'})
This commit log message title is too long.
It is $tlen characters wide but should be at most $max_width, a limit set by
your configuration option.
Please, amend your commit to make its title shorter.
EOS
                and ++$errors;
    }

    if (my $period = $git->get_config($CFG => 'title-period')) {
        if ($period eq 'deny') {
            $title !~ /\.$/
                or $git->fault(<<EOS, {commit => $id, option => 'title-period'})
This commit log message title SHOULD NOT end in a period.
This is required by your configuration option.
Please, amend your commit to remove the period.
EOS
                    and ++$errors;
        } elsif ($period eq 'require') {
            $title =~ /\.$/
                or $git->fault(<<EOS, {commit => $id, option => 'title-period'})
This commit log message title SHOULD end in a period.
This is required by your configuration option.
Please, amend your commit to add the period.
EOS
                    and ++$errors;
        } elsif ($period ne 'allow') {
            $git->fault(<<EOS, {commit => $id, option => 'title-period'})
Configuration error: invalid value '$period' for the configuration option.
The valid values are 'deny', 'allow', and 'require'.
EOS
                and ++$errors;
        }
    }

    foreach my $match ($git->get_config($CFG => 'title-match')) {
        $errors += _pattern_error($git, $title, $match, 'title', $id);
    }

    return $errors;
}

sub body_errors {
    my ($git, $id, $body) = @_;

    return 0 unless defined $body && length $body;

    if (my $max_width = $git->get_config_integer($CFG => 'body-max-width')) {
        if (my @biggies = grep {/^\S/} grep {length > $max_width} split(/\n/, $body)) {
            my $theseare = @biggies == 1 ? "this is" : "these are";
            $git->fault(<<EOS, {commit => $id, option => 'body-max-width', details => join("\n", @biggies)});
This commit log body has lines that are too long.
The configuration option limits body lines to $max_width characters.
But the following lines exceed it.
Please, amend your commit to make its lines shorter.
EOS
            return 1;
        }
    }

    return 0;
}

sub footer_errors {
    my ($git, $id, $cmsg) = @_;

    my $errors = 0;

    my @signed_off_by = $cmsg->get_footer_values('signed-off-by');

    if (@signed_off_by) {
        # Check for duplicate Signed-off-by footers
        my (%signed_off_by, @duplicates);
        foreach my $person (@signed_off_by) {
            $signed_off_by{$person} += 1;
            if ($signed_off_by{$person} == 2) {
                push @duplicates, $person;
            }
        }
        if (@duplicates) {
            $git->fault(<<EOS, {commit => $id, details => join("\n", sort @duplicates)});
This commit have duplicate Signed-off-by footers.
Please, amend it to remove the duplicates:
EOS
            ++$errors;
        }
    } elsif ($git->get_config_boolean($CFG => 'signed-off-by')) {
        $git->fault(<<EOS, {commit => $id, option => 'signed-off-by'});
This commit must have a Signed-off-by footer.
This is required by your configuration option.
Please, amend your commit to add it.
EOS
        ++$errors;
    }

    return $errors;
}

sub message_errors {
    my ($git, $commit, $msg) = @_;

    # assert(defined $msg)

    my $id = defined $commit ? $commit->commit : '';

    my $cmsg = Git::Message->new($msg);

    return
        spelling_errors($git, $id, $msg) +
        pattern_errors($git, $id, $msg) +
        revert_errors($git, $id, $msg) +
        title_errors($git, $id, $cmsg->title) +
        body_errors($git, $id, $cmsg->body) +
        footer_errors($git, $id, $cmsg);
}

sub check_message_file {
    my ($git, $commit_msg_file) = @_;

    _setup_config($git);

    my $current_branch = $git->get_current_branch();
    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($current_branch, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($current_branch, @noref);
    }

    my $msg = eval {$git->read_commit_msg_file($commit_msg_file)};

    unless (defined $msg) {
        $git->fault(<<EOS, {details => $@});
I cannot read the commit message file '$commit_msg_file'.
EOS
        return 0;
    }

    return message_errors($git, undef, $msg) == 0;
}

sub check_ref {
    my ($git, $ref) = @_;

    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($ref, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($ref, @noref);
    }

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        $errors += message_errors($git, $commit, $commit->message);
    }

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref)
            or ++$errors;
    }

    return $errors == 0;
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    return 1 if $git->im_admin();

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    # The --branch argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $branch = $opts->{'--branch'};
    $branch = "refs/heads/$branch"
        unless $branch =~ m:^refs/:;

    if (my @ref = $git->get_config($CFG => 'ref')) {
        return 1 unless $git->is_ref_enabled($branch, @ref);
    }
    if (my @noref = $git->get_config($CFG => 'noref')) {
        return 0 if $git->is_ref_enabled($branch, @noref);
    }

    return message_errors($git, $commit, $commit->message) == 0;
}

INIT: {
    # Install hooks
    APPLYPATCH_MSG   \&check_message_file;
    COMMIT_MSG       \&check_message_file;
    UPDATE           \&check_affected_refs;
    PRE_RECEIVE      \&check_affected_refs;
    REF_UPDATE       \&check_affected_refs;
    PATCHSET_CREATED \&check_patchset;
    DRAFT_PUBLISHED  \&check_patchset;
}

1;


__END__
=for Pod::Coverage spelling_errors pattern_errors revert_errors title_errors body_errors footer_errors message_errors check_ref check_affected_refs check_message_file check_patchset

=head1 NAME

Git::Hooks::CheckLog - Git::Hooks plugin to enforce commit log policies

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]
    plugin = CheckLog
    admin = joe molly

  [githooks "checklog"]
    title-max-width = 60
    title-period = deny
    body-max-width = 80
    spelling = true
    spelling-lang = pt_BR
    deny-merge-revert = true

The first section enables the plugin and defines the users C<joe> and C<molly>
as administrators, effectivelly exempting them from any restrictions the plugin
may impose.

The second instance enables C<some> of the options specific to this plugin.

The C<title-max-width> and the C<body-max-width> options specify the maxmimum
width allowed for the lines in the commit message's title and body,
respectively. Note that indented lines in the body aren't checked against this
limit.

The C<title-period> option denies commits which message title ends in a
period. This is a commom practice among the most mature Git projects out there.

The C<spelling> and C<spelling-lang> options spell checks the commit message
expecting it to be in Brazilian Portuguese.

The C<deny-merge-revert> option denies commits which messages contain the string
"This reverts commit <SHA-1>", if SHA-1 refers to a merge commit. Reverting a
merge commit has unexpected consequences, so that it's better to avoid it if at
all possible.

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to enforce
policies on the commit log messages.

=over

=item * B<commit-msg>, B<applypatch-msg>

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

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review, to check if the commit log messages of all commits being
pushed comply.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*), to check if the commit log
messages of all commits being pushed comply.

=back

Projects using Git, probably more than projects using any other
version control system, have a tradition of establishing policies on
the format of commit log messages. The REFERENCES section below lists
some of the most important.

This plugin allows one to enforce most of the established policies. The
default configuration already enforces the most common one.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckLog

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checklog.ref REFSPEC

By default, the message of every commit is checked. If you want to
have them checked only for some refs (usually some branch under
refs/heads/), you may specify them with one or more instances of this
option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 githooks.checklog.noref REFSPEC

By default, the message of every commit is checked. If you want to exclude
some refs (usually some branch under refs/heads/), you may specify them with
one or more instances of this option.

The refs can be specified as in the same way as to the C<ref> option above.

Note that the C<ref> option has precedence over the C<noref> option, i.e.,
if a reference matches both options it will be checked.

=head2 githooks.checklog.title-required BOOL

The first line of a Git commit log message is usually called the
'title'. It must be separated by the rest of the message (it's 'body')
by one empty line. This option, which is true by default, makes the
plugin check if there is a proper title in the log message.

=head2 githooks.checklog.title-max-width INT

This option specifies a limit to the width of the title's in
characters. It's 50 by default. If you set it to 0 the plugin imposes
no limit on the title's width.

=head2 githooks.checklog.title-period [deny|allow|require]

This option defines the policy regarding the title's ending in a
period ('.'). It can take three values:

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

=head2 githooks.checklog.title-match [!]REGEXP

This option may be specified more than once. It defines a list of regular
expressions that will be matched against the title.  If the '!' prefix is used,
the title must not match the REGEXPs. Otherwise, the log must match REGEXPs.

This allows you, for example, to require that the title starts with a capital
letter:

  [githooks "checklog"]
    title-match = ^[A-Z]

=head2 githooks.checklog.body-max-width INT

This option specifies a limit to the width of the commit log message's
body lines, in characters. It's 72 by default. If you set it to 0 the
plugin imposes no limit on the body line's width.

Only lines starting with a non-whitespace character are checked against the
limit. It's a common style to quote things with indented lines and we like
to make those lines free of any restriction in order to keep the quoted text
authentic.

=head2 githooks.checklog.match [!]REGEXP

This option may be specified more than once. It defines a list of
regular expressions that will be matched against the commit log
messages. If the '!' prefix is used, the log must not match the
REGEXPs. Otherwise, the log must match REGEXPs.

The REGEXPs are matched with the C</m> modifier so that the C<^> and the C<$>
metacharacters, if used, match the beginning and end of each line in the log,
respectively.

This allows you, for example, to disallow hard-tabs in your log messages:

  [githooks "checklog"]
    match = !\\t

=head2 githooks.checklog.spelling BOOL

This option makes the plugin spell check the commit log message using
C<Text::SpellChecker>. Any spelling error will cause the commit or push to
abort.

Note that C<Text::SpellChecker> isn't required to install
C<Git::Hooks>. So, you may see errors when you enable this
check. Please, refer to the module's own documentation to see how to
install it and its own dependencies (which are C<Text::Hunspell> or
C<Text::Aspell>).

=head2 githooks.checklog.spelling-lang ISOCODE

The Text::SpellChecker module uses defaults to infer which language it
must use to spell check the message. You can make it use a particular
language passing its ISO code to this option.

=head2 githooks.checklog.signed-off-by BOOL

This option requires the commit to have at least one C<Signed-off-by>
footer.

Despite of the value of this option, the plugin checks and complains if there
are duplicate C<Signed-off-by> footers in the commit.

=head2 githooks.checklog.deny-merge-revert BOOL

This boolean option allows you to deny commits that revert merge commits, since
such beasts introduce complications in the repository which you may want to
avoid. (To know more about this you should read Linus Torvald's L<How to revert
a faulty
merge|https://github.com/git/git/blob/master/Documentation/howto/revert-a-faulty-merge.txt>.)

The option is false by default, allowing such reverts.

Note that a revert is detected by the fact that Git introduces a standard
sentence in the commit's message, like this:

  This reverts commit 3114a008dc474f098babf2e22d444c82c6496c23.

If the committer removes or changes this line during the commit the hook won't
be able to detect it.

Note also that the C<git-revert> command, which creates the reverting commits
doesn't invoke the C<commit-msg> hook, so that this check can't be performed at
commit time. The checking will be performed at push time by a C<pre-receive> or
C<update> hook though.

=head1 REFERENCES

=over

=item * B<git-commit(1) Manual Page>

This L<Git manual
page|http://www.kernel.org/pub/software/scm/git/docs/git-commit.html> has a
section called DISCUSSION which discusses some common log message policies.

=item * B<Linus Torvalds GitHub rant>

In L<this
note|https://github.com/torvalds/linux/pull/17#issuecomment-5659933>,
Linus says why he dislikes GitHub's pull request interface, mainly
because it doesn't allow him to enforce log message formatting
policies.

=item * B<MediaWiki Git/Commit message guidelines>

L<This
document|http://www.mediawiki.org/wiki/Git/Commit_message_guidelines>
defines MediaWiki's project commit log message guidelines.

=item * B<Proper Git Commit Messages and an Elegant Git History>

L<This is a good
discussion|http://ablogaboutcode.com/2011/03/23/proper-git-commit-messages-and-an-elegant-git-history/>
about commit log message formatting and the reasons behind them.

=item * B<GIT Commit Good Practice>

L<This document|https://wiki.openstack.org/wiki/GitCommitMessages>
defines the OpenStack's project commit policies.

=item * B<A Note About Git Commit Messages>

This L<blog
post|http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html>
argues briefly and convincingly for the use of a particular format for Git
commit messages.

=item * B<Git Commit Messages: 50/72 Formatting>

This L<StackOverflow
question|http://stackoverflow.com/questions/2290016/git-commit-messages-50-72-formatting>
has a good discussion about the topic.

=item * B<What do you try to leave in your commit messages?>

A blog post from Kohsuke Kawaguchi, Jenkins's author, explaining what
information he usually includes in his commit messages and why.

=item * B<How to revert a faulty merge>

This
L<message|https://github.com/git/git/blob/master/Documentation/howto/revert-a-faulty-merge.txt>,
from Linus Torvald's himself, explains why reverting a merge commit is
problematic and how to deal with it.

=back
