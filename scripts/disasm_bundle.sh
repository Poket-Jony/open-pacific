#!/usr/bin/env bash
# Extract VrHome's Hermes bundle and disassemble it to editable .hasm.
#
# Reconnaissance only — nothing shipped needs this, because the library renders from the
# patched OCMS data layer with the stock bundle. Kept for future UI work; the mapped
# leads are in docs/architecture.md.
#
# Usage: disasm_bundle.sh          (needs work/apks/VrHome.apk and hbctool)
# Result: work/disasm/reactnative_v74/ (instruction.hasm, string.json, …)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need unzip xxd
need hbctool
[ -f "$APKS/VrHome.apk" ] || die "stock VrHome.apk not found — run extract_firmware.sh or extract_apks.sh first"
mkdir -p "$BUNDLE" "$DISASM"

unzip -o -q "$APKS/VrHome.apk" "$BUNDLE_ASSET" -d "$BUNDLE/extract"
cp "$BUNDLE/extract/$BUNDLE_ASSET" "$BUNDLE/reactnative.orig.bcbundle"

echo "[*] header:"
xxd "$BUNDLE/reactnative.orig.bcbundle" | head -1

rm -rf "${DISASM:?}/reactnative_v74"
hbctool disasm "$BUNDLE/reactnative.orig.bcbundle" "$DISASM/reactnative_v74"
echo "[*] functions: $(grep -c '^Function<' "$DISASM/reactnative_v74/instruction.hasm")"
