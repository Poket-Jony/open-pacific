#!/usr/bin/env bash
# Go/no-go check for Hermes bundle edits: reassemble the untouched disassembly and
# compare hashes. If disasm -> asm is byte-identical, a .hasm edit produces a bundle
# that differs only by that edit — which removes the usual reassembly-corruption risk.
#
# Usage: roundtrip_check.sh        (run disasm_bundle.sh first)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need hbctool
[ -d "$DISASM/reactnative_v74" ] || die "run disasm_bundle.sh first"

hbctool asm "$DISASM/reactnative_v74" "$BUNDLE/reactnative.roundtrip.bcbundle"

# sha256_of picks sha256sum (Linux) or shasum (macOS) — do not hardcode either.
a="$(sha256_of "$BUNDLE/reactnative.orig.bcbundle")"
b="$(sha256_of "$BUNDLE/reactnative.roundtrip.bcbundle")"
echo "orig:      $a"
echo "roundtrip: $b"
# Exit non-zero on a mismatch: this is a go/no-go gate, so it has to be usable from a
# script (`roundtrip_check.sh && edit_the_bundle`), not just readable by a human.
if [ "$a" = "$b" ]; then
  echo "[*] PASS byte-identical"
else
  echo "[!] DIFF — reassembly not lossless, investigate before patching" >&2
  exit 1
fi
