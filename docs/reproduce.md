# Reproduce the patched system image

End-to-end recipe to rebuild the patched Oculus Go `system_b` image from the stock
APKs. Every transformation is scripted, so the result is reproducible.

*"NUX" below is Oculus' own term for the first-time setup flow, kept because it is what
the code calls it.*

## Prerequisites

Stock inputs come from one of two sources; you never pull them by hand:

* **From the unlock ZIP (recommended, device-free):**
  `scripts/extract_firmware.sh path/to/unlocked_build.zip` — either the archive Meta
  hands you (which holds the instructions PDF plus the OTA) or the `unlocked_build.zip`
  inside it; the outer one is detected and unpacked. It dumps the `system`
  partition out of Meta's [Oculus Go SW Unlock](https://developers.meta.com/horizon/downloads/package/oculus-go-sw-unlock/)
  A/B OTA (`payload.bin` → `system.img`) and reads every stock APK, the framework and
  the stock boot out of it with `debugfs`. The dumped `system.img` is also the clean
  base the image build swaps into.
* **From a connected device:** `scripts/extract_apks.sh` pulls the APKs. This yields
  **no clean base image**, so either run `extract_firmware.sh` as well or pass your own
  with `SRC=path/to/system.img`. It also reads whatever that headset runs — against an
  active OpenPacific slot it would hand the patch scripts their own output, so use a
  stock slot. `deploy.sh` therefore always takes the ZIP route.

Everything lands under `work/`. Host tools and env overrides are listed in the
[README](../README.md#requirements); the framework deodex needs smali/baksmali `3.x`,
which `scripts/fetch_tools.sh` downloads (older 2.2.x builds produce a boot-looping
image — see [tools.md](tools.md)). One project key is reused for every patched APK
(`work/ocms/patch.jks`, auto-created by `patch_ocms.sh`).

## Build

One command does everything — extract, build, and flash both slots (stock on `_a`,
OpenPacific on `_b`). Each slot is only written if it does not already hold that
image, and the run ends with a check that the offline library actually serves apps:

```sh
scripts/deploy.sh path/to/unlocked_build.zip
```

Verified end to end on device: `_a` recognised as up to date and left alone, `_b`
flashed, `22 installed apps` reported by the patched provider afterwards.

A re-run reuses the artifacts already in `work/` and then writes nothing at all once
both slots match. Reuse is not just a shortcut: assembling the image is **not**
byte-reproducible (`apktool`, `apksigner` and `debugfs` each stamp the current time),
so a rebuild would differ from the identical image already on the device and rewrite
~2 GB every run. After changing a patch script, force a fresh build with `REBUILD=1`.

Or just the build. It runs in two phases, so the headset is needed as late as possible:
everything that patches an apk is host work, and only the three odex steps have to
compile on the target (`dex2oat` runs nowhere else; the headset's own firmware build does
not have to match the base image). Without an argument it does both and waits for the
device in between:

```sh
scripts/build_all.sh            # host phase, then wait for the headset, then device phase
scripts/build_all.sh host       # stop after the host phase — nothing needs to be connected
scripts/build_all.sh device     # the three dex2oat steps + the image assembly
```

Or run the individual patches:

```sh
scripts/patch_ocms.sh   work/ocms/OCMS.apk         # library shows installed apps offline
scripts/patch_horizon.sh                           # offline empty-account login + platform
scripts/patch_systemutilities.sh                   # NUX-complete setter opened
scripts/patch_trust.sh  work/apks/VrShell.apk  work/trust/VrShell_signed.apk   # panel trust mesh
scripts/patch_systemux.sh                          # SystemUX: trust flip + NUX dialogs removed
scripts/patch_trust.sh  work/apks/VrHome.apk   work/trust/VrHome_signed.apk
scripts/patch_trust_odex.sh work/trust/VrDesktopPanelApp.odex   # 2D-panel host: trust-flip the odex (needs device for dex2oat)
scripts/patch_companionserver.sh                   # clears the first-run OTA gate (needs device for dex2oat)
scripts/patch_userserver.sh                        # userserver api caller check -> no-op
scripts/patch_framework.sh                         # services.jar compareSignatures -> MATCH
scripts/patch_boot_magisk.sh                       # patched boot: dm-verity off + LEGACYSAR (needs adb root)
scripts/build_system_image.sh                      # assemble work/ocms/system_final.img
```

Two helpers are not part of the chain: `scripts/fetch_tools.sh` downloads
smali/baksmali (the patch scripts call it on demand, see [tools.md](tools.md)), and
`scripts/resign_apk.sh IN.apk OUT.apk` re-signs an apk with the project key **without**
touching its code — useful when an app has to join the project key but its `classes.dex`,
and therefore its pre-compiled odex, must stay valid.

## Flash

```sh
scripts/flash.sh work/ocms/system_final.img
```

`flash.sh` reboots to the bootloader and flashes **two** partitions on slot `_b`:
`system_b` (the patched image) and `boot_b` (the patched boot, generated by
`patch_boot_magisk.sh` on demand if absent). **Both are required** — the boot image is
what strips the dm-verity flag, without which the modified system cannot pass its hash
check. It then sets `_b` active and boots; this bootloader falls back to `_a` after
failed boots, so the script re-forces `_b`. Slot `_a` stays stock as the fallback.

The manual chain stops here. A flash alone leaves **root half-installed**:
`/data/adb/magisk` stays empty (normally the manager app fills it), so the daemon aborts
its environment setup, and nothing has granted `su` or registered the manager app. That
part is not an image patch and therefore not a script of its own — it lives in
the image itself: `build_system_image.sh` adds `/system/etc/init/openpacific.rc` plus
`/system/etc/openpacific/`, and that init service installs the manager app, populates
`/data/adb/magisk`, grants `su` and enables Zygisk on **every** boot. So a manual flash
gets root on its next boot without any further step — and so does a factory reset.

**No factory wipe is needed.** `com.oculus.horizon` + `com.oculus.home` share the
`com.oculus.uid` shared user, and re-signing changes their on-disk signature vs.
the one persisted in `/data/system/packages.xml`. Normally that mismatch makes
PackageManager drop the package (shell crash-loop, needing a wipe to regenerate
`packages.xml`). The framework `compareSignatures` → MATCH patch makes that check
pass regardless, so the re-signed suite installs over the existing `/data` with no
wipe. Note that this makes *PackageManager* tolerate mixed signatures inside the shared
user — individual apps may still refuse them, which is why MiniHome is re-signed too.
Iterating on one app is fastest with
`adb install -r <app_signed.apk>`.

**Nothing is written to `/data` after flashing** — every patch lives in the image, and
that includes the first-run gates. A factory reset is therefore survivable: the Horizon
patches clear the account/profile NUX, `patch_systemux.sh` the AnytimeUI dialog flow, and
`patch_companionserver.sh` the OTA gate that otherwise blocks the shell with "follow the
steps in the Oculus app on your phone". Verified after `fastboot -w`: the headset boots
straight to Home. The reasoning, and the four wrong turns it took to get there, are in
[device-constraints.md](device-constraints.md#the-first-run-gate-after-a-factory-reset).

## What each patch does

| App (script) | Change | Effect |
|---|---|---|
| **OCMS** `LibraryProvider.queryAllApps()` (`patch_ocms.sh`) | return a `MatrixCursor` of installed launchable/VR apps from `PackageManager` (`patch/java/.../InstalledApps.java`, merged via `d8`) | stock library lists installed apps **offline**. Icons are rendered to bounded PNGs and inlined as `data:` URIs, because the Home's image loader is Oculus' own RCTVR/OVR pipeline rather than Android's `ContentResolver`: it treats `content://` and cross-package `android.resource://` as asset paths inside its own APK, so both fail |
| OCMS `LibraryProvider.queryApp(pkg)` | route single-package lookups through `InstalledApps.one(ctx,pkg)` | per-app library lookups resolve offline (no `null cursor`); `entitlement_hash` is non-empty so `App()` doesn't reject rows |
| OCMS `onCheck[ReadOnly]Permissions()` | `return true` | resigned provider still serves callers |
| OCMS `LibraryCacheRefresher.refreshCache()` | logged-out branch returns success/empty, and the credentials null-check is forced onto it | no error on refresh offline; the offline credential from the Horizon patch must not send it down the (dead) server-fetch path |
| OCMS `LibraryStorage.loadAll()` | read the cursor from the OCMS provider instead of the server-synced SQLite `library` table | fills the in-memory entitlement cache (`mData`) the **library grid** gates on ("cache missed" → spinner) — this is what makes the grid render instead of showing "Loading Library". Rows only survive if **every** `AppConverter.isValid` field is non-empty; the last one found was `systemUiAsOverlayMode`, which otherwise fails with "Found invalid app while trying to save" |
| **Horizon** `HorizonAuthDatastore.getCredentials()` (`patch_horizon.sh`) | return `Credentials("1","offline-local-session")` | platform reports **logged in** offline; `uid=1` (non-`0`, avoids the online-resolve sentinel) |
| Horizon `clearCredentials()` | no-op | offline session never wiped |
| Horizon `OVR.assertIsInitialized()` | no-op | no `"Nobody is logged in!"` crash when the profile is null offline |
| Horizon `OVRServiceSynchronous.getServiceAvailability()` | return `SIGNATURE_VERIFIED` | panel connects to the re-signed platform service (kills the code-4 "incompatible version" spinner) |
| Horizon `ExternalPlatformNetwork.getAppScopedAccessToken()` | return a local dummy token | platform inits offline (no `graph.oculus.com` token spin) |
| Horizon `UserProfileHelper.getHasFinished/SeenNux*()` (5 getters) | `return true` | **removes the First-Time-NUX at the root**: the shell reads NUX-completion from the user profile (`ProfileContentProvider` → `UserProfileHelper`), which is empty offline → shell launches the VR NUX (`vrshell.home:vrnux`) that spins forever with no content. Forcing the profile to report the NUX done routes straight to Home |
| Horizon `ProfileContentProvider.doQuery()` | force the first-party branch (`callingAppHasSystemPlatformSDKPermission` → true) | the caller gets `Credentials.getUserId()` instead of `getAppScopedUserID()` throwing `PackageNotInLibraryException` offline — without it the library never receives a scoped user id and spins |
| Horizon `DeviceAuthTokenStore$1.onServiceConnected()` | no-op | `com.oculus.deviceauthserver` verifies callers against Meta's certs, so the re-signed Horizon is rejected and the `SecurityException` escapes the callback → `FATAL EXCEPTION: com.oculus.horizon`. The existing try/catch there only covers `RemoteException`. Patched on the **client** side because `DeviceAuthServer.apk` is platform-signed and carries no odex — re-signing it would drop `seinfo=platform`. The token is a server credential and useless offline |
| Horizon `VrCastServiceConnection.unbindService()` | no-op | no NPE after VrCastService removal |
| Horizon FB-secure `TrustedCallerInfo`/`isAppIdentityTrusted`/`enforceTrustedCaller` | force trusted / never throw | resigned app passes its own trust checks |
| **SystemUtilities** NUX receiver (`patch_systemutilities.sh`) | `throwIfNotAllowed()` → no-op | the NUX-complete setter broadcasts are accepted from any caller (`am broadcast -a set_first_time_nux_complete -p com.oculus.systemutilities`) |
| SystemUtilities `SigCertVerifier$SigCertInfo.createUntrusted()` | same `isTrusted=true` flip as `patch_trust.sh` | it is also a panel host: `PanelService.verifyVrShellUID` otherwise rejects the re-signed shell and drops `MSG_CREATE_PANEL_APP` |
| **VrShell / VrHome** `SigCertVerifier$SigCertInfo.createUntrusted()` (`patch_trust.sh`) | construct with `isTrusted=true` | panel trust mesh accepts the re-signed apps (no panel disconnect / dropped `MSG_CREATE_PANEL_APP`) |
| **SystemUX** (`patch_systemux.sh`) | the same trust flip, plus `NuxDialogs.showNuxDialogFlow()` → `endDialogNux()` | removes the AnytimeUI v2 first-time dialog flow **at the source**. It is gated by the server-side `oculus_mobile_auiv2_bypass_nux_dialogs` gatekeeper, which offline always resolves to false, so the flow ran on every fresh `/data` — i.e. after every factory reset. Jumping to the flow's own completion path also queues `auiV2MarkDialogNuxSeen`, so the state is recorded exactly as if it had been clicked through. Neither the Horizon profile NUX patches nor the `first_time_nux_*` settings cover this — verified on device with all five of those set |
| **VrDesktopPanelApp** `SigCertVerifier$SigCertInfo.createUntrusted()` (`patch_trust_odex.sh`) | same `isTrusted=true` flip, but on the **odex** (deodex → patch → on-device `dex2oat`); the platform-signed stub apk is left untouched | the 2D-app panel host (`android.uid.system`) authenticates the re-signed shell → 2D apps (Settings, etc.) launch. Patching the odex, not the apk, keeps `seinfo=platform` so SELinux still has a `seapp_context` at `uid=system` (re-signing → `seinfo=default` → zygote `setcontext` SIGABRT) |
| **CompanionServer** `NuxOtaStateMachine.initializeNuxOtaStateMachine()` (`patch_companionserver.sh`) | add `FirstTimeNuxManager.setFirstTimeNuxPreOtaComplete(true)` | clears the **first-run OTA gate**. VrShell's native `FirstTimeNUXGo` reads the system setting `first_time_nux_pre_ota_complete`; it is `0` on a fresh `/data` and only this state machine ever sets it — on the path where it reboots into a real OTA, which never happens offline. The shell therefore blocked with `systemux://dialog/ota-blocking` after every factory reset. Odex-only patch, so the stock apk is untouched. Writing the setting into `/data/oculus/settings/system.db` instead does **not** work: the native shell reads a cached copy, so it has to go through `SettingsManager` |
| **UserServer2** `SignatureVerifier.ensureAllowedFor()` (`patch_userserver.sh`) | no-op | app-level "Cannot access userserver api" gate opened for the re-signed caller |
| **framework** `PackageManagerService.compareSignatures()` (`patch_framework.sh`) | return `SIGNATURE_MATCH` (0) | root fix for the whole PM-signature layer: signature-level permissions + shared-UID signature checks all pass for the re-signed mesh; delivered as a dex-less stub jar + recompiled odex |
| **boot image** (`patch_boot_magisk.sh`) | headless Magisk patch of the stock boot via the apk's own `boot_patch.sh` + `magiskboot`, with `KEEPVERITY=false RECOVERYMODE=false` | **`KEEPVERITY=false` is what makes the patched system boot at all**: `fstab.pacific` mounts `/system` at `/` with the `verify` flag, so keeping dm-verity fails the hash check on every boot (boot loop). `RECOVERYMODE=false` because this boot image also carries the recovery — otherwise older Magisk builds patch it as a recovery and the device lands in "No command". `LEGACYSAR=true` is what makes Magisk work at all here: it hexpatches the kernel's `skip_initramfs` to `want_initramfs`, so the ramdisk holding `magiskinit` is actually used (see [device-constraints.md](device-constraints.md)) |
| **MiniHome** (`resign_apk.sh`) | re-signed with the project key, **no code change** | it shares `com.oculus.uid` with Horizon. The framework `compareSignatures` patch makes *PackageManager* accept the mixed signatures, but app-level checks do not: Horizon crashed with `SecurityException: Uid [com.oculus.horizon, com.oculus.home] has inconsistent signatures across packages` on an `IDeviceAuthService` call. Re-signing makes the shared UID consistent. Because `classes.dex` is byte-identical, the stock odex stays valid and its `oat/` is deliberately **not** removed |
| **VrCastService** | removed from image | offline-useless casting service that rejected the resigned caller |

Every trust/platform patch above is load-bearing — each one covers a distinct direct
certificate check, verified by removing them individually. The one exception is
MiniHome, which needs no re-sign because the framework patch lets a shared user hold
mixed signatures.

Why it is deployed as a reflash rather than in place, why dm-verity forces the boot
patch, and what was measured for Magisk: [device-constraints.md](device-constraints.md).
