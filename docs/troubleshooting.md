# Troubleshooting

Every symptom below was actually hit and diagnosed on device. Start with the symptom,
not with the guess.

## The headset boot-loops after flashing

The A/B bootloader retries slot `_b` a few times and then falls back to stock `_a` on
its own, so the device is not lost. Get a shell first:

```sh
adb devices                 # if it answers, you are on the stock slot _a
adb reboot bootloader       # or force the bootloader with the hardware keys
fastboot getvar all 2>&1 | grep -E "current-slot|slot-(success|unbootable|retry)"
```

If the bootloader has not marked the slot unbootable (`slot-unbootable:_b:No`), it
kept handing control to the kernel, which *suggests* the failure is in userspace
rather than in the boot chain. Treat it as a hint, not proof — the reliable signal is
bisecting the image (below).

There will be **no logs in `/data`** for an early failure, because logging is not up
yet. Do not go looking for them; bisect the image instead (see below).

### Known causes, in the order they were found

| Cause | How it looks | Fix |
|---|---|---|
| **dm-verity still enabled** | boots straight into a loop with a modified `/system` | the patched boot must be built with `KEEPVERITY=false` — `fstab.pacific` mounts `/system` at `/` with the `verify` flag. `patch_boot_magisk.sh` does this |
| **odex compiled against the wrong boot image** | loop, nothing in `/data`, `system_server` never starts | an odex embeds its boot image checksum. Build against the base image, not the running system — `device_boot_image()` + `-Xnorelocate` handle it. Never mix a `services.odex` from one build with a `boot.oat` from another |
| **baksmali too old** | loop, `deodex` printed `AnalysisException` lines | use smali/baksmali `3.0.9`+ (`scripts/fetch_tools.sh`). 2.2.x drops quickened field accesses it cannot resolve and yields an invalid dex — see [tools.md](tools.md) |
| **stale odex left in the image** | patches appear to have no effect | every code-patched app must lose its whole `oat/` tree; the layout differs per app (Horizon has `arm` *and* `arm64`, SystemUtilities only `arm`). `build_system_image.sh` enumerates it |

### Bisecting an image

Build a variant with only part of the changes and flash **only** `system_b` (~65 s).
The most informative split is "stock plus the framework patch alone", because the
framework is the only piece that can stop `system_server` — that is how the boot loop
documented above was pinned down:

```sh
# lib.sh exports $DBG (debugfs), which on macOS is not in PATH.
source scripts/lib.sh
cp work/firmware/system.img work/test.img
CTX=$(mktemp); printf 'u:object_r:system_file:s0\000' > "$CTX"
"$DBG" -w work/test.img <<EOF
rm /system/framework/services.jar
write $PWD/work/fw/deodex/services_stub.jar /system/framework/services.jar
ea_set -f $CTX /system/framework/services.jar security.selinux
sif /system/framework/services.jar mode 0100644
rm /system/framework/oat/arm64/services.odex
write $PWD/work/fw/deodex/services_patched.odex /system/framework/oat/arm64/services.odex
ea_set -f $CTX /system/framework/oat/arm64/services.odex security.selinux
sif /system/framework/oat/arm64/services.odex mode 0100644
EOF
fastboot flash system_b work/test.img && fastboot set_active b && fastboot reboot
```

Boots → the framework patch is fine, look at the APKs. Loops → the framework patch is
the culprit; check the `deodex` output for `AnalysisException` first.

## `No command` on the display

That is the **stock Android recovery**, not a brick. It happens when the boot image is
patched as a recovery — this device's boot image also carries the recovery
(`sbin/recovery` is in its ramdisk). `patch_boot_magisk.sh` passes
`RECOVERYMODE=false` to prevent it. Hold the hardware keys to reach the bootloader, or
`fastboot set_active a`.

## `dex2oat` leaves a 0-byte odex

ART could not start its runtime. Check the real error:

```sh
adb logcat -d | grep -i dex2oat
```

* `Only the zygote can create the global boot image` → the boot image needs relocating;
  pass `--runtime-arg -Xnorelocate` (the scripts do).
* `Could not create image space ... /data/local/tmp/...` → ART resolves an image
  *location*: `--boot-image=<dir>/boot.art` opens `<dir>/<isa>/boot.art`, so the
  classpath must sit in an `arm64/` subdirectory.

The scripts fail loudly on this now (`dex2oat produced an EMPTY odex`); older versions
silently shipped the empty file.

## `su: not found` / `Permission denied` from su

Root works on this device, so this means one of the two prerequisites is missing.
Tell them apart by what `su` says:

* **`su: not found`** → `/sbin` is not Magisk's tmpfs, i.e. `magiskinit` never ran. The
  boot image was patched without `LEGACYSAR=true`, so the kernel still honours the
  bootloader's `skip_initramfs` and skips the ramdisk. Check the boot image you flashed:

  ```sh
  adb shell ls /sbin        # expect magisk, magiskinit, su, resetprop, supolicy …
  ```

  Rebuild it with `REBUILD=1 scripts/deploy.sh …`; `patch_boot_magisk.sh` prints
  `legacy system-as-root: true` when it applies the kernel patch.

* **`Permission denied`** → Magisk is up but has not granted the shell. It normally asks
  via its manager app, which never appears on a headset that boots into the VR shell.
  `deploy.sh` pre-authorises it; to do it by hand:

  ```sh
  adb root
  adb shell '/sbin/magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,1,1)"'
  adb unroot
  ```

`adb root` works regardless, and nothing in OpenPacific depends on Magisk — all patches
live in the system image. If the log says `Magisk environment incomplete`,
`/data/adb/magisk` is empty — a reboot repairs it, because the setup shipped in the image
refills it from `/system/etc/openpacific/magisk` on every boot. Only `/system`-overlaying modules stay impossible (no overlayfs); see
[device-constraints.md](device-constraints.md).

## The Magisk app keeps asking for "additional setup"

Do not guess — the app tells you exactly why. On every start it runs
`env_check <version> <versionCode>` (from its own `app_functions.sh`) and shows the
dialog whenever that exits non-zero. Reproduce it by hand:

```sh
adb shell 'su -c "MAGISKBIN=/data/adb/magisk MAGISKTMP=/sbin; env_check 30.7 30700; echo $?"'
```

The function requires **all** of these in `/data/adb/magisk` — binaries *and* scripts:

```
busybox  magiskboot  magiskinit  magiskpolicy  util_functions.sh  boot_patch.sh
```

and greps `util_functions.sh` for `MAGISK_VER` / `MAGISK_VER_CODE`, so every file has to
come from the same Magisk apk. Exit 127 (`env_check: not found`) means
`util_functions.sh` itself is missing; exit 1 means one of the files is; exit 3 means a
version mismatch. `deploy.sh` installs the whole set — re-run it, then reboot.

## The Magisk app shows "N/A", or Zygisk as not installed

Usually root is fine and only the app cannot see it. It reaches the daemon through `su`
like any other app, so it needs a policy for **its own** uid — and Magisk's "additional
setup" reinstalls the app, which gives it a **new** uid and silently invalidates the
policy written for the old one. The daemon separately drops the manager row on every
boot, because it starts in `post-fs-data`, before the PackageManager exists.

The setup shipped in the image handles exactly this, so the fix is a reboot — the init
service re-asserts everything after boot-completed. To check what it restored:

```sh
adb root
adb shell '/sbin/magisk --sqlite "SELECT * FROM policies"'   # uid 2000 + the app uid
adb shell '/sbin/magisk --sqlite "SELECT * FROM settings"'   # zygisk|1
adb shell 'dumpsys package com.topjohnwu.magisk | grep -m1 userId='
```

Verify Zygisk by what it actually does rather than by what the app claims. This device
runs **two** zygotes and both must be injected:

```sh
adb shell 'grep -c zygisk /proc/$(pidof zygote64)/maps'   # 64-bit
adb shell 'grep -c zygisk /proc/$(pidof zygote)/maps'     # 32-bit
```

If the 64-bit one is injected and the 32-bit one is not, `magisk32` is missing from
`/data/adb/magisk`: the ramdisk carries only the 64-bit binary, and the daemon loads the
32-bit one from there at runtime. `deploy.sh` installs it; re-run it and reboot.

One ordering detail: the daemon decides whether to load Zygisk when it starts, in
`post-fs-data`. Enabling it later therefore only takes effect on the **next** boot.
If the app was open across a reboot, close it (`adb shell am force-stop
com.topjohnwu.magisk`) so it re-reads the status.

## After a factory reset it asks me to "follow the steps in the Oculus app"

That is the shell's first-run OTA gate (`systemux://dialog/ota-blocking`) and it is a
dead end offline — the flow needs Meta's phone app and live servers. It should be gone:
`patch_companionserver.sh` clears it. If you still see it, the patch is missing from the
image. Check:

```sh
adb shell 'logcat -d | grep -E "FirstTimeNUXGo|NuxOtaStateMachine"'
# bad:  FirstTimeNUXGo: Configuring OTA Blocking Dialog
# good: only the NuxOtaStateMachine lines, no "Configuring OTA Blocking Dialog"
```

Rebuild with `REBUILD=1 scripts/deploy.sh …`. Do **not** try to fix it by writing
`first_time_nux_pre_ota_complete` into `/data/oculus/settings/system.db`: the native
shell reads a cached copy of the settings, so the value has to go through
`SettingsManager` — which is exactly what the patch does. See
[device-constraints.md](device-constraints.md#the-first-run-gate-after-a-factory-reset)
for the four approaches that do *not* work.

To make the shell render without wearing the headset while debugging, you can pin the
proximity sensor closed — but **always undo it**, or the headset stops reacting to being
put on and taken off:

```sh
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close        # pretend: worn
adb shell am broadcast -a com.oculus.vrpowermanager.automation_disable

# undo, both of them:
adb shell am broadcast -a com.oculus.vrpowermanager.prox_open
adb shell am broadcast -a com.oculus.vrpowermanager.automation_enable
```

**Reboot afterwards.** Measured twice: the two undo broadcasts alone did *not* reliably
restore the sensor — the headset kept ignoring being put on and taken off until it was
restarted. Nothing is persisted to `/data`, so a reboot always clears the override. If
you only need the shell to come up for a log, prefer rebooting over this trick.

## The library is empty / spins

```sh
adb shell 'content query --uri content://com.oculus.ocms.library/apps --projection package_name' | grep -c '^Row:'
```

* **0 rows** → the OCMS patch did not land. Check that `/system/priv-app/OCMS/oat` is
  gone from the image and that `InstalledApps` made it into `classes.dex`.
* **rows, but the grid still spins** → the grid gates on the in-memory entitlement
  cache; `LibraryStorage.loadAll` must be repointed at the provider, and Horizon's
  `ProfileContentProvider` must hand out an app-scoped user id.
* **tiles render as a black box with a play button** → the image columns are being
  read as video; icons must be inlined as `data:` PNGs (the Home's loader resolves
  neither `content://` nor cross-package `android.resource://`).

## `extract_firmware.sh` says the ZIP has no payload.bin

Meta's download is an **outer** archive: it contains the instructions PDF and the actual
OTA (`unlocked_build.zip`). The script accepts both and unpacks the outer one itself, so
this message means the file is neither — check that the download completed and that you
picked the Oculus Go SW Unlock package, not another firmware.

## `zip error: Nothing to do!` from `patch_framework.sh`

The stock `services.jar` on this build is already dex-less, so there is no
`classes.dex` to strip. Handled — the script only strips when the entry exists.

## `deploy.sh` says "already built" and ignores my change

By design: a re-run reuses the artifacts in `work/` rather than rebuilding, because the
image assembly is not byte-reproducible and a fresh build would look different from the
identical image already on the device — every run would then rewrite ~2 GB. After
editing a patch script, force a build:

```sh
REBUILD=1 scripts/deploy.sh path/to/unlocked_build.zip
```

## Builds fail with a firmware mismatch

The odex must be built against the boot classpath of the image being assembled. If
`work/fw/` was populated from a device running a different build than `SRC`, delete it
and let the scripts re-extract from the base image:

```sh
rm -rf work/fw
SRC=work/firmware/system.img scripts/build_all.sh
```

## Getting back to stock entirely

```sh
fastboot set_active a && fastboot reboot     # instant: stock slot
adb reboot sideload && adb sideload unlocked_build.zip   # full official image
```

See [recovery.md](recovery.md).
