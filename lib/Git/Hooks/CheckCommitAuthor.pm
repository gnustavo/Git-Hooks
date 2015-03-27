## no critic (Modules::RequireVersionVar)
package Git::Hooks::CheckCommitAuthor;
# ABSTRACT: Git::Hooks plugin to enforce commit author policies

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Carp;
use File::Slurp::Tiny 'read_file';
require Git::Mailmap;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./msx;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    # TODO Global flag: use-extended-regexp

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};
    $default->{'match-mailmap-name'}  //= ['1'];
    $default->{'allow-mailmap-aliases'} //= ['1'];
    # $default->{'body-max-width'}  //= [72];

    return;
}

##########

sub check_author {
    my ($git) = @_;

    _setup_config($git);

    return 1 if im_admin($git);

    my $author_name   = $ENV{'GIT_AUTHOR_NAME'};
    my $author_email  = '<' . $ENV{'GIT_AUTHOR_EMAIL'} . '>';

    my $errors = 0;
    check_patterns($git, $author_name, $author_email) or ++$errors;
    check_mailmap($git, $author_name, $author_email) or ++$errors;
    check_git_user($git, $author_name, $author_email) or ++$errors;

    return $errors == 0;
}

sub check_patterns {
    my ($git, $author_name, $author_email) = @_;

    my $errors = 0;

    my $author = "$author_name $author_email";
    foreach my $match ($git->get_config($CFG => 'match')) {
        if ($match =~ s/^![[:space:]]*//msx) {
            ## no critic (RegularExpressions::RequireExtendedFormatting)
            $author !~ /$match/ms
                or $git->error($PKG, 'commit author '
                . "'\Q$author_name $author_email\Q' SHOULD NOT match '\Q$match\E'")
                    and ++$errors;
        } else {
            ## no critic (RegularExpressions::RequireExtendedFormatting)
            $author =~ /$match/ms
                or $git->error($PKG, 'commit author '
                . "'\Q$author_name $author_email\Q' SHOULD match '\Q$match\E'")
                    and ++$errors;
        }
    }

    return $errors == 0;
}

sub check_mailmap {
    my ($git, $author_name, $author_email) = @_;

    my $errors = 0;

    my $author = "$author_name $author_email";
    my ($mapfile_location) = $git->get_config($CFG => 'mailmap');
    my $mailmap_as_string;
    return 1 if(!defined $mapfile_location);

    if($mapfile_location eq '1') {
        croak 'This option is not yet implemented.';
    }
    else {
        $mailmap_as_string = read_file($mapfile_location);
    }
    my $mailmap = Git::Mailmap->new();
    $mailmap->from_string( 'mailmap' => $mailmap_as_string );
    my $verified = 0;
    # Always search (first) among proper emails (and names if wanted).
    my %search_params = ('proper-email' => $author_email);
    if($git->get_config($CFG => 'match-mailmap-name') eq '1') {
        $search_params{'proper-name'} = $author_name;
    }
    $verified = $mailmap->search(%search_params);
    # If was not found among proper-*, and user wants, search aliases.
    if( !$verified && $git->get_config($CFG => 'allow-mailmap-aliases') eq '1') {
        my %c_search_params = ('commit-email' => $author_email);
        if($git->get_config($CFG => 'match-mailmap-name') eq '1') {
            $c_search_params{'commit-name'} = $author_name;
        }
        $verified = $mailmap->search(%c_search_params);
    }
    if($verified == 0) {
        $git->error($PKG, 'commit author '
            . "'\Q$author\Q' does not match in mailmap file.")
            and ++$errors;
    }

    return $errors == 0;
}

sub check_git_user {
    my ($git, $author_name, $author_email) = @_;

    my $errors = 0;

    my $author = "$author_name $author_email";
    if($git->get_config($CFG => 'match-with-git-user')) {
            $git-error($PKG, 'the parameter match-with-git-user'
                . ' is not yet implemented.')
                and ++$errors;
    }

    return $errors == 0;
}

sub check_ref {
    my ($git, $ref) = @_;

    my $errors = 0;

    foreach my $commit ($git->get_affected_ref_commits($ref)) {
        check_message($git, $commit, $commit->{body})
            or ++$errors;
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
            or ++$errors;
    }

    return $errors == 0;
}

# Install hooks
PRE_COMMIT       \&check_author;
UPDATE           \&check_affected_refs; # TODO server-side stuff!
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;

1;

__END__
=for Pod::Coverage check_spelling check_patterns check_title check_body check_message check_ref

=head1 NAME

Git::Hooks::CheckCommitAuthor - Git::Hooks plugin to enforce commit log policies.

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to enforce
policies on commit author names and email addresses.

=over

=item * B<pre-commit>

This hook is invoked during the commit, to check if the commit author 
name and email address comply.

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, to check if the commit author
name and email address of all commits being pushed comply.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
to check if the commit author name and email address of all commits 
being pushed comply.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review, to check if the commit author name and email address of all commits being
pushed comply.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*), to check if the commit 
author name and email address of all commits being pushed comply.

=back

Projects using Git, probably more than projects using any other
version control system, have a tradition of establishing policies on
the format of commit log messages. The REFERENCES section below lists
some of the most important.

This plugin allows one to enforce most of the established policies. The
default configuration already enforces the most common one.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckCommitAuthor

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkcommitauthor.match [!]REGEXP

This option may be specified more than once. It defines a list of
regular expressions that will be matched against the commit log
authors. If the '!' prefix is used, the author must not match the
REGEXP.

=head2 githooks.checkcommitauthor.mailmap TEXT

The filename for the mailmap file to use, normally F<ROOT/.mailmap.>
If this option is not specified, the author is not matched against the
mailmap. If this option is "1" (i.e. true), mailmap file is searched for
in the normal locations: (Not yet implemented)

=over 8

=item TODO

=item 1) toplevel of the repository

=item 2) the location pointed to by the mailmap.file or

=item 3) mailmap.blob configuration options

=back

In mailmap file the author can be matched against both
the proper name and email or the alias (commit) name and email.

=head2 githooks.checkcommitauthor.match-mailmap-name [01]

Match also with the mailmap name, not just with the email address.
Default: On.

=head2 githooks.checkcommitauthor.deny-mailmap-aliases [01]

Only allow match with mailmap proper email (and name if allowed, see
B<match-mailmap-name>), not with the aliases. Default: Off.

=head2 githooks.checkcommitauthor.match-with-user [01]

Match commit author with the contents of the environment variable I<USER>.
For more information, see L<Git::Hooks|Git::Hooks>. Default: Off.

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

=head2 check_patchset GIT, HASH

This is the routine used to implement the C<patchset-created> Gerrit
hook. It needs a C<Git::More> object and the hash containing the
arguments passed to the hook by Gerrit.

=head1 REFERENCES

=over

=item * B<git-commit(1) Manual Page>

This L<Git manual
page|<http://www.kernel.org/pub/software/scm/git/docs/git-commit.html>
has a section called DISCUSSION which discusses some common log
message policies.

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

=back
