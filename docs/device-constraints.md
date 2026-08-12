# Device constraints and measurements

Why OpenPacific deploys the way it does, and what was measured on the device to get
there. Everything in the first three sections is **current**; the last section is the
historical record of the in-place-deployment attempts that were ruled out.

## Hard constraints of this device

| Constraint | Evidence | Consequence |
|---|---|---|
| **No overlayfs** in the 3.18 kernel | `grep overlay /proc/filesystems` → empty | Magisk's module engine cannot mount over `/system`; `system.prop` silently does nothing |
| **Magisk scripts run in an isolated mount namespace** | a bind from `post-fs-data.d` never reaches `system_server`; a fresh `su` cannot `umount` another `su`'s bind; `nsenter`/`unshare` absent | no boot script can mount into PID 1's namespace. Measured before the `LEGACYSAR` fix below, i.e. without a working `magiskinit`; it was never re-tested afterwards, because the missing overlayfs rules out in-place swaps regardless |
| **dm-verity is enforced** | `ro.boot.veritymode=enforcing`, and `fstab.pacific` mounts `/system` at `/` with the `verify` flag | any modified `/system` fails its hash check and boot-loops — unless the boot image is patched with `KEEPVERITY=false`, which strips the flag. This is what `patch_boot_magisk.sh` does |
| **`/` *is* `/system`** (system-as-root) | same fstab line; there is no `/vendor` entry either; the bootloader adds `skip_initramfs` | the boot image's ramdisk is ignored unless the kernel is patched for it — which is what decides whether root works (below) |
| **A/B bootloader falls back** | after repeated failed boots of `_b` the bootloader activates `_a` on its own (observed) | keeping `_a` stock is a real safety net, not a formality |
| **Re-signing changes the recorded cert** | `signatures=…[1476a1b0]` is Meta's original | PMS would reject the re-signed system apps — the framework `compareSignatures` patch neutralises that, so no wipe is needed. It does **not** cover app-level checks: MiniHome shares `com.oculus.uid` with Horizon and had to be re-signed as well, or `IDeviceAuthService` throws `inconsistent signatures across packages` |

Net: there is **no in-place way to swap a system app** on this device. The only route is
to assemble the image on the host and reflash it — which is what `deploy.sh` does.

## Magisk / root

Magisk root **works** on this device, but only with `LEGACYSAR=true` — and finding that
took a while, so the reasoning is worth keeping.

### Why it looked impossible

The bootloader appends `skip_initramfs` to the kernel command line (visible in
`/proc/cmdline`), which makes the kernel ignore the boot image's ramdisk and mount
`/system` as root directly. `magiskinit` lives in exactly that ramdisk, so it never ran:
no Magisk environment, no `su`. The daemon that did start came up without its
environment and aborted:

```
lsetxattr '/sbin/adbd' 'u:object_r:system_file:s0': Read-only file system
* Magisk environment incomplete, abort
```

That read like a hard device limit — `/sbin` sits on the read-only system partition, so
Magisk cannot set itself up there. It is not: Magisk has a dedicated path for this exact
device class.

### The fix

`boot_patch.sh` hexpatches the kernel's `skip_initramfs` string to `want_initramfs`, so
the bootloader's flag no longer matches and the ramdisk is used after all. It does that
only when `LEGACYSAR=true`, which Magisk normally derives in `util_functions.sh`
(`mount_partitions`) from a real block device as rootfs. We invoke `boot_patch.sh`
headlessly and therefore skipped that detection, leaving the default `false` — so the
kernel came out **byte-identical to stock** and the ramdisk stayed unused.
`patch_boot_magisk.sh` now runs Magisk's own check and passes the flag.

Verified on device afterwards: `/sbin` is Magisk's tmpfs (`magisk`, `magiskinit`,
`resetprop`, `su`, `supolicy`), the daemon reports `30.7:MAGISK:R`, and

```
$ adb shell su -c id
uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0
```

`deploy.sh` pre-authorises the adb shell in Magisk's policy db, because granting `su`
otherwise needs a confirmation prompt from the manager app that a headset booting
straight into the VR shell never shows. This survives reboots and a factory reset — the
policy lives in `/data`, so a wipe clears it and the next `deploy.sh` writes it back.

**A flash-only install leaves Magisk half-done — `deploy.sh` finishes it.** Nothing
populates `/data/adb/magisk` when Magisk is installed by flashing a patched boot instead
of through its manager app, and `magisk_env()` aborts on the missing `busybox` with
`Magisk environment incomplete`: no `post-fs-data.d`, no `service.d`, no module scripts,
and `/sbin` never gets `magiskpolicy` (its `supolicy` symlink dangles). The boot-time setup
extracts the binaries from the Magisk apk into `/data/adb/magisk` and reboots once so
`magiskinit` picks them up. The log then reads:

```
* Initializing Magisk environment
* Running post-fs-data.d scripts
** late_start service mode running
* Running service.d scripts
```

Five `lsetxattr '/sbin/<stock binary>': Read-only file system` lines remain at error
level. They are inherent: `magiskinit` bind-mounts the stock `/sbin` binaries from the
read-only system partition into its tmpfs and then tries to relabel them. The
environment initialises regardless.

The boot-time setup also does everything the manager app would normally do for itself,
because none of it happens on a flash-only install:

* installs the apk as a **user** app — never into `/system`, where Magisk refuses to run
  ("Running this app as a system app isn't supported") and Android keeps flagging it as a
  system app even after an update,
* installs the **full** manager apk — and verifies that it really is the full one.
  Whenever no manager is installed at all, the daemon puts its own built-in stub there
  instead: 70013 bytes, activities `x.COMPONENT_PLACEHOLDER_*`, the generic system icon
  rather than Magisk's, and a prompt to "connect to the internet" to fetch the real app,
  which never succeeds offline. Worse, while only that stub is present Magisk discards the
  `requester` row, so the app also demands "additional setup". Checking that *something*
  named `com.topjohnwu.magisk` exists is therefore not enough — `deploy.sh` looks for the
  real entry point (`ui.MainActivity`) and installs over the stub when it is missing.
  Measured: once the full 11.6 MB app is in place it survives reboots untouched,
* copies Magisk's **shell scripts** next to the binaries, not just the binaries. This is
  what the app actually checks: on every start it runs `env_check <ver> <code>` from its
  own `app_functions.sh` and shows "Requires additional setup" whenever that exits
  non-zero. The function requires `busybox`, `magiskboot`, `magiskinit`, `magiskpolicy`,
  `util_functions.sh` and `boot_patch.sh` in `/data/adb/magisk`, and additionally greps
  `util_functions.sh` for `MAGISK_VER` / `MAGISK_VER_CODE` — so the scripts must come from
  the same apk as the binaries. Copying only the `lib*.so` files left the two scripts
  missing, the check failed with 127 (`env_check: not found` — the function itself lives
  in them), and the dialog came back after every restart no matter how often it was
  dismissed. `deploy.sh` now ships that exact set and tests for it, rather than probing
  for busybox alone. `stub.apk` is copied as well (the app logs an `ENOENT` without it)
  but is *not* part of env_check,
* grants the storage permissions — there is no permission dialog in VR, and without them
  the app crashes on first launch,
* allows `su` for the **app's own uid**, not just the adb shell: without it the daemon
  answers `su: request rejected` and the app shows Magisk as `N/A` with Superuser and
  Modules greyed out,
* copies the **32-bit** `magisk` as `magisk32` alongside the 64-bit one. `boot_patch.sh`
  embeds exactly one magisk binary in the ramdisk — the 64-bit one on this device — so the
  daemon loads `magisk32` from `/data/adb/magisk` at runtime to inject the 32-bit zygote.
  This headset runs both (`zygote64` and `zygote`), and without that file Zygisk comes up
  in the 64-bit one only. Measured: 3 mapped `zygisk` regions in `zygote64` but 0 in
  `zygote`, and the app reporting Zygisk as not installed; with it, 3 in both,
* records the manager package and switches Zygisk on.

None of that is a one-off step, because Magisk undoes it by itself in two ways:

* the daemon runs in `post-fs-data`, before the PackageManager exists, so it cannot verify
  the manager package and **drops that row on every boot** — the app then asks for
  "additional setup" after each restart,
* Magisk's own "additional setup" **reinstalls the app under a new uid**, which silently
  invalidates the su policy written for the old one. The app can then no longer query the
  daemon and reports Magisk as `N/A` and Zygisk as not installed, even while both work.

So the state is re-asserted on every boot instead of being set once.
The setup shipped in the image handles this: it runs in
`late_start` — where `pm` and `dumpsys` work — and writes back the manager row, `zygisk=1`
and the su policies, reading the app uid back each time so a reinstall cannot break it.
`deploy.sh` then simply runs that same script rather than duplicating its logic.

One ordering detail matters: the daemon decides whether to load Zygisk when it starts, in
`post-fs-data`. A `zygisk=1` written afterwards therefore only takes effect on the **next**
boot — which is exactly what the boot script guarantees.

Verified on device: `su` returns uid 0, the daemon reports `30.7:MAGISK:R`, the boot script
restores all rows after a deliberately emptied database, and Zygisk is genuinely injected —
`zygisk` is mapped into both the 64-bit and the 32-bit zygote.

### What still does not work

* **Magisk modules that overlay `/system`** — the 3.18 kernel has no overlayfs (first
  table above), so the module engine has nothing to mount with. The module *scripts* do
  run now, and `/data/adb/modules` is live; only the file-overlay part is impossible.

### Version measurements

Same base image each time:

| Magisk | Result |
|---|---|
| **`30.7`** | with `LEGACYSAR=true`: working `su` as described above. Without it: `magiskinit` never runs at all — no `/sbin` tmpfs, no `su` |
| `26.4` | patched slot boots, but no Magisk at all — no daemon, no log |
| `23.0` | patched slot does **not** boot; the bootloader falls back to stock `_a`. Its `boot_patch.sh` also picks the recovery path on this combined boot+recovery image (display shows `No command`), which is why `RECOVERYMODE=false` is now passed explicitly |

Note that the offline library — the point of this project — does not depend on any of
this: every patch is baked into the system image, and `adb root` works regardless.

### Setting Magisk up without a host

The pieces above all live in `/data`, so a factory reset removes them and the headset
would need another `deploy.sh` run just to get root back. Since that contradicts "wipe and
go", the setup ships **inside the system image** and runs itself:

* `/system/etc/init/openpacific.rc` — an init service, started on `sys.boot_completed`.
  `seclabel u:r:magisk:s0` puts it in Magisk's own domain; SELinux is enforcing here and a
  default init domain may not reach the daemon or run `pm`.
* `/system/etc/openpacific/magisk-setup.sh` — installs the app, fills `/data/adb/magisk`,
  grants `su`, enables Zygisk. Runs on **every** boot, because the manager row, the su
  policy and the app uid are all unstable (see above).
* `/system/etc/openpacific/magisk/` — the Magisk files, already unpacked and named. The
  device has no `unzip`, and Magisk's own busybox is exactly what may be missing after a
  wipe, so extracting on-device would be a chicken-and-egg problem. The apk is shipped
  *as well*, because `pm install` needs it — the unpacked copies cannot substitute for it.

That costs about **15 MB** of the system partition, which has roughly 170 MB free on this
build (measured: `df /system` reports 91% used with the patched image). Comfortable, but
worth knowing before adding anything else to the image: `build_system_image.sh` grows the
file in place, and `debugfs` would fail on a full filesystem — which the error guard turns
into an aborted build rather than a broken image.

Two details were only found by measuring:

* **`pm path` is the only reliable installed-check.** `pm dump` and `dumpsys package` also
  print usage statistics, which keep naming `ui.MainActivity` long after a package is gone
  — measured: 10 matches for an uninstalled app. The size of the apk `pm path` reports
  then separates the full app from Magisk's ~70 KB stub.
* **The first boot after a wipe reboots once.** The daemon decides whether to load Zygisk
  in `post-fs-data`, before this script can run, so on a fresh `/data` Zygisk would be
  enabled but not loaded. The script reboots once (guarded by a persist property) and the
  headset comes up complete.

Verified on device: app uninstalled and `/data/adb/magisk` deleted, then a reboot — the
service reinstalled the full 11.6 MB app, repopulated the environment, restored both su
policies, and after its own reboot Zygisk was injected into **both** zygotes.

## The first-run gate after a factory reset

After `fastboot -w` the shell used to block with *"We are preparing your headset. Please
take off your headset and follow the steps in the Oculus app on your phone."* and never
reach Home — a dead end offline, because that flow needs Meta's phone app and live
servers. `patch_companionserver.sh` removes it at the source. The hunt is documented
here because almost every obvious fix is wrong.

What it is, from the shell's own log:

```
NuxOtaStateMachine: Entering NEW_DEVICE state.
NuxOta: High priority apps download skipped.
OtaSettings: Changing NUX OTA State: NEW_DEVICE --> HIGH_PRI_APPS_DOWNLOAD_COMPLETE
FirstTimeNUXGo: Configuring OTA Blocking Dialog
DialogController: Launching pending dialog: systemux://dialog/ota-blocking
```

VrShell's native `FirstTimeNUXGo` reads the **system** setting
`first_time_nux_pre_ota_complete`. It is `0` on a fresh device, and the only code that
ever sets it is CompanionServer's `NuxOtaStateMachine` — on the path where it reboots
into a real OTA. Offline the machine parks in `HIGH_PRI_APPS_DOWNLOAD_COMPLETE` and the
flag stays `0` forever.

**The fix:** `initializeNuxOtaStateMachine()` runs on every start of that machine and
already holds the constant `1` in `v3`, so a single added call
`FirstTimeNuxManager.setFirstTimeNuxPreOtaComplete(true)` clears the gate. CompanionServer
is odexed, so the patch goes through the same deodex → patch → on-device `dex2oat` route
as the panel host.

### Dead ends, measured — do not repeat them

| Attempt | Result |
|---|---|
| Set the five `first_time_nux_*` keys in `user0.db` (`user_settings`) to `1` | no effect — **wrong database**; the gate reads `system.db` (`system_settings`) |
| Add `first_time_nux_ota_state`/`pre_ota_complete` to `user0.db` | no effect, same reason |
| Write the correct keys straight into `system.db` | no effect at boot: the native shell reads a **cached** copy of the settings (`"Setting %s is not a registered, cached property"`, `SystemSettings.cpp`). The value has to go through `SettingsManager`, which is why the patch calls `FirstTimeNuxManager` instead of touching the file |
| Rewrite the `systemux://dialog/ota-blocking*` URIs in `libovrapp.so` to `systemux://dialog/none` | **worse**: the dialog disappears but state 31 remains, so the shell hangs with nothing displayed. Reverted |
| `am broadcast -a set_first_time_nux_complete` (what `patch_systemutilities.sh` opens up) | no effect — it only writes `first_time_nux_complete` in `user_settings`, not the OTA flag |

Also cleared, and a genuinely separate flow: SystemUX's AnytimeUI v2 dialog sequence,
which likewise ran on every fresh `/data` (`patch_systemux.sh`).

## Alternatives considered, not pursued

* **Zygisk hook** of the OCMS process to swap `queryAllApps` at runtime — no file or
  signature change, but it needs a C++ Zygisk module written against this API-25 runtime.
  Zygisk itself is no longer the blocker: it is enabled and genuinely injected into both
  zygotes (measured, see the Magisk section above). The reflash route was already working
  when this was considered, and it has the decisive advantage of surviving a factory reset
  — a Zygisk module lives in `/data` and would not.
* **Kernel with overlayfs** so Magisk modules work in place — a full kernel rebuild.

## Historical record: the in-place attempts

Kept because it documents *why* the reflash route was chosen, and because the OCMS
proof-of-concept below is what showed the whole approach was viable.

The first patched artifact was `OCMS_signed.apk` with three smali/dex changes:
`queryAllApps()` returning a `MatrixCursor` of installed apps in the exact **52-column**
contract the library UI parses (valid enum names for the strict `valueOf` columns),
`onCheck[ReadOnly]Permissions()` → `true`, and the `LibraryCacheRefresher` logged-out
branch returning empty success. Toolchain: `apktool` decode → smali edit → `apktool`
build → `d8` merge → `zipalign` → `apksigner` (v1+v2).

Two things were confirmed on device at that point:

* **The home UI really calls the provider at runtime** —
  `LibraryProvider: running queryAllApps() for com.oculus.uid:10046` appears in logcat
  while the home is open. That was the key proof that feeding this cursor would reach
  the library view.
* **A bind-mount swaps the apk by hand** (`mount -o bind`, verified by the size change)
  — but never in a way `system_server` could see, per the namespace constraint above.

**Result after switching to the reflash route:** PMS accepted the re-signed system app
**without a wipe** (the recorded cert simply changed to ours), and the provider returned
installed apps offline — verified with `content query`: 24 rows at that point, sideloaded
apps as well as system ones, all columns and enum values valid. The remaining shell-level
login/setup gates were then solved by the Horizon patch set; see
[reproduce.md](reproduce.md).
