#!/usr/bin/env perl

package Git::Hooks::Notify;
# ABSTRACT: Git::Hooks plugin to notify users via email

use 5.010;
use utf8;
use strict;
use warnings;
use Carp;
use Git::Hooks;
use Git::Repository::Log;
use Set::Scalar;
use List::MoreUtils qw/any/;
use Try::Tiny;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

sub ref_changes {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    my @files = $git->filter_files_in_range('AM', $old_commit, $new_commit);

    my $format = $git->get_config($CFG, 'format') || 'short';

    my $max_count = $git->get_config($CFG, 'max-count') || '10';

    # Treat specially if the reference is new
    my $range = $old_commit eq $git->undef_commit
        ? $new_commit
        : "$old_commit..$new_commit";

    my @cmd = ('log', '--numstat', '--first-parent', "--format=$format",
               "--max-count=$max_count", $range);

    my $log =
        "# Changed branch $ref\n\n" .
        "# git " . join(' ', @cmd), "\n\n" .
        $git->run(@cmd) . "\n\n";

    if (my $commit_url = $git->get_config($CFG, 'commit-url')) {
        my $replace_commit = sub {
            my ($sha1) = @_;
            my $pattern = $commit_url;
            $pattern =~ s/%H/$sha1/e;
            return $pattern;
        };
        $log =~ s/\b[0-9a-f]{40}\b/$replace_commit->($&)/eg;
    }

    return ($log, \@files);
}

sub get_transport {
    my ($git) = @_;

    my $transport = $git->get_config($CFG, 'transport');

    return unless $transport;

    croak "Unknown $PKG transport '$transport'" unless $transport eq 'smtp';

    my %args;

    for my $option (qw/host ssl port timeout sasl-username sasl-password debug/) {
        if (my $value = $git->get_config($CFG, "smtp-$option")) {
            # Replace hyphens by underslines on the two "sasl-" options
            my $name = $option;
            $name =~ s/sasl-/sasl_/;
            $args{$name} = $value;
        }
    }

    require Email::Sender::Transport::SMTP;

    return { transport => Email::Sender::Transport::SMTP->new(\%args) };
}

sub notify {
    my ($git, $recipients, $body) = @_;

    return 1 unless @$recipients;

    my @headers = (
        'Subject'      => $git->get_config($CFG => 'subject') || '[Git::Hooks::Notify]',
        'To'           => join(', ', @$recipients),
        'MIME-Version' => '1.0',
        'Content-Type' => 'text/plain',
    );

    if (my $from = $git->get_config($CFG, 'from')) {
        push @headers, (From => $from);
    }

    require Email::Sender::Simple;
    require Email::Simple;

    my $preamble = $git->get_config($CFG, 'preamble') || <<'EOF';
You're receiving this automatic notification because commits were pushed to a
Git repository you're watching.

EOF

    my $email = Email::Simple->create(
        header => \@headers,
        body   => $preamble . $body,
    );

    my $transport = get_transport($git);

    return Email::Sender::Simple->sendmail($email, $transport);
}

sub grok_include_rules {
    my ($git) = @_;

    my @includes = $git->get_config($CFG, 'include');

    my @rules;
    foreach my $include (@includes) {
        my @recipients = split / /, $include;
        next unless @recipients;
        my ($match_ref, $match_file);
        if ($recipients[0] =~ /:/) {
            my $match = shift @recipients;
            next unless @recipients;
            my @match = split /:/, $match;
            $match_ref = qr/$match[0]/
                if defined $match[0] && length $match[0] && $match[0] =~ /^^/;
            $match_file = qr/$match[1]/
                if defined $match[1] && length $match[1] && $match[1] =~ /^^/;
        }
        push @rules, [[$match_ref, $match_file], \@recipients];
    }

    return @rules;
}

# This routine can act as a post-receive hook.
sub notify_affected_refs {
    my ($git) = @_;

    my @rules = grok_include_rules($git);

    return 1 unless @rules;

    my $errors = 0;

    foreach my $branch (grep {m:^refs/heads/:} $git->get_affected_refs()) {
        my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
        my @files = $git->filter_files_in_range('AM', $old_commit, $new_commit);
        next unless @files;

      RULE:
        foreach my $rule (@rules) {
            my $log;
            my ($match_branch, $match_file) = @{$rule->[0]};
            if (defined $match_branch) {
                if (ref $match_branch) {
                    next RULE unless $branch =~ $match_branch;
                } else {
                    next RULE unless $branch eq $match_branch;
                }
            }
            if (defined $match_file) {
                my @matching_files = 
                if (ref $match_file) {
                    next RULE unless any { $_ =~ $match_file } @$files;
                } else {
                    next RULE unless any { $_ eq $match_file } @$files;
                }
                $log = gitlog($git, $ref, $old_commit, $new_commit, )
            }

            try {
                notify($git, $rule->[1], $body);
            } catch {
                my $error = $_;
                $git->error($PKG, 'Could not send mail to the following recipients: '
                                . join(", ", @{$error->recipients}) . "\n"
                                . 'Error message: ' . $error->message . "\n");
                ++$errors;
            };
        }
    }

    return $errors == 0;
}

# Install hooks
POST_RECEIVE \&notify_affected_refs;

1;


__END__
=for Pod::Coverage get_transport grok_include_rules notify notify_affected_refs ref_changes

=head1 NAME

Notify - Git::Hooks plugin to notify users via email

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to notify users via
email about pushed commits affecting specific files and/or references.

=over

=item * B<post-receive>

This hook is invoked once in the remote repository after a successful C<git
push>. It's used to notify JIRA of commits citing its issues via comments.

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin Notify

The email notification is sent in text mode with configurable C<Subject> and
C<From> headers. The body of the message contains a section for each branch
affected by the git-push command. Each section contains the result of a C<git
log> command showing the pushed commits and the list of files affected by
them. For example:

  Subject: [Git::Hooks::Notify]

  Changed branch refs/heads/master

  git log --numstat --first-parent --format=short --max-count=10 c45feb16fe3e6fc105414e60e91ffb031c134cd4..6eaa6a84fbd7e2a64e66664f3d58707618e20c72

  commit 6eaa6a84fbd7e2a64e66664f3d58707618e20c72 (HEAD -> notify)
  Author: Gustavo L. de M. Chaves <gnustavo@cpan.org>

      Add plugin Git::Hooks::Notify

  305     0       lib/Git/Hooks/Notify.pm
  63      0       t/02-notify.t

  commit b0a820600bb093afeafa547cbf39c468380e41af (tag: v2.1.8, origin/next, next)
  Author: Gustavo L. de M. Chaves <gnustavo@cpan.org>

      v2.1.8

  9       0       Changes

  commit c45feb16fe3e6fc105414e60e91ffb031c134cd4
  Author: Gustavo L. de M. Chaves <gnustavo@cpan.org>

      CheckJira: JQL options are scalar, not multi-valued

  40      32      lib/Git/Hooks/CheckJira.pm
  12      12      t/02-check-jira.t

You can change the C<git log> format and a few other things in the message using
the configuration options explained below.

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.notify.transport TRANSPORT

By default the messages are sent using L<Email::Simple>'s default transport. On
Unix systems, it is usually the C<sendmail> command. You can specify another
transport using this configuration. For now, the only explicitly supported
transport is C<smtp>, which uses the L<Email::Sender::Transport::SMTP> module.

=head2 githooks.notify.smtp-host HOST

Specify the name of the host to connect to; defaults to C<localhost>.

=head2 githooks.notify.smtp-ssl [starttls|ssl]

If 'starttls', use STARTTLS; if 'ssl' (or 1), connect securely; otherwise, no
security.

=head2 githooks.notify.smtp-port PORT

Port to connect to; defaults to 25 for non-SSL, 465 for 'ssl', 587 for
'starttls'.

=head2 githooks.notify.smtp-timeout NUM

Maximum time in seconds to wait for server; default is 120.

=head2 githooks.notify.smtp-debug [01]

If true, puts the L<Net::SMTP> object in debug mode.

=head2 githooks.notify.include [[REF]:[FILE]] RECIPIENTS

The B<include> directive includes a notification rule specifying which
RECIPIENTS should be notified of pushed commits affecting the REF:FILE filter.

The REF:FILE filters commits like this:

=over

=item * I<empty>

If there is no REF:FILE filter, all pushes send notifications.

=item * B<BRANCH:>

A branch can be specified by its name (e.g. "master") or by a regular expression
starting with a caret (C<^>), which is kept as part of the regexp
(e.g. "^(master|fix)"). Note that only branch changes are notified, i.e.,
references under C<refs/heads/>. Tags and other references aren't considered.

Only pushes affecting matching branches are notified.

=item * B<:FILE>

A file can be specified as a complete file name (e.g. "lib/Hooks.pm") or by a
regular expression starting with a caret (C<^>), which is kept as part of the
regexp (e.g. "^.*\.pm").

Only pushes affecting matching files are notified.

=item * B<BRANCH:FILE>

You may filter by branch and by file simultaneously.

=back

The RECIPIENTS is a comma-separated list of email addresses.

=head2 githooks.notify.from SENDER

This allows you to specify a sender address to be used in the notification's
C<To> header. If you don't specify it, the sender will probably be the user
running your hooks. But you shouldn't count on it. It's better to specify it
with a valid email address that your users can reply to. Something like this:

  [githooks "notify"]
    from = "Git::Hooks" <git@yourdomain.com>

=head2 githooks.notify.subject SUBJECT

This allows you to specify the subject of the notification emails. If you don't
specify it, the default is like this:

  Subject: [Git::Hooks::Notify]

=head2 githooks.notify.preamble TEXT

This allows you to specify a preamble for the notification emails. If you don't
specify it, the default is like this:

  You're receiving this automatic notification because commits were pushed to a
  Git repository you're watching.

=head2 githooks.notify.format [short|medium|full|fuller]

This allows you to specify which git-log format you want to be shown in the
notifications. Read about the --format option in C<git help log>. If not
specified, the C<short> format is used.

=head2 githooks.notify.max-count NUM

This allows you to specify the limit of commits that should be shown for each
changed branch. Read about the --max-count option in C<git help log>. If not
specified, a limit of 10 is used.

=head2 githooks.notify.commit-url URL_PATTERN

If your Git repository has a web interface it's useful to provide links to the
commits shown in the notification message. If configured, each SHA1 contained in
the C<git-log> output is substituted by C<URL_PATTERN>, with the C<%H>
placeholder replaced by the SHA1.

See below how to configure this for some common Git servers. Replace the
angle-bracketed names with values appropriate to your context:

=over

=item * GitHub

  https://github.com/<USER>/<REPO>/commit/%H

=item * Bitbucket Cloud

  https://bitbucket.org/<USER>/<REPO>/commits/%H

=item * Bitbucket Server

  <BITBUCKET_BASE_URL>/projects/<PROJECTID>/repos/<REPOID>/commits/%H

=item * Gerrit with Gitblit

  <GERRIT_BASE_URL>/plugins/gitblit/commit/?r=<REPO>&h=%H

=back

=head1 TO DO

These are just a few of the ideas for improving this plugin.

=over

=item * Send well-formatted HTML messages.

=item * Generalize the C<commit-url> template.

It should support other placeholders for the Git server's base URL, repository
name, user name, etc. So that we could configure a single template for all
repositories in a server. Currently one has to configure a different commit-url
for each repository.

=item * Send notifications on Gerrit's change-merged hook.

=back

=head1 SEE ALSO

=over

=item * L<Email::Sender::Simple>

=item * L<Email::Sender::Transport::SMTP>

=back
