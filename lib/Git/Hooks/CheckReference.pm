#!/usr/bin/env perl

package Git::Hooks::CheckReference;
# ABSTRACT: Git::Hooks plugin for checking references

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks;
use List::MoreUtils qw/any none/;

(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

# Assign meaningful names to action codes.
my %ACTION = (
    C => 'create',
    R => 'rewrite',
    U => 'update',
    D => 'delete',
);

sub check_ref {
    my ($git, $ref) = @_;

    my $errors = 0;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # Grok which action we're doing on this ref
    my $action;
    if      ($old_commit eq '0' x 40) {
        $action = 'C';              # create
    } elsif ($new_commit eq '0' x 40) {
        $action = 'D';              # delete
    } elsif ($ref !~ m:^refs/heads/:) {
        $action = 'R';              # rewrite a non-branch
    } else {
        # This is an U if "merge-base(old, new) == old". Otherwise it's an R.
        $action = try {
            chomp(my $merge_base = $git->run('merge-base' => $old_commit, $new_commit));
            ($merge_base eq $old_commit) ? 'U' : 'R';
        } catch {
            # Probably $old_commit and $new_commit do not have a common ancestor.
            'R';
        };
    }

    my @acls = eval { $git->grok_acls($CFG, 'CRUD') };
    if ($@) {
        $git->fault($@, {ref => $ref});
        return 1;
    }

  ACL:
    foreach my $acl (@acls) {
        next unless ref $acl->{spec} ? $ref =~ $acl->{spec} : $ref eq $acl->{spec};
        if (index($acl->{action}, $action) != -1) {
            unless ($acl->{allow}) {
                $git->fault(<<EOS, {ref => $ref, option => 'acl'});
The reference name is not allowed.
Please, check your ACL options.
EOS
                ++$errors;
            }
            last ACL;
        }
    }

    # Check deprecated options
    if ($action eq 'C') {
        if (any  {$ref =~ qr/$_/} $git->get_config($CFG => 'deny') and
            none {$ref =~ qr/$_/} $git->get_config($CFG => 'allow')) {
            $git->fault(<<EOS, {ref => $ref, option => 'deny'});
The reference name is not allowed.
Please, check your configuration option.
EOS
            ++$errors;
        }
    }

    if ($ref =~ m:^refs/tags/:
            && $git->get_config_boolean($CFG => 'require-annotated-tags')) {
        my $rev_type = $git->run('cat-file', '-t', $new_commit);
        if ($rev_type ne 'tag') {
            $git->fault(<<EOS, {ref => $ref, option => 'require-annotated-tags'});
This is a lightweight tag.
The option in your configuration accepts only annotated tags.
Please, recreate your tag as an annotated tag (option -a).
EOS
            ++$errors;
        }
    }

    return $errors;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        next unless $git->is_reference_enabled($ref);
        check_ref($git, $ref)
            or ++$errors;
    }

    return $errors == 0;
}

INIT: {
    # Install hooks
    UPDATE       \&check_affected_refs;
    PRE_RECEIVE  \&check_affected_refs;
    REF_UPDATE   \&check_affected_refs;
}

1;

__END__
=for Pod::Coverage check_ref check_affected_refs

=head1 NAME

CheckReference - Git::Hooks plugin for checking references

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]
    # Enable the plugin
    plugin = CheckReference

    # These users are exempt from all checks
    admin  = joe molly

    # This group is used in a ACL spec below
    groups = cms = mhelena tiago juliana

  [githooks "checkreference"]

    # Deny changes on any references by default
    acl = deny  CRUD ^refs/

    # Only users in the @cms group may create, change, or delete tags
    acl = allow CRUD ^refs/tags/ by @cms

    # Users may maintain personal branches under user/<username>/
    acl = allow CRUD ^refs/heads/user/{USER}/

    # Users may only update the vetted branch names
    acl = allow U    ^refs/heads/(?:feature|release|hotfix)/

    # Users in the @cms group may create, rewrite, update, and delete the vetted
    # branch names
    acl = allow CRUD ^refs/heads/(?:feature|release|hotfix)/ by @cms

    # Reject lightweight tags
    require-annotated-tags = true

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to check if the
names of references added to or renamed in the repository meet specified
constraints. If they don't, the commit/push is aborted.

=over

=item * B<update>

=item * B<pre-receive>

=item * B<ref-update>

=back

To enable it you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckReference

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checkacls> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 acl RULE

This multi-valued option specifies rules allowing or denying specific users to
perform specific actions on specific references. (Common references are branches
and tags, but an ACL may refer to any reference under the F<refs/> namespace.)
By default any user can perform any action on any reference. So, the rules are
used to impose restrictions.

The acls are grokked by the L<Git::Repository::Plugin::GitHooks>'s C<grok_acls>
method. Please read its documentation for the general documentation.

A RULE takes three or four parts, like this:

  (allow|deny) [CRUD]+ <refspec> (by <userspec>)?

Some parts are described below:

=over 4

=item * B<[CRUD]+>

The second part specifies which actions are being considered by a combination of
letters: (C) create a reference, (R) rewrite a reference (a non fast-forward
change), (U) update a reference (a fast-forward change), or (D) delete a
reference. You can specify one, two, three, or the four letters.

=item * B<< <refspec> >>

The third part specifies which references are being considered. In its simplest
form, a C<refspec> is a complete name starting with F<refs/>
(e.g. F<refs/heads/master>). These refspecs match a single file exactly.

If the C<refspec> starts with a caret (^) it's interpreted as a Perl regular
expression, the caret being kept as part of the regexp. These refspecs match
potentially many references (e.g. F<^refs/heads/feature/>).

Before being interpreted as a string or as a regexp, any substring of it in the
form C<{VAR}> is replaced by C<$ENV{VAR}>. This is useful, for example, to
interpolate the committer's username in the refspec, in order to create
reference namespaces for users.

=back

See the L</SYNOPSIS> section for some examples.

=head2 require-annotated-tags BOOL

By default one can push lightweight or annotated tags but if you want to require
that only annotated tags be pushed to the repository you can set this option to
true.

=head2 [DEPRECATED] deny REGEXP

This option is deprecated. Please, use an C<acl> option like this instead:

  [githooks "checkreference"]
    acl = deny C ^<REGEXP>

This directive denies references with names matching REGEXP.

=head2 [DEPRECATED] allow REGEXP

This option is deprecated. Please, use an C<acl> option like this instead:

  [githooks "checkreference"]
    acl = allow C ^<REGEXP>

This directive allows references with names matching REGEXP. Since by
default all names are allowed this directive is useful only to prevent a
B<githooks.checkreference.deny> directive to deny the same name.

The checks are evaluated so that a reference is denied only if it's name
matches any B<deny> directive and none of the B<allow> directives.  So, for
instance, you would apply it like this to allow only the creation of
branches with names prefixed by F<feature/>, F<release/>, and F<hotfix/>,
denying all others.

    [githooks "checkreference"]
        deny  = ^refs/heads/
        allow = ^refs/heads/(?:feature|release|hotfix)/

Note that the order of the directives is irrelevant.

=head1 REFERENCES

=over

=item * L<update-paranoid|https://github.com/git/git/blob/master/contrib/hooks/update-paranoid>

This module is inspired from the example hook which comes with the Git
distribution.

=back
