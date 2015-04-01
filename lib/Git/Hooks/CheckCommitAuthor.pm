## no critic (Modules::RequireVersionVar)
## no critic (Documentation)
package Git::Hooks::CheckCommitAuthor;

# ABSTRACT: Git::Hooks plugin to enforce policies on commit author name and email.

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks qw/:DEFAULT :utils/;
use Path::Tiny;
require Git::Mailmap;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./msx;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{ lc $CFG } //= {};

    my $default = $config->{ lc $CFG };
    $default->{'mailmap'} //= ['0'];
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

    my $author_name  = $commit->{'author_name'};
    my $author_email = '<' . $commit->{'author_email'} . '>';

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

    if( $git->get_config( $CFG => 'mailmap' ) == 0) {
        return 1;
    }

    my $author = $author_name . q{ } . $author_email;
    my $bare_repo = $git->command( 'config' => 'core.bare' ) eq 'true' ? 1 : 0;

    my $mailmap = Git::Mailmap->new();
    my $mailmap_as_string = $git->command( 'show', 'HEAD:.mailmap' );
    if(defined $mailmap_as_string) {
        $mailmap->from_string( 'mailmap' => $mailmap_as_string );
    }
    # 2) Config variable mailmap.file
    my $mapfile_location = $git->get_config( 'mailmap.' => 'file' );
    if(defined $mapfile_location) {
        if( -e $mapfile_location ) {
            my $file_as_str = Path::Tiny->file($mapfile_location)->slurp_utf8;
            $mailmap->from_string( 'mailmap' => $file_as_str );
        }
        else {
            $git->error( $PKG, "Config variable 'mailmap.file'"
                . " does not point to a file.");
        }
    }
    # 3) Config variable mailmap.blob
    my $mapfile_blob = $git->get_config( 'mailmap.' => 'blob' );
    if(defined $mapfile_blob) {
        if( my $blob_as_str = $git->command( 'show', $mapfile_blob ) ) {
            $mailmap->from_string( 'mailmap' => $blob_as_str );
        }
        else {
            $git->error( $PKG, "Config variable 'mailmap.blob'"
                . " does not point to a file.");
        }
    }

    my $verified = 0;

    # Always search (first) among proper emails (and names if wanted).
    my %search_params = ( 'proper-email' => $author_email );
    if ( $git->get_config( $CFG => 'match-mailmap-name' ) eq '1' ) {
        $search_params{'proper-name'} = $author_name;
    }
    $verified = $mailmap->verify(%search_params);

    # If was not found among proper-*, and user wants, search aliases.
    if (  !$verified
        && $git->get_config( $CFG => 'allow-mailmap-aliases' ) eq '1' )
    {
        my %c_search_params = ( 'commit-email' => $author_email );
        if ( $git->get_config( $CFG => 'match-mailmap-name' ) eq '1' ) {
            $c_search_params{'commit-name'} = $author_name;
        }
        $verified = $mailmap->verify(%c_search_params);
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
UPDATE \&check_affected_refs;
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

=head2 githooks.checkcommitauthor.mailmap [01]

Set this to 1, if you want to use the mailmap for matching the authors.
The mailmap file is located according to Git's normal preferences:

=over

=item 1 Default mailmap.

If exists, use mailmap file in F<HEAD:.mailmap>, i.e. the root
of a repository.

=item 2 Configuration variable I<mailmap.file>.

The location of an augmenting mailmap file.
The default mailmap, is loaded first,
then the mailmap file pointed to by this variable. The contents of this
mailmap will take precedence over the default one's contents.
File must be in UTF-8 format.

The location of the
mailmap file may be in a repository subdirectory, or somewhere outside
of the repository itself. If the repo is a bare repository, then this 
phase will raise an error. Use variable I<mailmap.blob> if file is in
the repository. If file cannot be found, this will raise an error.

=item 3 Configuration variable I<mailmap.blob>.

If the repo is a bare repository, then this config variable is used.
It points to a Git blob in the bare repo. The contents of this
mailmap will take precedence over the default one's contents and the
augmenting mailmap file's contents (var I<mailmap.file>).

This feature is not yet supported.

=back

In mailmap file the author can be matched against both
the proper name and email or the alias (commit) name and email.
The following parameters explain how mailmap file
usage is controlled.

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

=head2 check_commit_at_client GIT

This is the routine used to implement the C<pre-commit> hook. It needs
a C<Git::More> object.

=head2 check_commit_at_server GIT, COMMIT

This is the routine used to implement the C<pre-commit> hook. It needs
a C<Git::More> object and a commit hash from C<Git::More::get_commit()>.

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

