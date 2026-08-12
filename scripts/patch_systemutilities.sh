#!/usr/bin/env bash
# Reproduce the SystemUtilities (com.oculus.systemutilities) patch.
#
# Opens FirstTimeNUXSettingsReceiver.throwIfNotAllowed() (was: only release-signed
# com.oculus.vrshell.home may call it) so ANY caller can send the NUX-complete setter
# broadcast: `adb shell am broadcast -a set_first_time_nux_complete
# -p com.oculus.systemutilities` (no root).
#
# WHAT THIS IS AND IS NOT, measured on device: the broadcast writes
# `first_time_nux_complete` in `user_settings`, and that alone does NOT get past the
# first-run flow — the blocking screen after a factory reset is the shell's OTA gate
# (`first_time_nux_pre_ota_complete` in `system_settings`), which patch_companionserver.sh
# clears. So this is not the NUX fix.
#
# It is kept because the check it opens is one WE break: the receiver only accepts a
# release-signed `com.oculus.vrshell.home`, and re-signing the suite with the project key
# makes the shell fail exactly that test. Without this patch the setter would be
# unreachable for the shell itself, not just for adb.
# Usage: patch_systemutilities.sh [in.apk] [out.apk]   (defaults under work/sysutil/)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need apktool python3
IN="${1:-$ROOT/work/sysutil/SystemUtilities.apk}"
OUT="${2:-$ROOT/work/sysutil/SystemUtilities_signed.apk}"
[ -f "$IN" ] || die "stock SystemUtilities.apk not found: $IN (run extract_firmware.sh or extract_apks.sh first)"
[ -f "$KS" ] || die "keystore not found: $KS (run patch_ocms.sh first — it creates the shared key)"
WORK="$ROOT/work/sysutil/smali"

# -r: smali-only patch, so keep resources.arsc raw (no aapt re-encode on build).
apktool d -r -f -o "$WORK" "$IN" >/dev/null

F="$(find_one "$WORK" '*/FirstTimeNUXSettingsReceiver.smali' FirstTimeNUXSettingsReceiver.smali)"
python3 - "$F" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
anchor='''    .prologue
    .line 85
    const/4 v5, 0x0

    invoke-static {p2, v5}, Lcom/oculus/secure/trustedapp/CallerInfoHelper;->getCallerInfo(Landroid/content/Intent;Z)Lcom/oculus/secure/trustedapp/CallerInfoHelper$CallerInfo;'''
repl=anchor.replace('.prologue\n','.prologue\n    return-void\n\n',1)
assert anchor in s, "anchor not found (apktool output differs)"
open(p,'w').write(s.replace(anchor,repl,1)); print("patched throwIfNotAllowed -> no-op")
PY

# SystemUtilities is also a panel-mesh host: its SigCertVerifier authenticates the
# calling shell (com.oculus.vrshell) when the desktop 2D-app panel is created
# (PanelService.verifyVrShellUID). Our re-signed vrshell fails that Meta-cert
# check -> "Expected com.oculus.vrshell APK to be signed with trusted certificate"
# -> MSG_CREATE_PANEL_APP dropped -> 2D apps won't launch. Apply the same trust
# flip as patch_trust.sh: SigCertInfo.createUntrusted() -> isTrusted=true, so the
# mesh accepts the re-signed shell.
SC="$(find_one "$WORK" '*SigCertVerifier*SigCertInfo.smali' "SigCertVerifier\$SigCertInfo.smali")"
python3 "$ROOT/scripts/trust_flip.py" "$SC"

build_sign_apk "$WORK" "$OUT"
