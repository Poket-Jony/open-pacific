# Build tools (downloaded, not vendored)

`tools/` is **git-ignored and generated** — OpenPacific vendors no third-party
binaries. `scripts/fetch_tools.sh` downloads what the build needs into it, and the
patch scripts call it on demand:

```sh
scripts/fetch_tools.sh            # resolve version + download into tools/
SMALI_VER=3.0.9 scripts/fetch_tools.sh
```

| File | Project | License |
|---|---|---|
| `tools/baksmali-<ver>.jar` | baksmali (fat release jar) | BSD 3-Clause |
| `tools/smali-<ver>.jar` | smali (fat release jar) | BSD 3-Clause |

Source: <https://github.com/baksmali/smali/releases> (the continuation of
JesusFreke's smali).

## Version policy

Same as Magisk: **the latest release is used by default.** Precedence is an explicit
`SMALI_VER` pin > a version already cached in `tools/` > the latest GitHub release.
The verified version is `TESTED_SMALI_VER` in `scripts/lib.sh` (currently `3.0.9`) and is
printed as a hint whenever a different one is in use, so you can fall back to it if a
newer build misbehaves:

```sh
SMALI_VER=3.0.9 scripts/build_all.sh
```

## Never go below the tested version

baksmali **2.2.x cannot fully deodex this firmware**. It does not know the
`iget-boolean-quick` opcode and silently drops quickened field accesses it fails to
resolve, leaving only a `#AnalysisException` comment in the smali — for example in
`DeviceIdleController$Constants.dump` and
`NotificationUsageStats$AggregatedStats.toStringWithIndent`.

The reassembled dex then assembles and even compiles cleanly, but is semantically
broken in classes the `system_server` loads during boot. The result is a **boot loop
with no logs in `/data`**, because the failure happens before logging is up. Verified
on device: 2.2.3 produces 3 AnalysisExceptions, 3.0.9 produces none, and only the
3.0.9 build boots.

## Using your own copies

Both paths are overridable, so a distribution can point at its own packages instead:

```sh
BAKSMALI=/usr/share/java/baksmali.jar SMALI=/usr/share/java/smali.jar scripts/build_all.sh
```
