#!/usr/bin/env bash
# Generate the patched boot image headlessly (no Magisk app UI).
#
# This is NOT optional, and it does two things:
#   1. it strips the dm-verity `verify` flag from fstab (KEEPVERITY=false), without which
#      the modified /system fails its hash check on every boot;
#   2. it installs magiskinit and — via LEGACYSAR below — makes the kernel actually load
#      the ramdisk it lives in, which is what gives this device working root.
# See docs/device-constraints.md for the measurements behind both.
#
# Magisk ships a supported headless patcher (assets/boot_patch.sh + the magisk*
# binaries) inside its apk — the same code the app runs. We extract it, run it on the
# device against the stock boot, and save the result where flash.sh looks.
#
# Usage: patch_boot_magisk.sh [slot]     (slot: a|b; default = current device slot)
# Needs a connected device with root adbd (`adb root`); boot_patch.sh executes the
# magisk binaries there.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need unzip
require_device

MAGISK_VER="$(magisk_version)"
SLOT="${1:-$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')}"
SLOT="${SLOT#_}"
[ -n "$SLOT" ] || die "could not determine slot"
STOCK="${STOCK_BOOT:-$DOWNLOADS/boot_${SLOT}_stock.img}"
OUT="$(magisk_boot_path "$SLOT" "$MAGISK_VER")"
DEV_BOOT="/dev/block/bootdevice/by-name/boot_${SLOT}"
WORK="$ROOT/work/magisk"; DEVDIR="/data/local/tmp/magiskpatch"
rm -rf "${WORK:?}"; mkdir -p "$WORK"

MAGISK="${MAGISK:-$(ensure_magisk_apk "$MAGISK_VER")}"

# Stock boot, in order of trust: an explicit STOCK_BOOT, a previously saved copy,
# the untouched boot.img from the official ZIP (extract_firmware.sh), and only as a
# last resort a dd off the device — which on a headset that already runs this
# project would hand Magisk an already-patched image.
FW_BOOT="$ROOT/work/firmware/boot.img"
if [ ! -f "$STOCK" ] && [ -f "$FW_BOOT" ]; then
  echo "[*] using the stock boot from the official ZIP: $FW_BOOT"
  STOCK="$FW_BOOT"
fi
if [ ! -f "$STOCK" ]; then
  echo "[*] dumping stock boot_$SLOT from device"
  mkdir -p "$DOWNLOADS"
  adb_root_shell "dd if=$DEV_BOOT of=/data/local/tmp/boot_${SLOT}.img" >/dev/null 2>&1 \
    || die "could not dump $DEV_BOOT (need root)"
  adb pull "/data/local/tmp/boot_${SLOT}.img" "$STOCK" >/dev/null
  adb shell "rm -f /data/local/tmp/boot_${SLOT}.img" 2>/dev/null || true
fi
[ -f "$STOCK" ] || die "stock boot not found: $STOCK"

# Extract the headless patcher (scripts + arm64 binaries) from the apk.
echo "[*] extracting Magisk patcher from $(basename "$MAGISK")"
unzip -o -q "$MAGISK" 'assets/*' 'lib/arm64-v8a/*' 'lib/armeabi-v7a/*' -d "$WORK"
# Magisk ships the patcher binaries per ABI and the layout differs across
# generations: 24.x+ put them under lib/arm64-v8a (libmagisk.so or libmagisk64.so),
# 23.x and older only as 32-bit under lib/armeabi-v7a. Either is fine — magiskinit is
# exec'd by the arm64 kernel, which runs 32-bit binaries. Pick whichever ABI actually
# carries the patcher, and only enforce the inputs every generation documents as
# required (see boot_patch.sh's own header); copy the rest when present.
ABI_DIR=""
for a in arm64-v8a armeabi-v7a; do
  [ -f "$WORK/lib/$a/libmagiskinit.so" ] && { ABI_DIR="lib/$a"; break; }
done
[ -n "$ABI_DIR" ] || die "Magisk $MAGISK_VER carries no magiskinit for arm64-v8a or armeabi-v7a — unexpected apk layout; pin MAGISK_VER=$TESTED_MAGISK_VER"
for a in assets/boot_patch.sh assets/util_functions.sh \
         "$ABI_DIR/libmagiskinit.so" "$ABI_DIR/libmagiskboot.so"; do
  [ -f "$WORK/$a" ] || die "Magisk $MAGISK_VER has no $a — unexpected apk layout; pin MAGISK_VER=$TESTED_MAGISK_VER"
done
# The main binary is libmagisk.so (30.x) or libmagisk64.so/libmagisk32.so (<=26.x).
have_magisk_bin=0
for b in libmagisk.so libmagisk64.so libmagisk32.so; do
  [ -f "$WORK/$ABI_DIR/$b" ] && have_magisk_bin=1
done
[ "$have_magisk_bin" = 1 ] || die "Magisk $MAGISK_VER ships no magisk binary in $ABI_DIR"
# boot_patch.sh expects everything next to it; binaries without the lib/.so decoration.
cp "$WORK/assets/boot_patch.sh" "$WORK/assets/util_functions.sh" "$WORK/"
# Present in some generations only; boot_patch.sh uses them when they exist.
[ -f "$WORK/assets/stub.apk" ] && cp "$WORK/assets/stub.apk" "$WORK/"
[ -d "$WORK/assets/chromeos" ] && cp -R "$WORK/assets/chromeos" "$WORK/"
for so in "$WORK/$ABI_DIR"/lib*.so; do
  b="$(basename "$so")"; b="${b#lib}"; b="${b%.so}"
  cp "$so" "$WORK/$b"
done

# LEGACYSAR decides whether boot_patch.sh applies its `skip_initramfs -> want_initramfs`
# kernel hexpatch. Without it the bootloader's own `skip_initramfs` makes the kernel
# ignore the ramdisk entirely, so magiskinit — the thing the whole patch installs —
# never runs: no Magisk environment, no su. Magisk normally sets this in
# util_functions.sh's mount_partitions(), which the headless path here skips, so run
# Magisk's own check ourselves: a real block device as rootfs means legacy SAR.
LEGACYSAR=false
adb shell 'grep " / " /proc/mounts' 2>/dev/null | grep -q '/dev/root' && LEGACYSAR=true
echo "[*] legacy system-as-root: $LEGACYSAR (kernel gets the want_initramfs patch when true)"

# Device-side runner: a single su invocation (a compound "su -c 'cd .. && ..'"
# gets mis-split by adb's own shell, so we cd + run from one script instead).
cat > "$WORK/run.sh" <<EOF
cd "$DEVDIR" || exit 1
chmod 755 magiskboot magiskinit magisk magiskpolicy busybox init-ld boot_patch.sh 2>/dev/null
KEEPVERITY=false KEEPFORCEENCRYPT=true RECOVERYMODE=false LEGACYSAR=$LEGACYSAR sh boot_patch.sh stock-boot.img
EOF

# KEEPVERITY=false is REQUIRED, not a preference: fstab.pacific mounts
# /dev/block/bootdevice/by-name/system at / with the `verify` flag, i.e. dm-verity
# hashes the very partition this project modifies. Keeping verity makes the patched
# system fail its hash check on every boot -> boot loop. boot_patch.sh strips the
# flag when KEEPVERITY=false. KEEPFORCEENCRYPT stays true: /data is untouched.
# RECOVERYMODE=false is explicit because this boot image also carries the recovery
# (sbin/recovery is in its ramdisk). Left to guess, older Magisk builds patch it as a
# recovery, and the device then boots into stock recovery ("No command") instead of
# Android — observed with 23.0.
echo "[*] patching boot on device (KEEPVERITY=false — /system is modified, KEEPFORCEENCRYPT=true)"
adb shell "rm -rf $DEVDIR; mkdir -p $DEVDIR" >/dev/null
adb push "$WORK/." "$DEVDIR" >/dev/null
adb push "$STOCK" "$DEVDIR/stock-boot.img" >/dev/null
# `| tail` + pipefail would abort silently on a failing su/patcher, skipping the
# explicit new-boot.img check below (which has the useful message).
adb_root_shell "sh $DEVDIR/run.sh" 2>&1 | tail -20 || true

adb_root_shell "ls $DEVDIR/new-boot.img" >/dev/null 2>&1 || die "boot_patch.sh produced no new-boot.img"
adb pull "$DEVDIR/new-boot.img" "$OUT" >/dev/null
adb shell "rm -rf $DEVDIR" >/dev/null 2>&1 || true

# Sanity: it must be a valid Android boot image.
if command -v xxd >/dev/null 2>&1 && [ "$(xxd -l 8 -p "$OUT" 2>/dev/null | tr -d '\n')" != "414e44524f494421" ]; then
  die "output is not a valid boot image (missing ANDROID! magic): $OUT"
fi
echo "[*] OK -> $OUT ($(du -h "$OUT" | cut -f1)). flash.sh will use it for slot _$SLOT."
