# AGENTS.md

## Project overview

OpenPacific patches the stock Oculus Go firmware so its Home shell boots and runs
offline, listing the apps actually installed on the device. Everything is reproduced
from Meta's official unlock ZIP by shell + Python scripts; no binaries are vendored.

* `scripts/` — every patch is one script; `lib.sh` is the shared library, sourced (never
  executed) by all of them
* `patch/` — the only hand-written sources (the OCMS provider `.java`, the `hosts` file)
* `docs/` — [reproduce](docs/reproduce.md) · [architecture](docs/architecture.md) ·
  [root cause](docs/root-cause.md) · [device constraints](docs/device-constraints.md) ·
  [troubleshooting](docs/troubleshooting.md) · [recovery](docs/recovery.md) ·
  [tools](docs/tools.md)
* `work/`, `tools/`, `downloads/` — generated or downloaded, all git-ignored

## Setup commands

Host tools (auto-detected, every path env-overridable — see the README's
[Configuration](README.md#configuration) table):

```sh
# macOS
brew install android-platform-tools e2fsprogs apktool openjdk
# Debian/Ubuntu
apt install android-sdk-platform-tools e2fsprogs apktool default-jdk python3
pip install payload_dumper
```

`scripts/fetch_tools.sh` downloads smali/baksmali on demand. Never vendor a tool or a
firmware binary into the repo — Meta's binaries are not redistributable.

## Build and test commands

```sh
scripts/deploy.sh path/to/unlocked_build.zip   # extract + build + flash both slots
REBUILD=1 scripts/deploy.sh …                  # after editing a patch script
scripts/build_all.sh                           # build only
scripts/build_all.sh host                      # only the steps that need no headset
scripts/build_all.sh device                    # the three dex2oat steps + image assembly
```

A re-run reuses the artifacts in `work/`; see the invariants below for why that is not
merely a shortcut.

Checks, all of which must pass before a PR:

```sh
shellcheck scripts/*.sh                      # must be clean; config in .shellcheckrc
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py
python3 scripts/trust_flip.py --selftest
```

## Testing instructions

There is no test suite you can run on the host alone — this is hardware-in-the-loop
work. Three build steps (`patch_framework.sh`, `patch_trust_odex.sh`,
`patch_companionserver.sh`) need a connected, booted headset, because `dex2oat` only
runs on the target.

The real test is a deploy: `scripts/deploy.sh` ends by querying the patched provider and
reporting how many installed apps the offline library serves. A number greater than zero
is the pass condition; on the reference device it is 22. If you cannot flash, say so
rather than claiming a change is verified.

## Code style

* Shell is POSIX-minded bash and must run unchanged on Linux and macOS. Put anything
  platform-specific (hash tools, tool discovery) behind a helper in `lib.sh`.
* Every script sources `lib.sh` and uses its helpers (`die`, `need`, `find_one`,
  `sign_apk`, `build_sign_apk`, `device_dex2oat`, `partition_matches`) instead of
  re-implementing them. `lib.sh` sets `set -euo pipefail` for all of them.
* All code, comments and documentation are written in **English**.
* Comments explain *why*, not *what* — most of them record a failure that already cost a
  boot loop. Do not delete one without understanding what it prevents.
* Prefer deleting code over adding it; prefer one guard in a shared helper over one in
  every caller.

## Invariants you must not break

Every one of these fails **silently** — nothing errors out. Depending on which you
break you get a headset that never boots (1–3), one that boots fine and has no root (4),
one that boots into a setup screen it can never leave (5), a headset that loses root
after a wipe (6), an app that never starts (7),
an image that is quietly incomplete (8–9), or a run that rewrites ~2 GB while reporting
success (10). Full reasoning in [CONTRIBUTING.md](CONTRIBUTING.md).

1. The boot image must strip dm-verity (`KEEPVERITY=false`) — `/system` is mounted at `/`
   with `verify`, so any modified system fails its hash check.
2. An odex must be compiled against the boot classpath of the **base image**, never the
   running headset — use `device_boot_image()` and `--runtime-arg -Xnorelocate`.
3. Never lower the smali/baksmali version below `TESTED_SMALI_VER`; 2.2.x silently
   produces an invalid dex.
4. The boot patch must run with `LEGACYSAR=true` — it hexpatches the kernel so the
   ramdisk holding `magiskinit` is loaded at all. `boot_has_root_patch()` tells an image
   built without it apart, since nothing else about it differs.
5. First-run gates are cleared in the image, never by writing to `/data`: the native
   shell reads a *cached* copy of the Oculus settings, so writing
   `/data/oculus/settings/*.db` does nothing and would not survive a wipe either.
6. Magisk is set up **on the device**, by `patch/system/magisk-setup.sh` (started from
   `patch/system/openpacific.rc`), and nowhere else. Both files are baked into the image,
   which is what makes a factory reset repair itself. Do not add a second copy of that
   logic to `deploy.sh` — there used to be one, the two drifted, and the same wrong
   "is the app installed" probe had to be fixed twice. `deploy.sh` waits and verifies.
7. Never re-sign a **platform-signed** app, and never leave a shared UID mixed. Re-signing
   drops `seinfo=platform`, and with no `seapp_context` for `uid=system` zygote SIGABRTs
   the app on every launch — patch its odex instead (`patch_trust_odex.sh`). Conversely,
   every member of `com.oculus.uid` must carry the *same* key, which is why MiniHome is
   re-signed although its code is untouched: app-level checks reject a shared UID whose
   members differ, and the framework `compareSignatures` patch only covers PackageManager.
8. `debugfs` reports failures on stderr but exits 0 — treat its stderr as fatal.
9. `PYTHONOPTIMIZE` must stay empty; Python discards the `assert`-based patch anchors
   otherwise, and a patch then does not apply without a word. `lib.sh` exports it empty
   and CI verifies that guard is still armed — do not remove either.
10. `partition_matches()` must hash exactly the image length, and `deploy.sh` must reuse
   `work/` rather than rebuild. The image assembly is not byte-reproducible, and a
   Magisk-patched boot is never block-aligned — get either wrong and every run rewrites
   ~2 GB while reporting success.

## Security and repo hygiene

* Never commit firmware, APKs, images or keystores. `.gitignore` covers `work/`,
  `tools/`, `downloads/`, `*.apk`, `*.img`, `*.odex`, `*.jks` — keep it that way.
* The patches deliberately neutralise signature and trust checks on a device the owner
  has officially unlocked. That is the point of the project; do not extend it to
  anything that is not needed for the offline shell to work.
* Flashing is destructive and slot `_a` is the user's only fallback. Do not write to a
  partition outside the reviewed `deploy.sh` / `flash.sh` paths.

## Commit and PR guidelines

Do not commit or push unless explicitly asked; leave staged work for the maintainer.
Contribution details are in [CONTRIBUTING.md](CONTRIBUTING.md).
