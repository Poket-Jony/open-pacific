#!/usr/bin/env bash
# One entry point: reproduce every patched / re-signed artifact from stock APKs,
# then assemble the flashable system image. Idempotent; safe to re-run.
#
# Stock inputs (extract once with extract_firmware.sh, or extract_apks.sh + SRC):
#   work/apks/{Horizon,VrShell,SystemUX,VrHome,UserServer2}.apk
#   work/ocms/OCMS.apk
#   work/sysutil/SystemUtilities.apk
#   $SRC (default work/firmware/system.img) — the base image; the framework and the
#         panel-host odex are read out of it, so they always match what we ship
#   work/apks/MiniHome.apk — re-signed only (no code change), see below
#
# The headset is needed as late as possible. Every stock APK is read out of the base
# image on the host (extract_firmware.sh + debugfs), and every apk patch is host work,
# so the build runs with nothing connected until the three odex steps —
# patch_trust_odex.sh (panel host), patch_companionserver.sh (first-run OTA gate) and
# patch_framework.sh (services.odex) — which must compile on the target because dex2oat
# only runs there. Hence the phase argument below: `host` needs no device at all.
# The device's own firmware build does not have to match the base image — both
# compile against the base image's boot classpath (see device_boot_image in lib.sh).
#
# Prefer scripts/deploy.sh, which runs this and then flashes both slots.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="$ROOT/scripts"
T="$ROOT/work/trust"

# Phase to run. The split exists so the headset is needed as LATE as possible: every
# apk patch is pure host work, and only the three odex steps have to compile on the
# target. Running `host` first means a user can build the whole thing with nothing
# plugged in and connect the headset once, at the end, for dex2oat + flash.
#   host    every step that needs no device
#   device  the three dex2oat steps + the image assembly
#   all     both, waiting for the device in between (default)
PHASE="${1:-all}"
case "$PHASE" in host|device|all) ;; *) die "usage: build_all.sh [host|device|all]" ;; esac

if [ "$PHASE" != "device" ]; then
  echo "== host-side patches (no headset needed)"
  # patch_ocms creates the shared signing keystore (work/ocms/patch.jks) on first
  # run; every other script signs with it, so it must run first.
  "$S/patch_ocms.sh"          "$ROOT/work/ocms/OCMS.apk"
  "$S/patch_horizon.sh"
  "$S/patch_systemutilities.sh"
  "$S/patch_trust.sh"         "$ROOT/work/apks/VrShell.apk"   "$T/VrShell_signed.apk"
  # SystemUX gets the trust flip AND the NUX-dialog removal, so it has its own script.
  "$S/patch_systemux.sh"
  "$S/patch_trust.sh"         "$ROOT/work/apks/VrHome.apk"    "$T/VrHome_signed.apk"
  "$S/patch_userserver.sh"    "$ROOT/work/apks/UserServer2.apk" "$T/UserServer2_signed.apk"
  # MiniHome: re-signed only, no code change. The framework compareSignatures patch does
  # make PackageManager accept mixed signatures inside com.oculus.uid, but app-level checks
  # do not: Horizon crashed with "Uid [com.oculus.horizon, com.oculus.home] has inconsistent
  # signatures across packages" when calling IDeviceAuthService. Giving MiniHome the project
  # key makes the shared UID consistent again. Its classes.dex is untouched, so the stock
  # odex stays valid and no oat has to be dropped.
  "$S/resign_apk.sh"          "$ROOT/work/apks/MiniHome.apk"  "$T/MiniHome_signed.apk"
fi

[ "$PHASE" = "host" ] && { echo "[*] host phase done — run 'build_all.sh device' with the headset connected"; exit 0; }

# --- from here on the headset is required -------------------------------------
# dex2oat only runs on the target, so these three odex steps cannot be done on the host.
echo "== on-device steps (dex2oat) + image assembly"
need adb
if ! adb get-state >/dev/null 2>&1; then
  echo "[*] connect the headset now — the remaining steps compile odex on it"
  adb wait-for-device
fi
require_device
# VrDesktopPanelApp is the 2D-app panel host; it ships as a dex-less platform-
# signed apk + a separate .odex. We patch ONLY the odex (deodex -> trust flip ->
# on-device dex2oat) so the platform signature — and thus the android.uid.system
# SELinux domain — stays intact.
"$S/patch_trust_odex.sh"    "$T/VrDesktopPanelApp.odex"
# CompanionServer: odex-only patch that clears the first-run OTA gate (fresh /data).
"$S/patch_companionserver.sh"
"$S/patch_framework.sh"
"$S/build_system_image.sh"
echo "[*] done: all artifacts rebuilt + image at work/ocms/system_final.img"
echo "    to flash it, use scripts/deploy.sh (stock -> _a, OpenPacific -> _b)"
