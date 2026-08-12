#!/usr/bin/env bash
# Pull the stock APKs the patch scripts need off a connected device, into the
# same work/ paths that extract_firmware.sh produces from the official ZIP.
#
# WARNING: this reads whatever the headset currently runs. On a device that already has
# OpenPacific on the active slot those are the PATCHED apks, and patching them again
# builds on top of edits instead of on stock. Run it only against a stock slot — or
# prefer extract_firmware.sh, which takes everything from Meta's official ZIP and is
# therefore reproducible regardless of what the headset runs. That is why deploy.sh
# uses extract_firmware.sh and never this script.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_device

pull_apk() {
  local pkg="$1" out="$2" base path
  base="$(basename "$out")"
  path="$(adb shell pm path "$pkg" | tr -d '\r' | sed 's/package://' | head -1)" || true
  [ -n "$path" ] || die "package not found: $pkg"
  # Separate su -c calls: adb flattens a compound "su -c 'a; b'" so only the
  # first command would run as root (the ';' splits off to the non-root shell).
  adb_root_shell "cp $path /sdcard/$base"
  adb_root_shell "chmod 666 /sdcard/$base"
  mkdir -p "$(dirname "$out")"
  adb pull "/sdcard/$base" "$out"
  adb_root_shell "rm /sdcard/$base"
  echo "[*] $pkg -> $out"
}

pull_apk com.oculus.horizon         "$APKS/Horizon.apk"
pull_apk com.oculus.vrshell.home    "$APKS/VrHome.apk"
pull_apk com.oculus.vrshell         "$APKS/VrShell.apk"
pull_apk com.oculus.systemux        "$APKS/SystemUX.apk"
# VrDesktopPanelApp is deliberately absent: only its .odex is patched (the apk is a
# dex-less platform-signed stub that must stay untouched), and patch_trust_odex.sh
# obtains that odex itself.
pull_apk com.oculus.userserver2     "$APKS/UserServer2.apk"
# MiniHome shares com.oculus.uid with Horizon and is re-signed (not code-patched), so
# build_all.sh needs its stock apk just like the others — leaving it out here made this
# route produce 7 of the 8 required APKs and fail late, in resign_apk.sh.
pull_apk com.oculus.home            "$APKS/MiniHome.apk"
pull_apk com.oculus.ocms            "$ROOT/work/ocms/OCMS.apk"
pull_apk com.oculus.systemutilities "$ROOT/work/sysutil/SystemUtilities.apk"

# This route yields the APKs only, and three later steps read from the base image itself:
# patch_companionserver.sh (no device fallback — it dies without one), patch_trust_odex.sh
# (falls back to the device) and build_system_image.sh, which swaps the APKs into it.
# Only extract_firmware.sh produces that image (or pass your own with SRC=).
if [ ! -f "$ROOT/work/firmware/system.img" ]; then
  echo
  echo "[i] APKs done. The image build still needs a clean base system.img:"
  echo "    scripts/extract_firmware.sh <unlocked_build.zip>   # produces work/firmware/system.img"
  echo "    ... or run: SRC=<your stock system.img> scripts/build_all.sh"
fi
