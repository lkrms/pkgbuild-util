#!/bin/bash

# TODO:
# - [x] Add built packages to the repo
# - [x] Mount the repo in the container so it can be used to satisfy dependencies
# - [ ] Sign packages

set -euo pipefail
shopt -s nullglob extglob

function die() {
    local s=$?
    ((!$#)) || echo "${0##*/}: $1" >&2
    (exit $s) && false || exit
}

function message() {
    echo "$1" >&2
}

function run() {
    message " -> Running: $*"
    "$@"
}

# get_dockerfile [PKGNAME]
function get_dockerfile() {
    cat <<"Dockerfile"
# syntax=docker/dockerfile:1.4
FROM archlinux:base-devel AS build
ARG USER_ID
ARG GROUP_ID
ARG REPO=aur
ARG MIRROR
RUN <<EOF
[ "${USER_ID:+1}${GROUP_ID:+1}" = 11 ] ||
    { echo "Mandatory build arguments not set" >&2 && false || exit; }
echo '%wheel ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/nopasswd-%wheel &&
    groupadd -g "$GROUP_ID" build &&
    useradd -u "$USER_ID" -g "$GROUP_ID" -mG wheel build &&
    install -d -o build -g build /repo /package /pkg &&
    runuser -u build -- repo-add "/repo/$REPO.db.tar.xz" >/dev/null 2>&1 &&
    cat >>/etc/pacman.conf <<CONF &&
[$REPO]
SigLevel = Optional TrustAll
Server = file:///repo
CONF
    install -Dm 0755 /dev/stdin /usr/local/bin/makepkg-wrapper <<"SH" &&
#!/bin/sh

sudo pacman -Syyu --noconfirm &&
    makepkg "$@" &&
    makepkg --packagelist | tr '\n' '\0' | xargs -0r -I '{}' mv -v '{}' /pkg/
SH
{ [ -z "${MIRROR-}" ] || echo "$MIRROR" | tr , '\n' |
    sed 's/^/Server=/' >/etc/pacman.d/mirrorlist; } &&
    pacman -Syu --noconfirm &&
    { echo y && echo y; } | pacman -Scc &&
    printf '%s.UTF-8 UTF-8\n' en_AU en_GB en_US >/etc/locale.gen && locale-gen
EOF
ENV LANG=en_AU.UTF-8
WORKDIR /package
USER build
ENTRYPOINT ["/usr/local/bin/makepkg-wrapper", "--noconfirm"]
CMD ["--force", "--syncdeps", "--cleanbuild", "--clean"]
Dockerfile
}

# docker_build
function docker_build() { (
    CONTEXT=$(mktemp -d) &&
        trap "run rm$(printf ' %q' -rf "$CONTEXT")" EXIT &&
        cd "$CONTEXT" || exit
    run docker build \
        ${ARGS+"${ARGS[@]}"} \
        ${BUILD_ARGS+"${BUILD_ARGS[@]}"} \
        --tag=makepkg \
        . -f - < <(get_dockerfile)
); }

function docker_makepkg() {
    run docker run \
        ${ARGS+"${ARGS[@]}"} \
        --rm \
        --interactive \
        --tty \
        makepkg \
        "$@"
}

[[ ! -r ${LK_BASE-/opt/lk-platform}/etc/lk-platform/lk-platform.conf ]] ||
    . "${LK_BASE-/opt/lk-platform}/etc/lk-platform/lk-platform.conf" || exit

ARGS=()
[[ ! $MACHTYPE =~ ^(arm|aarch)64- ]] || ARGS+=(--platform linux/amd64)

BUILD_ARGS=()
[[ -z ${MIRROR:=${LK_ARCH_MIRROR-}} ]] || BUILD_ARGS+=(--build-arg "MIRROR=$MIRROR")

MAKEPKG_ARGS=()
PREPARE=0
VERB=
ALL=0
REPO=
while (($#)); do
    case "$1" in
    --prepare)
        PREPARE=1
        VERB=Preparing
        ;;
    --all)
        ALL=1
        ;;
    --force | --nocheck)
        MAKEPKG_ARGS+=("$1")
        ;;
    *)
        REPO=$1
        shift
        break
        ;;
    esac
    shift
done

{ ((PREPARE)) || [[ -n $REPO ]]; } &&
    case "$ALL,$#,${1-}" in
    0,0* | 0,1,PKGBUILD)
        [[ -f PKGBUILD ]] &&
            set -- "$PWD"
        ;;
    1,0*)
        set -- "$PWD"/*/PKGBUILD
        (($#)) &&
            set -- "${@%/PKGBUILD}"
        ;;
    0,*)
        set -- "${@%/PKGBUILD}"
        (while (($#)); do
            [[ -d $1 ]] && [[ -f $1/PKGBUILD ]] ||
                die "no PKGBUILD: $1"
            shift
        done)
        ;;
    esac || {
    message "Usage: ${0##*/} [--prepare] [--force] [--nocheck] [--all] <REPO>[:REPO_PATH] [PACKAGE...]"
    exit 1
}

(($#)) || die "nothing to build"

if [[ $REPO == *:* ]]; then
    SERVER=${REPO#*:}
    REPO=${REPO%%:*}
else
    SERVER=$(pacman-conf -r "$REPO" Server 2>/dev/null |
        sed -En 's/^file:\/\///p' | grep .) && [[ -d $SERVER ]] ||
        die "unable to locate repo '$REPO' on filesystem"
fi

BUILD_ARGS+=(--build-arg "USER_ID=$(id -u)")
BUILD_ARGS+=(--build-arg "GROUP_ID=$(id -g)")
BUILD_ARGS+=(--build-arg "REPO=$REPO")

message "==> ${VERB:-Building}:$(printf -- '\n  - %s' "$@")"

export DOCKER_BUILDKIT=1

docker_build

if ((PREPARE)); then
    while (($#)); do
        # Update pkgver and generate .SRCINFO
        (cd "$1" && ARGS+=(--mount "type=bind,source=$PWD,target=/package") &&
            docker_makepkg --nodeps --nobuild --cleanbuild --clean &&
            docker_makepkg --printsrcinfo >.SRCINFO)
        shift
    done
    exit
fi

while (($#)); do
    (cd "$1" &&
        PKG=$(mktemp -d "$PWD/.${0##*/}.XXXXXXXX") &&
        trap "run rm$(printf ' %q' -rf "$PKG")" EXIT &&
        ARGS+=(
            --mount "type=bind,source=$PWD,target=/package"
            --mount "type=bind,source=$PKG,target=/pkg"
            --mount "type=bind,source=$SERVER,target=/repo"
        ) &&
        docker_makepkg &&
        cd "$PKG" &&
        ASSETS=(!(*.sig)) &&
        { [[ -n ${ASSETS+1} ]] || die "no assets generated"; } &&
        mv -vf -- * "${SERVER%/}/" &&
        cd "$SERVER" &&
        repo-add -R "$REPO.db.tar.xz" "${ASSETS[@]}")
    shift
done

run docker image prune -f
