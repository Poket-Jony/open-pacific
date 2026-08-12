#!/usr/bin/env bash
# Extract everything the build needs straight from Meta's official Oculus Go
# unlock OTA ZIP — no files pulled from a headset. The device is then only needed
# at the very end (the framework dex2oat step + the flash).
#
# Because the base image comes from the official unlock package, a device that is
# NOT on the unlocked firmware yet can be flashed straight to unlocked+patched, as
# long as its bootloader is unlocked (Meta's official prerequisite — see the PDF
# in the download).
#
# The ZIP is an A/B OTA (`payload.bin`); we dump the `system` partition with
# payload_dumper and read the stock APKs + framework out of it with debugfs.
#
# Usage: extract_firmware.sh [zip]
#   Accepts EITHER the package you download from Meta (an outer archive holding the
#   instructions PDF plus the OTA) OR the unlocked_build.zip inside it — the outer one
#   is unpacked automatically.
#   Default ZIP:  $OCULUS_DOWNLOAD_DIR/unlocked_build.zip
#   Download page: https://developers.meta.com/horizon/downloads/package/oculus-go-sw-unlock/
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need unzip
need payload_dumper
need_debugfs

ZIP="${1:-$DOWNLOADS/unlocked_build.zip}"
FW="$ROOT/work/firmware"
SYS="$FW/system.img"
PAGE="https://developers.meta.com/horizon/downloads/package/oculus-go-sw-unlock/"

# The download page is a JS/session-gated SPA, so there is no stable direct link
# to hardcode. If you copy the direct download URL from the page (or a mirror),
# pass it as FIRMWARE_URL and it is fetched automatically; otherwise download the
# ZIP manually to the default path above.
mkdir -p "$DOWNLOADS"
if [ ! -f "$ZIP" ] && [ -n "${FIRMWARE_URL:-}" ]; then
  need curl
  echo "[*] downloading unlock ZIP from FIRMWARE_URL"
  # .part + rename: an interrupted transfer of this ~1 GB ZIP would otherwise be
  # picked up as a valid cached download on the next run.
  curl -fL --retry 3 -o "$ZIP.part" "$FIRMWARE_URL" \
    || { rm -f "$ZIP.part"; die "download failed: $FIRMWARE_URL"; }
  is_zip "$ZIP.part" || { rm -f "$ZIP.part"; die "downloaded file is not a ZIP (captive portal or wrong link?): $FIRMWARE_URL"; }
  mv "$ZIP.part" "$ZIP"
fi
[ -f "$ZIP" ] || die "unlock ZIP not found: $ZIP
  Download it from $PAGE (accept Meta's terms), then either drop it at the path
  above, pass its path as the first argument, or set FIRMWARE_URL=<direct-link>."

mkdir -p "$FW" "$APKS" "$ROOT/work/ocms" "$ROOT/work/sysutil" "$ROOT/work/fw/deodex"

# Meta's download page hands out an OUTER archive that contains the instructions PDF
# plus the actual OTA (unlocked_build.zip). Accept either, so passing whichever file
# you downloaded just works instead of failing with a cryptic unzip error.
if ! unzip -l "$ZIP" payload.bin >/dev/null 2>&1; then
  inner="$(unzip -Z1 "$ZIP" '*.zip' 2>/dev/null | head -1)" || true
  [ -n "$inner" ] || die "$ZIP contains neither payload.bin nor an inner .zip.
  Expected Meta's Oculus Go SW Unlock package (or the unlocked_build.zip inside it).
  Download page: $PAGE"
  echo "[*] outer package detected — unpacking $(basename "$inner") from it"
  unzip -o -q "$ZIP" "$inner" -d "$FW/outer" || die "could not extract $inner from $ZIP"
  ZIP="$FW/outer/$inner"
  [ -s "$ZIP" ] || die "extracted $inner is empty"
  unzip -l "$ZIP" payload.bin >/dev/null 2>&1 \
    || die "$(basename "$inner") has no payload.bin — is this really the Oculus Go unlock package?"
fi

# 1) OTA payload -> raw system.img
echo "[*] extracting payload.bin from $(basename "$ZIP")"
unzip -o -q "$ZIP" payload.bin -d "$FW"
echo "[*] dumping the system + boot partitions (payload_dumper)"
payload_dumper --partitions system,boot --out "$FW" "$FW/payload.bin" >/dev/null
[ -f "$SYS" ] || die "system.img not produced by payload_dumper"
# The stock boot from the official package is what patch_boot_magisk.sh should
# patch. Dumping boot off the device instead would hand it an ALREADY
# Magisk-patched image on any headset that ran this project before.
[ -f "$FW/boot.img" ] || die "boot.img not produced by payload_dumper"

# 2) stock APKs straight out of system.img, to the paths the patch scripts expect.
ext() { "$DBG" -R "dump $1 $2" "$SYS" >/dev/null 2>&1 && [ -s "$2" ] || die "not in image: $1"; echo "  $2"; }
echo "[*] extracting stock APKs"
ext /system/app/Horizon/Horizon.apk                      "$APKS/Horizon.apk"
ext /system/app/VrHome/VrHome.apk                        "$APKS/VrHome.apk"
ext /system/app/MiniHome/MiniHome.apk                    "$APKS/MiniHome.apk"
ext /system/priv-app/VrShell/VrShell.apk                 "$APKS/VrShell.apk"
ext /system/priv-app/SystemUX/SystemUX.apk               "$APKS/SystemUX.apk"
ext /system/priv-app/UserServer2/UserServer2.apk         "$APKS/UserServer2.apk"
ext /system/priv-app/OCMS/OCMS.apk                       "$ROOT/work/ocms/OCMS.apk"
ext /system/priv-app/SystemUtilities/SystemUtilities.apk "$ROOT/work/sysutil/SystemUtilities.apk"

# 3) framework bits for patch_framework (services + the boot classpath baksmali
#    needs to deodex). dex2oat itself still runs on-device at build time.
echo "[*] extracting framework (services + boot classpath)"
ext /system/framework/services.jar            "$ROOT/work/fw/deodex/services.jar"
ext /system/framework/oat/arm64/services.odex "$ROOT/work/fw/deodex/services.odex"
# VrDesktopPanelApp is odexed; patch_trust_odex.sh deodexes this to trust-patch it.
ext /system/priv-app/VrDesktopPanelApp/oat/arm64/VrDesktopPanelApp.odex "$ROOT/work/fw/deodex/VrDesktopPanelApp.odex"
rm -rf "${ROOT:?}/work/fw/boot"; mkdir -p "$ROOT/work/fw/boot"
"$DBG" -R "rdump /system/framework/arm64 $ROOT/work/fw/boot" "$SYS" >/dev/null 2>&1 \
  || die "could not extract the boot classpath (/system/framework/arm64)"

echo
echo "[*] done — firmware extracted device-free from the official unlock ZIP."
echo "    The dumped $SYS is the clean base build_system_image swaps into"
echo "    (auto-detected). Now build + flash:"
echo "      scripts/build_all.sh                         # device needed only for framework dex2oat"
echo "    Stock boot for the Magisk patch: $FW/boot.img"
echo "      scripts/flash.sh work/ocms/system_final.img  # device needed for the flash"
