#!/usr/bin/env bash
# Re-sign an APK with the patch key WITHOUT changing its code (classes.dex
# stays byte-identical, so its pre-compiled odex remains valid).
#
# build_all.sh runs this for MiniHome, and that is NOT optional: MiniHome shares the
# com.oculus.uid user with Horizon, and app-level checks reject a shared UID whose
# members carry different signatures — Horizon crashed with "Uid [com.oculus.horizon,
# com.oculus.home] has inconsistent signatures across packages" until MiniHome got the
# project key too. The framework compareSignatures patch does not cover this; it only
# makes *PackageManager* tolerant, not the checks apps run themselves.
#
# Use this script whenever an app must join the project key but its code — and therefore
# its pre-compiled odex — has to stay valid.
#
# Usage: resign_apk.sh <in.apk> <out.apk>
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need zip
[ $# -ge 2 ] || die "usage: resign_apk.sh <in.apk> <out.apk>"
IN="$1"; OUT="$2"
[ -f "$IN" ] || die "apk not found: $IN"
[ -f "$KS" ] || die "keystore not found: $KS (run patch_ocms.sh first — it creates the shared key)"
TMP="$(dirname "$OUT")/$(basename "$OUT" .apk).stripped.apk"
cp "$IN" "$TMP"
zip -d "$TMP" 'META-INF/*' >/dev/null 2>&1 || true
sign_apk "$TMP" "$OUT"
"$BT/apksigner" verify --print-certs "$OUT" | grep "certificate DN" || true
