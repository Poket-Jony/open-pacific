#!/usr/bin/env bash
# Trust-patch an ODEXED, platform-signed panel-mesh app by rebuilding ONLY its
# .odex — never the apk.
#
# VrDesktopPanelApp is the 2D-app panel host. Its apk is a dex-less,
# platform-signed stub (manifest + resources); all its code lives in a separate
# VrDesktopPanelApp.odex. It also shares android.uid.system. Re-signing the apk
# with our key would drop its seinfo from "platform" to "default", for which
# there is no seapp_context at uid=system, so zygote's selinux_android_setcontext
# aborts the process on every launch. So we leave the apk (and its platform
# signature) untouched and patch the code in the odex instead: deodex, flip
# SigCertVerifier$SigCertInfo.createUntrusted -> isTrusted=true (so the mesh
# accepts our re-signed shell), reassemble the dex, and recompile the odex with
# on-device dex2oat (host ART would mismatch the target boot image). The apk is a
# dex-less stub, so ART always uses this odex with no dex/odex checksum fallback.
#
# Usage: patch_trust_odex.sh <out.odex> [stock.odex] [apk_device_path] [odex_device_path]
#   <out.odex>          where to write the patched odex (build_system_image reads it)
#   [stock.odex]        stock odex; else work/fw/deodex/<name>.odex, else pulled from device
#   [apk_device_path]   dex-location recorded in the odex (the on-device apk path)
#   [odex_device_path]  where to pull the stock odex from, when neither of the above applies
# Needs a connected device with root adbd (`adb root`) for the dex2oat step; its own
# firmware build is irrelevant, because the odex is compiled against the base image's
# boot classpath.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need java python3 zip unzip
OUT="${1:-$ROOT/work/trust/VrDesktopPanelApp.odex}"
ODEX="${2:-}"
APK_DEV="${3:-/system/priv-app/VrDesktopPanelApp/VrDesktopPanelApp.apk}"
ODEX_DEV="${4:-/system/priv-app/VrDesktopPanelApp/oat/arm64/VrDesktopPanelApp.odex}"
NAME="$(basename "${APK_DEV%.apk}")"
# dex2oat at the end needs the headset; check now rather than after a minute of deodexing.
require_device
ensure_smali_tools
BOOT="$ROOT/work/fw/boot/arm64/boot.oat"
WORK="$ROOT/work/trust/${NAME}_odex"
rm -rf "${WORK:?}"; mkdir -p "$WORK" "$(dirname "$OUT")"

# Both the stock odex and the boot classpath must come from the SAME build as the
# base image, because the odex we emit is only valid against that boot classpath.
# Read them out of the base image; the device is a fallback that is only correct when
# it runs the same build (hence the warning).
SRC="${SRC:-$ROOT/work/firmware/system.img}"
if [ ! -f "$BOOT" ]; then
  if [ -f "$SRC" ]; then
    need_debugfs
    echo "[*] extracting the boot classpath from the base image"
    rm -rf "${ROOT:?}/work/fw/boot"; mkdir -p "$ROOT/work/fw/boot"
    "$DBG" -R "rdump /system/framework/arm64 $ROOT/work/fw/boot" "$SRC" >/dev/null 2>&1
  else
    require_device
    echo "[!] no base image at $SRC — pulling the boot classpath from the device." >&2
    echo "    Only valid if the device runs the same build as the image you flash." >&2
    mkdir -p "$ROOT/work/fw/boot/arm64"
    adb pull /system/framework/arm64/ "$ROOT/work/fw/boot/" >/dev/null 2>&1 || \
      adb pull /system/framework/oat/arm64/ "$ROOT/work/fw/boot/" >/dev/null 2>&1 || true
  fi
fi
[ -f "$BOOT" ] || die "boot.oat not found: $BOOT (expected in /system/framework/arm64 of the base image)"

# Stock odex: from the base image, a saved copy, or the device (same caveat).
if [ -z "$ODEX" ]; then
  FW_ODEX="$ROOT/work/fw/deodex/${NAME}.odex"
  if [ -f "$FW_ODEX" ]; then
    ODEX="$FW_ODEX"
  elif [ -f "$SRC" ]; then
    need_debugfs
    mkdir -p "$ROOT/work/fw/deodex"
    ODEX="$FW_ODEX"
    "$DBG" -R "dump $ODEX_DEV $ODEX" "$SRC" >/dev/null 2>&1
    [ -s "$ODEX" ] || die "$ODEX_DEV not found in the base image $SRC"
    echo "[*] extracted $(basename "$ODEX") from the base image"
  else
    require_device
    echo "[!] no base image at $SRC — pulling the odex from the device." >&2
    ODEX="$WORK/$(basename "$ODEX_DEV")"
    adb pull "$ODEX_DEV" "$ODEX" >/dev/null || die "cannot pull odex from $ODEX_DEV"
  fi
fi
[ -s "$ODEX" ] || die "odex not found or empty: $ODEX"

echo "[*] deodex $(basename "$ODEX")"
java -jar "$BAKSMALI" deodex -a 25 -b "$BOOT" "$ODEX" -o "$WORK/smali"

SC="$(find_one "$WORK/smali" '*SigCertVerifier*SigCertInfo.smali' "SigCertVerifier\$SigCertInfo.smali")"
python3 "$ROOT/scripts/trust_flip.py" "$SC"

echo "[*] reassemble classes.dex"
java -jar "$SMALI" assemble -a 25 "$WORK/smali" -o "$WORK/classes.dex"
# dex2oat consumes a jar/zip whose entry is named classes.dex.
( cd "$WORK" && zip -q compile.jar classes.dex )

# Recompile the odex ON THE DEVICE (host ART cannot target this runtime), but against
# the boot image of the BASE IMAGE we are building — not the one the device happens to
# be running. An odex embeds the checksum of its boot image, so compiling against the
# running system would boot-loop the panel host on any device whose firmware build
# differs from the base. We therefore push the extracted boot classpath and point
# dex2oat at it.
#   -Xnorelocate is REQUIRED: without it ART tries to relocate the boot image into
#   /data/dalvik-cache and aborts with "Only the zygote can create the global boot
#   image" (dex2oat is not the zygote), leaving a 0-byte odex behind.
require_device
echo "[*] on-device dex2oat against the base image's boot classpath -> $(basename "$OUT")"
device_dex2oat "$WORK/compile.jar" "$APK_DEV" "$OUT" "$(dirname "$BOOT")/boot.art"
echo "[*] OK -> $OUT"
