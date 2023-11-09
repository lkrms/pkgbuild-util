#!/bin/bash

set -euo pipefail

function run() {
    local IFS=$' \t\n'
    echo " -> Running: $*" >&2
    "$@"
}

DOTNET_ENDPOINT=https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json

# dotnet-core-bin <channel-version>
function dotnet-core-bin() {
    local RELEASE
    RELEASE=($(
        run curl -fsSL "$DOTNET_ENDPOINT" |
            jq -r --arg channel_version "$1" '
.["releases-index"][] | select( .["channel-version"] == $channel_version ) |
  ( .["releases.json"],
    .["latest-release"],
    (.["latest-release"] + ".sdk" + ( .["latest-sdk"] | split(".") | last )))'
    )) || return
    printf 'pkgver=%q\n' "${RELEASE[2]}"
    run curl -fsSL "${RELEASE[0]}" |
        jq -r --arg release_version "${RELEASE[1]}" '
.releases[] | select( .["release-version"] == $release_version ).sdk.files[] |
  ( select(.name == "dotnet-sdk-linux-x64.tar.gz")   + {"arch": "x86_64"},
    select(.name == "dotnet-sdk-linux-arm.tar.gz")   + {"arch": "armv7h"},
    select(.name == "dotnet-sdk-linux-arm64.tar.gz") + {"arch": "aarch64"} ) |
  ( "source_\(.arch)=(\(.url | @sh))", "sha512sums_\(.arch)=(\(.hash | @sh))")'
}

# npmjs <package>
function npmjs() {
    run curl -fsSL "https://registry.npmjs.org/$1/latest" |
        jq '
{ "pkgver": .version,
  "pkgdesc": .description,
  "url": .homepage }' |
        json_to_sh
}

# pypi <package>
function pypi() {
    run curl -fsS "https://pypi.org/pypi/$1/json" |
        jq 'def e2n: if . == "" then null else . end;
( .info + { "digests": [ .releases[.info.version][].digests ] } ) |
  { "pkgver":     .version,
    "pkgdesc":    .summary,
    "url":        ((.project_urls.Homepage | e2n) // (.home_page | e2n) // .project_url),
    "sha256sums": [ .digests[0].sha256 ] }' |
        json_to_sh
}

# github_release <owner> <repo>
function github_release() {
    github_repo "$@" &&
        github_curl "https://api.github.com/repos/$1/$2/releases/latest" |
        tee >(jq -r .body >"$NOTES") |
            jq -r .tag_name |
            sed -E 's/^[^0-9]*/pkgver=/'
}

# github_tag <owner> <repo>
function github_tag() {
    github_repo "$@" &&
        github_curl "https://api.github.com/repos/$1/$2/tags" |
        jq -r '.[].name' |
            sort -V |
            sed -En 's/^v?([0-9]+(\.[0-9]+){1,2})$/pkgver=\1/p' |
            tail -n1
}

# adobe-fonts <owner> <repo>
function adobe-fonts() {
    github_repo "$@" &&
        github_curl "https://api.github.com/repos/$1/$2/releases/latest" |
        tee >(jq -r .body >"$NOTES") |
            jq -r .tag_name |
            awk '
{ print "_relver=" $0
  gsub(/\//, "+")
  print "pkgver=" tolower($0) }' |
            sed -E '2s/(=|\+)([0-9]+\.[0-9]+)r?-?/\1\2/g'
}

# github_repo <owner> <repo>
function github_repo() {
    github_curl "https://api.github.com/repos/$1/$2" | jq '
{ "pkgdesc": .description,
  "url": (if (.homepage // "") != "" then .homepage else .html_url end) }' |
        json_to_sh
}

function github_curl() {
    run curl -fsS ${GITHUB_TOKEN:+-H @-} "$@" \
        <<<"${GITHUB_TOKEN:+"Authorization: Bearer $GITHUB_TOKEN"}"
}

function json_to_sh() {
    jq -r '
to_entries[] | "\(.key)=\(
  if .value | type == "array" then
    [ .value[] | gsub("'\''"; "'\''\\'\'''\''")] |
      "('\''" + join("'\'' '\''") + "'\'')"
  elif .value | test("[^a-z0-9+./@_-]"; "i") then
    .value | "\"" + gsub("(?<special>[\"$`])"; "\\\(.special)") + "\""
  else
    .value
  end
)"'
}

# process_package [-u] PACKAGE COMMAND [ARG...]
#
# Run COMMAND and apply its output to the given package's PKGBUILD file.
function process_package() {
    local UPDPKGSUMS=0
    [[ $1 != -u ]] || { UPDPKGSUMS=1 && shift; }

    local IFS=$'\n' PKG=$1 PKGBUILD=$1/PKGBUILD VAR OUTDATED=0 REPLACE=0 DIRTY=0
    shift

    echo "==> Checking $PKG"
    : >"$NOTES"

    if ((!OFFLINE)) && VAR=($("$@")) && [[ -n ${VAR+1} ]]; then
        if is_outdated "$PKGBUILD" "${VAR[@]}"; then
            VAR+=("pkgrel=1")
            OUTDATED=1
        else
            VAR+=("pkgrel=$((${pkgrel:-0} + 1))")
        fi
        if ((FORCE || OUTDATED)); then
            "$_DIR/update-PKGBUILD.awk" "${VAR[@]}" <"$PKGBUILD" >"$TEMP" || return
            "$DIFF" "$PKGBUILD" "$TEMP" || REPLACE=1
        fi
    elif ((!OFFLINE)); then
        echo " -> Update failed"
    fi

    if ((!REPLACE)) &&
        { { PAGER="cat" git -C "$PKG" "$DIFF" PKGBUILD | grep .; } ||
            { PAGER="cat" git -C "$PKG" "$DIFF" --staged PKGBUILD | grep .; }; }; then
        DIRTY=1
    fi

    if ((REPLACE)); then
        echo
        echo " -> Updating:" "$PKG"
        cp "$TEMP" "$PKGBUILD"
    elif ((DIRTY)); then
        echo
        echo " -> Uncommitted changes:" "$PKG"
    else
        echo " -> Already up to date:" "$PKG"
    fi

    if ((REPLACE || DIRTY)) && [[ -s $NOTES ]]; then
        echo
        echo "==> Release notes:"
        echo
        cat "$NOTES"
    fi

    if ((REPLACE || DIRTY)); then
        echo "$PKG" >>"$PENDING"
    fi

    (cd "$PKG" &&
        [[ .SRCINFO -nt PKGBUILD ]] ||
        { { ((!UPDPKGSUMS)) || run updpkgsums; } &&
            run makepkg --printsrcinfo >.SRCINFO ||
            run rm -f .SRCINFO; })

    echo
}

# is_outdated PKGBUILD <option>=<value>...
function is_outdated() (
    . "$1" && shift || exit
    IFS=$'\n'
    oldpkgver=${pkgver-}
    unset pkgver
    eval "$*" &&
        [[ -n ${pkgver+1} ]] &&
        [[ $pkgver != "$oldpkgver" ]]
)

OFFLINE=0
FORCE=0
while [[ ${1-} == -* ]]; do
    case "$1" in
    --offline)
        OFFLINE=1
        ;;
    --force)
        FORCE=1
        ;;
    *)
        echo "Invalid argument: $1"
        exit 1
        ;;
    esac
    shift
done

_DIR=$(realpath "${BASH_SOURCE[0]}")
_DIR=${_DIR%/*}

TEMP=$(mktemp)
NOTES=$(mktemp)
PENDING=$(mktemp)

DIFF=icdiff
type -P icdiff >/dev/null ||
    DIFF="diff"

(($#)) ||
    set -- *

for PKG in "$@"; do (

    if [[ ! -f $PKG/PKGBUILD ]]; then
        exit
    fi

    set +u

    . "$PKG/PKGBUILD"

    if [[ ${pkgname-} == *-git ]]; then
        exit
    fi

    python_pkgname=${pkgname#python-}

    if [[ $pkgbase == dotnet-core-3.1-bin ]]; then

        process_package "$PKG" dotnet-core-bin 3.1

    elif [[ ${source-} == *://registry.npmjs.org/*/-/* ]]; then

        package=${source#*://registry.npmjs.org/}
        package=${package%/-/*}
        process_package -u "$PKG" npmjs "$package"

    elif [[ ::${source-} == *::https://files.pythonhosted.org/packages/source/${python_pkgname::1}/${python_pkgname}/${python_pkgname}-${pkgver}.tar.gz ]]; then

        process_package "$PKG" pypi "$python_pkgname"

    elif [[ ::${source-} == *::https://github.com/*/*/*${pkgver-}.tar.gz ]]; then

        [[ $source =~ https://github.com/([^/]+)/([^/]+) ]]
        process_package -u "$PKG" github_release "${BASH_REMATCH[@]:1:2}"

    elif [[ ::${source-} == *::git+https://github.com/*/*#tag=*${pkgver-} ]]; then

        [[ $source =~ git\+https://github.com/([^/]+)/([^/]+)\.git ]]
        process_package -u "$PKG" github_tag "${BASH_REMATCH[@]:1:2}"

    elif [[ -n ${_relver-} ]] && [[ ::${source-} == *::https://github.com/adobe-fonts/*/*${_relver}.tar.gz ]]; then

        [[ $source =~ https://github.com/([^/]+)/([^/]+) ]]
        process_package -u "$PKG" adobe-fonts "${BASH_REMATCH[@]:1:2}"

    else

        echo "==> Not checked: $PKG"
        echo

    fi

); done

[[ ! -s $PENDING ]] || {
    echo "==> Packages with uncommitted changes:"
    cat "$PENDING"
    echo
}

rm -f "$TEMP" "$NOTES" "$PENDING"
