#!/usr/bin/env bash
# Reproduce the framework (services.jar) signature patch.
#
# ROOT of the signature-permission cascade: PackageManagerService.compareSignatures
# decides whether two packages share a signature, which gates every signature-level
# permission. Our re-signed system apps have a different cert than the stock
# Meta-signed apps that declare those permissions, so the whole home mesh is denied.
# Forcing compareSignatures to return SIGNATURE_MATCH (0) makes the framework treat
# every package as same-signed, so signature permissions resolve for our apps.
#
# services.jar is NOT in BOOTCLASSPATH; it has its own services.odex (arm64), so it
# is patchable like a large app: deodex -> patch smali -> reassemble dex -> recompile
# odex on-device with dex2oat. The shipped jar stays a dex-less stub (META-INF only)
# so ART always uses the odex.
#
# Do NOT "simplify" this by shipping the dex inside services.jar and dropping the
# odex: baksmali cannot fully deodex a few methods of this build (quickened field
# accesses it fails to resolve, e.g. DeviceIdleController$Constants.dump), so the
# reassembled dex is subtly invalid. dex2oat accepts it at build time and records the
# verification result in the odex, but a runtime-verified dex hits a VerifyError in a
# class the system_server loads at boot -> boot loop. Verified on device.
#
# dex2oat must run ON THE DEVICE (host has no matching ART), but it is pointed at the
# boot classpath of the BASE IMAGE, not at the running system, so the resulting odex
# is valid for the image we ship regardless of the firmware build the device runs.
#
# Usage: patch_framework.sh
#   Uses saved stock artifacts under work/fw/ if present, else pulls them from the
#   connected device (only needed to obtain the stock odex + boot classpath).
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need java python3 zip unzip
FW="$ROOT/work/fw"
D="$FW/deodex"
# dex2oat at the end needs the headset; check now rather than after a minute of deodexing.
require_device
ensure_smali_tools
BOOT="$FW/boot/arm64/boot.oat"
mkdir -p "$D"

# 1) Stock inputs: services.jar (already a dex-less stub on this build), services.odex,
#    and the boot classpath oat/art set (baksmali resolves boot-*.oat siblings next
#    to boot.oat).
#
#    These MUST come from the same build as the base image we assemble, because the
#    odex we produce is only valid against that boot classpath. So read them out of
#    the base image itself; falling back to the connected device is only correct when
#    the device happens to run the same build, hence the warning.
SRC="${SRC:-$ROOT/work/firmware/system.img}"
if [ ! -f "$D/services.jar" ] || [ ! -f "$D/services.odex" ] || [ ! -f "$BOOT" ]; then
  if [ -f "$SRC" ]; then
    need_debugfs
    echo "[*] extracting stock framework artifacts from the base image"
    "$DBG" -R "dump /system/framework/services.jar $D/services.jar" "$SRC" >/dev/null 2>&1
    "$DBG" -R "dump /system/framework/oat/arm64/services.odex $D/services.odex" "$SRC" >/dev/null 2>&1
    rm -rf "${FW:?}/boot"; mkdir -p "$FW/boot"
    # the boot image (boot.oat/.art) lives in /system/framework/arm64/, not oat/arm64/
    "$DBG" -R "rdump /system/framework/arm64 $FW/boot" "$SRC" >/dev/null 2>&1
  else
    require_device
    echo "[!] no base image at $SRC — pulling the framework from the device instead." >&2
    echo "    That is only valid if the device runs the same build as the image you flash." >&2
    adb pull /system/framework/services.jar "$D/services.jar" >/dev/null
    adb pull /system/framework/oat/arm64/services.odex "$D/services.odex" >/dev/null
    mkdir -p "$FW/boot/arm64"
    adb pull /system/framework/arm64/ "$FW/boot/" >/dev/null 2>&1 || \
      adb pull /system/framework/oat/arm64/ "$FW/boot/" >/dev/null 2>&1 || true
  fi
fi
[ -s "$D/services.jar" ] || die "stock services.jar not obtained (base image $SRC readable?)"
[ -s "$D/services.odex" ] || die "stock services.odex not obtained (base image $SRC readable?)"
[ -f "$BOOT" ] || die "boot.oat not found: $BOOT (expected in /system/framework/arm64 of the base image)"

# 2) Deodex services.odex -> smali (API 25 oat, needs the device boot.oat classpath).
echo "[*] deodex services.odex"
rm -rf "${D:?}/smali"
java -jar "$BAKSMALI" deodex -a 25 -b "$BOOT" "$D/services.odex" -o "$D/smali"

# 3) THE patch: compareSignatures -> SIGNATURE_MATCH (0). This is the only edit;
#    the deodex round-trip (baksmali deodex -a 25 + smali assemble -a 25) reassembles
#    and dex2oat-verifies clean with no other changes.
python3 - "$D/smali" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, 'com/android/server/pm/PackageManagerService.smali')
s = open(p).read()
s2 = re.sub(
    r'(\.method static compareSignatures\(\[Landroid/content/pm/Signature;\[Landroid/content/pm/Signature;\)I\n\s*\.registers \d+\n)',
    r'\1\n    const/4 v0, 0x0\n\n    return v0\n', s, count=1)
if s2 == s: sys.exit("compareSignatures not patched")
open(p,'w').write(s2); print("  patched compareSignatures -> SIGNATURE_MATCH")
PY

# 4) Reassemble the patched dex.
echo "[*] assemble patched dex"
java -jar "$SMALI" assemble -a 25 "$D/smali" -o "$D/classes.dex"

# 5) Stub jar (META-INF only, ships in image) + compile jar (META-INF + patched dex).
# The stock jar is already dex-less on this build, so only strip a classes.dex if this
# build ships one: `zip -d` on a jar without that entry exits 12 ("Nothing to do!")
# and would abort under set -e.
cp "$D/services.jar" "$D/services_stub.jar"
if unzip -l "$D/services_stub.jar" | grep -q ' classes\.dex$'; then
  zip -dq "$D/services_stub.jar" classes.dex
fi
cp "$D/services_stub.jar" "$D/services_for_compile.jar"
( cd "$D" && zip -q "$D/services_for_compile.jar" classes.dex )

# 6) Recompile the odex on-device, against the BASE IMAGE's boot classpath.
#    -Xnorelocate is required: otherwise ART tries to relocate the boot image into
#    /data/dalvik-cache and aborts ("Only the zygote can create the global boot
#    image"), silently leaving a 0-byte odex behind.
require_device
echo "[*] on-device dex2oat against the base image's boot classpath -> services_patched.odex"
device_dex2oat "$D/services_for_compile.jar" /system/framework/services.jar \
  "$D/services_patched.odex" "$(dirname "$BOOT")/boot.art"

echo "[*] OK -> $D/services_stub.jar + $D/services_patched.odex"
