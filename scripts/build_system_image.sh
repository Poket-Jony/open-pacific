#!/usr/bin/env bash
# Assemble the patched system_b image from a clean dump by swapping the patched
# system apps in place with debugfs (no mount, macOS-friendly).
#
# Contents baked in:
#   /system/priv-app/OCMS/OCMS.apk                 patched (installed apps offline), oat removed
#   /system/app/Horizon/Horizon.apk                patched (offline empty-account login), oat removed
#   /system/app/MiniHome/MiniHome.apk              RE-SIGNED only (no code change): it shares com.oculus.uid
#                                                  with Horizon, and app-level checks reject a shared UID whose
#                                                  members carry different signatures. oat/ is KEPT — the dex is
#                                                  byte-identical, so the stock odex stays valid
#   /system/priv-app/SystemUtilities/*.apk         patched (NUX-complete setter kept reachable for the
#                                                  re-signed shell) + trust-flip
#                                                  (panel-mesh host), oat removed
#   /system/priv-app/CompanionServer/oat/*.odex     ODEX only: clears the first-run OTA gate
#   /system/priv-app/VrDesktopPanelApp/oat/*.odex  trust-patched ODEX only (the 2D-app panel host that
#                                                  authenticates the shell). Its apk is a dex-less
#                                                  platform-signed stub; patching the odex (not the apk)
#                                                  keeps the platform signature, so this android.uid.system
#                                                  app keeps seinfo=platform and its SELinux context. The
#                                                  stock apk is left untouched.
#   /system/priv-app/VrShell/VrShell.apk           trust-patched + re-signed (panel mesh), oat removed
#   /system/priv-app/SystemUX/SystemUX.apk         trust-patched + NUX dialog flow short-circuited
#                                                  + re-signed (panel mesh), oat removed
#   /system/priv-app/UserServer2/UserServer2.apk   patched (api caller check -> no-op) + re-signed, oat removed
#   /system/app/VrHome/VrHome.apk                  trust-patched + re-signed (panel mesh), oat removed
#   /system/app/VrCastService/VrCastService.apk    REMOVED (offline-useless; rejected the resigned caller)
#   /system/framework/services.jar                 dex-less stub + /system/framework/oat/arm64/services.odex
#                                                  recompiled: PackageManagerService.compareSignatures -> MATCH
#   /system/etc/hosts                              null-routes Meta/Facebook/Oculus (no outbound requests)
#   /system/etc/init/openpacific.rc                boot service that runs the Magisk setup — in the image
#   /system/etc/openpacific/magisk-setup.sh        that setup: installs the app, fills /data/adb/magisk,
#                                                  grants su, enables Zygisk. Survives a factory reset,
#                                                  because /data does not
#   /system/etc/openpacific/magisk.apk             the Magisk apk this build was made with
#   /system/build.prop                             + debug.rs.default-CPU-driver=1 (global RenderScript fallback)
#
# Code-changed apps get their stale oat removed so ART uses the new dex.
# All patched/re-signed apps use the same key (work/ocms/patch.jks).
# Usage: build_system_image.sh [out.img]     (default work/ocms/system_final.img)
#        SRC=<base system.img> overrides the base image.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_debugfs
# Clean base: the stock system.img extracted from the official unlock ZIP
# (extract_firmware.sh). No personal backup is needed — the untouched A/B slot
# stays stock as the recovery fallback.
SRC="${SRC:-$ROOT/work/firmware/system.img}"
[ -f "$SRC" ] || die "clean base image not found: $SRC (run extract_firmware.sh first, or set SRC=<stock system.img>)"
OUT="${1:-$ROOT/work/ocms/system_final.img}"
OCMS="$ROOT/work/ocms/OCMS_signed.apk"
HZ="$ROOT/work/horizon/Horizon_signed.apk"
SU="$ROOT/work/sysutil/SystemUtilities_signed.apk"
VRSHELL="$ROOT/work/trust/VrShell_signed.apk"
VDESK_ODEX="$ROOT/work/trust/VrDesktopPanelApp.odex"
VDESK_ODEX_PATH="/system/priv-app/VrDesktopPanelApp/oat/arm64/VrDesktopPanelApp.odex"
CS_ODEX="$ROOT/work/trust/CompanionServer.odex"
CS_ODEX_PATH="/system/priv-app/CompanionServer/oat/arm64/CompanionServer.odex"
SYSTEMUX="$ROOT/work/trust/SystemUX_signed.apk"
VRHOME="$ROOT/work/trust/VrHome_signed.apk"
MINIHOME="$ROOT/work/trust/MiniHome_signed.apk"
HOSTS="$ROOT/patch/hosts/hosts"
# Boot-time Magisk setup, shipped IN the image so it survives a factory reset (see
# patch/system/openpacific.rc). The apk is the one this build was made with.
OP_RC="$ROOT/patch/system/openpacific.rc"
OP_SETUP="$ROOT/patch/system/magisk-setup.sh"
MAGISK_APK="$(ensure_magisk_apk "$(magisk_version)")"
SERVICES="$ROOT/work/fw/deodex/services_stub.jar"
SERVICES_ODEX="$ROOT/work/fw/deodex/services_patched.odex"
USERSERVER="$ROOT/work/trust/UserServer2_signed.apk"

# Every artifact must exist BEFORE the image is touched: debugfs reports a failed
# command on stderr but keeps going and still exits 0, so a missing input would
# leave the stock file deleted and unreplaced in an image that reports success.
for f in "$OCMS" "$HZ" "$SU" "$VRSHELL" "$VDESK_ODEX" "$SYSTEMUX" "$VRHOME" \
         "$USERSERVER" "$CS_ODEX" "$MINIHOME" "$HOSTS" "$SERVICES" "$SERVICES_ODEX" \
         "$OP_RC" "$OP_SETUP" "$MAGISK_APK"; do
  [ -s "$f" ] || die "missing/empty build input: $f (run build_all.sh first)"
done

# Unpack the Magisk apk here, on the host, and ship the files ready to use. The device
# has no unzip (this Android build ships none) and Magisk's own busybox is exactly what
# may be missing after a wipe, so extracting on-device would be a chicken-and-egg problem.
# Every temp path is created BEFORE the trap below, so no failure path can leak one —
# unpacking the apk can fail, and it used to happen before the trap existed.
MAGISK_FILES="$(mktemp -d)"
CTX="$(mktemp)"; CMD="$(mktemp)"; ERR="$(mktemp)"; BP="$(mktemp)"
OK=0
# Delete a half-built image on ANY failure. The first thing further down is a plain copy
# of the STOCK image, so an aborted run would otherwise leave a stock-or-partial
# system_final.img behind — and deploy.sh treats an existing one as "already built" and
# would flash it, silently unpatched. Cleared only on success.
trap 'rm -f "$CTX" "$CMD" "$ERR" "$BP"; rm -rf "$MAGISK_FILES"; [ "$OK" = 1 ] || rm -f "$OUT"' EXIT
printf 'u:object_r:system_file:s0\000' > "$CTX"

need unzip
unzip -o -q "$MAGISK_APK" 'lib/arm64-v8a/*' 'lib/armeabi-v7a/libmagisk.so' \
  'assets/util_functions.sh' 'assets/boot_patch.sh' 'assets/stub.apk' -d "$MAGISK_FILES" \
  || die "could not unpack $MAGISK_APK"
for so in "$MAGISK_FILES"/lib/arm64-v8a/lib*.so; do
  [ -f "$so" ] || continue
  b="$(basename "$so")"; b="${b#lib}"; b="${b%.so}"
  mv "$so" "$MAGISK_FILES/$b"
done
# The ramdisk carries only one magisk binary (64-bit here); the daemon loads magisk32
# from /data/adb/magisk to inject the 32-bit zygote, so it has to travel too.
[ -f "$MAGISK_FILES/lib/armeabi-v7a/libmagisk.so" ] &&
  mv "$MAGISK_FILES/lib/armeabi-v7a/libmagisk.so" "$MAGISK_FILES/magisk32"
for a in util_functions.sh boot_patch.sh stub.apk; do
  [ -f "$MAGISK_FILES/assets/$a" ] && mv "$MAGISK_FILES/assets/$a" "$MAGISK_FILES/$a"
done
rm -rf "${MAGISK_FILES:?}/lib" "${MAGISK_FILES:?}/assets"
if [ ! -f "$MAGISK_FILES/busybox" ] || [ ! -f "$MAGISK_FILES/util_functions.sh" ]; then
  die "unexpected Magisk apk layout — busybox/util_functions.sh missing"
fi

cp "$SRC" "$OUT"

# Global RenderScript CPU-driver fallback (system-wide, not per-app): libRS reads
# debug.rs.default-CPU-driver at every RS context creation, so this forces the CPU
# reference driver for ANY app using RenderScript blur (ScriptIntrinsicBlur), which
# otherwise SIGSEGVs in the Adreno 530 OpenCL driver on this API-25 device. Zero
# effect on apps that don't use RenderScript; a free safety net for sideloaded apps.
"$DBG" -R "dump /system/build.prop $BP" "$OUT" 2>/dev/null
[ -s "$BP" ] || die "failed to read /system/build.prop from $OUT"
grep -q '^debug.rs.default-CPU-driver=' "$BP" || echo 'debug.rs.default-CPU-driver=1' >> "$BP"

# The oat layout differs per app AND per build — Horizon ships arm + arm64 here,
# SystemUtilities only arm — so hardcoding one arch leaves a stale, UNPATCHED odex
# behind for the others. Enumerate what the base image actually contains instead.
img_ls() { "$DBG" -R "ls -l $1" "$SRC" 2>/dev/null | awk '{print $NF}' | grep -vE '^(\.|\.\.)$' || true; }

# Drop an app's whole oat/ tree so ART has to use the patched dex in the new apk.
# Every rmdir is emitted only for a directory that actually exists: debugfs answers a
# missing one with "rmdir: File not found" on stderr, which the error guard below
# rightly treats as fatal — so an app that simply ships no oat/ would abort the build
# with "do not flash it" even though nothing is wrong.
oat_rm() {
  local d="$1" a f had any=0
  for a in arm arm64; do
    had=0
    while read -r f; do
      [ -n "$f" ] || continue
      echo "rm $d/oat/$a/$f"; had=1
    done < <(img_ls "$d/oat/$a")
    [ "$had" = 1 ] && { echo "rmdir $d/oat/$a"; any=1; }
  done
  [ "$any" = 1 ] && echo "rmdir $d/oat"
  return 0   # a bare `[ ... ]` above would return 1 and trip set -e in the caller
}

# Replace one code-patched app: apk + its stale oat out, patched apk in.
swap_app() {  # $1 = dir under /system, $2 = apk name, $3 = patched apk on the host
  echo "rm $1/$2"
  oat_rm "$1"
  put "$3" "$1/$2"
}

# write + selinux label + mode for one file.
put() {  # $1 = source on host, $2 = destination in the image
  echo "write $1 $2"
  echo "ea_set -f $CTX $2 security.selinux"
  echo "sif $2 mode 0100644"
}

# Same, but executable — init runs the setup script directly.
put_exec() {  # $1 = source on host, $2 = destination in the image
  echo "write $1 $2"
  echo "ea_set -f $CTX $2 security.selinux"
  echo "sif $2 mode 0100755"
}

{
  echo "rm /system/build.prop"
  put "$BP" /system/build.prop
  swap_app /system/priv-app/OCMS            OCMS.apk            "$OCMS"
  swap_app /system/app/Horizon              Horizon.apk         "$HZ"
  swap_app /system/priv-app/SystemUtilities SystemUtilities.apk "$SU"
  swap_app /system/priv-app/VrShell         VrShell.apk         "$VRSHELL"
  swap_app /system/priv-app/SystemUX        SystemUX.apk        "$SYSTEMUX"
  swap_app /system/app/VrHome               VrHome.apk          "$VRHOME"
  swap_app /system/priv-app/UserServer2     UserServer2.apk     "$USERSERVER"
  # MiniHome: re-signed only, classes.dex identical -> its stock odex stays valid, so
  # replace the apk WITHOUT dropping oat/ (swap_app would).
  echo "rm /system/app/MiniHome/MiniHome.apk"
  put "$MINIHOME" /system/app/MiniHome/MiniHome.apk
  # VrDesktopPanelApp: ONLY the odex is replaced — its dex-less platform-signed apk
  # must stay untouched to keep seinfo=platform (see patch_trust_odex.sh).
  echo "rm $VDESK_ODEX_PATH"
  put "$VDESK_ODEX" "$VDESK_ODEX_PATH"
  # CompanionServer: ONLY the odex, same reason — its apk stays stock. Clears the
  # first-run OTA gate that blocks the shell on a fresh /data (patch_companionserver.sh).
  echo "rm $CS_ODEX_PATH"
  put "$CS_ODEX" "$CS_ODEX_PATH"
  # VrCastService is removed entirely (offline-useless, rejects the re-signed caller);
  # take its oat with it, otherwise a multi-MB odex for a non-existent apk stays.
  echo "rm /system/app/VrCastService/VrCastService.apk"
  oat_rm /system/app/VrCastService
  echo "rm /system/etc/hosts"
  put "$HOSTS" /system/etc/hosts
  # Boot-time Magisk setup. debugfs mkdir creates a directory WITHOUT a security.selinux
  # attribute (it would end up "unlabeled" and init could not read it), so label it too.
  echo "mkdir /system/etc/openpacific"
  echo "ea_set -f $CTX /system/etc/openpacific security.selinux"
  echo "sif /system/etc/openpacific mode 040755"
  put      "$OP_RC"      /system/etc/init/openpacific.rc
  put_exec "$OP_SETUP"   /system/etc/openpacific/magisk-setup.sh
  put      "$MAGISK_APK" /system/etc/openpacific/magisk.apk
  # Ready-to-copy Magisk environment: the setup script just cp's these into
  # /data/adb/magisk, which is what env_check looks for.
  echo "mkdir /system/etc/openpacific/magisk"
  echo "ea_set -f $CTX /system/etc/openpacific/magisk security.selinux"
  echo "sif /system/etc/openpacific/magisk mode 040755"
  for f in "$MAGISK_FILES"/*; do
    [ -f "$f" ] || continue
    put_exec "$f" "/system/etc/openpacific/magisk/$(basename "$f")"
  done
  # framework: dex-less stub jar + the recompiled odex. The odex is what ART loads;
  # shipping the dex instead would be runtime-verified and boot-loop (see
  # patch_framework.sh).
  echo "rm /system/framework/services.jar"
  put "$SERVICES" /system/framework/services.jar
  echo "rm /system/framework/oat/arm64/services.odex"
  put "$SERVICES_ODEX" /system/framework/oat/arm64/services.odex
} > "$CMD"
"$DBG" -w -f "$CMD" "$OUT" 2>"$ERR"
# debugfs prints per-command failures ("write: ...", "rm: ...") on stderr but still
# exits 0, so the status alone cannot be trusted: treat any stderr line that is not
# the version banner / cwd note as fatal rather than shipping an incomplete image.
if grep -vE '^(debugfs [0-9]|Shell cwd was reset)' "$ERR" | grep -q .; then
  grep -vE '^(debugfs [0-9]|Shell cwd was reset)' "$ERR" >&2
  die "debugfs reported errors — $OUT is incomplete, do not flash it"
fi
# e2fsck returns non-zero for the free-block/inode counts that debugfs -w edits
# leave behind (reported, not fixed, under -n); that is expected here and must
# not abort the build under set -e/pipefail. Surface the summary, ignore status.
"$FSCK" -fn "$OUT" 2>&1 | tail -2 || true
OK=1
echo "[*] image -> $OUT (OCMS+Horizon+SystemUtilities+trust-mesh+framework patched, MiniHome re-signed, VrCast removed, hosts null-routed)"
