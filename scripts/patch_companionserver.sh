#!/usr/bin/env bash
# Clear the shell's first-run OTA gate at its source, in CompanionServer.
#
# THE PROBLEM. On a fresh /data — i.e. after every factory reset — the shell blocks with
#   systemux://dialog/ota-blocking
#   "We are preparing your headset. Please take off your headset and follow the steps in
#    the Oculus app on your phone."
# and never reaches Home. Offline that is a dead end: the flow it points at needs Meta's
# phone app and live servers.
#
# WHAT ACTUALLY DRIVES IT. VrShell's native FirstTimeNUXGo reads the system setting
# `first_time_nux_pre_ota_complete`. It is `0` on a fresh device, and the only thing that
# ever sets it is CompanionServer's `NuxOtaStateMachine` — which reaches that line only
# when it reboots into a real OTA (state REBOOTING). Offline the machine parks itself in
# HIGH_PRI_APPS_DOWNLOAD_COMPLETE and the flag stays `0` forever:
#   NuxOtaStateMachine: Entering NEW_DEVICE state.
#   NuxOta: High priority apps download skipped.
#   OtaSettings: Changing NUX OTA State: NEW_DEVICE --> HIGH_PRI_APPS_DOWNLOAD_COMPLETE
#   FirstTimeNUXGo: Configuring OTA Blocking Dialog
#
# WHY IT MUST BE PATCHED HERE. The value must go through FirstTimeNuxManager ->
# SettingsManager, because the native shell reads a *cached* copy of the settings
# ("Setting %s is not a registered, cached property" in SystemSettings.cpp). Writing
# `/data/oculus/settings/system.db` directly — the obvious shortcut — is therefore
# ineffective, and it would also live in /data and not survive a wipe. Patching the
# state machine keeps everything in the image: the app itself sets the flag, exactly as
# it would once an OTA had completed.
#
# THE PATCH. `initializeNuxOtaStateMachine()` runs on every start of the machine and
# already holds the constant 1 in v3, so one added call is enough.
#
# CompanionServer ships odexed, so this follows patch_trust_odex.sh: deodex against the
# base image's boot classpath, patch, reassemble, recompile with on-device dex2oat.
#
# Usage: patch_companionserver.sh [out.odex]
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need java python3 zip unzip
need_debugfs
OUT="${1:-$ROOT/work/trust/CompanionServer.odex}"
SRC="${SRC:-$ROOT/work/firmware/system.img}"
ODEX_DEV="/system/priv-app/CompanionServer/oat/arm64/CompanionServer.odex"
APK_DEV="/system/priv-app/CompanionServer/CompanionServer.apk"
WORK="$ROOT/work/trust/companionserver"
BOOT="$ROOT/work/fw/boot/arm64/boot.oat"
# Validate before ensure_smali_tools: unlike the other odex patches this one has no
# device fallback, so a missing base image is fatal — and downloading ~10 MB of
# smali/baksmali first only to die afterwards is a pointless detour.
[ -f "$SRC" ] || die "base image not found: $SRC (run extract_firmware.sh first)"
# dex2oat at the end needs the headset; check now rather than after a minute of deodexing.
require_device
ensure_smali_tools
rm -rf "${WORK:?}"; mkdir -p "$WORK" "$(dirname "$OUT")"

# Boot classpath of the BASE IMAGE — the odex we emit is only valid against it.
if [ ! -f "$BOOT" ]; then
  rm -rf "${ROOT:?}/work/fw/boot"; mkdir -p "$ROOT/work/fw/boot"
  "$DBG" -R "rdump /system/framework/arm64 $ROOT/work/fw/boot" "$SRC" >/dev/null 2>&1
fi
[ -f "$BOOT" ] || die "boot.oat not found: $BOOT"

STOCK="$WORK/CompanionServer.odex"
"$DBG" -R "dump $ODEX_DEV $STOCK" "$SRC" >/dev/null 2>&1
[ -s "$STOCK" ] || die "$ODEX_DEV not found in the base image $SRC"

echo "[*] deodex CompanionServer.odex"
java -jar "$BAKSMALI" deodex -a 25 -b "$BOOT" "$STOCK" -o "$WORK/smali"

SM="$(find_one "$WORK/smali" '*firsttimenux/ota/NuxOtaStateMachine.smali' NuxOtaStateMachine.smali)"
python3 - "$SM" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

CALL = "    invoke-static {v3}, Lcom/oculus/os/FirstTimeNuxManager;->setFirstTimeNuxPreOtaComplete(Z)Z\n"
# Anchor on the method's own prologue, which already loads the constant 1 into v3.
old = """.method private initializeNuxOtaStateMachine()V
    .registers 5

    .prologue
    const/4 v3, 0x1
"""
if old not in s:
    sys.exit("initializeNuxOtaStateMachine prologue not found (CompanionServer layout differs?)")
# The setter must exist — otherwise we would emit a call to nothing.
if 'setFirstTimeNuxPreOtaComplete(Z)Z' not in s:
    sys.exit("FirstTimeNuxManager.setFirstTimeNuxPreOtaComplete not referenced — refusing")
s = s.replace(old, old + "\n" + CALL, 1)
open(p, 'w').write(s)
print("  patched initializeNuxOtaStateMachine -> setFirstTimeNuxPreOtaComplete(true)")
PY

echo "[*] reassemble classes.dex"
java -jar "$SMALI" assemble -a 25 "$WORK/smali" -o "$WORK/classes.dex"
( cd "$WORK" && zip -q compile.jar classes.dex )

require_device
echo "[*] on-device dex2oat against the base image's boot classpath -> $(basename "$OUT")"
device_dex2oat "$WORK/compile.jar" "$APK_DEV" "$OUT" "$(dirname "$BOOT")/boot.art"
echo "[*] OK -> $OUT"
