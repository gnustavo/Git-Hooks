#!/usr/bin/env perl

use 5.016;
use strict;
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

    # Private keys
    'RSA Private Key'               => qr/-----BEGIN RSA PRIVATE KEY-----/,
    'SSH Private Key'               => qr/-----BEGIN OPENSSH PRIVATE KEY-----/,
    'PKCS8 Private Key'             => qr/-----BEGIN PRIVATE KEY-----/,
    'PGP Private Key'               => qr/-----BEGIN PGP PRIVATE KEY BLOCK-----/,
    'EC Private Key'                => qr/-----BEGIN EC PRIVATE KEY-----/,

    # Passwords
    'URL with Password'             => qr'(?i)[a-z][a-z+.-]*://[^:@/]+:([^@/]+)@',
);

my $errors = 0;

my ($filename, $lineno);

while (<>) {
    if (/^\+\+\+ (.+)/) {
        $filename = $1;
    } elsif (/^\@\@ -[0-9,]+ \+(\d+)/) {
        $lineno = $1;
    } elsif (/^\+/) {
        while (my ($token, $regex) = each %tokens) {
            if (/$regex/) {
                $errors += 1;
                warn "$filename:$lineno: Secret Leakage: $token '$&'";
                last;
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

=head1 EXIT CODES

The script exits with the number of secrets found. So, it succeeds if no secret
is found and fails if it finds at least one.

=head1 SEE ALSO

=over

=item * L<How Bad Can It Git? Characterizing Secret Leakage in Public GitHub Repositories|https://blog.acolyer.org/2019/04/08/how-bad-can-it-git-characterizing-secret-leakage-in-public-github-repositories/>

This blog post sumarizes L<a paper by the
same|https://www.ndss-symposium.org/ndss-paper/how-bad-can-it-git-characterizing-secret-leakage-in-public-github-repositories/>
name which studies how secrets such as API keys, auuthorization tokens, and
private keys are commonly leaked by being inadvertently pushed to GitHub
directories. The study found that this much more common than one would think and
tells which kind of secrets are most commonly leaked like that. Moreover, it
shows specific regular expressions which can be used to detect such secrets in
text. This is the main source of inspiration for this script.

=back
