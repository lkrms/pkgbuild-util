#!/bin/bash

set -euo pipefail

DOTNET_ENDPOINT=https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json

function dotnet-core-bin() {
    local RELEASE
    RELEASE=($(
        curl -fsSL "$DOTNET_ENDPOINT" |
            jq -r --arg channel_version "$1" '
.["releases-index"][] | select( .["channel-version"] == $channel_version ) |
  ( .["releases.json"],
    .["latest-release"],
    (.["latest-release"] + ".sdk" + ( .["latest-sdk"] | split(".") | last )))'
    )) || return
    printf 'pkgver=%q\n' "${RELEASE[2]}"
    curl -fsSL "${RELEASE[0]}" |
        jq -r --arg release_version "${RELEASE[1]}" '
.releases[] | select( .["release-version"] == $release_version ).sdk.files[] |
  ( select(.name == "dotnet-sdk-linux-x64.tar.gz") + {"arch": "x86_64"},
    select(.name == "dotnet-sdk-linux-arm.tar.gz") + {"arch": "armv7h"},
    select(.name == "dotnet-sdk-linux-arm64.tar.gz") + {"arch": "aarch64"} ) |
  ( "source_\(.arch)=(\(.url | @sh))", "sha512sums_\(.arch)=(\(.hash | @sh))")'
}

function process_package() {
    local IFS=$'\n' PKG=$1 PKGBUILD=$1/PKGBUILD VAR
    shift
    [[ -f $PKGBUILD ]] || {
        echo "File not found: $PKGBUILD" >&2
        exit 1
    }
    echo "==> Checking $PKG"
    VAR=($("$@"))
    awk -f "$AWK" "${VAR[@]}" <"$PKGBUILD" >"$TEMP"
    if "$DIFF" "$PKGBUILD" "$TEMP"; then
        echo " -> No update required"
    else
        echo
        echo " -> Updating:" "$PKG"
        cp "$TEMP" "$PKGBUILD"
    fi
    (cd "$PKG" &&
        [[ .SRCINFO -nt PKGBUILD ]] ||
        makepkg --printsrcinfo >.SRCINFO)
    echo
}

AWK=$(mktemp)
cat >"$AWK" <<"EOF"
BEGIN {
  for (i = 1; i < ARGC; i++) {
    if (split(ARGV[i], a, /=/) && a[1]) {
        sub(/^[^=]+=/, "", ARGV[i])
        val[a[1]]=ARGV[i]
        ARGV[i]=""
    }
  }
  FS="="
}
!in_val && /^[^ \t=]+=([^(]|(\(.*\))?[ \t]*$)/ && val[$1] {
    print $1 "=" val[$1]
    val[$1]=""
    next
}
!in_val && /^[^ \t=]+=\((.*[^ \t)])?[ \t]*$/ {
    in_val=$1
    in_val_lines=$0
    next
}
in_val && /\)[ \t]*$/ {
    if (val[in_val]) {
        print in_val "=" val[in_val]
        val[in_val] = ""
    } else {
        print in_val_lines
        print
    }
    in_val = ""
    next
}
in_val {
    in_val_lines = in_val_lines "\n" $0
    next
}
{
    print
    next
}
EOF

TEMP=$(mktemp)

DIFF=icdiff
type -P icdiff >/dev/null ||
    DIFF="diff"

for PKG in *; do
    [[ -d $PKG ]] || continue
    case "$PKG" in
    dotnet-core-3.1-bin)
        process_package "$PKG" dotnet-core-bin 3.1
        ;;
    *)
        echo "==> Not checked: $PKG" >&2
        echo
        ;;
    esac
done

rm -f "$TEMP" "$AWK"
