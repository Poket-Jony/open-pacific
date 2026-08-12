# Contributing

Thanks for helping improve OpenPacific, the offline Oculus Go Home patch set.

## Scope & ground rules

- **No Meta/Oculus binaries in the repo, ever.** APKs, firmware images, and
  `reactnative.bcbundle` are Meta's copyright. They are extracted from the official
  unlock ZIP (`extract_firmware.sh`) or your own unlocked device (`extract_apks.sh`),
  and `.gitignore` keeps `work/` out of git. PRs that add such files will be rejected.
- Patches are expressed as **original source** (Java/smali fragments, `.hasm`
  edits) applied by scripts — never as redistributed patched binaries.
- This is an independent project for a discontinued device you own and have
  officially unlocked. Keep it that way.

## Conventions

- Every script starts with `#!/usr/bin/env bash` and sources `lib.sh`:

  ```sh
  # shellcheck source=lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
  ```

  `lib.sh` provides `set -euo pipefail`, the repo paths (`ROOT`, `APKS`, `TOOLS`,
  `DOWNLOADS`, `KS`, …), toolchain discovery (`BT`, `AJ`, `DBG`, …) and the shared
  helpers: `die` / `need` / `need_sdk` / `need_debugfs`, `find_one`, `require_device` /
  `ensure_adb_root` / `adb_root_shell`, `ensure_smali_tools` / `smali_version`,
  `magisk_version` / `ensure_magisk_apk`, `sign_apk` / `build_sign_apk`,
  `device_boot_image` / `device_dex2oat`, `partition_matches` / `boot_has_root_patch` /
  `magisk_boot_path`, `md5_of` / `sha256_of` / `is_zip`. Reuse them instead of re-implementing.
  Note that `WORK` is *not* one of them: each patch script uses that name for its own
  apktool/deodex directory.
- Guard external tools with `need <tool>...` so missing deps fail with a clear
  message instead of a cryptic error.
- Host paths are auto-detected and env-overridable; never hardcode
  `~/Library/Android/...` or a specific build-tools version.
- Keep it **cross-platform** (Linux, macOS, WSL2): no GNU-only flags (`stat -c`,
  `sed -i` without a suffix, `readlink -f`, `grep -P`, `find -printf`) and no
  BSD-only ones either. Use the `lib.sh` helpers (`md5_of`, `sha256_of`) instead of
  calling `md5sum`/`shasum` directly.
- Keep build output under `work/` (git-ignored) — `patch/` stays source-only.
- `tools/` and `downloads/` are **generated and git-ignored** too. Third-party build
  tools are never vendored: `scripts/fetch_tools.sh` downloads smali/baksmali on
  demand (see [docs/tools.md](docs/tools.md)).
- `scripts/deploy.sh` is the user-facing entry point (build locally, then write stock
  to slot `_a` and OpenPacific to `_b`). Keep the individual scripts usable on their
  own, and keep `deploy.sh` free of logic that belongs in them.

## Invariants you must not break

Each of these was learned the hard way on device, and all of them fail **silently**:
the first three build a fine-looking image that never boots (no logs in `/data`), the
fourth boots perfectly and just has no root, the fifth loses root after a wipe, the sixth
leaves an app that never starts, and the traps below cost anything from a silently
unpatched app to a headset stuck on a setup screen.

1. **The boot image must strip dm-verity** (`KEEPVERITY=false`). `/system` is mounted at
   `/` with the `verify` flag, so a modified system fails its hash check otherwise.
2. **An odex must be compiled against the boot classpath of the base image**, never
   against whatever the connected headset runs — use `device_boot_image()` and pass
   `--runtime-arg -Xnorelocate`. An odex carries its boot image checksum, and ART
   rejects a mismatch.
3. **Never lower the smali/baksmali version** below `TESTED_SMALI_VER`. 2.2.x cannot
   deodex this firmware and silently produces an invalid dex
   ([docs/tools.md](docs/tools.md)).
4. **The boot patch must run with `LEGACYSAR=true`.** The bootloader appends
   `skip_initramfs`, so without the kernel hexpatch it enables, the ramdisk holding
   `magiskinit` is never loaded and the device simply has no root — everything else
   still works, so nothing fails visibly. `boot_has_root_patch()` exists because a boot
   image built without it is otherwise indistinguishable from a good one.

5. **Magisk is set up on the device, in one place.** `patch/system/magisk-setup.sh`,
   started by `patch/system/openpacific.rc`, installs the manager app, populates
   `/data/adb/magisk`, grants `su` and enables Zygisk. Both files are baked into the
   system image, which is precisely what lets a factory reset repair itself — everything
   Magisk keeps lives in `/data` and is gone after a wipe. Do **not** re-add that logic to
   `deploy.sh`: it was there once, the two copies drifted, and the same wrong "is the app
   installed" probe had to be found and fixed twice. (`pm dump` and `dumpsys package` are
   no good for that probe, by the way — they also print usage statistics that keep naming
   an app's activities long after it is uninstalled. Use `pm path`.) `deploy.sh` waits for
   the boot service and verifies the outcome, nothing more.
6. **Never re-sign a platform-signed app, and never leave a shared UID mixed.** These
   pull in opposite directions, and both failures are silent. Re-signing a platform-signed
   app drops its `seinfo` from `platform` to `default`; with no `seapp_context` for
   `uid=system`, zygote's `selinux_android_setcontext` aborts the process on every launch,
   so the app simply never appears. That is why `VrDesktopPanelApp` is patched through its
   **odex only** (`patch_trust_odex.sh`) and its apk is left untouched. In the other
   direction, every member of the `com.oculus.uid` shared user must carry the *same* key:
   Horizon crashed with "inconsistent signatures across packages" until MiniHome was
   re-signed too, although its code needed no change at all. The framework
   `compareSignatures` patch does not cover this — it only makes *PackageManager* tolerant,
   not the app-level checks.

Four more silent-failure traps the scripts already guard against — keep the guards:

* `debugfs` reports a failed command on stderr but still **exits 0**, so
  `build_system_image.sh` treats any stderr output as fatal.
* The embedded python patch steps assert every smali anchor, and Python **discards
  `assert` when `PYTHONOPTIMIZE` is set** — a patch would then not apply, silently.
  `lib.sh` exports an empty `PYTHONOPTIMIZE` to neutralise that, and CI sets a hostile
  `PYTHONOPTIMIZE=2` before sourcing `lib.sh` to prove the guard still works.
* The first-run gates are cleared **in the image**, never by writing to `/data`. The
  native shell reads a *cached* copy of the Oculus settings, so a value written straight
  into `/data/oculus/settings/*.db` has no effect at all — it has to go through
  `SettingsManager`, which is why `patch_companionserver.sh` patches the state machine
  that calls it. A patch that "works" by seeding `/data` also dies at the next wipe.
* `partition_matches()` must hash **exactly** the image length: the whole blocks plus
  the trailing partial one. A Magisk-patched boot image is never block-aligned, and an
  earlier version that simply refused to compare unaligned images made slot `_b` look
  stale forever and rewrote ~2 GB on every run. Likewise, `deploy.sh` reuses the
  artifacts in `work/` instead of rebuilding, because the image assembly is not
  byte-reproducible and a rebuild would defeat that comparison the same way.

## Checks (run before a PR)

```sh
shellcheck scripts/*.sh          # must be clean (config in .shellcheckrc)
shellcheck -s sh patch/system/*.sh   # device-side scripts run as POSIX sh
bash -n scripts/*.sh             # syntax
sh -n patch/system/*.sh
python3 -m py_compile scripts/*.py
python3 scripts/trust_flip.py --selftest   # patch-logic self-check
python3 scripts/check_docs.py              # dead links/anchors, whitespace, newlines
```

Note that shellcheck findings differ between releases — 0.11 dropped SC2015, older
runners still report it — so a green local run does not guarantee a green CI run. The
workflow prints its version for exactly that reason.

CI runs exactly these on **Linux and macOS** on every push, plus two guards that no
local run covers: that the `lib.sh` helpers behave the same on either platform, and that
`lib.sh` still neutralises `PYTHONOPTIMIZE` (`.github/workflows/lint.yml`).

## Debugging

[docs/troubleshooting.md](docs/troubleshooting.md) is the first stop and the right
place to record new failure modes: symptom → how to tell it apart → cause → fix. Keep
it measured, not guessed — every entry there was reproduced on device.

## Reproducing / testing

`scripts/deploy.sh <unlock.zip>` is the full path; [docs/reproduce.md](docs/reproduce.md)
documents each step. It writes stock to slot `_a` and OpenPacific to `_b`, so the
fallback is always a known-good stock image ([docs/recovery.md](docs/recovery.md)) — no
manual backup needed. A failed `_b` costs one `fastboot set_active a`.
