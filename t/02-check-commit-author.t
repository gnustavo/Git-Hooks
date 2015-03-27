use 5.010;
use strict;
use warnings;
use lib 't';
use Path::Tiny;
use Test::Most;
die_on_fail;

use Log::Any::Adapter ('Stderr');    # Activate to get all log messages.

BEGIN { require "test-functions.pl" }

my ( $repo, $file, $clone, $T ) = new_repos();

my $msgfile = path($T)->child('msg.txt');

sub check_can_commit {
    my ( $testname, $msg, $author ) = @_;
    $msgfile->spew($msg)
      or BAIL_OUT("check_can_commit: can't '$msgfile'->spew('$msg')\n");
    $file->append($testname)
      or BAIL_OUT("check_can_commit: can't '$file'->append('$testname')\n");
    $repo->command( add => $file );
    test_ok(
        $testname, $repo, 'commit', '-F', $msgfile,
        defined $author && '--author',
        defined $author && $author
    );
}

sub check_cannot_commit {
    my ( $testname, $regex, $msg, $author ) = @_;
    $msgfile->spew($msg)
      or BAIL_OUT("check_cannot_commit: can't '$msgfile'->spew('$msg')\n");
    $file->append($testname)
      or BAIL_OUT("check_cannot_commit: can't '$file'->append('$testname')\n");
    $repo->command( add => $file );
    if ($regex) {
        test_nok_match(
            $testname, $regex, $repo, 'commit', '-F', $msgfile,
            defined $author && '--author',
            defined $author && $author
        );
    }
    else {
        test_nok(
            $testname, $repo, 'commit', '-F', $msgfile,
            defined $author && '--author',
            defined $author && $author
        );
    }
}

sub check_can_push {
    my ( $testname, $ref ) = @_;
    new_commit( $repo, $file, $testname );
    test_ok( $testname, $repo, 'push', $clone->repo_path(), $ref || 'master' );
}

sub check_cannot_push {
    my ( $testname, $regex, $ref ) = @_;
    new_commit( $repo, $file, $testname );
    test_nok_match( $testname, $regex, $repo,
        'push', $clone->repo_path(), $ref || 'master' );
}

install_hooks( $repo, undef, 'pre-commit' );

$repo->command( config => "githooks.plugin", 'CheckCommitAuthor' );

# Authors

# No limits
check_can_commit(
    'This author can commit (1): pattern',
    'Dummy commit message',
    'A UThor <a.uthor@site>'
);

# Limit by matching pattern.
$repo->command(
    config => 'githooks.checkcommitauthor.match',
    '(<a.uthor@site>|An Other <an.other@si.te>)'
);

check_can_commit(
    'This author can commit (2): pattern',
    'Dummy commit message',
    'A UThor <a.uthor@site>'
);

check_can_commit(
    'This author can commit (3): pattern',
    'Dummy commit message',
    'An Other <an.other@si.te>'
);

check_cannot_commit(
    'This author cannot commit (1): pattern',
    qr/commit author \'AnOther/,
    'Dummy commit message',
    'AnOther <an.other@si.te>'
);

$repo->command(
    config => 'githooks.checkcommitauthor.match',
    '!(<.*\@wrong.company>|<.*\@bad.company>)'
);

check_cannot_commit(
    'This author cannot commit (2): pattern',
    qr/commit author \'An.* Other.*SHOULD.* NOT/,
    'Dummy commit message',
    'An Other <an.other@wrong.company>'
);

check_cannot_commit(
    'This author cannot commit (3): pattern',
    qr/commit author \'One.* An.* Other.*SHOULD.* NOT/,
    'Dummy commit message',
    'One An Other <one.an.other@bad.company>'
);

# Limit by mailmap

$repo->command( config => '--unset-all', 'githooks.checkcommitauthor.match' );
$repo->command( config => 'githooks.checkcommitauthor.mailmap', '.mailmap' );

# Set normal defaults. Here just for reference.
$repo->command(
    config => 'githooks.checkcommitauthor.allow-mailmap-aliases',
    '1'
);
$repo->command(
    config => 'githooks.checkcommitauthor.match-mailmap-name',
    '1'
);

my $mapfile = path($T)->child('repo')->child('.mailmap');
my $map     = '# The .mailmap file
Proper Committer <proper.committer@company.com>
Al H Proper <al.proper@comp.com> Al Other <al.other@pomp.pom>
Me Too <me.too@some.site> <me.too@wrong.site> # Am I really here (comment)?
<i.alone@any.where> <me.alone@some.where>
';
$mapfile->spew($map) or BAIL_OUT(": can't '$mapfile'->spew('$map')\n");

check_can_commit(
    'This author can commit (1): mailmap(name)',
    'Dummy commit message',
    'Proper Committer <proper.committer@company.com>'
);

# Match with name, if name exists in mailmap.
$repo->command(
    config => 'githooks.checkcommitauthor.match-mailmap-name',
    '0'
);
check_can_commit(
    'This author can commit (2): mailmap (no name)',
    'Dummy commit message',
    'With Wrong Name <i.alone@any.where>'
);
$repo->command(
    config => 'githooks.checkcommitauthor.match-mailmap-name',
    '1'
);
check_cannot_commit(
    'This author cannot commit (3): mailmap(no name),ask with name.',
    undef,
    'Dummy commit message',
    'With Wrong Name <i.alone@any.where>'
); # This test is sort of crazy,
   # because match-mailmap-name is set, and yet the mailmap doesn't support it:
   # <i.alone@any.where> has no name! So the test must fail! No commit possible!

# Try with aliases.
$repo->command(
    config => 'githooks.checkcommitauthor.match-mailmap-name',
    '0'
);
$repo->command(
    config => 'githooks.checkcommitauthor.allow-mailmap-aliases',
    '1'
);
check_can_commit(
    'This author can commit (4): mailmap',
    'Dummy commit message',
    'Al Other <al.other@pomp.pom>'
);

$repo->command(
    config => 'githooks.checkcommitauthor.match-mailmap-name',
    '1'
);
$repo->command(
    config => 'githooks.checkcommitauthor.allow-mailmap-aliases',
    '0'
);
check_cannot_commit(
    'This author cannot commit (2): mailmap',
    undef,
    'Dummy commit message',
    'Al Other <al.other@pomp.pom>'
);

done_testing();

