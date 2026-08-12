#!/usr/bin/env bash
# Download the third-party build tools instead of vendoring them in the repo.
#
# Only smali/baksmali are needed (the framework and panel-host odex patches deodex
# and reassemble dex). They are fetched as the official fat release jars from the
# smali project's GitHub releases into tools/, which is git-ignored.
#
# Version policy mirrors Magisk: the LATEST release is used by default; the tested
# stable version ($TESTED_SMALI_VER) is only surfaced as a hint and is what to pin with
# SMALI_VER=... if a newer build misbehaves. Never pin below it — baksmali 2.2.x
# cannot deodex this firmware and produces a boot-looping image (see docs/tools.md).
#
# Usage: fetch_tools.sh [version]     # default: SMALI_VER, else cached, else latest
#        SMALI_VER=3.0.9 fetch_tools.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl

VER="${1:-$(smali_version)}"; VER="${VER#v}"
mkdir -p "$TOOLS"

fetch() {  # $1 = artifact base name (baksmali|smali)
  local name="$1" dest="$TOOLS/$1-$VER.jar" url
  url="https://github.com/baksmali/smali/releases/download/$VER/$name-$VER-fat-release.jar"
  if [ -f "$dest" ]; then
    echo "[=] $(basename "$dest") already present"
    return
  fi
  echo "[*] downloading $name $VER"
  curl -fL --retry 3 -o "$dest.part" "$url" \
    || { rm -f "$dest.part"; die "download failed: $url
  If that version has no fat release jar, pin the tested one: SMALI_VER=$TESTED_SMALI_VER"; }
  # A captive portal answers 200 with HTML, which curl -f happily saves.
  is_zip "$dest.part" || { rm -f "$dest.part"; die "$name $VER is not a jar (captive portal or bad mirror?)"; }
  mv "$dest.part" "$dest"
  echo "[*] OK -> $dest"
}

fetch baksmali
fetch smali

if [ "$VER" != "$TESTED_SMALI_VER" ]; then
  echo "[i] smali/baksmali $VER in use. Tested stable is $TESTED_SMALI_VER — pin SMALI_VER=$TESTED_SMALI_VER if a newer build misbehaves." >&2
fi
echo "[*] smali/baksmali $VER ready in $TOOLS/"
