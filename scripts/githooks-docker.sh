#!/usr/bin/bash -eu
# PODNAME: githooks-docker.sh
# ABSTRACT: Manage Docker images and containers to run Git::Hooks

# Specify the Git::Hooks module version (https://metacpan.org/pod/Git::Hooks).
# By default it groks the version from the Git::Hooks installed in your
# system. If you don't have it installed, you can replace the value by a static
# version string, such as '3.3.1'.
GITHOOKS_VERSION=$(perl -MGit::Hooks -E 'say $Git::Hooks::VERSION')

# Specify the Docker Perl tag (https://hub.docker.com/_/perl)
PERL_IMAGE_TAG=5.36-bullseye

# Set to "sudo" if you need to invoke docker with sudo.
SUDO=

# You shouldn't need to change the following variables
DOCKER_IMAGE_NAME=git-hooks
DOCKER_IMAGE=$DOCKER_IMAGE_NAME:$GITHOOKS_VERSION
USRHOME=$HOME
USRID=$(id -u)
USRNAME=$(id -un)
GRPID=$(id -g)
GRPNAME=$(id -gn)

error() {
    cat >&2 <<EOF
$*

Usage:
        $0 build

        $0 run REPO_ROOT HOOK_PATH [ARGS...]

        $0 start REPO_ROOT
        $0 status
        $0 stop
        $0 exec HOOK_PATH [ARGS...]

EOF
    exit 1
}

if [ $# -ge 1 ]; then
    COMMAND="$1"
    shift
else
    error "Missing COMMAND."
fi

case $COMMAND in
    build)
        set -x
        $SUDO docker build -t $DOCKER_IMAGE - <<EOF
FROM perl:${PERL_IMAGE_TAG}

# Install Git::Hooks and any other Perl module that you may need.

RUN cpanm \
      Git::Hooks@${GITHOOKS_VERSION} \
      Gerrit::REST \
      JIRA::REST \
      Perl::Critic \
    && rm -rf $HOME/.cpanm

# Uncomment the lines below to install linters for specific programming
# languages and other packages you need.

# RUN DEBIAN_FRONTEND=noninteractive apt-get -y install \
#       ansible-lint \
#       cpp-lint \
#       eslint \
#       flake8 \
#       jsonlint \
#       puppet-lint \
#       pylint \
#       rubocop \
#       shellcheck \
#       yamllint \
#     && rm -rf /var/lib/apt/lists/*

# Re-create the current group and user in the image.

RUN groupadd -g $GRPID -o $GRPNAME \
    && useradd --badname -d $USRHOME -g $GRPID -l -m -o -u $USRID $USRNAME

EOF
        ;;

    run)
        if [ $# -ge 1 ]; then
            REPO_ROOT=$1
            shift
        else
            error "Missing $COMMAND's REPO_ROOT argument"
        fi

        if [ ! -d $REPO_ROOT ]; then
            error "No such directory: $REPO_ROOT"
        fi

        if [ $# -ge 1 ]; then
            HOOK_PATH=$1
            shift
        else
            error "Missing $COMMAND's HOOK_PATH argument"
        fi

        $SUDO docker container run \
               --interactive \
               --rm \
               --volume $REPO_ROOT:$REPO_ROOT \
               --volume $USRHOME/.gitconfig:$USRHOME/.gitconfig:ro \
               --env-file=<(env | grep -E '^(HOME|(GIT|BB|GERRIT|GL)_)') \
               --user $USRID:$GRPID \
               --workdir=$PWD \
               $DOCKER_IMAGE_NAME \
               perl -MGit::Hooks -E 'run_hook(@ARGV)' -- "$HOOK_PATH" "$@"
        ;;

    start)
        if [ $# -eq 1 ]; then
            REPO_ROOT=$1
            shift
        else
            error "Missing $COMMAND's REPO_ROOT argument"
        fi

        if [ ! -d $REPO_ROOT ]; then
            error "No such directory: $REPO_ROOT"
        fi

        $SUDO docker container run \
               --detach \
               --rm \
               --volume $REPO_ROOT:$REPO_ROOT \
               --volume $USRHOME/.gitconfig:$USRHOME/.gitconfig:ro \
               --user $USRID:$GRPID \
               --name=$DOCKER_IMAGE_NAME \
               $DOCKER_IMAGE \
               sleep infinity
        ;;

    status)
        $SUDO docker container ls --all | sed -n "1p;/$DOCKER_IMAGE_NAME/p"
        ;;

    stop)
        $SUDO docker container kill $DOCKER_IMAGE_NAME
        ;;

    exec)
        if [ $# -ge 1 ]; then
            HOOK_PATH=$1
            shift
        else
            error "Missing $COMMAND's HOOK_PATH"
        fi

        $SUDO docker container exec \
               --env-file=<(env | grep -E '^(HOME|(GIT|BB|GERRIT|GL)_)') \
               --user $USRID:$GRPID \
               --workdir=$PWD \
               $DOCKER_IMAGE_NAME \
               perl -MGit::Hooks -E 'run_hook(@ARGV)' -- "$HOOK_PATH" "$@"
        ;;

    *)
        error "Invalid COMMAND: $COMMAND"
        ;;
esac
