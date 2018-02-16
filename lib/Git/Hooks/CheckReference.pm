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

sub check_ref {
    my ($git, $ref) = @_;

    my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);

    # Check names of newly created refs
    if ($old_commit eq $git->undef_commit) {
        if (any  {$ref =~ qr/$_/} $git->get_config($CFG => 'deny') and
            none {$ref =~ qr/$_/} $git->get_config($CFG => 'allow')) {
            $git->fault(<<EOS);
The reference name '$ref' is not allowed.
Please, check the $CFG.deny options in your configuration.
EOS
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

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]
    plugin = CheckReference
    admin = joe molly

  [githooks "checkreference"]
    deny  = ^refs/heads/
    allow = ^refs/heads/(?:feature|release|hotfix)/

The first section enables the plugin and defines the users C<joe> and C<molly>
as administrators, effectivelly exempting them from any restrictions the plugin
may impose.

The second instance enables C<some> of the options specific to this plugin.

The C<deny> and C<allow> options conspire to only allow the creation of branches
which names begin with C<feature/>, C<release/>, and C<hotfix/>.

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
        deny  = ^refs/heads/
        allow = ^refs/heads/(?:feature|release|hotfix)/

Note that the order of the directives is irrelevant.
