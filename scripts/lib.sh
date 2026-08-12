#!/usr/bin/env bash
# Shared library for every script in this directory. Source it, never execute it:
#
#   # shellcheck source=lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Sections below: paths · basics · files and hashes · host toolchain · build tools ·
# Magisk · device · apk signing · on-device compilation.
# shellcheck disable=SC2034  # the constants below are consumed by the sourcing scripts
set -euo pipefail

# --- paths -------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Deliberately no shared WORK variable: every patch script uses `WORK` for its own
# apktool/deodex directory, so one of the same name here would mean two different
# things depending on which file you are reading.
APKS="$ROOT/work/apks"      # stock APKs, extracted from the base image or the device
BUNDLE="$ROOT/work/bundle"  # VrHome's Hermes bundle (reconnaissance only)
DISASM="$ROOT/work/disasm"  # its disassembly
TOOLS="$ROOT/tools"         # downloaded smali/baksmali (git-ignored)
DOWNLOADS="${OCULUS_DOWNLOAD_DIR:-$ROOT/downloads}"   # unlock ZIP, Magisk apk, boot images
BUNDLE_ASSET="assets/reactnative.bcbundle"
# The single signing key every patched apk shares (created by patch_ocms.sh on first
# run). Defined here because sign_apk() reads it: leaving it to each caller made it an
# undeclared contract — and an unbound variable under set -u the day one forgot.
KS="${KS:-$ROOT/work/ocms/patch.jks}"

# --- basics ------------------------------------------------------------------
# The embedded python patch steps verify every smali anchor with `assert`. Python drops
# assert statements entirely when PYTHONOPTIMIZE is set, which would let a patch silently
# not apply and produce a boot-looping image. Neutralise it for every child process.
export PYTHONOPTIMIZE=

die() { echo "error: $*" >&2; exit 1; }
need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done; }

# --- files and hashes --------------------------------------------------------
# Both things this project downloads (Magisk apk, firmware OTA) are zip
# containers. A captive portal or proxy answering 200 with an HTML login page
# passes curl -f, so check the magic before the file is cached under its final
# name — otherwise the failure surfaces much later as a cryptic unzip error.
is_zip() { [ "$(head -c 2 "$1" 2>/dev/null)" = "PK" ]; }

# md5 of a file, portable across macOS (md5) and Linux (md5sum). Used to compare a
# local image against what is already on a device partition — an integrity check
# against accidental difference, not against tampering.
md5_of() {
  if command -v md5 >/dev/null 2>&1; then md5 -q "$1"
  else md5sum "$1" | cut -d" " -f1; fi
}

# sha256 of a file, portable across macOS (shasum) and Linux (sha256sum).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d" " -f1
  else shasum -a 256 "$1" | cut -d" " -f1; fi
}

# Locate exactly one file inside a decoded/deodexed tree and echo its path.
# Uses `-print -quit` rather than `| head -1`: under pipefail, find writing further
# matches after head has exited can abort the caller with no message at all.
#   $1 = tree to search, $2 = -path glob, $3 = what it is (for the error message)
find_one() {
  local hit
  hit="$(find "$1" -path "$2" -print -quit 2>/dev/null)" || true
  [ -n "$hit" ] || die "$3 not found under $1"
  printf '%s' "$hit"
}

# --- host toolchain (cross-platform; override any with an env var) -----------
# Android SDK root: honour ANDROID_HOME / ANDROID_SDK_ROOT, else common locations.
_find_sdk() {
  local d
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "/opt/android-sdk"; do
    [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
}
# Discovery must not trip `set -e`/`pipefail` (unmatched globs make ls exit non-zero),
# so run it with errexit off and restore afterwards.
set +e
ANDROID_SDK="${ANDROID_SDK:-$(_find_sdk)}"
# Latest installed build-tools + platform android.jar (version-agnostic).
BT="${BT:-$(find "$ANDROID_SDK/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)}"
AJ="${AJ:-$(find "$ANDROID_SDK/platforms" -mindepth 2 -maxdepth 2 -name android.jar 2>/dev/null | sort -V | tail -1)}"
# ext2/3/4 tooling: PATH first (Linux), else Homebrew (macOS).
DBG="${DBG:-$(command -v debugfs 2>/dev/null || find /opt/homebrew/Cellar/e2fsprogs /usr/local/opt/e2fsprogs -name debugfs -type f 2>/dev/null | head -1)}"
FSCK="${FSCK:-$(command -v e2fsck 2>/dev/null || find /opt/homebrew/Cellar/e2fsprogs /usr/local/opt/e2fsprogs -name e2fsck -type f 2>/dev/null | head -1)}"
set -e

need_sdk() {
  [ -n "$BT" ] && [ -x "$BT/apksigner" ] || die "Android build-tools not found — set ANDROID_HOME or BT=<sdk>/build-tools/<ver>"
  [ -n "$AJ" ] && [ -f "$AJ" ] || die "android.jar not found — set AJ=<sdk>/platforms/android-<n>/android.jar"
}
need_debugfs() {
  [ -n "$DBG" ] && [ -x "$DBG" ] || die "debugfs not found (install e2fsprogs) — set DBG=<path>"
  [ -n "$FSCK" ] && [ -x "$FSCK" ] || die "e2fsck not found (install e2fsprogs) — set FSCK=<path>"
}

# --- build tools (smali/baksmali) --------------------------------------------
# The smali/baksmali version this project was verified with. Newer releases are used by
# default; pin this one if a newer build misbehaves. Never go BELOW it: 2.2.x cannot
# deodex this firmware (it drops unresolvable quickened field accesses) and yields a dex
# that boot-loops. See docs/tools.md.
TESTED_SMALI_VER="3.0.9"

# Resolve which smali/baksmali version to use. Precedence mirrors magisk_version():
# an explicit SMALI_VER pin > a version already cached in tools/ > the latest GitHub
# release (fetched only when nothing is cached). Echoes the version; notes to stderr.
smali_version() {
  if [ -n "${SMALI_VER:-}" ]; then echo "${SMALI_VER#v}"; return; fi
  local jar latest
  jar="$(find "$TOOLS" -maxdepth 1 -name 'baksmali-*.jar' 2>/dev/null | sort -V | tail -1)" || true
  if [ -n "$jar" ]; then
    basename "$jar" | sed -E 's/^baksmali-(.+)\.jar$/\1/'
    return
  fi
  need curl
  latest="$(curl -fsSL "${SMALI_API:-https://api.github.com/repos/baksmali/smali/releases/latest}" 2>/dev/null \
            | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)" || true
  [ -n "$latest" ] || die "could not resolve the latest smali version (GitHub API unreachable) — set SMALI_VER=$TESTED_SMALI_VER"
  echo "$latest"
}

# Make sure smali/baksmali are present and point BAKSMALI/SMALI at them; fetch on
# demand. Honours explicit BAKSMALI/SMALI overrides (e.g. distro packages).
ensure_smali_tools() {
  if [ -n "${BAKSMALI:-}" ] && [ -n "${SMALI:-}" ]; then
    { [ -f "$BAKSMALI" ] && [ -f "$SMALI" ]; } || die "smali/baksmali not found ($BAKSMALI, $SMALI)"
    return
  fi
  local ver
  ver="$(smali_version)"
  BAKSMALI="$TOOLS/baksmali-$ver.jar"
  SMALI="$TOOLS/smali-$ver.jar"
  if [ ! -f "$BAKSMALI" ] || [ ! -f "$SMALI" ]; then
    SMALI_VER="$ver" "$ROOT/scripts/fetch_tools.sh" >&2
  fi
  { [ -f "$BAKSMALI" ] && [ -f "$SMALI" ]; } || die "smali/baksmali still missing after fetch"
  if [ "$ver" != "$TESTED_SMALI_VER" ]; then
    echo "[i] smali/baksmali $ver in use. Tested stable is $TESTED_SMALI_VER — pin SMALI_VER=$TESTED_SMALI_VER if a newer build misbehaves." >&2
  fi
}

# --- Magisk ------------------------------------------------------------------
# The Magisk version this project was verified with — NOT a lower bound: on this API-25
# device both directions are worse. 26.4 boots but brings up no Magisk at all, 23.0 does
# not boot the patched slot; 30.7 gives full root (with LEGACYSAR=true, see
# patch_boot_magisk.sh). docs/device-constraints.md has the measurements.
TESTED_MAGISK_VER="v30.7"

# Resolve which Magisk version to use. Precedence: an explicit MAGISK_VER pin > a
# Magisk apk already cached in $DOWNLOADS > the latest GitHub release (fetched only
# when nothing is cached). ensure_magisk_apk then points at $TESTED_MAGISK_VER whenever
# the resolved version differs — that is the TESTED version, not a lower bound:
# downgrading is known to be worse on this device (see TESTED_MAGISK_VER above).
# Echoes the version tag (vX.Y) on stdout; notes go to stderr so callers can
# capture the value with $(...).
magisk_version() {
  if [ -n "${MAGISK_VER:-}" ]; then echo "v${MAGISK_VER#v}"; return; fi
  local apk latest
  apk="$(find "$DOWNLOADS" -maxdepth 1 -name 'Magisk-v*.apk' 2>/dev/null | sort -V | tail -1)" || true
  if [ -n "$apk" ]; then
    basename "$apk" | sed -E 's/^Magisk-(v[0-9.]+)\.apk$/\1/'
    return
  fi
  need curl
  latest="$(curl -fsSL "${MAGISK_API:-https://api.github.com/repos/topjohnwu/Magisk/releases/latest}" 2>/dev/null \
            | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p' | head -1)" || true
  [ -n "$latest" ] || die "could not resolve the latest Magisk version (GitHub API unreachable) — set MAGISK_VER=$TESTED_MAGISK_VER"
  echo "$latest"
}

# Ensure the Magisk manager apk for version $1 is in $DOWNLOADS; echo its path.
# Downloads from the official GitHub release if missing. Prints a one-line hint
# when the version differs from the tested one ($TESTED_MAGISK_VER).
ensure_magisk_apk() {
  local ver="$1" apk="$DOWNLOADS/Magisk-$1.apk"
  if [ ! -f "$apk" ]; then
    need curl
    mkdir -p "$DOWNLOADS"
    echo "[*] downloading Magisk $ver" >&2
    # Download to .part and rename only on success: an interrupted transfer
    # otherwise leaves a truncated apk that every later run treats as cached
    # (magisk_version even reads its version back out of the filename).
    curl -fL --retry 3 -o "$apk.part" \
      "${MAGISK_URL:-https://github.com/topjohnwu/Magisk/releases/download/$ver/Magisk-$ver.apk}" \
      || { rm -f "$apk.part"; die "Magisk download failed: $ver"; }
    is_zip "$apk.part" || { rm -f "$apk.part"; die "downloaded Magisk $ver is not an apk (captive portal or bad mirror?)"; }
    mv "$apk.part" "$apk"
  fi
  if [ "$ver" != "$TESTED_MAGISK_VER" ]; then
    echo "[i] Magisk $ver in use. Tested version is $TESTED_MAGISK_VER — pin MAGISK_VER=$TESTED_MAGISK_VER if this build misbehaves (older releases are known NOT to work here)." >&2
  fi
  echo "$apk"
}

# Path of the Magisk-patched boot image for one slot. Single definition, because
# deploy.sh, flash.sh and patch_boot_magisk.sh all have to agree on it.
#   $1 = slot (a|b), $2 = Magisk version tag (vX.Y)
magisk_boot_path() { printf '%s/magisk%s_patched_boot_%s.img' "$DOWNLOADS" "${2#v}" "$1"; }

# True when a boot image carries the legacy-SAR kernel patch (skip_initramfs ->
# want_initramfs) that this device needs for root. An image built before that flag was
# passed has the same name, size and Magisk version — only its kernel differs — so
# reusing a cached one silently costs root with no error anywhere. Any problem reading
# it answers "no", which only ever causes a rebuild.
boot_has_root_patch() {  # $1 = boot image
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" <<'PY'
import struct, sys, zlib
try:
    d = open(sys.argv[1], 'rb').read()
    kernel_size = struct.unpack('<I', d[8:12])[0]
    page_size = struct.unpack('<I', d[36:40])[0]
    k = d[page_size:page_size + kernel_size]
    if k[:2] == b'\x1f\x8b':                       # gzip-compressed kernel
        k = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(k)
    sys.exit(0 if b'want_initramfs' in k else 1)
except Exception:
    sys.exit(1)
PY
}

# --- device ------------------------------------------------------------------
require_device() {
  need adb
  adb get-state >/dev/null 2>&1 || die "no device (check USB, close SideQuest desktop)"
}

# True when adbd itself runs as root; asks for it via `adb root` if it does not.
# The officially unlocked build grants this, which matters because a stock slot has
# no su binary at all and Magisk's su is unavailable until its environment is set up.
adb_is_root() { [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = "0" ]; }
ensure_adb_root() {
  adb_is_root && return 0
  adb root >/dev/null 2>&1 || true
  adb wait-for-device >/dev/null 2>&1 || true
  sleep 2
  adb_is_root
}

# Run a command as root on the device: prefer root adbd, fall back to Magisk su.
adb_root_shell() {
  if ensure_adb_root; then
    adb shell "$1"
  else
    adb shell su -c "$1"
  fi
}

# True when the given device partition already holds exactly this local image.
# Hashes the same byte range on both sides, because the partition is usually larger
# than the image. Reading ~2 GB on the device costs less than writing it, and spares
# the eMMC on every re-deploy.
partition_matches() {  # $1 = local image, $2 = partition name (e.g. system_a)
  local img="$1" part="$2" size full rest want got dev
  size="$(wc -c < "$img" | tr -d ' ')"
  full=$((size / 4096)); rest=$((size % 4096))
  want="$(md5_of "$img")"
  dev="/dev/block/bootdevice/by-name/$part"
  # Hash EXACTLY $size bytes: the whole blocks in one fast bs=4096 read, then any
  # trailing partial block byte-wise. That tail is not academic — a Magisk-patched
  # boot image is never block-aligned, and simply refusing to compare unaligned
  # images made every slot _b look stale and rewrote ~2 GB on every single run.
  # Block devices are root-only, so this must go through root adbd/su — a plain
  # `adb shell` returns nothing and would silently hash the empty input.
  got="$(adb_root_shell "{ dd if=$dev bs=4096 count=$full; dd if=$dev bs=1 skip=$((full * 4096)) count=$rest; } 2>/dev/null | md5sum" \
         2>/dev/null | tr -d '\r' | awk '{print $1}')"
  [ -n "$got" ] && [ "$got" != "d41d8cd98f00b204e9800998ecf8427e" ] && [ "$want" = "$got" ]
}

# --- apk signing -------------------------------------------------------------
# Align, sign with the project key and verify one apk. Single place for the signing
# parameters, so every patched app is signed identically.
#   $1 = input apk, $2 = output apk
sign_apk() {
  local in="$1" out="$2" aligned="${2%.apk}.aligned.apk"
  need_sdk
  [ -f "$KS" ] || die "keystore not found: $KS (run patch_ocms.sh first — it creates the project key)"
  "$BT/zipalign" -p -f 4 "$in" "$aligned"
  "$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --v1-signing-enabled true --v2-signing-enabled true --out "$out" "$aligned"
  "$BT/apksigner" verify "$out" >/dev/null || die "apksigner could not verify $out"
  echo "[*] OK -> $out"
}

# Rebuild an apktool work tree into a signed apk.
#   $1 = apktool output dir, $2 = output apk
build_sign_apk() {
  local work="$1" out="$2"
  need apktool
  apktool b -f "$work" -o "${out%.apk}.unsigned.apk" >/dev/null
  sign_apk "${out%.apk}.unsigned.apk" "$out"
}

# --- on-device compilation ---------------------------------------------------
# Pick the --boot-image location for on-device dex2oat. An odex embeds the checksum
# of the boot image it was compiled against, so it MUST be built against the boot
# classpath of the image we ship — not whatever the device happens to run. If the
# device already runs exactly that build, use its own /system copy (then the recorded
# image location matches the target as well); otherwise push our extracted copy and
# compile against that. Echoes the value for --boot-image; $1 = local boot.art path.
# Callers must additionally pass `--runtime-arg -Xnorelocate` to dex2oat, or ART tries
# to relocate the image into /data/dalvik-cache and dies ("Only the zygote can create
# the global boot image"), leaving a 0-byte odex.
device_boot_image() {
  local local_art="$1" dev_art
  dev_art="$(mktemp)"
  if adb pull /system/framework/arm64/boot.art "$dev_art" >/dev/null 2>&1 && cmp -s "$local_art" "$dev_art"; then
    rm -f "$dev_art"
    echo "/system/framework/boot.art"
    return
  fi
  rm -f "$dev_art"
  local d=/data/local/tmp/op_bootcp
  echo "[i] device runs a different build than the base image — compiling against our own boot classpath" >&2
  adb shell "rm -rf $d; mkdir -p $d/arm64" >/dev/null
  # ART resolves an image LOCATION: <dir>/boot.art means it opens <dir>/<isa>/boot.art.
  adb push "$(dirname "$local_art")/." "$d/arm64" >/dev/null 2>&1 || die "could not push the boot classpath to the device"
  echo "$d/boot.art"
}

# Compile a jar (single entry classes.dex) into an odex ON THE DEVICE. dex2oat only runs
# on the target, and the odex carries the checksum of the boot image it was built
# against — so it is built against the BASE IMAGE's boot classpath, never the running
# system (device_boot_image), and -Xnorelocate is mandatory or ART aborts with
# "Only the zygote can create the global boot image" and leaves a 0-byte file.
#   $1 = local compile jar, $2 = dex-location to record, $3 = local output odex,
#   $4 = local boot.art of the base image
device_dex2oat() {
  local jar="$1" dexloc="$2" out="$3" boot tag
  require_device
  boot="$(device_boot_image "$4")"
  tag="op_$(basename "${out%.odex}")"
  adb push "$jar" "/data/local/tmp/$tag.jar" >/dev/null
  # `| tail` under pipefail would abort silently and skip the checks below.
  adb shell "rm -f /data/local/tmp/$tag.odex; dex2oat \
    --dex-file=/data/local/tmp/$tag.jar \
    --dex-location=$dexloc \
    --oat-file=/data/local/tmp/$tag.odex \
    --instruction-set=arm64 --instruction-set-features=default \
    --boot-image=$boot \
    --runtime-arg -Xnorelocate \
    --runtime-arg -Xms64m --runtime-arg -Xmx512m --compiler-filter=speed" 2>&1 | tail -3 || true
  adb pull "/data/local/tmp/$tag.odex" "$out" >/dev/null \
    || die "dex2oat produced no odex (see its output above)"
  [ -s "$out" ] || die "dex2oat produced an EMPTY odex — see 'adb logcat | grep dex2oat'"
  adb shell "rm -rf /data/local/tmp/$tag.jar /data/local/tmp/$tag.odex /data/local/tmp/op_bootcp" 2>/dev/null || true
}
