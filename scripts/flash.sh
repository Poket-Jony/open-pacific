#!/usr/bin/env bash
# Flash the patched system image (+ Magisk-patched boot) to slot _b. No factory
# reset is needed — the framework compareSignatures patch makes the re-signed
# suite install over the existing /data. `--wipe` stays available for a fully
# fresh provision (it also regenerates packages.xml). The Oculus Go A/B
# bootloader tends to fall back to slot _a on reboot, so we force _b via fastboot
# after each boot. Slot _a is left intact as a stock recovery fallback.
#
# Two pieces make the device work: system_final.img (all patches) AND the
# Magisk-patched boot — the boot is NOT optional, because it is what strips the
# dm-verity `verify` flag from fstab; with the stock boot the modified system fails
# its hash check and boot-loops. It is generated headlessly by patch_boot_magisk.sh
# (auto-invoked below if missing).
#
# This writes slot _b only. Use scripts/deploy.sh for a full install, which also
# puts stock on slot _a as the recovery fallback.
# Usage: flash.sh [image] [--wipe]           (default work/ocms/system_final.img)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need adb fastboot
IMG="${1:-$ROOT/work/ocms/system_final.img}"
WIPE="${2:-}"
# Validate before the reboot below: a missing image would otherwise strand the
# device in the bootloader with nothing to flash.
[ -s "$IMG" ] || die "system image not found: $IMG (run build_all.sh first)"
MAGISK_VER="$(magisk_version)"
BOOT="${BOOT:-$(magisk_boot_path b "$MAGISK_VER")}"

# Returns non-zero on timeout, so the caller does not go on to report success for a
# device that never came back.
wait_boot(){ adb wait-for-device; for _ in $(seq 1 80); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && return 0; sleep 5; done
  echo "[!] boot did not complete within ~7 min — check the device" >&2; return 1; }
ensure_b(){ local s; s="$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')"
  if [ "$s" != "_b" ]; then adb reboot bootloader; sleep 6; fastboot set_active b; fastboot reboot; wait_boot; fi
  echo "slot=$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')"; }

# Ensure the Magisk-patched boot exists (generate it headlessly while adb is
# still up, before dropping to the bootloader). Root needs it; the apk alone
# does not. Skips generation only if the device isn't rooted for the patcher.
if [ ! -f "$BOOT" ]; then
  echo "[*] Magisk boot missing — generating it (patch_boot_magisk.sh b)"
  "$(dirname "${BASH_SOURCE[0]}")/patch_boot_magisk.sh" b || \
    echo "[!] could not auto-generate the Magisk boot — flashing system only." >&2
fi

adb reboot bootloader; sleep 7
fastboot flash system_b "$IMG"
if [ -f "$BOOT" ]; then
  echo "[*] flashing Magisk boot: $(basename "$BOOT")"
  fastboot flash boot_b "$BOOT"
else
  echo "[!] no Magisk boot ($BOOT) — system-only flash (device won't gain root)." >&2
fi
[ "$WIPE" = "--wipe" ] && fastboot -w   # needed on FIRST deploy (shared-UID signature reset)
fastboot set_active b
fastboot reboot
if ! wait_boot; then
  echo "[!] flashed $IMG, but the device did not report boot_completed." >&2
  echo "    Fall back with: fastboot set_active a && fastboot reboot (see docs/recovery.md)" >&2
  exit 1
fi
ensure_b
echo "[*] flashed $IMG"
