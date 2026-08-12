#!/usr/bin/env bash
# Neutralize the Oculus panel signature trust check in a panel-mesh APK.
#
# vrshell (PanelServiceConnection) verifies each panel app's signature and each
# panel app (PanelService.verifyVrShellUID) verifies vrshell, both via
# SigCertVerifier against a hardcoded Meta cert set. Re-signing any mesh member
# breaks these checks (panels get disconnected / MSG_CREATE_PANEL_APP dropped).
#
# Patch: flip SigCertVerifier$SigCertInfo.createUntrusted() to construct the
# result with isTrusted=true. Every "untrusted" verdict (checkSigCertInfo,
# checkAssetBundleSignature) then reads as trusted, so the mesh accepts our
# re-signed apps. Then re-sign with the project key.
#
# Usage: patch_trust.sh <in.apk> <out.apk>
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need apktool python3
[ $# -ge 2 ] || die "usage: patch_trust.sh <in.apk> <out.apk>"
IN="$1"; OUT="$2"
WORK="$ROOT/work/trust/$(basename "${IN%.apk}")"
[ -f "$IN" ] || die "apk not found: $IN"
[ -f "$KS" ] || die "keystore not found: $KS"

apktool d -r -f -o "$WORK" "$IN" >/dev/null

F="$(find_one "$WORK" '*SigCertVerifier*SigCertInfo.smali' "SigCertVerifier\$SigCertInfo.smali")"
python3 "$ROOT/scripts/trust_flip.py" "$F"

build_sign_apk "$WORK" "$OUT"
