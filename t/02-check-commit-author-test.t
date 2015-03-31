## no critic (Modules::RequireVersionVar)
## no critic (Documentation)
use 5.010;
use strict;
use warnings;

use Test::Most;
use Test::Git;
use Config;
use Path::Tiny;
use Data::Dumper;
use Carp::Assert::More;
use Params::Validate qw(:all);

sub install_hooks {
    my ($repo_path, $extra_perl, @hooks) = @_;
    my $hooks_dir = path($repo_path)->child('hooks');
    my $hook_pl   = $hooks_dir->child('hook.pl');
    {
        ## no critic (RequireBriefOpen)
        open my $fh, '>', $hook_pl or BAIL_OUT("Can't create $hook_pl: $!");
        state $debug = $ENV{DBG} ? '-d' : '';
        use Cwd; my $cwd = path(cwd);
        state $bliblib = $cwd->child('blib', 'lib');
        print $fh <<"EOF";
#!$Config{perlpath} $debug
use strict;
use warnings;
use lib '$bliblib';
EOF

        state $pathsep = $^O eq 'MSWin32' ? ';' : ':';
        if (defined $ENV{PERL5LIB} and length $ENV{PERL5LIB}) {
            foreach my $path (reverse split "$pathsep", $ENV{PERL5LIB}) {
                say $fh "use lib '$path';" if $path;
            }
        }

        print $fh <<'EOF';
use Git::Hooks;
EOF

        print $fh $extra_perl if defined $extra_perl;

        # Not all hooks defined the GIT_DIR environment variable
        # (e.g., pre-rebase doesn't).
        print $fh <<"EOF";
\$ENV{GIT_DIR}    = '.git' unless exists \$ENV{GIT_DIR};
\$ENV{GIT_CONFIG} = "\$ENV{GIT_DIR}/config";
EOF

        # Reset HOME to avoid reading ~/.gitconfig
        print $fh <<"EOF";
\$ENV{HOME}       = '';
EOF

        # Hooks on Windows are invoked indirectly.
        if ($^O eq 'MSWin32') {
            print $fh <<"EOF";
my \$hook = shift;
run_hook(\$hook, \@ARGV);
EOF
        } else {
            print $fh <<"EOF";
run_hook(\$0, \@ARGV);
EOF
        }
    }
    chmod 0755 => $hook_pl;

    @hooks = qw/ applypatch-msg pre-applypatch post-applypatch
        pre-commit prepare-commit-msg commit-msg
        post-commit pre-rebase post-checkout post-merge
        pre-receive update post-receive post-update
        pre-auto-gc post-rewrite /
            unless @hooks;

    foreach my $hook (@hooks) {
        my $hookfile = $hooks_dir->child($hook);
        if ($^O eq 'MSWin32') {
            (my $perl = $^X) =~ tr:\\:/:;
            $hook_pl =~ tr:\\:/:;
            my $d = $ENV{DBG} ? '-d' : '';
            my $script = <<"EOF";
#!/bin/sh
$perl $d $hook_pl $hook \"\$@\"
EOF
            path($hookfile)->spew($script)
                or BAIL_OUT("can't path('$hookfile')->spew('$script')\n");
            chmod 0755 => $hookfile;
        } else {
            symlink 'hook.pl', $hookfile
                or BAIL_OUT("can't symlink '$hooks_dir', '$hook': $!");
        }
    }
    return;
}

# check there is a git binary available, or skip all
has_git( '1.7.10' );

# create a new, empty repository in a temporary location
# and return a Git::Repository object
my $central = test_repository(
        temp  => [ CLEANUP => 0 ],    # File::Temp::tempdir options
        init  => [ '--bare' ],        # git init options
        git   => {},                  # Git::Repository options
    );
 
# diag(Dumper($central));
diag("Bare repository created at '$central->{'git_dir'}'.");

# clone an existing repository in a temporary location
# and return a Git::Repository object
 my $clone = test_repository(
         temp  => [ CLEANUP => 0 ],
         clone => [ "file://$central->{'git_dir'}" ],
         git   => {
             env => {
                # GIT_COMMITTER_EMAIL => 'book@cpan.org',
                # GIT_COMMITTER_NAME  => 'Philippe Bruhat (BooK)',
            },
        }, 
     );

diag(Dumper($clone));
diag("Cloned repository created at '$clone->{'git_dir'}'.");
path($clone->{'work_tree'})->child('test-file.txt')->spew("The only row.");
install_hooks( $clone->{'git_dir'}, undef, 'pre-commit' );

sub can_commit {
    my %params = validate(
        @_,
        {
            'repo' => { isa => 'Git::Repository', },
            'test_name' => { type => SCALAR, },
            'files' => { type => ARRAYREF, optional => 1, },
            'commit_msg' => { type => SCALAR, },
            'author'  => { type => SCALAR, optional => 1, },
        }
    );
    my $work_tree = $params{'repo'}->{'work_tree'};
    my $repo = $params{'repo'};
    if( $params{'files'} ) {
        foreach my $file (@{$params{'files'}}) {
            print Dumper($file);
            my $f = path($work_tree)->child($file->{'path'});
            $f->spew($file->{'content'}//$params{'test_name'});
            $repo->run('add', $file->{'path'});
        }
    }
    $repo->run('commit', '-m', $params{'commit_msg'}, '--author', $params{'author'});
    return 1;
}

can_commit(
    'repo' => $clone,
    'test_name' => 'One test',
    'files' => [ { 'path' => 'my-file', 'content' => 'my file content', }, ],
    'commit_msg' => 'Initial commit', 'author' => 'Mikko <mikko@site>',
    );

#
# sub check_can_commit {
#     my ( $testname, $msg, $author ) = @_;
#     $msgfile->spew($msg)
#       or BAIL_OUT("check_can_commit: can't '$msgfile'->spew('$msg')\n");
#     $file->append($testname)
#       or BAIL_OUT("check_can_commit: can't '$file'->append('$testname')\n");
#     $repo->command( add => $file );
#     test_ok(
#         $testname, $repo, 'commit', '-F', $msgfile,
#         defined $author && '--author',
#         defined $author && $author
#     );
# }
#
# sub check_cannot_commit {
#     my ( $testname, $regex, $msg, $author ) = @_;
#     $msgfile->spew($msg)
#       or BAIL_OUT("check_cannot_commit: can't '$msgfile'->spew('$msg')\n");
#     $file->append($testname)
#       or BAIL_OUT("check_cannot_commit: can't '$file'->append('$testname')\n");
#     $repo->command( add => $file );
#     if ($regex) {
#         test_nok_match(
#             $testname, $regex, $repo, 'commit', '-F', $msgfile,
#             defined $author && '--author',
#             defined $author && $author
#         );
#     }
#     else {
#         test_nok(
#             $testname, $repo, 'commit', '-F', $msgfile,
#             defined $author && '--author',
#             defined $author && $author
#         );
#     }
# }
#
# sub check_can_push {
#     my ( $testname, $ref ) = @_;
#     new_commit( $repo, $file, $testname );
#     test_ok( $testname, $repo, 'push', $clone->repo_path(), $ref || 'master' );
# }
#
# sub check_cannot_push {
#     my ( $testname, $regex, $ref ) = @_;
#     new_commit( $repo, $file, $testname );
#     test_nok_match( $testname, $regex, $repo,
#         'push', $clone->repo_path(), $ref || 'master' );
# }
#
# install_hooks( $repo, undef, 'pre-commit' );
#
# $repo->command( config => "githooks.plugin", 'CheckCommitAuthor' );
#
# # Authors
#
# # No limits
# check_can_commit(
#     'This author can commit (1): pattern',
#     'Dummy commit message',
#     'A UThor <a.uthor@site>'
# );
#
# # Limit by matching pattern.
# $repo->command(
#     config => 'githooks.checkcommitauthor.match',
#     '(<a.uthor@site>|An Other <an.other@si.te>)'
# );
#
# check_can_commit(
#     'This author can commit (2): pattern',
#     'Dummy commit message',
#     'A UThor <a.uthor@site>'
# );
#
# check_can_commit(
#     'This author can commit (3): pattern',
#     'Dummy commit message',
#     'An Other <an.other@si.te>'
# );
#
# check_cannot_commit(
#     'This author cannot commit (1): pattern',
#     qr/commit author \'AnOther/,
#     'Dummy commit message',
#     'AnOther <an.other@si.te>'
# );
#
# $repo->command(
#     config => 'githooks.checkcommitauthor.match',
#     '!(<.*\@wrong.company>|<.*\@bad.company>)'
# );
#
# check_cannot_commit(
#     'This author cannot commit (2): pattern',
#     qr/commit author \'An.* Other.*SHOULD.* NOT/,
#     'Dummy commit message',
#     'An Other <an.other@wrong.company>'
# );
#
# check_cannot_commit(
#     'This author cannot commit (3): pattern',
#     qr/commit author \'One.* An.* Other.*SHOULD.* NOT/,
#     'Dummy commit message',
#     'One An Other <one.an.other@bad.company>'
# );
#
# # Limit by mailmap
#
# $repo->command( config => '--unset-all', 'githooks.checkcommitauthor.match' );
# $repo->command( config => 'githooks.checkcommitauthor.mailmap', '.mailmap' );
#
# # Set normal defaults. Here just for reference.
# $repo->command(
#     config => 'githooks.checkcommitauthor.allow-mailmap-aliases',
#     '1'
# );
# $repo->command(
#     config => 'githooks.checkcommitauthor.match-mailmap-name',
#     '1'
# );
#
# my $mapfile = path($T)->child('repo')->child('.mailmap');
# my $map     = '# The .mailmap file
# Proper Committer <proper.committer@company.com>
# Al H Proper <al.proper@comp.com> Al Other <al.other@pomp.pom>
# Me Too <me.too@some.site> <me.too@wrong.site> # Am I really here (comment)?
# <i.alone@any.where> <me.alone@some.where>
# ';
# $mapfile->spew($map) or BAIL_OUT(": can't '$mapfile'->spew('$map')\n");
#
# check_can_commit(
#     'This author can commit (1): mailmap(name)',
#     'Dummy commit message',
#     'Proper Committer <proper.committer@company.com>'
# );
#
# # Match with name, if name exists in mailmap.
# $repo->command(
#     config => 'githooks.checkcommitauthor.match-mailmap-name',
#     '0'
# );
# check_can_commit(
#     'This author can commit (2): mailmap (no name)',
#     'Dummy commit message',
#     'With Wrong Name <i.alone@any.where>'
# );
# $repo->command(
#     config => 'githooks.checkcommitauthor.match-mailmap-name',
#     '1'
# );
# check_cannot_commit(
#     'This author cannot commit (3): mailmap(no name),ask with name.',
#     undef,
#     'Dummy commit message',
#     'With Wrong Name <i.alone@any.where>'
# ); # This test is sort of crazy,
#    # because match-mailmap-name is set, and yet the mailmap doesn't support it:
#    # <i.alone@any.where> has no name! So the test must fail! No commit possible!
#
# # Try with aliases.
# $repo->command(
#     config => 'githooks.checkcommitauthor.match-mailmap-name',
#     '0'
# );
# $repo->command(
#     config => 'githooks.checkcommitauthor.allow-mailmap-aliases',
#     '1'
# );
# check_can_commit(
#     'This author can commit (4): mailmap',
#     'Dummy commit message',
#     'Al Other <al.other@pomp.pom>'
# );
#
# $repo->command(
#     config => 'githooks.checkcommitauthor.match-mailmap-name',
#     '1'
# );
# $repo->command(
#     config => 'githooks.checkcommitauthor.allow-mailmap-aliases',
#     '0'
# );
# check_cannot_commit(
#     'This author cannot commit (2): mailmap',
#     undef,
#     'Dummy commit message',
#     'Al Other <al.other@pomp.pom>'
# );
#
# # Server-side
# $repo->command( config => '--unset-all', 'githooks.checkcommitauthor.mailmap' );
#
# use Data::Dumper;
# diag("clone:" . Dumper($clone));
# diag("clone->opts->Repository:" . Dumper($clone->{'opts'}->{'Repository'}));
# my @config_rows = ("[githooks]\n", "    plugin = CheckCommitAuthor\n",
#     "[githoooks \"checkcommitauthor\"]\n", "    match = \"^Mallikas\$\"\n");
# $clone->{'opts'}->{'Repository'}->child('config')->append(@config_rows);
#
#
# check_can_push(
#     'This author\'s commit cannot push (1): match',
# );
#
done_testing();

