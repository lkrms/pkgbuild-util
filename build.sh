#!/bin/bash

set -euo pipefail
shopt -s nullglob

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

[[ ! -r ${LK_BASE-/opt/lk-platform}/etc/lk-platform/lk-platform.conf ]] ||
    . "${LK_BASE-/opt/lk-platform}/etc/lk-platform/lk-platform.conf" || exit

ARGS=(
    --noconfirm
    --remove
    --chroot
    --makepkg-conf=/etc/makepkg.conf
)
[[ -z ${GPGKEY+1} ]] || ARGS+=(--sign)
[[ -z ${CCACHE_DIR+1} ]] || ARGS+=(--bind-rw "$CCACHE_DIR:/build/.ccache")
[[ -z ${LK_ARCH_AUR_CHROOT_DIR:+1} ]] || ARGS+=(--directory "$LK_ARCH_AUR_CHROOT_DIR")

PREPARE=0
ALL=0
REPO=
while (($#)); do
    case "$1" in
    --prepare)
        PREPARE=1
        ;;
    --all)
        ALL=1
        ;;
    --force | --nocheck)
        ARGS+=("$1")
        ;;
    *)
        REPO=$1
        shift
        break
        ;;
    esac
    shift
done

[[ -n $REPO ]] &&
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

message "==> Building:$(printf -- '\n -> %s' "$@")"

if ((PREPARE)); then
    while (($#)); do
        # Update pkgver and generate .SRCINFO
        (cd "$1" &&
            run makepkg --nodeps --noconfirm --nobuild &&
            run makepkg --printsrcinfo >.SRCINFO)
        shift
    done
    exit
elif ! type -P aur >/dev/null; then
    die "command not found: aur"
fi

ARGS=(
    --database "$REPO"
    "${ARGS[@]}"
)

# If building multiple packages in the same directory, use `aur graph` to queue
# dependencies before dependents, otherwise build packages in commandline order
if (($# > 1)) && (($(printf '%s\n' "${@%/*}" | sort -u | wc -l) == 1)); then
    QUEUE=$(mktemp)
    cd "${1%/*}"
    aur graph "${@/%//.SRCINFO}" | tsort | tac >"$QUEUE"
    run aur build "${ARGS[@]}" --arg-file "$QUEUE"
    rm -f "$QUEUE"
else
    while (($#)); do
        (cd "$1" &&
            aur build "${ARGS[@]}")
        shift
    done
fi
