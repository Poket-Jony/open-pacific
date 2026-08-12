#!/usr/bin/env bash
# Reproduce the UserServer2 (com.oculus.userserver) patch from a stock
# UserServer2.apk.
#
# UserServer2 exposes its manager API only to Meta-signed callers: every entry
# point calls SignatureVerifier.ensureAllowedFor(...), which throws
# SecurityException ("Cannot access userserver api") for our re-signed home.
# This is an app-level check, independent of the framework signature permission,
# so patching PackageManagerService.compareSignatures does not cover it.
#
# Patch: make ensureAllowedFor(...) a no-op (return before the verification
# loop), then re-sign with the project key.
#
# Usage: patch_userserver.sh [in.apk] [out.apk]
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need apktool python3
IN="${1:-$ROOT/work/apks/UserServer2.apk}"
OUT="${2:-$ROOT/work/trust/UserServer2_signed.apk}"
WORK="$ROOT/work/trust/userserver2"
[ -f "$IN" ] || die "stock UserServer2.apk not found: $IN"
[ -f "$KS" ] || die "keystore not found: $KS"

apktool d -r -f -o "$WORK" "$IN" >/dev/null

SV="$(find_one "$WORK" '*callerverifiers/SignatureVerifier.smali' SignatureVerifier.smali)"
python3 - "$SV" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
pat = r'(\.method public varargs ensureAllowedFor\(\[Lcom/oculus/userserver/managerservice/callerverifiers/SignatureVerifier\$InternalSignatureVerifier;\)V\n\s*\.locals \d+\n)'
s2 = re.sub(pat, r'\1\n    return-void\n', s, count=1)
if s2 == s: sys.exit("ensureAllowedFor not patched")
open(p, 'w').write(s2)
print("  patched ensureAllowedFor -> no-op")
PY

build_sign_apk "$WORK" "$OUT"
