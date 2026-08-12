#!/usr/bin/env bash
# Reproduce the SystemUX (com.oculus.systemux) patches.
#
# 1) Panel trust mesh: the same SigCertVerifier flip patch_trust.sh applies, because
#    SystemUX is a panel-mesh member and would otherwise reject the re-signed shell.
#
# 2) First-time NUX dialogs, removed at the source. SystemUX's AnytimeUI v2 shows the
#    NUX dialog flow (intro -> social -> apps -> sharing -> settings) whenever its
#    "dialog NUX seen" marker is unset — which is the case on every fresh /data, i.e.
#    after every factory reset. Meta gates it server-side with the
#    `oculus_mobile_auiv2_bypass_nux_dialogs` gatekeeper, which offline always resolves
#    to false, so the flow always runs. It is NOT covered by the Horizon profile NUX
#    patches (those handle the account/profile NUX) nor by the `first_time_nux_*`
#    settings in /data/oculus/settings/user0.db — verified on device: with all five of
#    those set to 1 the dialogs still appear.
#
#    The patch points showNuxDialogFlow() straight at endDialogNux(), the method the
#    flow itself calls when the user finishes the last dialog. That hides the dialog and
#    queues `systemux auiV2MarkDialogNuxSeen`, so the NUX is recorded as completed
#    exactly as if it had been clicked through — no dialog, no leftover state.
#
# Usage: patch_systemux.sh [in.apk] [out.apk]   (defaults under work/)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need apktool python3
IN="${1:-$APKS/SystemUX.apk}"
OUT="${2:-$ROOT/work/trust/SystemUX_signed.apk}"
WORK="$ROOT/work/trust/systemux"
[ -f "$IN" ] || die "stock SystemUX.apk not found: $IN (run extract_firmware.sh or extract_apks.sh first)"
[ -f "$KS" ] || die "keystore not found: $KS (run patch_ocms.sh first — it creates the shared key)"

echo "[*] decompile $(basename "$IN")"
# -r: smali-only patch, so keep resources.arsc raw (no aapt re-encode on build).
apktool d -r -f -o "$WORK" "$IN" >/dev/null

# 1) panel trust mesh
SC="$(find_one "$WORK" '*SigCertVerifier*SigCertInfo.smali' "SigCertVerifier\$SigCertInfo.smali")"
python3 "$ROOT/scripts/trust_flip.py" "$SC"

# 2) NUX dialog flow -> straight to its own completion path
ND="$(find_one "$WORK" '*anytimeui/v2/NuxDialogs.smali' NuxDialogs.smali)"
python3 - "$ND" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Replace the whole entry point rather than the call inside it: showIntroNuxDialog is
# also invoked from the flow's lambdas, and those must keep working for the (now
# unreachable) manual path.
new = '''.method public static showNuxDialogFlow(Lcom/oculus/panelapp/anytimeui/v2/AnytimeUIAndroidPanelAppV2;Landroid/content/res/Resources;)V
    .registers 4

    invoke-static {p0}, Lcom/oculus/panelapp/anytimeui/v2/NuxDialogs;->endDialogNux(Lcom/oculus/panelapp/anytimeui/v2/AnytimeUIAndroidPanelAppV2;)V

    return-void
.end method'''
# endDialogNux is what we jump to. Check for its DEFINITION, and do it before the
# replacement: afterwards the file always contains the string, because our own inserted
# call put it there — a check on the result would pass no matter what.
if '.method private static endDialogNux(Lcom/oculus/panelapp/anytimeui/v2/AnytimeUIAndroidPanelAppV2;)V' not in s:
    sys.exit("endDialogNux not found — refusing to emit a dangling call")
s2 = re.sub(r'\.method public static showNuxDialogFlow\(Lcom/oculus/panelapp/anytimeui/v2/AnytimeUIAndroidPanelAppV2;Landroid/content/res/Resources;\)V.*?\.end method',
            new, s, count=1, flags=re.S)
if s2 == s:
    sys.exit("showNuxDialogFlow not patched (SystemUX layout differs?)")
open(p, 'w').write(s2)
print("  patched showNuxDialogFlow -> endDialogNux (NUX marked seen, no dialogs)")
PY

build_sign_apk "$WORK" "$OUT"
