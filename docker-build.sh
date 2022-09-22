#!/bin/bash

# TODO:
# - Add built packages to the repo
# - Mount the repo in the container so it can be used to satisfy dependencies
# - Sign packages

set -euo pipefail

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
    local ARGS=(${MAKEPKG_ARGS+"${MAKEPKG_ARGS[@]}"} --syncdeps --noconfirm)
    cat <<"Dockerfile"
# syntax=docker/dockerfile:1.4
FROM archlinux:base-devel AS build
ARG MIRROR
RUN <<EOF
{ [ -z "${MIRROR-}" ] || echo "$MIRROR" | tr , '\n' |
    sed 's/^/Server=/' >/etc/pacman.d/mirrorlist; } &&
    pacman -Syu --noconfirm &&
    { echo y && echo y; } | pacman -Scc &&
    printf '%s.UTF-8 UTF-8\n' en_AU en_GB en_US >/etc/locale.gen && locale-gen
EOF
RUN <<EOF
echo '%wheel ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/nopasswd-%wheel &&
    useradd -mG wheel build
EOF
ENV LANG=en_AU.UTF-8
WORKDIR /package
Dockerfile
    if [[ -n ${1-} ]]; then
        cat <<Dockerfile
LABEL pkgname="$1"
RUN ["install", "-d", "-o", "build", "-g", "build", "/package", "/pkg"]
USER build
COPY . /package
RUN <<EOF
makepkg ${ARGS[*]-} &&
    makepkg --packagelist | tr '\n' '\0' | xargs -0r -I '{}' mv -v '{}' /pkg/
EOF
FROM scratch
COPY --from=build /pkg /
Dockerfile
        return
    fi
    cat <<"Dockerfile"
USER build
ENTRYPOINT ["makepkg", "--noconfirm"]
CMD ["--force", "--syncdeps"]
Dockerfile
}

# docker_build [PKGNAME]
function docker_build() {
    local TAG
    # Tag the "makepkg" image and leave others "dangling" (untagged) for easy
    # removal
    (($#)) || TAG=1
    run docker build \
        ${ARGS+"${ARGS[@]}"} \
        ${BUILD_ARGS+"${BUILD_ARGS[@]}"} \
        ${TAG:+--tag="${1-makepkg}"} \
        . -f - < <(get_dockerfile "$@" |
            tee "/tmp/Dockerfile-${0##*/}.${1-makepkg}")
}

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
    message "Usage: ${0##*/} [--prepare] [--force] [--nocheck] [--all] <REPO> [PACKAGE...]"
    exit 1
}

(($#)) || die "nothing to build"

message "==> ${VERB:-Building}:$(printf -- '\n  - %s' "$@")"

export DOCKER_BUILDKIT=1

if ((PREPARE)); then
    docker_build
    while (($#)); do
        # Update pkgver and generate .SRCINFO
        (cd "$1" && ARGS+=(--volume "$PWD:/package") &&
            docker_makepkg --nodeps --nobuild --cleanbuild --clean &&
            docker_makepkg --printsrcinfo >.SRCINFO)
        shift
    done
    exit
fi

while (($#)); do
    (cd "$1" &&
        PKG=$(mktemp -d "$PWD/.${0##*/}.XXXXXXXX") &&
        SH=$(. ./PKGBUILD && declare -p pkgname) && eval "$SH" &&
        { [[ -f .dockerignore ]] ||
            { trap "run rm$(printf ' %q' -f "$PWD/.dockerignore")" EXIT &&
                printf '%s\n' /.git /pkg/ /src/ >.dockerignore; }; } &&
        BUILD_ARGS+=(--output "$PKG") &&
        docker_build "$pkgname")
    shift
done

run docker image prune -f
