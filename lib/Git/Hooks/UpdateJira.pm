## no critic (Modules::RequireVersionVar)
## no critic (Documentation)
## no critic (ControlStructures::ProhibitUnlessBlocks)
## no critic (ControlStructures::ProhibitPostfixControls)
## no critic (RegularExpressions::RequireLineBoundaryMatching)
## no critic (RegularExpressions::RequireDotMatchAnything)
package Git::Hooks::UpdateJira;

# ABSTRACT: Git::Hooks plugin which updates JIRA issues according to commit messages

use 5.010;
use utf8;
use strict;
use warnings;
use English qw{-no_match_vars};
use Git::Hooks qw/:DEFAULT :utils/;
use List::MoreUtils qw/uniq/;

my $PKG = __PACKAGE__;
( my $CFG = __PACKAGE__ ) =~ s/.*::/githooks./msx;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{ lc $CFG } //= {};

    my $default = $config->{ lc $CFG };

    # Default matchkey for matching default JIRA keys.
    ## no critic (ValuesAndExpressions::RequireInterpolationOfMetachars)
    $default->{matchkey} //= ['\b[A-Z][A-Z]+-\d+\b'];

    return;
}

##########

sub grok_msg_jiras {
    my ( $git, $msg ) = @_;

    my $matchkey = $git->get_config( $CFG => 'matchkey' );
    my @matchlog = $git->get_config( $CFG => 'matchlog' );

    # Grok the JIRA issue keys from the commit log
    if (@matchlog) {
        my @keys;
        foreach my $matchlog (@matchlog) {
            if ( my ($match) = ( $msg =~ /$matchlog/ ) ) {
                push @keys, ( $match =~ /$matchkey/go );
            }
        }
        return @keys;
    }
    else {
        return $msg =~ /$matchkey/go;
    }
}

sub _jira {
    my ($git) = @_;

    my $cache = $git->cache($PKG);

    # Connect to JIRA if not yet connected
    unless ( exists $cache->{jira} ) {
        unless ( eval { require JIRA::REST; } ) {
            $git->error( $PKG, 'Please, install Perl module JIRA::REST'
                    . ' to use the UpdateJira plugin',
                $EVAL_ERROR
            );
            return;
        }

        my %jira;
        for my $option (qw/jiraurl jirauser jirapass/) {
            $jira{$option} = $git->get_config( $CFG => $option )
                or $git->error( $PKG,
                "missing $CFG.$option configuration attribute" )
                and return;
        }
        $jira{jiraurl} =~ s/\/+$//;    # trim trailing slashes from the URL

        my $jira = eval {
            JIRA::REST->new( $jira{jiraurl}, $jira{jirauser}, $jira{jirapass} );
        };
        length $EVAL_ERROR
            and $git->error( $PKG, 'cannot connect to the JIRA server at'
                    . "'$jira{jiraurl}' as '$jira{jirauser}",
            $EVAL_ERROR
          ) and return;
        $cache->{jira} = $jira;
    }

    return $cache->{jira};
}

# Returns a JIRA::REST object or undef if there is any problem
sub post_comment_to_issue {
    my ( $git, $key, $comment ) = @_;

    my $jira = _jira($git);

    my $issue = $jira->POST(
        "/issue/$key/comment", undef, { 'body' => $comment, }
    );
    return $issue;
}

sub _act_on_jira_keys {
    my ( $git, $commit, $ref, @keys ) = @_;

    _setup_config($git);
    my $commit_msg = $commit->{'body'};

    my $errors = 0;

    foreach my $key (@keys) {
        my @action_commands = ( 'action-add-comment' );
        foreach my $action_command (@action_commands) {
            foreach my $com_row ($git->get_config( $CFG => $action_command )) {
                my ($search, @actions) = split q{ }, $com_row;
                if($commit_msg =~ /$search/msx) {
                    foreach my $action (@actions) {
                        ## no critic (ControlStructures::ProhibitDeepNests)
                        if($action eq 'commit-msg') {
                            my $updated_issue =
			        post_comment_to_issue( $git, $key,
                                    $commit_msg );
                        }
                        if($action eq 'commit-diff') {
                            my $diff = $git->command(
				'log' => $commit->{'commit'},
				'--full-diff', '-1', '-p', q{.} );
                            my $updated_issue =
                                post_comment_to_issue( $git, $key,
                                    $commit_msg );
                        }
                    }
                }
            }
        }
    }

    return $errors == 0;
}

sub commit_msg {
    my ( $git, $commit, $ref ) = @_;

    return _act_on_jira_keys( $git, $commit, $ref,
        uniq( grok_msg_jiras( $git, $commit->{'body'} ) ) );
}

sub this_ref {
    my ($git) = @_;

    my $current_branch = $git->get_current_branch();
    return 1
      unless is_ref_enabled( $current_branch,
        $git->get_config( $CFG => 'ref' ) );

    my $commit_msg_oneline =
        $git->command( 'log' => 'HEAD', '-1', '--format=oneline' );
    my ($sha, $msg) = split q{ }, $commit_msg_oneline, 2;

    return commit_msg( $git, $git->get_commit($sha), $current_branch);
}

sub affected_ref {
    my ( $git, $ref ) = @_;

    return 1 unless is_ref_enabled( $ref, $git->get_config( $CFG => 'ref' ) );

    my $errors = 0;

    foreach my $commit ( $git->get_affected_ref_commits($ref) ) {
        commit_msg( $git, $commit, $ref )
          or ++$errors;
    }

    return $errors == 0;
}

# This routine can act both as an update or a pre-receive hook.
sub affected_refs {
    my ($git) = @_;

    my $errors = 0;

    foreach my $ref ( $git->get_affected_refs() ) {
        affected_ref( $git, $ref )
          or ++$errors;
    }

    # Disconnect from JIRA
    $git->clean_cache($PKG);

    return $errors == 0;
}

# Install hooks
POST_COMMIT \&this_ref;
POST_RECEIVE \&affected_refs;

1;

__END__
=for Pod::Coverage post_comment_to_issue commit_msg affected_ref grok_msg_jiras

=head1 DESCRIPTION

Git::Hooks::UpdateJira is a "companion" plugin to L<Git::Hooks::CheckJira>.
UpdateJira updates a Jira ticket with the information in the commit message
or other information, e.g. the current commit diff.

This Git::Hooks plugin hooks itself to the hooks below:

=over

=item * B<post-commit>

This hook is invoked after the commit (at client-side).

=item * B<post-receive>

This hook is invoked once in the remote repository during C<git push>.
It will execute after the actual push is complete. The push will not fail
even if this hook crashes. The user's push operation will remain pending
while post-receive hook executes.

=back

Jira ticket number is picked from the commit message in the same way
as in CheckJira plugin. Jira ticket is updated according to config
options I<action-*>.

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin UpdateJira

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.updatejira.ref REFSPEC

By default, the message of every commit is checked. If you want to
have them checked only for some refs (usually some branch under
refs/heads/), you may specify them with one or more instances of this
option.

The refs can be specified as a complete ref name
(e.g. "refs/heads/master") or by a regular expression starting with a
caret (C<^>), which is kept as part of the regexp
(e.g. "^refs/heads/(master|fix)").

=head2 githooks.updatejira.jiraurl URL

This option specifies the JIRA server HTTP URL, used to construct the
C<JIRA::REST> object which is used to interact with your JIRA
server. Please, see the JIRA::REST documentation to know about them.

=head2 githooks.updatejira.jirauser USERNAME

This option specifies the JIRA server username, used to construct the
C<JIRA::REST> object.

=head2 githooks.updatejira.jirapass PASSWORD

This option specifies the JIRA server password, used to construct the
C<JIRA::REST> object.

=head2 githooks.updatejira.matchkey REGEXP

By default, JIRA keys are matched with the regex
C</\b[A-Z][A-Z]+-\d+\b/>, meaning, a sequence of two or more capital
letters, followed by an hyphen, followed by a sequence of digits. If
you customized your L<JIRA project
keys|https://confluence.atlassian.com/display/JIRA/Configuring+Project+Keys>,
you may need to customize how this hook is going to match them. Set
this option to a suitable regex to match a complete JIRA issue key.

=head2 githooks.updatejira.matchlog REGEXP

By default, JIRA keys are looked for in all of the commit message. However,
this can lead to some false positives, since the default issue pattern can
match other things besides JIRA issue keys. You may use this option to
restrict the places inside the commit message where the keys are going to be
looked for. You do this by specifying a regular expression with a capture
group (a pair of parenthesis) in it. The commit message is matched against
the regular expression and the JIRA tickets are looked for only within the
part that matched the capture group.

Here are some examples:

=over

=item * C<\[([^]]+)\]>

Looks for JIRA keys inside the first pair of brackets found in the
message.

=item * C<(?s)^\[([^]]+)\]>

Looks for JIRA keys inside a pair of brackets that must be at the
beginning of the message's title.

=item * C<(?im)^Bug:(.*)>

Looks for JIRA keys in a line beginning with C<Bug:>. This is a common
convention around some high caliber projects, such as OpenStack and
Wikimedia.

=back

This is a multi-valued option. You may specify it more than once. All
regexes are tried and JIRA keys are looked for in all of them. This
allows you to more easily accomodate more than one way of specifying
JIRA keys if you wish.

=head2 githooks.updatejira.action-* REGEXP, TEXT

All B<action-*> options are commands to modify the Jira ticket.
They start with a regexp which is matched against the commit message.
If the regexp matches, then the following options are used as parameters
to the command.

=head3 githooks.updatejira.action-add-comment

Add a new comment to the ticket. Parameters:

=over

=item * commit-msg, Use the whole commit message as a comment.

=item * commit-diff, Get a diff of the commit and insert it as a comment.

=back

E.g. B<action-add-comment = "^Finished commit-msg commit-diff">. If the
commit message starts with the word "Finished", insert two comments to the
ticket: first the message, then the diff.

=head1 EXPORTS

This module exports the following routines that can be used directly without
using all of Git::Hooks infrastructure.

=head2 affected_refs GIT

This is the routine used to implement the C<post-receive> hook.
It needs a C<Git::More> object.

=head2 this_ref GIT, MSGFILE

This is the routine used to implement the C<post-commit> hook. It needs
a C<Git::More> object.

=head1 SEE ALSO

=over

=item * L<Git::More>

=item * L<JIRA::REST>

=item * L<JIRA::Client>

=back

=head1 REFERENCES

=over

=item * L<JIRA REST API documentation|https://docs.atlassian.com/jira/REST/latest/>

=back

=head1 CONTRIBUTORS

=over

=item * Mikko Koivunalho <mikkoi@cpan.org>

=back

