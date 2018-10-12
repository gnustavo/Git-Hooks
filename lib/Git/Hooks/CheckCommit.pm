use strict;
use warnings;

package Git::Hooks::CheckCommit;
# ABSTRACT: Git::Hooks plugin to enforce commit policies

use 5.010;
use utf8;
use Carp;
use Log::Any '$log';
use Git::Hooks;
use Git::Repository::Log;
use List::MoreUtils qw/any none/;

my $PKG = __PACKAGE__;
(my $CFG = __PACKAGE__) =~ s/.*::/githooks./;

#############
# Grok hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();

    $config->{lc $CFG} //= {};

    my $default = $config->{lc $CFG};

    $default->{'push-limit'} //= [0];

    return;
}

##########

# Return common help messages to fix author or committer name/email.  This
# routine is used to compose some error messages in the routine match_errors
# below. The "no critic" exemption below is a false positive.
sub _amend_help {               ## no critic (ProhibitUnusedPrivateSubroutines)
    my ($who) = @_;
    if ($who eq 'author') {
        return 'Please, amend your commit using the --author option to fix the author name/email.';
    } elsif ($who eq 'committer') {
        return 'Please, amend your commit after fixing your user.name and/or user.email configuration options.';
    } else {
        croak "Internal error: invalid who ($who)";
    }
}

sub match_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{identity}) {
        $cache->{identity} = {};
        foreach my $info (qw/name email/) {
            foreach my $regexp ($git->get_config($CFG => $info)) {
                $regexp =~ s/^(\!?)//;
                push @{$cache->{identity}{$info}{$1}}, qr/$regexp/; ## no critic (ProhibitCaptureWithoutTest)
            }
        }
    }

    if (keys %{$cache->{identity}}) {
        foreach my $info (qw/name email/) {
            if (my $checks = $cache->{identity}{$info}) {
                foreach my $who (qw/author committer/) {
                    my $who_info = "${who}_${info}";
                    my $data     = $commit->$who_info;

                    if (none { $data =~ $_ } @{$checks->{''}}) {
                        $git->fault(<<"EOS", {commit => $commit, option => $info});
The commit $who $info ($data) is invalid.
It must match at least one positive option.
@{[_amend_help($who)]}
EOS
                        ++$errors;
                    }

                    if (any { $data =~ $_ } @{$checks->{'!'}}) {
                        $git->fault(<<"EOS", {commit => $commit, option => $info});
The commit $who $info ($data) is invalid.
It matches some negative option.
@{[_amend_help($who)]}
EOS
                        ++$errors;
                    }
                }
            }
        }
    }

    return $errors;
}

sub merge_errors {
    my ($git, $commit) = @_;

    if ($commit->parent() > 1) { # it's a merge commit
        if (my @mergers = $git->get_config($CFG => 'merger')) {
            if (none {$git->match_user($_)} @mergers) {
                $git->fault(<<"EOS", {commit => $commit, option => 'merger'});
Authorization error: you cannot push this commit.

I'm sorry, but you (@{[$git->authenticated_user]}) are not authorized to push
*merge commits* because you're not included in the configuration option. You
must either include yourself in that option or ask somebody else to push the
commit for you.
EOS
                return 1;
            }
        }
    }

    return 0;
}

sub email_valid_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    my $cache = $git->cache($PKG);

    if ($git->get_config_boolean($CFG => 'email-valid')) {
        # Let's also cache the Email::Valid object
        unless (exists $cache->{email_valid}) {
            $cache->{email_valid} = undef;
            if (eval { require Email::Valid; }) {
                my @checks;
                foreach my $check (qw/mxcheck tldcheck fqdn allow_ip/) {
                    if (my $value = $git->get_config_boolean($CFG => "email-valid.$check")) {
                        push @checks, "-$check" => $value;
                    }
                }
                $cache->{email_valid} = Email::Valid->new(@checks);
            } else {
                $git->fault(<<'EOS', {option => 'email-valid.*'});
I could not load the Email::Valid Perl module.

I need it to validate your commit's author and committer as requested by your
configuration options.

Please, install the module or disable the options to proceed.
EOS
                ++$errors;
            }
        }

        if (my $ev = $cache->{email_valid}) {
            foreach my $who (qw/author committer/) {
                my $who_email = "${who}_email";
                my $email     = $commit->$who_email;
                unless ($ev->address($email)) {
                    my $details = $ev->details();
                    $git->fault(<<"EOS", {commit => $commit});
The commit $who email ($email) failed the $details check.
@{[_amend_help($who)]}
EOS
                    ++$errors;
                }
            }
        }
    }

    return $errors;
}

sub _canonical_identity {
    my ($git, $mailmap, $identity) = @_;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{canonical}{$identity}) {
        $cache->{canonical}{$identity} =
            $git->run('-c', "mailmap.file=$mailmap", 'check-mailmap', $identity);
    }

    return $cache->{canonical}{$identity};
}

sub canonical_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    if (my $mailmap = $git->get_config($CFG => 'canonical')) {
        foreach my $who (qw/author committer/) {
            my $who_name  = "${who}_name";
            my $who_email = "${who}_email";
            my $identity  = $commit->$who_name . ' <' . $commit->$who_email . '>';
            my $canonical = eval {_canonical_identity($git, $mailmap, $identity) };
            unless (defined $canonical) {
                $git->fault(<<'EOS', {option => 'canonical'});
Git error: could not run command git-check-mailmap.
The configuration option requires it.
It's available since Git 1.8.4.
Please, either upgrade your Git or disable this option.
EOS
                ++$errors;
            }

            if ($identity ne $canonical) {
                $git->fault(<<"EOS", {commit => $commit, option => 'canonical'});
The commit $who identity isn't canonical.
It's '$identity' but its canonical form is '$canonical'.
@{[_amend_help($who)]}
EOS
                ++$errors;
            }
        }
    }

    return $errors;
}

sub signature_errors {
    my ($git, $commit) = @_;

    my $errors = 0;

    my $signature = $git->get_config($CFG => 'signature');

    if (defined $signature && $signature ne 'nocheck') {
        my $status = $git->run(qw/log -1 --format='%G?'/, $commit->commit);

        if ($status eq 'B') {
            $git->fault(<<'EOS', {commit => $commit, option => 'signature'});
The commit has a BAD GPG signature.
Please, amend your commit with the -S option to fix it.
EOS
            ++$errors;
        } elsif ($status eq 'N' && $signature ne 'optional') {
            $git->fault(<<'EOS', {commit => $commit, option => 'signature'});
The commit has NO GPG signature.
Please, amend your commit with the -S option to add one.
EOS
            ++$errors;
        } elsif ($status eq 'U' && $signature eq 'trusted') {
            $git->fault(<<'EOS', {commit => $commit, option => 'signature'});
The commit has an UNTRUSTED GPG signature.
Please, amend your commit with the -S option to add another one.
EOS
            ++$errors;
        }
    }

    return $errors;
}

sub code_errors {
    my ($git, $commit, $ref) = @_;

    my $errors = 0;

    my $cache = $git->cache($PKG);

    unless (exists $cache->{codes}) {
        $cache->{codes} = [];
      CODE:
        foreach my $check ($git->get_config($CFG => 'check-code')) {
            my $code;
            if ($check =~ s/^file://) {
                $code = do $check;
                unless ($code) {
                    if (length $@) {
                        $git->fault("I couldn't parse the file ($check):",
                                    {commit => $commit, option => 'check-code', details => $@});
                    } elsif (! defined $code) {
                        $git->fault("I couldn't read the file ($check):",
                                    {commit => $commit, option => 'check-code', details => $@});
                    } else {
                        $git->fault("The file ($check) returned FALSE",
                                    {commit => $commit, option => 'check-code', details => $@});
                    }
                    ++$errors;
                    next CODE;
                }
            } else {
                $code = eval $check; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                if (length $@) {
                    $git->fault("I couldn't parse the option value ($check):",
                                {commit => $commit, option => 'check-code', details => $@});
                    ++$errors;
                    next CODE;
                }
            }
            if (defined $code && ref $code && ref $code eq 'CODE') {
                push @{$cache->{codes}}, $code;
            } else {
                $git->fault("The option value must end with a code ref.",
                            {commit => $commit, option => 'check-code'});
                ++$errors;
            }
        }
    }

    foreach my $code (@{$cache->{codes}}) {
        my $ok = eval { $code->($git, $commit, $ref) };
        if (defined $ok) {
            unless ($ok) {
                $git->fault("Error detected while evaluating the option.",
                            {commit => $commit, option => 'check-code'});
                ++$errors;
            }
        } elsif (length $@) {
            $git->fault('Error detected while evaluating the option',
                        {commit => $commit, option => 'check-code', details => $@});
            ++$errors;
        }
    }

    return $errors;
}

sub commit_errors {
    my ($git, $commit, $ref) = @_;

    return
        match_errors($git, $commit) +
        merge_errors($git, $commit) +
        email_valid_errors($git, $commit) +
        canonical_errors($git, $commit) +
        signature_errors($git, $commit) +
        code_errors($git, $commit, $ref);
}

sub check_ref {
    my ($git, $ref) = @_;

    my $errors = 0;

    my @commits = $git->get_affected_ref_commits($ref);

    if (my $limit = $git->get_config_integer($CFG => 'push-limit')) {
        if (@commits > $limit) {
            $git->fault(<<"EOS", {ref => $ref, option => 'push-limit'});
Are you sure you want to push @{[scalar @commits]} commits to this reference at
once?

The configuration option currently allows one to push at most $limit commits to
a reference at once.

If you're sure about this you can break the whole commit sequence in smaller
subsequences and push them one at a time.
EOS
            ++$errors;
        }
    }

    foreach my $commit (@commits) {
        $errors += commit_errors($git, $commit, $ref);
    }

    return $errors;
}

sub check_pre_commit {
    my ($git) = @_;

    $log->debug(__PACKAGE__ . "::check_pre_commit");

    _setup_config($git);

    my $current_branch = $git->get_current_branch();

    return 1 unless $git->is_reference_enabled($current_branch);

    # Grok author and committer information from git's environment variables, if
    # they're defined. Sometimes they aren't...

    my $author_name     = $ENV{GIT_AUTHOR_NAME}     || 'nobody';
    my $author_email    = $ENV{GIT_AUTHOR_EMAIL}    || 'nobody@example.net';
    my $committer_name  = $ENV{GIT_COMMITTER_NAME}  || $author_name;
    my $committer_email = $ENV{GIT_COMMITTER_EMAIL} || $author_email;

    # Construct a fake commit object to pass to the error checking routines.
    my $commit = Git::Repository::Log->new(
        commit    => '<new>',
        author    => "$author_name <$author_email> 1234567890 -0300",
        committer => "$committer_name <$committer_email> 1234567890 -0300",
        message   => "Fake\n",
    );

    return 0 ==
        (match_errors($git, $commit) +
         email_valid_errors($git, $commit) +
         canonical_errors($git, $commit) +
         code_errors($git, $commit));
}

sub check_post_commit {
    my ($git) = @_;

    $log->debug(__PACKAGE__ . "::check_post_commit");

    _setup_config($git);

    my $current_branch = $git->get_current_branch();

    return 1 unless $git->is_reference_enabled($current_branch);

    my $commit = $git->get_sha1('HEAD');

    return signature_errors($git, $commit);
}

# This routine can act both as an update or a pre-receive hook.
sub check_affected_refs {
    my ($git) = @_;

    $log->debug(__PACKAGE__ . "::check_affected_refs");

    _setup_config($git);

    return 1 if $git->im_admin();

    my $errors = 0;

    foreach my $ref ($git->get_affected_refs()) {
        next unless $git->is_reference_enabled($ref);
        $errors += check_ref($git, $ref);
    }

    return $errors == 0;
}

sub check_patchset {
    my ($git, $opts) = @_;

    $log->debug(__PACKAGE__ . "::check_patchset");

    _setup_config($git);

    return 1 if $git->im_admin();

    my $sha1   = $opts->{'--commit'};
    my $commit = $git->get_commit($sha1);

    # The --branch argument contains the branch short-name if it's in the
    # refs/heads/ namespace. But we need to always use the branch long-name,
    # so we change it here.
    my $branch = $opts->{'--branch'};
    $branch = "refs/heads/$branch"
        unless $branch =~ m:^refs/:;

    return 1 unless $git->is_reference_enabled($branch);

    return commit_errors($git, $commit) == 0;
}

# Install hooks
PRE_APPLYPATCH   \&check_pre_commit;
POST_APPLYPATCH  \&check_post_commit;
PRE_COMMIT       \&check_pre_commit;
POST_COMMIT      \&check_post_commit;
UPDATE           \&check_affected_refs;
PRE_RECEIVE      \&check_affected_refs;
REF_UPDATE       \&check_affected_refs;
PATCHSET_CREATED \&check_patchset;
DRAFT_PUBLISHED  \&check_patchset;

1;


__END__
=for Pod::Coverage match_errors merge_errors email_valid_errors canonical_errors identity_errors signature_errors spelling_errors pattern_errors subject_errors body_errors footer_errors commit_errors code_errors check_pre_commit check_post_commit check_ref check_affected_refs check_patchset

=head1 NAME

Git::Hooks::CheckCommit - Git::Hooks plugin to enforce commit policies

=head1 SYNOPSIS

As a C<Git::Hooks> plugin you don't use this Perl module directly. Instead, you
may configure it in a Git configuration file like this:

  [githooks]

    # Enable the plugin
    plugin = CheckCommit

    # These users are exempt from all checks
    admin = joe molly

    # The @mergers group is used below
    groups = mergers = larry sally

  [githooks "checkcommit"]

    # Reject commits if the author or committer name contains any characters
    # other then lowercase letters.
    name = !^[a-z]+$

    # Reject commits if the author or committer email does not belong to the
    # @cpqd.com.br domain.
    email = @cpqd\.com\.br$

    # Enable several integrity checks on the author and committer emails using
    # the Email::Valid Perl module.
    email-valid = true

    # Only users in the @mergers group can push merge commits.
    merger = @mergers

    # Rejects pushes with more than two commits in a single branch, in order to
    # avoid careless pushes.
    push-limit = 2

=head1 DESCRIPTION

This L<Git::Hooks> plugin hooks itself to the hooks below to enforce commit
policies.

=over

=item * B<pre-commit>, B<pre-applypatch>

This hook is invoked before a commit is made to check the author and
committer identities.

=item * B<post-commit>, B<post-applypatch>

This hook is invoked after a commit is made to check its signature. Note
that the commit is checked after is has been made and any errors must be
fixed with a C<git-commit --amend> command afterwards.

=item * B<update>

This hook is invoked multiple times in the remote repository during C<git
push>, once per branch being updated, to check if all commits being pushed
comply.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>, to
check if all commits being pushed comply.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code Review,
to check if all commits being pushed comply.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code Review
for a virtual branch (refs/for/*), to check if all commits being pushed
comply.

=back

Projects using Git, probably more than projects using any other version
control system, have a tradition of establishing policies on several aspects
of commits, such as those relating to author and committer identities and
commit signatures.

To enable this plugin you should add it to the githooks.plugin configuration
option:

    [githooks]
      plugin = CheckCommit

=head1 CONFIGURATION

The plugin is configured by the following git options under the
C<githooks.checkcommit> subsection.

It can be disabled for specific references via the C<githooks.ref> and
C<githooks.noref> options about which you can read in the L<Git::Hooks>
documentation.

=head2 name [!]REGEXP

This multi-valued option impose restrictions on the valid author and
committer names using regular expressions.

The names must match at least one of the "positive" regular expressions (the
ones not prefixed by "!") and they must not match any one of the negative
regular expressions (the ones prefixed by "!").

This check is performed by the C<pre-commit> local hook.

This allows you, for example, to require that author and committer names have at
least a first and a last name, separated by spaces:

  [githooks "checklog"]
    name = .\\s+.

=head2 email [!]REGEXP

This multi-valued option impose restrictions on the valid author and
committer emails using regular expressions.

The emails must match at least one of the "positive" regular expressions
(the ones not prefixed by "!") and they must not match any one of the
negative regular expressions (the ones prefixed by "!").

This check is performed by the C<pre-commit> local hook.

=head2 email-valid BOOL

This option uses the L<Email::Valid> module' C<address> method to validate
author and committer email addresses.

These checks are performed by the C<pre-commit> local hook.

Note that the L<Email::Valid> module isn't required to install
L<Git::Hooks>.  If it's not found or if there's an error in the construction
of the C<Email::Valid> object the check fails with a suitable message.

The C<Email::Valid> constructor (new) accepts some parameters. You can pass
the boolean parameters to change their default values by means of the
following sub-options. For more information, please consult the
L<Email::Valid> documentation.

=head3 githooks.checkcommit.email-valid.mxcheck BOOL

Specifies whether addresses should be checked for a valid DNS entry. The
default is false.

=head3 githooks.checkcommit.email-valid.tldcheck BOOL

Specifies whether addresses should be checked for valid top level
domains. The default is false.

=head3 githooks.checkcommit.email-valid.fqdn BOOL

Species whether addresses must contain a fully qualified domain name
(FQDN). The default is true.

=head3 githooks.checkcommit.email-valid.allow_ip BOOL

Specifies whether a "domain literal" is acceptable as the domain part.  That
means addresses like: C<rjbs@[1.2.3.4]>. The default is true.

=head2 canonical MAILMAP

This option requires the use of canonical names and emails for authors and
committers, as configured in a F<MAILMAP> file and checked by the
C<git-check-mailmap> command. Please, read that command's documentation to
know how to configure a mailmap file for name and email canonicalization.

This check is only able to detect known non-canonical names and emails that
are converted to their canonical forms by the C<git-check-mailmap>
command. This means that if an unknown email is used it won't be considered
an error.

Note that the C<git-check-mailmap> command is available since Git
1.8.4. Older versions of Git don't have it and Git::Hooks will complain
accordingly.

Note that you should not have Git configured to use a default mailmap file,
either by placing one named F<.mailmap> at the top level of the repository
or by setting the configuration options C<mailmap.file> and
C<mailmap.blob>. That's because if Git is configured to use a mailmap it
will convert non-canonical to canonical names and emails before passing them
to the hooks. This will invoke C<git-check-mailmap> using the C<-c> option
to temporarily configure it to use the F<MAILMAP> file.

These checks are performed by the C<pre-commit> local hook.

=head2 signature {nocheck|optional|good|trusted}

This option allows one to check commit signatures according to these values:

=over

=item * B<nocheck>

By default, or if this value is specified, no check is performed. This value
is useful to disable checks in a repository when they are enabled globally.

=item * B<optional>

This value does not require commits to be signed but if they are their
signatures must be valid (i.e. good or untrusted, but not bad).

=item * B<good>

This value requires that all commits be signed with good signatures.

=item * B<trusted>

This value requires that all commits be signed with good and trusted
signatures.

=back

This check is performed by the C<post-commit> local hook.

=head2 merger WHO

This multi-valued option restricts who can push commit merges to the
repository. WHO may be specified as a username, a groupname, or a regex,
like the C<githooks.admin> option (see L<Git::Hooks/CONFIGURATION>) so that
only users matching WHO may push merge commits.

=head2 push-limit INT

This limits the number of commits that may be pushed at once on top of any
reference. Set it to 1 to force developers to squash their commits before
pushing them. Or set it to a low number (such as 3) to deny long chains of
commits to be pushed, which are usually made by Git newbies who don't know
yet how to amend commits. ;-)

=head2 check-code CODESPEC

If the above checks aren't enough you can use this option to define a custom
code to check your commits. The code may be specified directly as the
option's value or you may specify it indirectly via the filename of a
script. If the option's value starts with "file:", the remaining is treated
as the script filename, which is executed by a B<do> command. Otherwise, the
option's value is executed directly by an eval. Either way, the code must
end with the definition of a routine, which will be called once for each
commit with the following arguments:

=over

=item * B<GIT>

The Git repository object used to grok information about the commit.

=item * B<COMMIT>

This is a hash representing a commit, as returned by the
L<Git::Repository::Plugin::GitHooks::get_commits> method.

=item * B<REF>

The name of the reference being changed, for the B<update> and the
B<pre-receive> hooks. For the B<pre-commit> hook this argument is B<undef>.

=back

The subroutine should return a boolean value indicating success. Any errors
should be produced by invoking the
B<Git::Repository::Plugin::GitHooks::error> method.

If the subroutine returns undef it's considered to have succeeded.

If it raises an exception (e.g., by invoking B<die>) it's considered
to have failed and a proper message is produced to the user.

=cut

=head1 REFERENCES

=over

=item * L<Email::Valid>

Module used to check validity of email addresses.

=item * L<A Git Horror Story: Repository Integrity With Signed Commits|http://mikegerwitz.com/papers/git-horror-story>

=back
