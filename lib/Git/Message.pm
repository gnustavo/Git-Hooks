use strict;
use warnings;

package Git::Message;
# ABSTRACT: A Git commit message

use 5.010;
use utf8;
use Carp;

sub new {
    my ($class, $msg) = @_;

    # We assume that $msg is the contents of a commit message file as
    # returned by Git::Repository::Plugin::GitHooks::read_commit_msg_file,
    # i.e., with whitespace cleaned up.

    # Our first mission is to split it up into blocks of consecutive
    # non-blank lines separated by blank lines. The blocks all end in
    # a newline.

    my @blocks = split /(?<=\n)\n+/, $msg;

    # The message blocks are aggregated in three components: title, body,
    # and footer.

    # The title is the first block, but only if it has a single line.
    # The footer is the last block, but only if it complies with a
    # strict syntax, which we parse later.  The body is comprised by
    # the blocks in the middle, joined by blank lines.  Note that all
    # three components can be defined or not independently.

    my $title = (@blocks && ($blocks[0] =~ tr/\n/\n/) == 1)
        ? shift @blocks
            : undef;

    # Our second mission is to parse the footer as a set of key:value
    # specifications, in the same way that Gerrit's commit-msg hook
    # does (http://goo.gl/tyjri). We parse the footer and populate a
    # hash.

    my %footer = ();

    if (my $footer = pop @blocks) {
        my $key = '';
        my $in_footer_comment = 0;
        foreach (split /^/m, $footer) {
            if ($in_footer_comment) {
                # A footer comment may span multiple lines and we
                # simply keep appending them to what came previously.
                $footer{$key}[-1] .= $_;
                # A line ending in a ']' marks the end of the comment.
                $in_footer_comment = 0 if /\]$/;
            } elsif (/^\[[\w-]+:/i) {
                # A line beginning with '[key:' starts a comment.
                push @{$footer{$key}}, $_;
                $in_footer_comment = 1;
            } elsif (/^([\w-]+):\s*(.*)/i) {
                # This is a key:value line
                $key = lc $1;
                push @{$footer{$key}}, [$1, $2];
            } else {
                # Oops. This is not a valid footer. So, let's push
                # $footer back to @blocks,
                push @blocks, $footer;
                # clean up %footer,
                %footer = ();
                # and break out of the loop.
                last;
            }
        }
        # What should we do if $in_footer_comment is still true here?
        # I think it's too drastic to consider the block a non-footer
        # in this case. But I'm not sure about what to do with the
        # unfinished comment we're reading. For now I'll leave it
        # unfinished there.
    }

    return bless {
        title  => $title,
        body   => @blocks ? join("\n\n", @blocks) : undef,
        footer => \%footer,
    } => $class;
}

sub title {
    my ($self, $title) = @_;
    if (defined $title) {
        $title =~ /^[^\n]+\n$/s
            or croak "A title must be a single line ending in a newline.\n";
        $self->{title} = $title;
    }
    return $self->{title};
}

sub body {
    my ($self, $body) = @_;
    if (defined $body) {
        $body =~ /\n$/s
            or croak "A body must be end in a newline.\n";
        $self->{body} = $body;
    }
    return $self->{body};
}

sub footer {
    my ($self) = @_;

    # Reconstruct the footer. The keys are ordered lexicographically,
    # except that the 'Signed-off-by' key must be the last one.

    my $footer  = $self->{footer};
    return unless %$footer;
    my $foot    = '';
    my @keys;
    if (my $signoff = delete $footer->{'signed-off-by'}) {
        @keys = sort keys %$footer;
        push @keys, 'signed-off-by';
        $footer->{'signed-off-by'} = $signoff;
    } else {
        @keys = sort keys %$footer;
    }
    foreach my $key (@keys) {
        foreach my $line (@{$footer->{$key}}) {
            if (ref $line) {
                $foot .= join(': ', @$line);
            } else {
                $foot .= $line;
            }
            $foot .= "\n";
        }
    }

    return $foot;
}

sub get_footer_keys {
    my ($self) = @_;
    return keys %{$self->{footer}};
}

sub delete_footer_key {
    my ($self, $key) = @_;
    delete $self->{footer}{lc $key};
    return;
}

sub get_footer_values {
    my ($self, $key) = @_;
    if (my $values = $self->{footer}{lc $key}) {
        return map {$_->[1]} grep {ref $_} @$values;
    } else {
        return ();
    }
}

sub add_footer_values {
    my ($self, $key, @values) = @_;
    croak "Malformed footer key: '$key'\n"
        unless $key =~ /^[\w-]+$/i;

    ## no critic (BuiltinFunctions::ProhibitComplexMappings)
    push @{$self->{footer}{lc $key}},
        map { [$key => $_] }
            map { my $copy = $_; $copy =~ s/foo/BAR/; $copy } # strip trailing newlines to keep the footer structure
                @values;
    ## use critic

    # ANCIENT PERL ALERT! The strange looking dance above with the
    # $copy variable is needed in old Perls.
    # (http://www.perl.com/pub/2011/05/new-features-of-perl-514-non-destructive-substitution.html)
    # Since Perl 5.14 that could be simply: map { s/\n+$//r }

    return;
}

sub as_string {
    my ($self) = @_;

    return join("\n", grep {defined} ($self->title, $self->body, $self->footer));
}


1; # End of Git::Message
__END__

=head1 SYNOPSIS

    use Git::Repository 'GitHooks';
    my $git = Git::Repository->new();

    use Git::Message;
    my $msg = Git::Message->new($git->read_commit_msg_file($filename));

    if (my $title = $msg->title) {
        if ($title =~ s/\.$//) {
            $msg->title($title); # remove trailing period from title
        }
    }

    my $body = $msg->body;

    $msg->add_footer_value(Issue => 'JIRA-100');

    unless ($msg->get_footer_value('Signed-off-by')) {
        die "Missing Signed-off-by in footer.\n";
    }

    $gitmore->write_commit_msg_file($filename, $msg->as_string);

=head1 DESCRIPTION

This class represents a Git commit message. Generally speaking, a
commit message can be any string whatsoever. However, the Git
community came up with a few conventions for how to best format a
message and this class embraces those conventions making it easier for
you to validate and change a commit message structure.

A conventional Git commit message consists of a sequence of non-blank-line
blocks, or paragraphs, separated by one of more blank lines. Let's call them
blocks, for short. These blocks are aggregated in three components: the
C<title>, the C<body>, and the C<footer>.

=over

=item * The C<title> is the first block of the
message. Conventionally, it must have a single line, but this class
doesn't require this. You have to check this for yourself, if it
matters to you.

=item * The C<footer> is the last block of the message, if there are
any blocks left after the title. But the footer has to follow a strict
syntax which is checked during construction. If the last block does
not follow that syntax, it's not considered a footer but just the last
block of the body.

=item * The C<body> is comprised by all the blocks between the title and
the footer, if any.

=back

Note that all three components are undefined if the message doesn't
have any blocks. If there is at least one block, the title is the first
one. In this case, either the body or the footer can be undefined
independently, depending on the number of blocks left and on the
specific contents of the last one.

=head2 Footer Syntax

The footer is a set of key:value specifications, much like the headers
of a SMTP email message or of a HTTP request. There is, however, a
notion of "in footer comments" which turn the parsing a little more
involved. These comments are used, apparently, by the Linux kernel
hackers. Well, they must know what they're doing. ;-)

The specific syntax we parse is the one implemented by L<Gerrit's
standard Git commit-msg hook|http://goo.gl/tyjri>. After the parsing,
which occurs during construction, we aggregate, for each key, all the
values and comments associated with it in the footer. Since a key may
appear multiple times with different letter case, we use their
lowercased form as the aggregation keys to avoid spurious
differences. As an example, suppose we have a message with the
following footer in it:

    Issue: JIRA-100
    [what: the hell is this comment
           doing here?]
    issue: JIRA-101
    Signed-off-by: John Contributor <jc@cpan.org>
    Signed-off-by: Gustavo Chaves <gnustavo@cpan.org>

Internally, it's kept in a data structure like this:

    {
        'issue' => [
            ['Issue' => 'JIRA-100'],
            "[what: the hell is this comment\n           doing here?]",
            ['issue' => 'JIRA-101'],
        ],
        'signed-off-by' => [
            ['Signed-off-by' => 'John Contributor <jc@cpan.org>'],
            ['Signed-off-by' => 'Gustavo Chaves <gnustavo@cpan.org>'],
        ],
    }

This way we can reconstruct the footer in string form preserving the
letter case of its keys and the order of the values and comments
inside each key. Note, however, that we do not preserve the exact
order of each line in the footer, which isn't relevant normally. The
footer stringification outputs the keys in lexicographical order with
the exception of the C<Signed-off-by> key, which, if present, is
always output last.

=head1 METHODS

=head2 new MSG

The constructor receives the commit message contents in a string,
parses it and saves the message structure internally.

IMPORTANT: The constructor parser assumes that the message contents are
cleaned up as if you had passed it through the C<git stripspace -s>
command. You can do that yourself or use the
C<Git::Repository::Plugin::GitHooks::read_commit_msg_file> method to read
the message from a file and clean it up automatically.

=head2 title [TITLE]

This returns the message title or undef if there is none.

You can change the message's title by passing a string to it.

=head2 body [BODY]

This returns the message body or undef if there is none.

You can change the message's body by passing a string to it.

=head2 footer

This returns the message footer or undef it there is none.

Note that the result string may be different from the original footer
in the message, because the lines may be reordered as we told
L<above/Footer syntax>.

=head2 get_footer_keys

This returns the list of footer keys. Multi-valued keys appear only
once in the list, in lower case.

=head2 delete_footer_key KEY

This deletes KEY from the footer, along with all of its values.

=head2 get_footer_values KEY

This returns the list of values associated with KEY, which may be in
any letter case form. The values are strings and the list will be
empty if the key doesn't appear in the footer at all.

=head2 add_footer_values KEY, VALUE...

This adds a list of VALUEs to KEY.

=head2 as_string

This returns the complete message by joining its title, body, and
footer separating them with empty lines.

=head1 SEE ALSO

=over

=item * C<Git::Repository::Plugin::GitHooks>

A Git::Repository plugin with some goodies for hook developers.

=item * B<git-commit(1) Manual Page>

This L<Git manual
page|http://www.kernel.org/pub/software/scm/git/docs/git-commit.html> has a
section called DISCUSSION which discusses some common log message policies.

=item * B<MediaWiki Git/Commit message guidelines>

L<This
document|http://www.mediawiki.org/wiki/Git/Commit_message_guidelines>
defines the MediaWiki's project commit log message guidelines.

=item * B<Proper Git Commit Messages and an Elegant Git History>

L<This is a good
discussion|http://ablogaboutcode.com/2011/03/23/proper-git-commit-messages-and-an-elegant-git-history/>
about commit log message formatting and the reasons behind them.

=item * B<GIT Commit Good Practice>

L<This document|https://wiki.openstack.org/wiki/GitCommitMessages>
defines the OpenStack's project commit policies.

=back
