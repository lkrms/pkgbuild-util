#!/bin/bash

# For example, `dotnet-core-bin 3.1` currently generates the following output,
# which `process_package` uses to update `dotnet-core-3.1-bin/PKGBUILD`:
#
#     pkgver=3.1.28.sdk422
#     source_armv7h=('https://download.visualstudio.microsoft.com/download/pr/e5ec7845-008a-4b7d-a247-c314f2407b8d/9117e05fa19f0217a030666df6b6eb9d/dotnet-sdk-3.1.422-linux-arm.tar.gz')
#     sha512sums_armv7h=('9cbccaf303f693657f797ae81eec2bd2ea55975b7ae71a8add04175a0104545208fa2f9c536b97d91fa48c6ea890678eb0772a448977bce4acbc97726ac47f83')
#     source_aarch64=('https://download.visualstudio.microsoft.com/download/pr/fdf76122-e9d5-4f66-b96f-4dd0c64e5bea/d756ca70357442de960db145f9b4234d/dotnet-sdk-3.1.422-linux-arm64.tar.gz')
#     sha512sums_aarch64=('3eb7e066568dfc0135f2b3229d0259db90e1920bb413f7e175c9583570146ad593b50ac39c77fb67dd3f460b4621137f277c3b66c44206767b1d28e27bf47deb')
#     source_x86_64=('https://download.visualstudio.microsoft.com/download/pr/4fd83694-c9ad-487f-bf26-ef80f3cbfd9e/6ca93b498019311e6f7732717c350811/dotnet-sdk-3.1.422-linux-x64.tar.gz')
#     sha512sums_x86_64=('690759982b12cce7a06ed22b9311ec3b375b8de8600bd647c0257c866d2f9c99d7c9add4a506f4c6c37ef01db85c0f7862d9ae3de0d11e9bec60958bd1b3b72c')
#

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

function npmjs() {
    curl -fsSL "https://registry.npmjs.org/$1/latest" |
        jq -r '"pkgver=\(.version)"'
}

# process_package [-u] PACKAGE COMMAND [ARG...]
#
# Run COMMAND and apply its output to the given package's PKGBUILD file.
function process_package() {
    local UPDPKGSUMS=0
    [[ ${1-} != -u ]] || { UPDPKGSUMS=1 && shift; }
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
        { { ((!UPDPKGSUMS)) || updpkgsums; } &&
            makepkg --printsrcinfo >.SRCINFO ||
            rm -f .SRCINFO; })
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
        if [[ -f $PKG/PKGBUILD ]]; then (
            set +u
            . "$PKG/PKGBUILD"
            if NPMJS=$(printf '%s\n' ${source+"${source[@]}"} |
                sed -En 's@.*://registry\.npmjs\.org/([^/]+(/[^/]+)?)/-/.*@\1@p' |
                head -n1 |
                grep .); then
                process_package -u "$PKG" npmjs "$NPMJS"
            else
                echo "==> Not checked: $PKG"
                echo
            fi
        ); fi
        ;;
    esac
done

rm -f "$TEMP" "$AWK"
