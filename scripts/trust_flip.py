#!/usr/bin/env python3
"""Flip SigCertVerifier$SigCertInfo.createUntrusted() to build a TRUSTED result.

The Oculus panel mesh authenticates every member by signature via SigCertVerifier.
createUntrusted() is the single place that constructs the "not trusted" verdict, so
flipping the isTrusted argument it passes to <init>(Z...) makes every untrusted
verdict (checkSigCertInfo, checkAssetBundleSignature, verifyVrShellUID) read as
trusted — which is what lets the re-signed apps talk to each other.

Used by patch_trust.sh, patch_trust_odex.sh, patch_systemutilities.sh and
patch_systemux.sh, i.e. for both apktool-decoded apks and deodexed .odex smali.

Usage: trust_flip.py <SigCertVerifier$SigCertInfo.smali>
       trust_flip.py --selftest
"""
import re
import sys

METHOD = re.compile(r'\.method public static createUntrusted\(.*?\.end method', re.S)
# createUntrusted() ends in `invoke-direct {vN, vTrusted, ...}, L...SigCertInfo;-><init>(Z...`
INIT = re.compile(r'invoke-direct \{v\d+, (v\d+),[^}]*\},\s*L[^;]*SigCertInfo;-><init>\(Z')


def flip(smali):
    """Return (patched_smali, register) or raise ValueError."""
    m = METHOD.search(smali)
    if not m:
        raise ValueError("createUntrusted not found")
    block = m.group(0)
    inv = INIT.search(block)
    if not inv:
        raise ValueError("SigCertInfo <init> invoke not found")
    reg = inv.group(1)
    new = re.sub(r'const/4 ' + reg + r', 0x0', 'const/4 ' + reg + ', 0x1', block, count=1)
    if new == block:
        raise ValueError("isTrusted const not flipped (register %s)" % reg)
    return smali.replace(block, new, 1), reg


def check(condition, message):
    """assert would be discarded under PYTHONOPTIMIZE, silently passing the selftest.

    This is the only automated check of the patch logic and CI runs it directly, i.e.
    without lib.sh's PYTHONOPTIMIZE guard, so it must not depend on assert.
    """
    if not condition:
        raise AssertionError(message)


def selftest():
    src = """.method public static createUntrusted(Ljava/lang/String;)LSigCertVerifier$SigCertInfo;
    .locals 3

    const/4 v1, 0x0

    const/4 v2, 0x0

    invoke-direct {v0, v1, v2}, LSigCertVerifier$SigCertInfo;-><init>(ZLjava/lang/String;)V

    return-object v0
.end method
"""
    out, reg = flip(src)
    check(reg == "v1", "expected register v1, got %s" % reg)
    check("const/4 v1, 0x1" in out, "isTrusted register not flipped to 0x1:\n%s" % out)
    check("const/4 v2, 0x0" in out, "unrelated register must stay untouched")
    try:
        flip(".method public static somethingElse()V\n.end method\n")
    except ValueError:
        pass
    else:
        raise AssertionError("missing createUntrusted must raise")

    # The method may be found and still not be patchable — refuse loudly instead of
    # writing the file back unchanged, which would ship an unpatched, silently
    # untrusted app. Two ways that happens:
    #   a) the flag is not a const/4 literal (a future build could sget it),
    #   b) it is already 0x1, i.e. the file was patched before.
    no_const = src.replace("const/4 v1, 0x0", "sget-boolean v1, LFoo;->BAR:Z")
    try:
        flip(no_const)
    except ValueError:
        pass
    else:
        raise AssertionError("a non-literal isTrusted must raise, not pass silently")

    already, _ = flip(src)
    try:
        flip(already)
    except ValueError:
        pass
    else:
        raise AssertionError("an already-flipped file must raise, not double-patch")
    print("selftest ok")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        selftest()
        sys.exit(0)
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path) as f:
        try:
            patched, register = flip(f.read())
        except ValueError as e:
            sys.exit("error: %s: %s" % (path, e))
    with open(path, 'w') as f:
        f.write(patched)
    print("  patched createUntrusted: isTrusted -> true (%s)" % register)
