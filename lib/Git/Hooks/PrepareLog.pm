#!/usr/bin/env perl

package Git::Hooks::PrepareLog;
# ABSTRACT: Git::Hooks plugin to prepare commit messages before being edited

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks;
use Path::Tiny;
use Carp;

(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};
    $default->{'issue-place'} //= ['title [%I] %T'];

    return;
}

##########

sub insert_issue_in_title {
    my ($git, $msg_file, $issue, $format) = @_;

    my $encoding = $git->get_config(i18n => 'commitEncoding') || 'utf-8';
    my @lines = path($msg_file)->lines({binmode => ":encoding($encoding)"});
    # The message title is the first line after comments
    foreach (@lines) {
        next if /^\s*#/;
        $format =~ s/\%T/$_/;
        $format =~ s/\%I/$issue/;
        $_ = $format . "\n";
        last;
    }
    path($msg_file)->spew({binmode => ":encoding($encoding)"}, @lines);

    return;
}

sub insert_issue_as_trailer {
    my ($git, $msg_file, $issue, $key) = @_;

    if ($git->version_ge('2.8.0')) {
        # The interpret-trailers was implemented on Git 2.1.0 and its --in-place
        # option only on Git 2.8.0.
        $key = ucfirst lc $key;
        $git->run(qw/interpret-trailers --in-place --trailer/, "$key:$issue", $msg_file);
    } else {
        $git->fault(<<EOS);
The $CFG.issue-place option 'trailer' setting requires Git 2.8.0 or newer.
Please, either upgrade your Git or disable this option.
EOS
    }

    return;
}

sub insert_issue {
    my ($git, $msg_file) = @_;

    # Continue only if we have a pattern to match against branches
    my $issue_branch_regex = $git->get_config($CFG => 'issue-branch-regex')
        or return 0;

    my $branch_rx = eval { qr:(?p)\brefs/heads/\K$issue_branch_regex\b: };
    unless (defined $branch_rx) {
        $git->fault(<<EOS, {details => $@});
Configuration error: the $CFG.issue_branch_regex option must be a
valid regular expression, but '$issue_branch_regex' isn't.
Please, fix your configuration and try again.
EOS
        return 1;
    }

    # Continue only if we are in a named branch
    my $branch = $git->get_current_branch
        or return 0;

    # Try to grok the issue id from the current branch name. Do not continue if
    # we cannot grok it.
    my $issue = $branch =~ $branch_rx ? $1 || ${^MATCH} : undef;
    return 0 unless defined $issue and length $issue;

    my $place = $git->get_config($CFG => 'issue-place');
    if ($place =~ /^trailer\s+(?<key>[A-Za-z]+)\b/) {
        insert_issue_as_trailer($git, $msg_file, $issue, $+{key});
    } elsif ($place =~ /^title\s+(?<format>.+?)\s*$/) {
        insert_issue_in_title($git, $msg_file, $issue, $+{format});
    } else {
        $git->fault(<<EOS);
Configuration error: invalid value to option $CFG.issue-place ($place)
Please, fix it and try again.
EOS
        return 1;
    }

    return 0;
}

sub prepare_message {
    my ($git, $msg_file, $source, $sha1) = @_;

    # Do not mess up with messages if there is already a previous source for it.
    return 0 if defined $source;

    _setup_config($git);

    my $errors = 0;

    $errors += insert_issue($git, $msg_file);

    return $errors;
}

INIT: {
    # Install hooks
    PREPARE_COMMIT_MSG \&prepare_message;
}

1;


__END__
=for Pod::Coverage insert_issue_in_title insert_issue_as_trailer insert_issue prepare_message

=head1 NAME

Git::Hooks::PrepareLog - Git::Hooks plugin to prepare commit log messages before
being edited

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]
    plugin = PrepareLog

  [githooks "preparelog"]
    issue-branch-regex = [A-Z]+-\\d+
    issue-place = key Jira

The first section enables the plugin.

The second section makes the message include an issue ID grokked by the current
branch name. If the current branch matches the C<issue-branch-regex> option it's
name will be used as the issue ID. In this case, it matches a
L<JIRA|https://www.atlassian.com/software/jira> ID. The C<issue-place> option
specifies that the JIRA ID should be inserted as a message trailer, keyed by
"JIRA". For example:

  Jira: PRJ-123

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the C<prepare-commit-msg>. It's
invoked during a Git commit in order to prepare the commit log message before
invoking the editor. It should be used to pre-format or to insert automatic
information in the message before the user is given a chance to edit it. If you
want to check problems in the message you should use the L<Git::Hooks::CheckLog>
plugin instead.

The C<prepare-commit-msg> is invoked in every commit, but the plugin only
changes the message if it's a new commit and not if it's the result of an amend,
a merge, or if the message is provided via the C<-m> or the C<-F> options,
because it assumes that preexisting messages shouldn't be re-prepared. Hence,
the plugin simply skips these types of commits.

Even though it's not intended to "check" the message it's possible that the
plugin encounters a few problems. In these situations it will abort the commit
with a suitable message.

To enable the plugin you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin PrepareLog

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.preparelog.issue-branch-regex REGEX

This option enables the issue inserting feature, which inserts an issue ID (aka
bug-id) in the message, making the commit refer to the project issue which
required the change made by the commit. It's very common, in large or enterprise
projects, to require that every commit cites at least one issue in the project's
issue management system. In fact, the L<Git::Hooks::CheckJira> plugin is used to
require the citation of JIRA issues in commit messages.

It's cumbersome for the developer to have to insert issue IDs for every commit
message. In order to make it automatic, as a developer, you enable this plugin
and configures this option to match the syntax of your issue IDs. Then, when you
start to work on a new issue, you should create a local branch named after the
issue ID and let this plugin insert it into your commit messages for you.

If you're using JIRA, for example, the issue IDs are strings like C<PRJ-123> and
C<HD-1000>. In this case, you can configure it like this:

  [githooks "preparelog"]
    issue-branch-regex = [A-Z]+-\\d+

The regex provided does not need to match the whole current branch name, only a
word inside it.

If your issue ID is very simple, such as a number, you can capture it with a
group in the regex. Like this:

  [githooks "preparelog"]
    issue-branch-regex = issue-(\\d+)

In this case you should name your branches as C<issue-NNN> and the plugin will
understand that the issue ID is just what matched the first group in the regex.

If your branch does not match the regex, the plugin will not prepare the log
message.

=head2 githooks.preparelog.issue-place SPEC

This options specifies where in the log message the issue ID should be
inserted. For now there are two possibilities which you may specify with SPECs
like this:

=over 4

=item B<title FORMAT>

This makes the issue ID be inserted in the log message's title, i.e., in its
first line. The FORMAT specifies how the title should be changed in order to
incorporate the issue ID. It's a string which should contain two format codes:
C<%T> and C<%I>. The C<%T> code is replaced by the original title, if any. And
the C<%I> code is replaced by the issue ID.

The default value of this option is C<title [%I] %T>, which makes the issue ID
be prefixed to the title, enclosed in brackets.

Other common formats are these:

=over 4

=item C<%I: %T>

Prefix the issue ID, separating it by a colon and a space.

=item C<%T (%I)>

Suffix the issue ID, enclosing it in parenthesis.

=back

=item B<trailer KEY>

Inserting the issue ID in the title makes it stand out, but it can make the
title very wide and distract from its main purpose which is to tell succinctly
what the commit does. In fact, if you are using L<Git::Hooks::CheckLog> plugin
to limit the log message title's width the insertion of issue IDs in it can make
you overflow that limit often.

You can insert the issue ID as a trailer to the log message instead, in order to
solve these problems. You must simply choose a KEY for the trailer. If you're
using JIRA you can use C<Jira> as the key. Other generic common choices are
C<Issue> and C<Bug>. In this case, your issue ID will appear at the end of the
log message, something like this:

  Jira: PRJ-123

The key is always capitalized, so that in this case it will be C<Jira> even if
you specified C<JIRA> or C<jira> in the format.

Note that this format only works with Git 2.7.0 and later, because we rely on
the L<git interpret-trailers|https://git-scm.com/docs/git-interpret-trailers>
command with the C<--in-place> option, which was implemented in that Git
version. If you're using an older Git an error message will tell you that.

=back

=head1 REFERENCES

=over

=item * L<git interpret-trailers|https://git-scm.com/docs/git-interpret-trailers>

Git command used to insert trailers in the commit log messages.

=back
