use warnings;

package Git::Hooks::CheckLog;
# ABSTRACT: Git::Hooks plugin to enforce commit log policies

use 5.016;
use utf8;
use Log::Any '$log';
use Git::Hooks;
use Git::Message;
use List::MoreUtils qw/uniq/;

my $CFG = __PACKAGE__ =~ s/.*::/githooks./r;

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
            $git->fault(<<'EOS', {option => 'spelling', details => $@});
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

        unless (defined eval { $checker->next_word(); }) {
            $git->fault(<<'EOS', {option => 'spelling', details => $@});
There was an error while I tried to spell check your commits using the
Text::SpellChecker module. If you cannot fix it consider disabling this
your configuration option.
EOS
            return;
        }

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
            # Get the reverted commit in an eval because it may be unreachable
            # now. In this case we simply don't care anymore.
            if (my $reverted_commit = eval {$git->get_commit($1)}) {
                if ($reverted_commit->parent() > 1) {
                    $git->fault(<<'EOS', {commit => $id, option => 'deny-merge-revert'});
This commit reverts a merge commit, which is not allowed
by your configuration option.
EOS
                    return 1;
                }
            }
        }
    }

    return 0;
}

sub title_errors {
    my ($git, $id, $title) = @_;

    unless (defined $title and length $title) {
        if ($git->get_config_boolean($CFG => 'title-required')) {
            $git->fault(<<'EOS', {commit => $id, option => 'title-required'});
This commit log message needs a title line.
This is required by your configuration option.
Please, amend your commit to add one.
EOS
            return 1;
        } else {
            return 0;
        }
    }

    ($title =~ tr/\n/\n/) == 1
        or $git->fault(<<'EOS', {commit => $id})
This commit log message title must have just one line.
Please amend your commit and edit its log message so that its first line
is separated from the rest by an empty line.
EOS
            and return 1;

    my $errors = 0;

    if (my $max_width = $git->get_config_integer($CFG => 'title-max-width')) {
        my $tlen = length($title) - 1; # discount the newline
        $tlen <= $max_width
            or $git->fault(<<"EOS", {commit => $id, option => 'title-max-width'})
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
                or $git->fault(<<'EOS', {commit => $id, option => 'title-period'})
This commit log message title SHOULD NOT end in a period.
This is required by your configuration option.
Please, amend your commit to remove the period.
EOS
                    and ++$errors;
        } elsif ($period eq 'require') {
            $title =~ /\.$/
                or $git->fault(<<'EOS', {commit => $id, option => 'title-period'})
This commit log message title SHOULD end in a period.
This is required by your configuration option.
Please, amend your commit to add the period.
EOS
                    and ++$errors;
        } elsif ($period ne 'allow') {
            $git->fault(<<"EOS", {commit => $id, option => 'title-period'})
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
            $git->fault(<<"EOS", {commit => $id, option => 'body-max-width', details => join("\n", @biggies)});
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
            $git->fault(<<'EOS', {commit => $id, details => join("\n", sort @duplicates)});
This commit have duplicate Signed-off-by footers.
Please, amend it to remove the duplicates:
EOS
            ++$errors;
        }
    } elsif ($git->get_config_boolean($CFG => 'signed-off-by')) {
        $git->fault(<<'EOS', {commit => $id, option => 'signed-off-by'});
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
    my ($git, $msg) = @_;

    return message_errors($git, undef, $msg);
}

sub check_ref {
    my ($git, $ref) = @_;

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        $errors += message_errors($git, $commit, $commit->message);
    }

    return $errors;
}

sub check_patchset {
    my ($git, $branch, $commit) = @_;

    return message_errors($git, $commit, $commit->message);
}

# Install hooks
my $options = {config => \&_setup_config};

GITHOOKS_CHECK_AFFECTED_REFS \&check_ref,          $options;
GITHOOKS_CHECK_PATCHSET      \&check_patchset,     $options;
GITHOOKS_CHECK_MESSAGE_FILE  \&check_message_file, $options;

1;


__END__
=for Pod::Coverage spelling_errors pattern_errors revert_errors title_errors body_errors footer_errors message_errors check_ref check_message_file check_patchset

=head1 NAME

Git::Hooks::CheckLog - Git::Hooks plugin to enforce commit log policies

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckLog

    # These users are exempt from all checks
    admin = joe molly

  [githooks "checklog"]

    # The title line of commit messages must have at most 60 characters.
    title-max-width = 60

    # The title line of commit messages must not end in a period.
    title-period = deny

    # The lines in the body of commit messages must have at most 80 characters.
    body-max-width = 80

    # Enable spell checking of the commit messages.
    spelling = true

    # Use Brazilian Portuguese dictionary for spell checking
    spelling-lang = pt_BR

    # Rejects commits with messages containing the string "This reverts commit
    # <SHA-1>", if SHA-1 refers to a merge commit. Reverting a merge commit has
    # unexpected consequences, so that it's better to avoid it if at all
    # possible.
    deny-merge-revert = true

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

This hook is invoked when a direct push request is received by Gerrit Code
Review, to check if the commit log messages of all commits being pushed comply.

=item * B<commit-received>

This hook is invoked when a push request is received by Gerrit Code Review to
create a change for review, to check if the commit log messages of all commits
being pushed comply.

=item * B<submit>

This hook is invoked when a change is submitted in Gerrit Code Review, to check
if the commit log messages of all commits being pushed comply.

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
default configuration already enforces the most common ones.

To enable it you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckLog

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checklog> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 title-required BOOL

The first line of a Git commit log message is usually called the
'title'. It must be separated by the rest of the message (it's 'body')
by one empty line. This option, which is true by default, makes the
plugin check if there is a proper title in the log message.

=head2 title-max-width INT

This option specifies a limit to the width of the title's in
characters. It's 50 by default. If you set it to 0 the plugin imposes
no limit on the title's width.

=head2 title-period [deny|allow|require]

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

=head2 title-match [!]REGEXP

This option may be specified more than once. It defines a list of regular
expressions that will be matched against the title.  If the '!' prefix is used,
the title must not match the REGEXPs. Otherwise, the log must match REGEXPs.

This allows you, for example, to require that the title starts with a capital
letter:

  [githooks "checklog"]
    title-match = ^[A-Z]

=head2 body-max-width INT

This option specifies a limit to the width of the commit log message's
body lines, in characters. It's 72 by default. If you set it to 0 the
plugin imposes no limit on the body line's width.

Only lines starting with a non-whitespace character are checked against the
limit. It's a common style to quote things with indented lines and we like
to make those lines free of any restriction in order to keep the quoted text
authentic.

=head2 match [!]REGEXP

This option may be specified more than once. It defines a list of
regular expressions that will be matched against the commit log
messages. If the '!' prefix is used, the log must not match the
REGEXPs. Otherwise, the log must match REGEXPs.

The REGEXPs are matched with the C</m> modifier so that the C<^> and the C<$>
meta-characters, if used, match the beginning and end of each line in the log,
respectively.

This allows you, for example, to disallow hard-tabs in your log messages:

  [githooks "checklog"]
    match = !\\t

=head2 spelling BOOL

This option makes the plugin spell check the commit log message using
C<Text::SpellChecker>. Any spelling error will cause the commit or push to
abort.

Note that C<Text::SpellChecker> isn't required to install
C<Git::Hooks>. So, you may see errors when you enable this
check. Please, refer to the module's own documentation to see how to
install it and its own dependencies (which are C<Text::Hunspell> or
C<Text::Aspell>).

=head2 spelling-lang ISOCODE

The Text::SpellChecker module uses defaults to infer which language it
must use to spell check the message. You can make it use a particular
language passing its ISO code to this option.

=head2 signed-off-by BOOL

This option requires the commit to have at least one C<Signed-off-by>
footer.

Despite of the value of this option, the plugin checks and complains if there
are duplicate C<Signed-off-by> footers in the commit.

=head2 deny-merge-revert BOOL

This Boolean option allows you to deny commits that revert merge commits, since
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
