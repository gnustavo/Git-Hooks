#!/bin/sh

# Copyright (C) 2012 by CPqD

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# http://www.dwheeler.com/essays/fixing-unix-linux-filenames.html
set -eu
IFS=`printf '\n\t'`

TMPDIR=`mktemp -d` || exit 1

set -x
cd $TMPDIR

cat >hook.pl <<'EOF'
#!/usr/bin/env perl
use Git::Hooks;
run_hook($0, @ARGV);
exit 0;

warn "### $0\n";
use Data::Dumper;
warn "+++ \@ARGV = ", Dumper(\@ARGV);
use Cwd;
warn "+++ CWD = ", getcwd();
foreach my $var (sort grep {/GIT/} keys %ENV) {
    warn "+++ \$ENV{$var} = $ENV{$var}\n";
}
warn "\n\n";
exit 0;
EOF
chmod +x hook.pl

git init repo
cd repo
echo asdf >file.txt
git add file.txt
git commit -am'initial'
while read hook; do
    ln -s ../../../hook.pl .git/hooks/$hook
done <<EOF
applypatch-msg
pre-applypatch
post-applypatch
pre-commit
prepare-commit-msg
commit-msg
post-commit
pre-rebase
post-checkout
post-merge
pre-receive
update
post-receive
post-update
pre-auto-gc
post-rewrite
EOF
cd ..

git clone --bare repo bare
ln -s ../../hook.pl bare/hooks/pre-receive

git clone bare clone

echo pushd $TMPDIR
