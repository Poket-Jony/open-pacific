# OpenPacific

[![lint](https://github.com/Poket-Jony/open-pacific/actions/workflows/lint.yml/badge.svg)](https://github.com/Poket-Jony/open-pacific/actions/workflows/lint.yml)

**OpenPacific revives the discontinued Oculus Go: its stock Home boots and runs
entirely offline and lists the apps you actually have installed.**

The Go can be [officially unlocked by Meta](https://developers.meta.com/horizon/blog/unlocking-oculus-go/),
but after a factory reset the stock shell is stranded: it blocks on a Meta login that
can never complete, runs a first-time setup that fetches content from dead servers, and
its library lists server-side entitlements that are gone. The result is an endless
spinner.

This project patches the shell and its dependencies so every one of those gates
resolves locally, and adds an offline data source so the library lists the apps
actually installed on the device. One command builds and installs it. Everything is
reproduced from Meta's own official unlock ZIP — **no Meta binaries and no
third-party binaries are redistributed here**.

## Status

Verified on device:

* **Home boots and renders offline** — no login wall, no first-time setup, no crash,
  and no outbound Meta/Facebook/Oculus traffic.
* **The library lists your installed apps with their real icons**, and 2D apps
  (Settings, etc.) launch.
* **The install runs unattended end to end** — `scripts/deploy.sh` writes stock to slot
  `_a` and OpenPacific to `_b`, then verifies that the offline library really serves
  apps.
* **A factory reset is survivable, root included** — the first-run gates that normally
  demand Meta's phone app (OTA blocking dialog, NUX dialog flow) are patched out of the
  **image**, so a wiped headset boots straight to Home with the library intact. Magisk
  keeps its data in `/data` and would be gone, so the setup for it ships in the image too
  and runs itself on the first boot: it installs the manager app, restores Magisk's
  environment, grants `su` and enables Zygisk, then reboots once. No host, no reflash,
  nothing to click.
* **Root works** — Magisk comes up with a complete environment and `adb shell su`
  returns uid 0, set up by the same single command and restored after a factory reset.
  See [Root](#root).

### Scope

* **The Meta store stays dead.** Browse, purchase and entitlement sync need live Meta
  servers; nothing local can resurrect them. Only the library is offline-capable.
* **Magisk modules cannot overlay `/system`** — that needs overlayfs, which the 3.18
  kernel lacks. Magisk itself, `su`, Zygisk and the module scripts do work.
* **No Hermes bundle patch is shipped** — the UI needed no edit, so `VrHome`'s bundle is
  untouched. The reconnaissance tooling stays in the tree for optional future UI work;
  the mapped leads are in [docs/architecture.md](docs/architecture.md).
* **The device's signature checks end up weaker, by necessity.** Re-signing the shell
  only works because `PackageManagerService.compareSignatures` is patched to report a
  match for *every* pair of packages, and the panel-mesh trust checks are flipped to
  "trusted". So signature-level permissions no longer separate anything on this device,
  and an app you install could reach APIs that Meta's signature would normally gate.
  That is inherent to running a re-signed system shell — there is no version of this
  project without it. Treat the headset accordingly and install only software you
  trust. Root (Magisk) is set up on top of that; see [Root](#root).

## Install

```sh
scripts/deploy.sh path/to/unlocked_build.zip
```

That is the whole install. The ZIP is Meta's official
[Oculus Go SW Unlock](https://developers.meta.com/horizon/downloads/package/oculus-go-sw-unlock/)
package — it provides both the stock APKs and the clean base image. Pass either the
archive you downloaded or the `unlocked_build.zip` inside it; the outer one is unpacked
automatically.

**You can start it with nothing plugged in.** Every stock APK is read out of the base
image on the host, and every apk patch is host work, so the build runs unattended until
step 3, where it asks you to connect the headset and waits for it. From there the headset
is needed for the three `dex2oat` steps — which only run on the target — and the flash:

| Slot | Content                                                | Purpose                         |
|------|--------------------------------------------------------|---------------------------------|
| `_a` | stock, unlocked firmware — written once, never patched | recovery fallback, always boots |
| `_b` | **OpenPacific**: patched system + patched boot         | active slot                     |

A first install takes about five minutes end to end. A re-run reuses what is already in
`work/` (`REBUILD=1` forces a fresh build) and compares each slot against it, so it only
writes what actually differs — after a successful install, nothing, and it finishes in
under a minute. Either way `deploy.sh` proves the result instead of just reporting a
boot:

```
[=] already built: work/ocms/system_final.img  (REBUILD=1 forces a fresh build)
[*] slot _a stock: up to date
[*] slot _b custom: up to date
[*] both slots already hold these images and _b is active — nothing to flash
[*] su works for the adb shell: uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0
[*] OpenPacific runs on slot _b; the offline library serves 22 installed apps
```

It works from any starting point: any firmware build, and even a headset that no longer
boots — if only fastboot answers, `deploy.sh` puts stock on `_a`, boots that, and
continues. No factory wipe is needed at any point.

Build tools are not vendored either: `scripts/fetch_tools.sh` downloads smali/baksmali
on demand (see [docs/tools.md](docs/tools.md)).

## Requirements

* An Oculus Go with an **unlocked bootloader** ([Meta's official procedure](https://developers.meta.com/horizon/blog/unlocking-oculus-go/)).
  The headset does not have to be on the unlocked build yet — `deploy.sh` flashes it
  there, and it is only needed for the last stretch (the three `dex2oat` steps and the
  flash), not while the patches are built. It only has to boot far enough for `adb`,
  which serves as the ARM compiler for those steps, and its firmware build does not
  have to match anything.
* Meta's unlock ZIP (link above; `FIRMWARE_URL=<direct-link>` lets the script fetch it).
* Host tools: `adb`, `fastboot`, Android build-tools (`zipalign`, `apksigner`, `d8`),
  a JDK (`javac`/`java`/`javap`/`keytool`), `apktool`, `e2fsprogs`
  (`debugfs`/`e2fsck`), Python 3, and `payload_dumper` (`pip install payload_dumper`).
  The SDK is auto-detected; every path is env-overridable (see
  [Configuration](#configuration)).

### Platforms

Everything is POSIX shell plus Python and runs on **Linux** and **macOS** unchanged;
platform differences (hash tools, `debugfs` location, SDK path) are abstracted in
`lib.sh` and both are covered by CI.

| Platform           | Notes                                                                                                                                                                                                                                                                                                                                      |
|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Linux**          | `apt install android-sdk-platform-tools e2fsprogs apktool default-jdk python3` (or your distro's equivalents)                                                                                                                                                                                                                              |
| **macOS**          | `brew install android-platform-tools e2fsprogs apktool openjdk`                                                                                                                                                                                                                                                                            |
| **Windows / WSL2** | WSL2 has **no direct USB access**, so `adb`/`fastboot` cannot see the headset out of the box. Either attach it with [usbipd-win](https://github.com/dorssel/usbipd-win) (`usbipd attach --wsl --busid ID`), or build inside WSL and run just the flash from Windows with `fastboot.exe`. `debugfs` must be the WSL one, not a Windows tool |

## Patches

Each patch is one reproducible script; each solves a distinct offline gate. The full
per-method table is in [docs/reproduce.md](docs/reproduce.md).

| Component                                 | Script                     | Effect                                                                                                                                                                                                                                                                             |
|-------------------------------------------|----------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **OCMS** (`com.oculus.ocms`)              | `patch_ocms.sh`            | the library content provider serves installed apps from `PackageManager` offline, with real launcher icons inlined as `data:` PNGs and every `AppConverter.isValid` field populated so the stock grid renders them                                                                 |
| **Horizon** (`com.oculus.horizon`)        | `patch_horizon.sh`         | offline "empty account" login, offline platform init, FB-secure trust, the **account/profile first-time setup** removed at the root, an offline app-scoped user id from `ProfileContentProvider`, and no device-auth-token fetch (the platform-signed `DeviceAuthServer` rejects the re-signed caller, which crashed Horizon)                                                                               |
| **SystemUtilities**                       | `patch_systemutilities.sh` | opens the setup-complete setters; also a panel host, so it gets the trust flip                                                                                                                                                                                                     |
| **VrShell / VrHome**                      | `patch_trust.sh`           | the panel signature trust mesh accepts the re-signed apps                                                                                                                                                                                                                          |
| **SystemUX**                              | `patch_systemux.sh`        | same trust flip, plus the **first-time NUX dialogs removed at the source** — its AnytimeUI v2 flow runs on every fresh `/data`, so it reappeared after each factory reset                                                                                                          |
| **CompanionServer**                       | `patch_companionserver.sh` | clears the **first-run OTA gate**: on a fresh `/data` the shell otherwise blocks with "follow the steps in the Oculus app on your phone" and never reaches Home. Odex-only patch                                                                                                   |
| **VrDesktopPanelApp** (2D-app panel host) | `patch_trust_odex.sh`      | trust flip on the **odex only**, so its dex-less platform-signed apk stays untouched. Re-signing it would drop `seinfo=platform` for this `android.uid.system` app, and with no `seapp_context` at `uid=system` zygote SIGABRTs on every launch. This is what makes 2D apps launch |
| **framework** (`services.jar`)            | `patch_framework.sh`       | `PackageManagerService.compareSignatures` → MATCH, so signature permissions and shared-UID checks pass for the re-signed suite                                                                                                                                                     |
| **UserServer2**                           | `patch_userserver.sh`      | opens the app-level caller signature check                                                                                                                                                                                                                                         |
| **boot image**                            | `patch_boot_magisk.sh`     | headless Magisk patch with `KEEPVERITY=false` — **required**, see below — plus `LEGACYSAR=true`, which is what makes root work ([Root](#root))                                                                                                                                     |
| MiniHome (`com.oculus.home`)              | `resign_apk.sh`            | re-signed only, no code change: it shares `com.oculus.uid` with Horizon, and app-level checks reject a shared UID whose members carry different signatures. Its `classes.dex` is untouched, so the stock odex stays valid                                                          |
| VrCastService                             | removed                    | offline-useless, and it rejected the re-signed caller                                                                                                                                                                                                                              |
| `/system/etc/hosts`                       | `build_system_image.sh`    | null-routes Meta/Facebook/Oculus                                                                                                                                                                                                                                                   |

All patched APKs are signed with one **project key** (`work/ocms/patch.jks`, auto-created).
The framework's `compareSignatures` match is what lets that single key be accepted
everywhere the OS checks signatures.

## Two things that make it boot at all

Both were learned the hard way; each one causes a silent boot loop if you get it wrong.
(A third, equally silent trap decides whether you get *root* — see [Root](#root).)

**dm-verity is enforced.** `fstab.pacific` mounts `/system` at `/` with the `verify`
flag, so dm-verity hashes the very partition this project modifies. The patched boot
must therefore be built with `KEEPVERITY=false`, which strips that flag — otherwise
the modified system fails its hash check on every boot.

**An odex is bound to its boot image.** An odex embeds the checksum of the boot image
it was compiled against, and `dex2oat` only runs on the device. Compiling against the
*running* system would produce an odex that ART rejects on any headset whose firmware
build differs from the base image — `system_server` never starts and the device
boot-loops with no logs in `/data`. OpenPacific instead compiles against the boot
classpath of the **base image** (`device_boot_image()` in `lib.sh`, plus
`-Xnorelocate`), which is what makes the build independent of what the headset runs.

## Root

`deploy.sh` sets root up for you; afterwards:

```sh
adb shell su -c id
# uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0
```

Two things are needed for that, and both are easy to miss:

* **`LEGACYSAR=true`.** The bootloader appends `skip_initramfs` to the kernel command
  line, so the kernel ignores the boot image's ramdisk — where `magiskinit` lives. It
  therefore never ran. With this flag `boot_patch.sh` hexpatches the kernel's
  `skip_initramfs` string to `want_initramfs`, the ramdisk is used, `magiskinit` runs and
  mounts its own `/sbin`. Magisk derives the flag in `util_functions.sh`, which the
  headless patch path skips, so `patch_boot_magisk.sh` runs that same check itself.
* **A pre-authorised `su` policy.** Magisk otherwise grants `su` only after a
  confirmation prompt from its manager app, which a headset booting straight into the VR
  shell never shows. `deploy.sh` writes the adb shell into Magisk's policy db instead.

A patched boot alone is not enough, though. It never populates `/data/adb/magisk`
(normally the manager app does that), so Magisk aborts its environment setup — no
`post-fs-data.d`, no `service.d`, no modules. The manager app is missing too, and the su
policy and Zygisk setting do not stay put: Magisk's own "additional setup" reinstalls the
app under a **new uid**, which silently invalidates the policy written for the old one.

All of that lives in `/data` and would be gone after a factory reset, so the setup ships
**in the system image** and runs itself: `/system/etc/init/openpacific.rc` starts
`/system/etc/openpacific/magisk-setup.sh` on every boot, which installs the manager app,
fills `/data/adb/magisk` from files unpacked at build time, grants `su`, enables Zygisk,
and re-reads the app uid each time. The first boot after a wipe reboots once — Zygisk is
decided in `post-fs-data`, before the script can run — and the headset then comes up
complete, with Zygisk injected into **both** zygotes. `deploy.sh` does not duplicate any
of this; it waits for it and verifies the result.

Only **`/system`-overlaying modules** stay impossible — that needs overlayfs, which the
3.18 kernel lacks.
Measurements in [docs/device-constraints.md](docs/device-constraints.md).

## When something goes wrong

[docs/troubleshooting.md](docs/troubleshooting.md) covers every failure mode that was
actually hit on device — boot loops, `No command`, an empty library, a 0-byte odex,
a `su` that is refused — each with how to tell it apart, its cause, and the fix.

## Advanced usage

All scripts live in `scripts/` and share `lib.sh` (toolchain discovery, helpers). Run
them from anywhere; paths resolve against the repo root.

### The individual steps

`deploy.sh` is these four, plus the slot comparison, the su setup and the final check:

```sh
scripts/extract_firmware.sh path/to/unlocked_build.zip   # stock APKs + framework + base image + stock boot
scripts/build_all.sh                                     # every patch + the assembled image
                                                         #   build_all.sh host    -> no headset needed
                                                         #   build_all.sh device  -> dex2oat + image
scripts/patch_boot_magisk.sh b                           # patched boot
scripts/flash.sh work/ocms/system_final.img              # writes slot _b only
```

`extract_firmware.sh` dumps the `system` partition from the ZIP's `payload.bin` with
`payload_dumper` and reads the stock APKs and framework out of it with `debugfs` — no
device pull at all. `build_all.sh` runs each patch, then `build_system_image.sh`
assembles the flashable image by swapping the patched apps into the base image with
`debugfs` (no mount, so it works on macOS and Linux alike).

### One patch at a time

Every patch is also runnable on its own — arguments are `[in.apk] [out.apk]`, both
defaulting to the standard paths under `work/`. The full list with what each one changes
is in [docs/reproduce.md](docs/reproduce.md#build).

### Using your own headset as the source

`extract_apks.sh` pulls the stock APKs off a connected device instead of reading them
from the ZIP. It does **not** produce a clean base image, so the build still needs one.
Note that it reads whatever the headset currently runs: on a device that already has
OpenPacific active those are the **patched** apks, so run it against a stock slot.

```sh
scripts/extract_apks.sh
SRC=/path/to/stock_system.img scripts/build_all.sh
```

### Iterating on one app (no reflash)

Once the project key is adopted, push a re-patched app straight to `/data`:

```sh
adb install -r work/ocms/OCMS_signed.apk
adb shell am force-stop com.oculus.ocms       # reload the provider process
```

### Hermes bundle (not needed for anything shipped)

The stock `VrHome` bundle is left untouched — the library renders from the patched OCMS
data layer. These stay in the tree as reconnaissance tools for future UI work:

```sh
scripts/disasm_bundle.sh                      # extract + disassemble VrHome's reactnative.bcbundle
scripts/roundtrip_check.sh                    # prove disasm→asm is byte-identical
scripts/hbc_grep.py work/disasm/reactnative_v74 strings KEYWORD     # find a string
scripts/hbc_grep.py work/disasm/reactnative_v74 refs STRING_ID      # functions referencing it
```

## Configuration

Defaults are auto-detected; override any as needed, e.g.
`BT=/path ANDROID_HOME=/sdk scripts/patch_ocms.sh`.

| Var                                 | Default                                         | Purpose                                                             |
|-------------------------------------|-------------------------------------------------|---------------------------------------------------------------------|
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | common SDK locations                            | Android SDK root                                                    |
| `BT`                                | newest `build-tools/*`                          | build-tools (`apksigner`, `zipalign`, `d8`)                         |
| `AJ`                                | newest `platforms/android-*/android.jar`        | compile classpath                                                   |
| `DBG` / `FSCK`                      | `PATH`, else Homebrew                           | `debugfs` / `e2fsck`                                                |
| `KS`                                | `work/ocms/patch.jks`                           | the project key, auto-created on first run                          |
| `SRC`                               | `work/firmware/system.img`                      | base image the build swaps into                                     |
| `BAKSMALI` / `SMALI`                | `tools/{bak,}smali-<ver>.jar` (auto-downloaded) | use your own smali/baksmali jars                                    |
| `SMALI_VER`                         | cached jar, else latest release                 | pin smali/baksmali (tested: `3.0.9`; never below)                   |
| `MAGISK_VER`                        | cached apk, else latest release                 | pin Magisk (tested: `v30.7`; older releases measured worse)         |
| `MAGISK`                            | auto-downloaded apk                             | use a local Magisk apk instead                                      |
| `STOCK_BOOT`                        | from the base image, else the device            | stock boot the patch is applied to                                  |
| `BOOT`                              | `downloads/magisk<ver>_patched_boot_b.img`      | use a ready-made patched boot                                       |
| `FIRMWARE_URL`                      | —                                               | direct link so `extract_firmware.sh` fetches the ZIP itself         |
| `OCULUS_DOWNLOAD_DIR`               | `downloads/`                                    | local asset store: unlock ZIP, Magisk apk, boot images              |
| `REBUILD`                           | —                                               | `REBUILD=1 scripts/deploy.sh …` rebuilds instead of reusing `work/` |

## Development

```sh
shellcheck scripts/*.sh                       # lint — clean; config in .shellcheckrc
bash -n scripts/*.sh                          # syntax
python3 -m py_compile scripts/*.py            # python syntax
python3 scripts/trust_flip.py --selftest      # patch-logic self-check
```

CI runs all four on Linux **and** macOS on every push
(`.github/workflows/lint.yml`). See [CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

Ordered from "I want to use this" to "I want to understand or extend it".

| Doc                                                 | Description                                                                                                                                        |
|-----------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| [reproduce.md](docs/reproduce.md)                   | the end-to-end recipe, and a table of every single patch with its effect                                                                           |
| [troubleshooting.md](docs/troubleshooting.md)       | symptom → cause → fix for every failure that was hit on device                                                                                     |
| [recovery.md](docs/recovery.md)                     | slot layout, getting back to stock, why a hard brick is out of reach                                                                               |
| [tools.md](docs/tools.md)                           | the downloaded smali/baksmali, and why their version is critical                                                                                   |
| [device-constraints.md](docs/device-constraints.md) | the device's hard limits (no overlayfs, enforced dm-verity, system-as-root), why in-place deployment is impossible, and why root needs `LEGACYSAR` |
| [root-cause.md](docs/root-cause.md)                 | why the library is empty offline: runtime evidence, the data path, and the cursor contract the patch has to satisfy                                |
| [architecture.md](docs/architecture.md)             | reverse-engineering notes: the login wall, package map, VrHome/Hermes internals, and mapped leads for future UI work                               |

```
scripts/   reproducible steps: deploy, extract, per-app patches, image build, flash
patch/     original patch sources: Java for OCMS, the hosts file, and system/ —
           the boot service + setup script that get baked into the image
docs/      the documents above
tools/     gitignored: smali/baksmali, downloaded by fetch_tools.sh
work/      gitignored: extracted binaries and all generated artifacts
downloads/ gitignored: unlock ZIP, Magisk apk, patched boot images
```

## Legal & disclaimer

**Trademarks & affiliation.** *OpenPacific* is an independent, unofficial open-source
project. It is **not** affiliated with, endorsed by, sponsored by, or connected to Meta
Platforms, Inc. or any of its subsidiaries. "Oculus", "Oculus Go", "Meta", "Quest",
"Horizon", and related names and logos are trademarks of their respective owners and
are used here **only nominatively** — to describe the hardware this project is
compatible with. The project name *OpenPacific* / `open-pacific` refers to the device's
generic internal codename (`pacific`) and claims no trademark.

**Copyright / redistribution.** This repo contains **only original work**: scripts,
documentation, and patch definitions (Java/smali fragments authored here, expressed
against disassembly). That original work is released under the **MIT License** (see
`LICENSE`). It contains **no** Meta/Oculus binary — no APKs, no firmware images, no
`reactnative.bcbundle`. Those are Meta's copyrighted property; every user extracts them
from **their own** unlocked device (or Meta's official unlock package) via `scripts/`,
and `.gitignore` keeps `work/` out of the repo.

**Third-party tools.** None are redistributed either: `scripts/fetch_tools.sh`
downloads smali/baksmali (BSD 3-Clause) from its official releases, and `.gitignore`
keeps `tools/` out of the repo. See [docs/tools.md](docs/tools.md).

**Scope.** This is an independent open-source project for a discontinued device you own
and have officially unlocked. It circumvents no DRM for piracy (there is nothing left
to buy) and touches no other user's data or account.

**Security posture.** These patches deliberately neutralise signature and trust checks
so a re-signed system shell can run at all (see [Scope](#scope)). The result is a device
that no longer enforces signature-level separation between packages. That is the
intended trade for an offline-capable headset you own and have unlocked — but it is a
real trade, and it is yours to make knowingly.

**No warranty.** Provided "as is", without warranty of any kind. Flashing system
partitions and modifying firmware carries inherent risk; you do so **at your own
risk**. The authors are not liable for any damage, data loss, or bricked hardware.
