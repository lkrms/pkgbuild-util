#!/bin/bash

set -euo pipefail

function usage() {
    echo "Usage: ${0##*/} (npm|electron) <package>" >&2
    exit 1
}

(($# == 2)) || usage

TEMP=$(mktemp)
trap 'rm -f "$TEMP"' EXIT

case "$1" in
npm)
    curl -fsSL "https://registry.npmjs.org/$2/latest" | jq -r '
"# Maintainer: Luke Arms <luke@arms.to>

pkgname=\(.name)
pkgver=\(.version)
pkgrel=1
pkgdesc=\(.description | @sh)
arch=(\("any" | @sh))
url=\(.homepage | @sh)
license=(\(.license | gsub("(\\.0$|[^a-zA-Z0-9]+)"; "") | @sh))"'
    cat <<"EOF"
depends=('nodejs')
makedepends=('npm')
source=("https://registry.npmjs.org/${pkgname}/-/${pkgname}-${pkgver}.tgz")
noextract=("${pkgname}-${pkgver}.tgz")
sha256sums=()

package() {
    npm install -g --prefix "${pkgdir}/usr" --cache "${srcdir}/.npm" "${srcdir}/${pkgname}-${pkgver}.tgz"
    install -d "${pkgdir}/usr/share/licenses/${pkgname}"
    ln -sr "${pkgdir}/usr/lib/node_modules/${pkgname}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"

    # See https://github.com/npm/npm/issues/9359 and
    # https://bugs.archlinux.org/task/63396
    chmod -R u=rwX,go=rX "${pkgdir}"
    chown -R root:root "${pkgdir}"
}
EOF
    ;;

default)
    usage
    ;;
esac >"$TEMP"

[[ ! -s PKGBUILD ]] || cp -avf PKGBUILD{,.bak}
cp "$TEMP" PKGBUILD
updpkgsums
makepkg --printsrcinfo >.SRCINFO

if [[ ! -d .git ]]; then
    git init
    git add PKGBUILD .SRCINFO
fi

if [[ ! -f .gitignore ]]; then
    cat >.gitignore <<EOF
*
!.gitignore
!PKGBUILD
!.SRCINFO
!*.patch
EOF
    git add .gitignore
fi
