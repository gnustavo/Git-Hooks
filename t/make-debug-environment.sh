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

git init repo
cd repo
echo asdf >file.txt
git add file.txt
git commit -am'initial'
cd ..

git clone --bare repo bare
cd bare/hooks
cat >hook.pl <<'EOF'
#!/usr/bin/env perl
use Git::Hooks;
run_hook($0, @ARGV);
EOF
chmod +x hook.pl
ln -s hook.pl pre-receive
cd ../..

git clone bare clone
echo pushd $TMPDIR/clone
