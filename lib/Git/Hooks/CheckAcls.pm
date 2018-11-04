use strict;
use warnings;

package Git::Hooks::CheckAcls;
# ABSTRACT: [DEPRECATED] Git::Hooks plugin for branch/tag access control

use 5.010;
use utf8;
use Log::Any '$log';
use Git::Hooks;

(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

##########

sub grok_acls {
    my ($git) = @_;

    my @acls;                   # This will hold the ACL specs

    foreach my $acl ($git->get_config($CFG => 'acl')) {
        # Interpolate environment variables embedded as "{VAR}".
        $acl =~ s/{(\w+)}/$ENV{$1}/ige;
        push @acls, [split ' ', $acl, 3];
    }

    return @acls;
}

sub match_ref {
    my ($ref, $spec) = @_;

    if ($spec =~ /^\^/) {
        return 1 if $ref =~ $spec;
    } elsif ($spec =~ /^!(.*)/) {
        return 1 if $ref !~ $1;
    } else {
        return 1 if $ref eq $spec;
    }
    return 0;
}

sub check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # Grok which operation we're doing on this ref
    my $op;
    if      ($old_commit eq '0' x 40) {
        $op = 'C';              # create
    } elsif ($new_commit eq '0' x 40) {
        $op = 'D';              # delete
    } elsif ($ref !~ m:^refs/heads/:) {
        $op = 'R';              # rewrite a non-branch
    } else {
        # This is an U if "merge-base(old, new) == old". Otherwise it's an R.
        $op = eval {
            my $merge_base = $git->run('merge-base' => $old_commit, $new_commit);
            ($merge_base eq $old_commit) ? 'U' : 'R';
        } || 'R'; # Probably $old_commit and $new_commit do not have a common ancestor.
    }

    foreach my $acl (grok_acls($git)) {
        my ($who, $what, $refspec) = @$acl;
        next unless $git->match_user($who);
        next unless match_ref($ref, $refspec);
        if ($what =~ /[^CRUD-]/) {
            $git->fault(<<"EOS", {option => 'acl', ref => $ref});
Configuration error: It has an invalid second argument:

  acl = $who *$what* $refspec

The valid values are combinations of the letters 'CRUD'.
Please, check your configuration and fix it.
EOS
            return 0;
        }
        return 1 if index($what, $op) != -1;
    }

    # Assign meaningful names to op codes.
    my %op = (
        C => 'create',
        R => 'rewrite',
        U => 'update',
        D => 'delete',
    );

    if (my $myself = eval { $git->authenticated_user() }) {
        $git->fault(<<"EOS", {option => 'acl', ref => $ref});
Authorization error: you ($myself) cannot $op{$op} this reference.
Please, check the your configuration options.
EOS
    } else {
        $git->fault(<<'EOS', {details => $@});
Internal error: I cannot get your username to authorize you.
Please check your Git::Hooks configuration with regards to the function
https://metacpan.org/pod/Git::Repository::Plugin::GitHooks#authenticated_user
EOS
    }

    return 0;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    $log->debug(__PACKAGE__ . "::check_affected_refs");

    return 1 if $git->im_admin();

    foreach my $ref ($git->get_affected_refs()) {
        next unless $git->is_reference_enabled($ref);
        check_ref($git, $ref)
            or return 0;
    }
    return 1;
}

# Install hooks
UPDATE          \&check_affected_refs;
PRE_RECEIVE     \&check_affected_refs;
REF_UPDATE      \&check_affected_refs;
COMMIT_RECEIVED \&check_affected_refs;
SUBMIT          \&check_affected_refs;

1;


__END__
=for Pod::Coverage check_ref grok_acls match_ref check_affected_refs

=head1 NAME

Git::Hooks::CheckAcls - [DEPRECATED] Git::Hooks plugin for branch/tag access control

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckAcls

    # These users are exempt from all checks
    admin = joe molly

  [githooks "checkacls"]

    # Any user can create, rewrite, update, and delete branches prefixed with
    # their own usernames.
    acl = ^.      CRUD ^refs/heads/{USER}/

    # Any user can update any branch.
    acl = ^.      U    ^refs/heads/

=head1 DESCRIPTION

This plugin is deprecated. Please, use the L<Git::Hooks::CheckReference> plugin
instead.

This L<Git::Hooks> plugin hooks itself to the hooks below to guarantee that
only allowed users can push commits and tags to specific branches.

=over

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated, checking if the user
performing the push can update the branch in question.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>,
checking if the user performing the push can update every affected
branch.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review, to check if the user performing the push can update the branch
in question.

=item * B<commit-received>

This hook is invoked when a push request is received by Gerrit Code Review to
create a change for review, to check if the user performing the push can update
the branch in question.

=item * B<submit>

This hook is invoked when a change is submitted in Gerrit Code Review, to check
if the user performing the push can update the branch in question.

=back

To enable it you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckAcls

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checkacls> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 acl ACL

The authorization specification for a repository is defined by the set
of ACLs defined by this option. Each ACL specify 'who' has 'what' kind
of access to which refs, by means of a string with three components
separated by spaces:

    who what refs

By default, nobody has access to anything, except the users specified by the
C<githooks.admin> configuration option. During an update, all the ACLs are
processed in the order defined by the C<git config --list> command. The
first ACL matching the authenticated username and the affected reference
name (usually a branch) defines what operations are allowed. If no ACL
matches username and reference name, then the operation is denied.

The 'who' component specifies to which users this ACL gives access. It can
be specified as a username, a groupname, or a regex, like the
C<githooks.admin> configuration option.

The 'what' component specifies what kind of access to allow. It's
specified as a string of one or more of the following opcodes:

=over

=item * B<C> - Create a new ref.

=item * B<R> - Rewrite an existing ref. (With commit loss.)

=item * B<U> - Update an existing ref. (A fast-forward with no commit loss.)

=item * B<D> - Delete an existing ref.

=back

You may specify that the user has B<no> access whatsoever to the
references by using a single hyphen (C<->) as the what component.

The 'refs' component specifies which refs this ACL applies to. It can
be specified in one of these formats:

=over

=item * B<^REGEXP>

A regular expression anchored at the beginning of the reference name.
For example, "^refs/heads", meaning every branch.

=item * B<!REGEXP>

A negated regular expression. For example, "!^refs/heads/master",
meaning everything but the master branch.

=item * B<STRING>

The complete name of a reference. For example, "refs/heads/master".

=back

The ACL specification can embed strings in the format C<{VAR}>. These
strings are substituted by the corresponding environment's variable
VAR value. This interpolation occurs before the components are split
and processed.

This is useful, for instance, if you want developers to be restricted
in what they can do to official branches but to have complete control
with their own branch namespace.

    [githooks "checkacls"]
      acl = ^. CRUD ^refs/heads/{USER}/
      acl = ^. U    ^refs/heads

In this example, every user (^.) has complete control (CRUD) to the
branches below "refs/heads/{USER}". Supposing the environment variable
USER contains the user's login name during a "pre-receive" hook. For
all other branches (^refs/heads) the users have only update (U) rights.

=head1 REFERENCES

=over

=item * L<update-paranoid|https://github.com/gitster/git/blob/b12905140a8239ac687450ad43f18b5f0bcfb62e/contrib/hooks/update-paranoid>

This script is heavily inspired (and, in some places, derived) from the
example hook which comes with the Git distribution.

=back
