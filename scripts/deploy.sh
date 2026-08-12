#!/usr/bin/env bash
# One command, any Oculus Go: build OpenPacific locally and flash it.
#
# Usage: deploy.sh [unlocked_build.zip]      (default $OCULUS_DOWNLOAD_DIR/unlocked_build.zip)
#        REBUILD=1 deploy.sh …               rebuild instead of reusing work/
#
# Slot layout this produces (deliberate):
#   slot _a : stock, unlocked firmware from Meta's official package — the recovery
#             fallback. Untouched by any patch, so it always boots.
#   slot _b : OpenPacific — patched system + Magisk-patched boot. Active slot.
#
# Everything is prepared on the host first; the device is written exactly once, at
# the end. The headset is needed before that only as an ARM compiler for the three
# dex2oat steps (framework, panel-host odex, CompanionServer) — and for those it may run ANY
# firmware build, it just has to boot: the odex are compiled against the boot
# classpath of the base image, not against the running system (see
# device_boot_image() in lib.sh).
#
# If the headset cannot boot at all (e.g. a previous bad flash), this script
# recovers it first by putting stock on slot _a and booting that.
#
# Magisk is NOT set up from here. The image carries /system/etc/init/openpacific.rc and
# /system/etc/openpacific/, which install the manager app, populate /data/adb/magisk,
# grant su and enable Zygisk on every boot — so a factory reset repairs itself without a
# host. deploy.sh only waits for that to finish and verifies the result.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need adb fastboot
S="$ROOT/scripts"
ZIP="${1:-$DOWNLOADS/unlocked_build.zip}"
FW="$ROOT/work/firmware"
STOCK_SYS="$FW/system.img"
STOCK_BOOT_IMG="$FW/boot.img"
CUSTOM_SYS="$ROOT/work/ocms/system_final.img"

# Wait for the in-image setup to finish and report what it produced.
#
# The setup ITSELF is not done here. It lives in /system/etc/openpacific/magisk-setup.sh,
# is started by /system/etc/init/openpacific.rc on every boot, and installs the manager
# app, fills /data/adb/magisk, grants su and enables Zygisk. Doing it from the host as
# well would mean two implementations of the same thing — which is exactly what this
# project already paid for: the same wrong "is the app installed" probe had to be fixed
# in both copies. The device-side script is the single source of truth; deploy.sh only
# verifies the outcome, because a flash should not claim success it has not checked.
#
# On the first boot after a wipe that script reboots once (Zygisk is decided in
# post-fs-data, before it can run), so allow for the device disappearing briefly.
await_magisk_setup() {
  local _i out path size
  echo "[*] waiting for the in-image Magisk setup (runs on boot)"
  for _i in $(seq 1 40); do
    adb wait-for-device >/dev/null 2>&1 || true
    path="$(adb shell 'pm path com.topjohnwu.magisk' 2>/dev/null | tr -d '\r' | head -1 | sed 's/^package://')"
    if [ -n "$path" ]; then
      size="$(adb shell "ls -l $path" 2>/dev/null | tr -d '\r' | tr -s ' ' | cut -d' ' -f5)"
      case "$size" in
        ''|*[!0-9]*) ;;
        *) [ "$size" -ge 1000000 ] && adb shell 'test -f /data/adb/magisk/busybox' >/dev/null 2>&1 && break ;;
      esac
    fi
    sleep 5
  done
  # Prove root from an UNPRIVILEGED shell: with root adbd this would pass regardless.
  adb unroot >/dev/null 2>&1 || true
  adb wait-for-device; sleep 2
  out="$(adb shell 'su -c id' 2>&1 | tr -d '\r')"
  case "$out" in
    *"uid=0(root)"*) echo "[*] su works for the adb shell: $out" ;;
    *) echo "[!] su is not available yet ($out) — see docs/troubleshooting.md" >&2 ;;
  esac
}

# Prove the result instead of just reporting a boot: the offline library is the whole
# point, so ask the patched provider how many installed apps it serves.
verify_result() {
  local slot apps
  slot="$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')"
  apps="$(adb shell 'content query --uri content://com.oculus.ocms.library/apps --projection package_name 2>/dev/null' \
          2>/dev/null | grep -c '^Row:')" || apps=0
  echo "[*] OpenPacific runs on slot $slot; the offline library serves $apps installed apps"
  [ "$apps" -gt 0 ] || echo "[!] the library returned no rows — check 'adb logcat | grep -i ocms'" >&2
  echo "    stock fallback on slot _a: 'fastboot set_active a' (see docs/recovery.md)"
}

wait_boot() {
  adb wait-for-device
  local _i
  for _i in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && return 0
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- 1) stock sources
echo "== 1/4  stock sources"
# Check for the stock APKs too, not just the images: when a newer version of this
# project extracts one more file (MiniHome was added this way), an existing work/ from
# an older run looks complete and the build then dies on a missing input.
STOCK_INPUTS=("$STOCK_SYS" "$STOCK_BOOT_IMG" "$APKS/Horizon.apk" "$APKS/VrHome.apk"
  "$APKS/MiniHome.apk" "$APKS/VrShell.apk" "$APKS/SystemUX.apk" "$APKS/UserServer2.apk"
  "$ROOT/work/ocms/OCMS.apk" "$ROOT/work/sysutil/SystemUtilities.apk")
missing=""
for f in "${STOCK_INPUTS[@]}"; do [ -s "$f" ] || missing="$missing $(basename "$f")"; done
if [ -n "$missing" ]; then
  [ -f "$STOCK_SYS" ] && echo "[!] stock inputs missing ($missing ) — re-extracting"
  "$S/extract_firmware.sh" "$ZIP"
else
  echo "[=] already extracted: $STOCK_SYS"
fi
[ -s "$STOCK_SYS" ] && [ -s "$STOCK_BOOT_IMG" ] || die "stock system.img/boot.img missing"

# --------------------------------------------------- 2) build, host side (no device)
# Reuse what is already built. Besides saving ~4 min, this is what makes the slot
# comparison in step 4 work at all: assembling the image is NOT byte-reproducible
# (apktool, apksigner and debugfs each stamp the current time), so a rebuild on
# every run would differ from the identical image already on the device and
# rewrite ~2 GB every time. Set REBUILD=1 after changing a patch script.
#
# Everything here runs on the host: the stock APKs come out of the base image via
# debugfs, and every apk patch is host work. The headset is not touched until step 3,
# so it only has to be plugged in for the last stretch (dex2oat + flash).
echo "== 2/4  build (host side, no headset needed)"
MAGISK_VER="$(magisk_version)"
CUSTOM_BOOT="${BOOT:-$(magisk_boot_path b "$MAGISK_VER")}"
NEED_BUILD=1
if [ -z "${REBUILD:-}" ] && [ -s "$CUSTOM_SYS" ]; then
  echo "[=] already built: $CUSTOM_SYS  (REBUILD=1 forces a fresh build)"
  NEED_BUILD=0
else
  # Drop the assembled image BEFORE rebuilding. The host phase produces new apks but not
  # the image; if the device phase then fails (no headset, dex2oat error), a leftover
  # system_final.img from an earlier run would look "already built" on the next run and
  # get flashed — without the host patches that were just rebuilt.
  rm -f "$CUSTOM_SYS"
  SRC="$STOCK_SYS" "$S/build_all.sh" host
fi

# ----------------------------------------- 3) device: dex2oat, boot image, checks
# From here the headset is required: dex2oat only runs on the target, and the boot
# patch runs Magisk's own binaries there. If only fastboot answers, the headset is in
# a bad state — put stock on _a and boot that first.
echo "== 3/4  device  (dex2oat + boot image)"
if ! adb get-state >/dev/null 2>&1 && ! fastboot devices 2>/dev/null | grep -q .; then
  echo "[*] connect the headset now — waiting for it (Ctrl-C aborts; work/ is kept)"
  adb wait-for-device
fi
# get-state also answers "recovery"/"sideload"; only a fully booted "device" can run
# dex2oat, so treat anything else like an unbootable headset.
if [ "$(adb get-state 2>/dev/null)" != "device" ]; then
  if fastboot devices 2>/dev/null | grep -q .; then
    echo "[!] no booted device, only fastboot — recovering with stock on slot _a"
    fastboot flash system_a "$STOCK_SYS" || die "could not flash system_a"
    fastboot flash boot_a "$STOCK_BOOT_IMG" || die "could not flash boot_a"
    fastboot set_active a; fastboot reboot
    wait_boot || die "the device did not boot from stock slot _a"
  else
    die "no device found (neither adb nor fastboot) — connect the headset"
  fi
fi
wait_boot || die "device is connected but never reports boot_completed"
# The odex steps need root; the unlocked build grants it via `adb root`.
ensure_adb_root || echo "[!] adb root refused — the dex2oat steps may fail" >&2
echo "[*] device up: slot $(adb shell getprop ro.boot.slot_suffix | tr -d '\r'), build $(adb shell getprop ro.build.version.incremental | tr -d '\r')"
if [ "$NEED_BUILD" = 1 ]; then
  SRC="$STOCK_SYS" "$S/build_all.sh" device
fi
# The boot image is judged by CONTENT, not just existence: one built before the
# legacy-SAR fix carries the same name and version but no root (see lib.sh), and
# would otherwise be reused forever. Checked separately from the system image so a
# missing boot does not trigger a four-minute rebuild of everything.
if [ -n "${BOOT:-}" ]; then
  [ -s "$CUSTOM_BOOT" ] || die "BOOT is set but not readable: $CUSTOM_BOOT"
  echo "[=] using the boot image from BOOT: $CUSTOM_BOOT"
elif [ -z "${REBUILD:-}" ] && [ -s "$CUSTOM_BOOT" ] && boot_has_root_patch "$CUSTOM_BOOT"; then
  echo "[=] already patched: $CUSTOM_BOOT"
else
  if [ -s "$CUSTOM_BOOT" ] && ! boot_has_root_patch "$CUSTOM_BOOT"; then
    echo "[!] cached boot image predates the legacy-SAR kernel patch (no root) — rebuilding it"
  fi
  STOCK_BOOT="$STOCK_BOOT_IMG" "$S/patch_boot_magisk.sh" b
fi
[ -s "$CUSTOM_SYS" ] || die "patched system image missing: $CUSTOM_SYS"
[ -s "$CUSTOM_BOOT" ] || die "Magisk-patched boot missing: $CUSTOM_BOOT"

# ------------------------------------------------------------- 4) flash both slots
# Decide what actually needs writing while adb is still up. Rewriting ~2 GB per slot
# is only worth it if the partition does not already hold exactly that image, so
# compare first — reading is cheaper than writing and spares the eMMC.
echo "== 4/4  flash  (_a = stock fallback, _b = OpenPacific)"
echo "[*] comparing both slots against the built images (reads the partitions)"
STOCK_A_CURRENT=0; CUSTOM_B_CURRENT=0
partition_matches "$STOCK_SYS" system_a && partition_matches "$STOCK_BOOT_IMG" boot_a && STOCK_A_CURRENT=1
partition_matches "$CUSTOM_SYS" system_b && partition_matches "$CUSTOM_BOOT" boot_b && CUSTOM_B_CURRENT=1
echo "[*] slot _a stock: $([ "$STOCK_A_CURRENT" = 1 ] && echo "up to date" || echo "needs flashing")"
echo "[*] slot _b custom: $([ "$CUSTOM_B_CURRENT" = 1 ] && echo "up to date" || echo "needs flashing")"

ACTIVE_SLOT="$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')"
if [ "$STOCK_A_CURRENT" = 1 ] && [ "$CUSTOM_B_CURRENT" = 1 ] && [ "$ACTIVE_SLOT" = "_b" ]; then
  echo "[*] both slots already hold these images and _b is active — nothing to flash"
  await_magisk_setup
  verify_result
  exit 0
fi

adb reboot bootloader; sleep 8
fastboot devices | grep -q . || die "device did not enter the bootloader"
if [ "$STOCK_A_CURRENT" = 1 ]; then
  echo "[=] slot _a already holds this stock image — not rewriting it"
else
  fastboot flash system_a "$STOCK_SYS"      || die "flashing system_a failed"
  fastboot flash boot_a   "$STOCK_BOOT_IMG" || die "flashing boot_a failed"
fi
if [ "$CUSTOM_B_CURRENT" = 1 ]; then
  echo "[=] slot _b already holds this OpenPacific image — not rewriting it"
else
  fastboot flash system_b "$CUSTOM_SYS"  || die "flashing system_b failed"
  fastboot flash boot_b   "$CUSTOM_BOOT" || die "flashing boot_b failed"
fi
fastboot set_active b
fastboot reboot
if wait_boot; then
  await_magisk_setup
  verify_result
else
  echo "[!] the device did not report boot_completed. Fall back with:" >&2
  echo "      adb reboot bootloader  (or force the bootloader) && fastboot set_active a && fastboot reboot" >&2
  exit 1
fi
