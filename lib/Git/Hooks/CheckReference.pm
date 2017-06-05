#!/usr/bin/env perl

package Git::Hooks::CheckReference;
# ABSTRACT: Git::Hooks plugin for checking references

use 5.010;
use utf8;
use strict;
use warnings;
use Git::Hooks;
use List::MoreUtils qw/any none/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

sub check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # Check names of newly created refs
    if ($old_commit eq $git->undef_commit) {
        if (any  {$ref =~ qr/$_/} $git->get_config($CFG => 'deny') and
            none {$ref =~ qr/$_/} $git->get_config($CFG => 'allow')) {
            $git->error($PKG, "reference name '$ref' not allowed");
            return 0;
        }
    }

    return 1;
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        check_ref($git, $ref)
            or ++$errors;
    }

    return $errors == 0;
}

# Install hooks
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;

1;

__END__
=for Pod::Coverage check_ref check_affected_refs

=head1 NAME

CheckReference - Git::Hooks plugin for checking references

=head1 DESCRIPTION

This Git::Hooks plugin hooks itself to the hooks below to check if the names
of references added to or renamed in the repository meet specified
constraints. If they don't, the commit/push is aborted.

=over

=item * B<update>

=item * B<pre-receive>

=item * B<ref-update>

=back

To enable it you should add it to the githooks.plugin configuration
option:

    git config --add githooks.plugin CheckReference

=head1 CONFIGURATION

The plugin is configured by the following git options.

=head2 githooks.checkreference.deny REGEXP

This directive denies references with names matching REGEXP.

=head2 githooks.checkreference.allow REGEXP

This directive allows references with names matching REGEXP. Since by
default all names are allowed this directive is useful only to prevent a
B<githooks.checkreference.deny> directive to deny the same name.

The checks are evaluated so that a reference is denied only if it's name
matches any B<deny> directive and none of the B<allow> directives.  So, for
instance, you would apply it like this to allow only the creation of
branches with names prefixed by F<feature/>, F<release/>, and F<hotfix/>,
denying all others.

    [githooks "checkreference"]
        deny  ^refs/heads/
        allow ^refs/heads/(?:feature|release|hotfix)/

Note that the order of the directives is irrelevant.
