#!/usr/bin/env perl
# PODNAME: find-secret-leakage-in-git-diff.pl
# ABSTRACT: find secrets leaking in a Git repository
## no critic (RequireCarping)

use v5.16.0;
use warnings;

my %tokens = (
    # Article's TABLE III
    'Amazon AWS Access Key ID'      => qr/AKIA[0-9A-Z]{16}/,
    'Amazon MWS Auth Token'         => qr/amzn\.mws\.[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/,
    'Facebook Access Token'         => qr/EAACEdEose0cBA[0-9a-zA-Z]+/,
    'Google API Key'                => qr/AIza[0-9a-zA-Z_-]{35}/,
    'Google OAuth ID'               => qr/\d+-[0-9a-zA-Z_]{32}\.apps\.googleusercontent\.com/,
    'MailChimp API Key'             => qr/[0-9a-f]{32}-us\d{1,2}/,
    'MailGun API Key'               => qr/key-[0-9a-zA-Z]{32}/,
    'PayPal Braintree Access Token' => qr/access_token\$production\$[0-9a-z]{16}\$[0-9a-f]{32}/,
    'Picatic API Key'               => qr/sk_live_[0-9a-z]{32}/,
    'Square Access Token'           => qr/sq0atp-[0-9a-zA-Z_-]{22}/,
    'Square OAuth Secret'           => qr/sq0csp-[0-9a-zA-Z_-]{43}/,
    'Stripe API Key'                => qr/[rs]k_live_[0-9a-zA-Z]{24}/,
    'Twilio API Key'                => qr/SK[0-9a-fA-F]{32}/,
    'Twitter Access Token'          => qr/[1-9]\d+-[0-9a-zA-Z]{40}/,

    # Private keys (RSA, SSH, PKCS8, PGP, EC, etc.)
    'Private Key'                   => qr/-----BEGIN [A-Z ]*?PRIVATE KEY(?: BLOCK)?-----/,

    # Passwords
    'URL with Password'             => qr'(?i)[a-z][a-z+.-]*://[^:@/]+:([^@/]+)@',
);

my $errors = 0;

my ($filename, $lineno, $skip) = ('', 0, 0);

while (<>) {
    if (/^\+\+\+ (.+)/) {
        $filename = $1;
    } elsif (/^\@\@ -[0-9,]+ \+(\d+)/) {
        $lineno = $1;
    } elsif (/^\ /) {
        $lineno += 1;
    } elsif (/^\+/) {
        if (/## not a secret leak ?(begin|end)?/) {
            if ($skip) {
                $skip = 0 if defined $1 && $1 eq 'end';
            } else {
                $skip = 1 if defined $1 && $1 eq 'begin';
            }
            $lineno += 1;
            next;
        }
        unless ($skip) {
            while (my ($token, $regex) = each %tokens) {
                if (/$regex/) {
                    $errors += 1;
                    warn "$filename:$lineno: Secret Leakage: $token '$&'";
                    last;
                }
            }
        }
        $lineno += 1;
    }
}

exit $errors;


__END__
=encoding utf8

=head1 NAME

find-secret-leakage-in-git-diff.pl - Find secrets leakage in a Git diff

=head1 SYNOPSIS

  find-secret-leakage-in-git-diff.pl [FILE]

=head1 DESCRIPTION

This script reads from a FILE or from STDIN the output of a git-diff command
containing a patch and tries to detect secrets in the lines being added. It's
intended to be invoked by the L<Git::Hooks::CheckDiff> plugin, which feds it the
output of either git-diff-index or git-diff-tree with the following options:

    git diff* -p -U0 --no-color --diff-filter=AM --no-prefix

A "secret" is an API key, an authorization token, or a private key, which
shouldn't be leaked by being saved in a versioned file. So, this script should
be used in a pre-commit hook in order to alert the programmer when she does
that.

When it finds a secret in the git-diff output it outputs a line like this:

  <path>:<lineno>: Secret Leakage: <secret type> '<secret>'

Meaning:

=over 4

=item * <path>

The path of the file adding the secret.

=item * <lineno>

The line number in the file where the secret is being added.

=item * <secret type>

The type of the secret found.

=item * <secret>

The specific secret found.

=back

Sometimes you need to have a pseudo-secret in a file. Perhaps it's a credential
used only in your test environment or as an example. You can mark these secrets
so that this script disregards them. If you can, add the following mark in the
same line of your pseudo-secret, like this:

  my $aws_access_key = 'AKIA1234567890ABCDEF'; ## not a secret leak

The mark is the string C<## not a secret leak>. The two hashes are part of it!

Sometimes you can't put the mark in the same line. Lines beginning private keys,
for example, do not have room for anything else. In these cases you can skip a
whole block marking its beginning and end like this:

  ## not a secret leak begin
  my $rsa_private_key = <<EOS;
  -----BEGIN RSA PRIVATE KEY-----
  izfrNTmQLnfsLzi2Wb9xPz2Qj9fQYGgeug3N2MkDuVHwpPcgkhHkJgCQuuvT+qZI
  MbS2U6wTS24SZk5RunJIUkitRKeWWMS28SLGfkDs1bBYlSPa5smAd3/q1OePi4ae
  <...>
  8S86b6zEmkser+SDYgGketS2DZ4hB+vh2ujSXmS8Gkwrn+BfHMzkbtio8lWbGw0l
  eM1tfdFZ6wMTLkxRhBkBK4JiMiUMvpERyPib6a2L6iXTfH+3RUDS6A==
  -----END RSA PRIVATE KEY-----
  EOS
  ## not a secret leak end

None of the lines inside the block will be denounced as leaks.

=head1 EXIT CODES

The script exits with the number of secrets found. So, it succeeds if no secret
is found and fails if it finds at least one.

=head1 SEE ALSO

=over

=item * L<How Bad Can It Git? Characterizing Secret Leakage in Public GitHub Repositories|https://blog.acolyer.org/2019/04/08/how-bad-can-it-git-characterizing-secret-leakage-in-public-github-repositories/>

This blog post summarizes L<a paper by the same
name|https://www.ndss-symposium.org/ndss-paper/how-bad-can-it-git-characterizing-secret-leakage-in-public-github-repositories/>
which studies how secrets such as API keys, authorization tokens, and private
keys are commonly leaked by being inadvertently pushed to GitHub
directories. The study found that this much more common than one would think and
tells which kind of secrets are most commonly leaked like that. Moreover, it
shows specific regular expressions which can be used to detect such secrets in
text. This is the main source of inspiration for this script.

=back
