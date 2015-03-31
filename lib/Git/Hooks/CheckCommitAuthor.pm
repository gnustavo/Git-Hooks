## no critic (Modules::RequireVersionVar)
## no critic (Documentation)
package Git::Hooks::CheckCommitAuthor;

# ABSTRACT: Git::Hooks plugin to enforce policies on commit author name and email.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Carp;
use File::Slurp::Tiny 'read_file';
require Git::Mailmap;

my $PKG = __PACKAGE__;
( my $CFG = __PACKAGE__ ) =~ s/.*::/githooks./msx;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{ lc $CFG } //= {};

    my $default = $config->{ lc $CFG };
    $default->{'match-mailmap-name'}    //= ['1'];
    $default->{'allow-mailmap-aliases'} //= ['1'];

    return;
}

##########

sub check_commit_at_client {
    my ($git) = @_;

    my $author_name  = $ENV{'GIT_AUTHOR_NAME'};
    my $author_email = '<' . $ENV{'GIT_AUTHOR_EMAIL'} . '>';

    return check_author($git, $author_name, $author_email);
}

sub check_commit_at_server {
    my ($git, $commit) = @_;

    my $commit_hash = $git->get_commit( $commit );
    print Dumper($commit_hash);

    my $author_name  = $commit_hash->{'author_name'};
    my $author_email = $commit_hash->{'author_email'};

    return check_author($git, $author_name, $author_email);
}

sub check_author {
    my ($git, $author_name, $author_email) = @_;

    _setup_config($git);

    return 1 if im_admin($git);

    my $errors = 0;
    check_patterns( $git, $author_name, $author_email ) or ++$errors;
    check_mailmap( $git, $author_name, $author_email ) or ++$errors;
    check_git_user( $git, $author_name, $author_email ) or ++$errors;

    return $errors == 0;
}

sub check_patterns {
    my ( $git, $author_name, $author_email ) = @_;

    my $errors = 0;

    my $author = "$author_name $author_email";
    foreach my $match ( $git->get_config( $CFG => 'match' ) ) {
        if ( $match =~ s/^![[:space:]]*//msx ) {
            ## no critic (RegularExpressions::RequireExtendedFormatting)
            $author !~ /$match/ms
              or $git->error( $PKG,
                    'commit author '
                  . "'\Q$author_name $author_email\Q' SHOULD NOT match '\Q$match\E'"
              ) and ++$errors;
        }
        else {
            ## no critic (RegularExpressions::RequireExtendedFormatting)
            $author =~ /$match/ms
              or $git->error( $PKG,
                    'commit author '
                  . "'\Q$author_name $author_email\Q' SHOULD match '\Q$match\E'"
              ) and ++$errors;
        }
    }

    return $errors == 0;
}

sub check_mailmap {
    my ( $git, $author_name, $author_email ) = @_;

    my $errors = 0;

    my $author = "$author_name $author_email";
    my ($mapfile_location) = $git->get_config( $CFG => 'mailmap' );
    my $mailmap_as_string;
    return 1 if ( !defined $mapfile_location );

    if ( $mapfile_location eq '1' ) {
        croak 'This option is not yet implemented.';
    }
    else {
        $mailmap_as_string = read_file($mapfile_location);
    }
    my $mailmap = Git::Mailmap->new();
    $mailmap->from_string( 'mailmap' => $mailmap_as_string );
    my $verified = 0;

    # Always search (first) among proper emails (and names if wanted).
    my %search_params = ( 'proper-email' => $author_email );
    if ( $git->get_config( $CFG => 'match-mailmap-name' ) eq '1' ) {
        $search_params{'proper-name'} = $author_name;
    }
    $verified = $mailmap->search(%search_params);

    # If was not found among proper-*, and user wants, search aliases.
    if (  !$verified
        && $git->get_config( $CFG => 'allow-mailmap-aliases' ) eq '1' )
    {
        my %c_search_params = ( 'commit-email' => $author_email );
        if ( $git->get_config( $CFG => 'match-mailmap-name' ) eq '1' ) {
            $c_search_params{'commit-name'} = $author_name;
        }
        $verified = $mailmap->search(%c_search_params);
    }
    if ( $verified == 0 ) {
        $git->error( $PKG,
            'commit author ' . "'\Q$author\Q' does not match in mailmap file." )
          and ++$errors;
    }

    return $errors == 0;
}

sub check_git_user {
    my ( $git, $author_name, $author_email ) = @_;

    my $errors = 0;

    my $author = "$author_name $author_email";
    if ( $git->get_config( $CFG => 'match-with-git-user' ) ) {
        $git->error( $PKG,
            'the parameter match-with-git-user' . ' is not yet implemented.' )
          and ++$errors;
    }

    return $errors == 0;
}

sub check_ref {
    my ( $git, $ref ) = @_;

    my $errors = 0;

    foreach my $commit ( $git->get_affected_ref_commits($ref) ) {
        check_commit_at_server( $git, $commit )
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

    foreach my $ref ( $git->get_affected_refs() ) {
        check_ref( $git, $ref )
          or ++$errors;
    }

    return $errors == 0;
}

sub check_patchset {
    my ($git, $opts) = @_;

    _setup_config($git);

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    return check_commit_at_server($git, $commit);
}

# Install hooks
PRE_COMMIT \&check_commit_at_client;
UPDATE \&check_affected_refs;    # TODO server-side stuff!
PRE_RECEIVE \&check_affected_refs;
REF_UPDATE \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED \&check_patchset;

1;

__END__
=for Pod::Coverage check_spelling check_patterns check_title check_body check_message check_ref

=head1 DESCRIPTION

By its very nature, the Git VCS (version control system) is open
and with very little access control. It is common in many instances to run
Git under one user id (often "git") and allowing access to it
via L<SSH|http://en.wikipedia.org/wiki/Secure_Shell> and 
L<public keys|http://en.wikipedia.org/wiki/Public-key_cryptography>.
This means that user can push commits without any control on either commit
message or the commit author.

This plugin allows one to enforce policies on the author information
in a commit. Author information consists of author name and author email.
Email is the more important of these. In principle, email is used to identify
committers, and in some Git clients, 
L<GitWeb|http://git-scm.com/book/en/v2/Git-on-the-Server-GitWeb>
WWW-interface, for instance,
email is also used to show a picture of the committer
via L<Gravatar|http://en.gravatar.com>.
The common way for user to set the author is to use the
(normally user global)
configuration options I<user.name> and I<user.email>. When doing a commit,
user can override these via the command line option I<--author>. The

To enable CheckCommitAuthor plugin, you should 
add it to the githooks.plugin configuration option:

    git config --add githooks.plugin CheckCommitAuthor

Git::Hooks::CheckCommitAuthor plugin hooks itself to the hooks below:

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

=item * B<draft-published>

The draft-published hook is executed when the user publishes a draft change,
making it visible to other users.

=back

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
in the normal locations:

This option is not yet implemented!

=over

=item Possible .mailmap locations:

=item 1) the location pointed to by the mailmap.file or

=item 2) mailmap.blob configuration options

=item 3) toplevel of the repository

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

Match commit author against the contents of the environment variable I<USER>.
For more information, see
L<Git::Hooks userenv variable|
https://metacpan.org/pod/Git::Hooks#githooks.userenv-STRING>.
Default: Off.

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

=head1 CONTRIBUTORS

=over

=item * Mikko Koivunalho <mikkoi@cpan.org>

=back

