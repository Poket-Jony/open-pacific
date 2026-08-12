# Architecture and reverse-engineering notes

Device: Oculus Go (`pacific`, MSM8996 / Adreno 530), Android 7.1.1 (API 25), A/B
slots, officially unlockable.

**`NGI77B` is not one build.** It is the Android build ID of the final firmware, but
several deliveries carry it with different `ro.build.version.incremental` — a headset
may run `20008400174500000` while Meta's unlock package is `20480400000200000`. The APKs
are byte-identical between them; what differs are `build.prop` and the **pre-compiled
ART files** (`boot.art`, `boot-*.oat`, `services.odex`), which are generated per build.
That distinction matters: an odex is only valid against the boot image it was compiled
against (see the README's *Two things that make it boot at all*).

## The login wall (why the library hangs)

Opening the library shows an infinite spinner. Logcat, offline:

```
PlatformPluginManager: User not logged in, aborting init
OVRService.getAppScopedAccessToken(OVRService.java:287)
OCPlatformModule: access token fetch returned error: 'user not logged in'
LibraryCacheRefresher: Unable to refresh library due to being logged out
```

The gate is a chain, and only the first link is client-side:

1. `PlatformPluginManager` (in `com.oculus.horizon`) aborts init when logged out.
2. `getAppScopedAccessToken` performs an **HTTP request to Meta's servers**,
   which return `user not logged in`. Server-side, not patchable on-device.
3. `library_database` (in `com.oculus.ocms`) has **0 rows** — it is a cache of
   *purchased* server entitlements, not a list of installed apps.

Confirmed empirically: flipping `maybe_access_token_valid` in
`com.oculus.horizon`'s `fbconnect_shared_preferences.xml` moved the failure exactly one
step forward — from "aborting init" to the `getAppScopedAccessToken` server call
failing. Faking the login state locally therefore only shifts the wall; it does not
remove it.

Conclusion: unlocking the **Meta store** is impossible (dead servers, no login). The
tractable goal is different — make Home's library render **locally installed apps** and
stop waiting on the login. The UI can already do it: the library's "Unknown Sources"
section lists sideloaded apps without an account, so the missing piece is a data source,
not a renderer.

## Package map

| Package | APK | Role |
|---|---|---|
| `com.oculus.vrshell` | `/system/priv-app/VrShell/VrShell.apk` (52 MB) | shell / compositor, home activity |
| `com.oculus.vrshell.home` | `/system/app/VrHome/VrHome.apk` (64 MB) | **the library/store/home UI** |
| `com.oculus.horizon` | `/system/app/Horizon/Horizon.apk` (77 MB) | platform/login (`PlatformPluginManager`, `OVRService`) |
| `com.oculus.ocms` | `/system/priv-app/OCMS/OCMS.apk` (6 MB) | `LibraryProvider`, `library_database` |
| `com.oculus.systemux` | `/system/priv-app/SystemUX/SystemUX.apk` (23 MB) | system panels (settings, taskbar) |

They run under distinct UIDs (`vrshell` 10030, `vrshell.home` 10053,
`horizon` 10046, `ocms` 10020, `systemux` 10026) — but `horizon` and MiniHome
(`com.oculus.home`) DO share the `com.oculus.uid` shared user, which is why
re-signing Horizon touches a UID cluster after all. The framework
`compareSignatures` patch is what makes that cluster tolerate mixed signatures
(see [reproduce.md](reproduce.md)); MiniHome can therefore stay Meta-signed.

## VrHome internals

Not Unity, not IL2CPP, not Java-logic-in-dex. It is a **React Native** app:

- Native runtime in `lib/armeabi-v7a/libhome.so` (5.9 MB, stripped ARM32). Only
  26 exported symbols, all JNI bridges (`ShellIPC`, `JSBundleModuleImpl`,
  `LocalMediaManager`, …). No internal logic symbols.
- The 32-bit ABI (`armeabi-v7a`) is what the process runs.

The UI logic lives in the JS bundle: `assets/reactnative.bcbundle`, 7.0 MB,
**Hermes bytecode**.

- Magic `c6 1f bc 03 c1 03 19 1f`, version byte `0x4a` = **HBC v74**.
- Source hash `4144648c3e6c8c9992523663411ae2b4260ee653`.
- String table is plaintext (readable via `strings`); logic is compiled bytecode.
- Disassembles to **27,289 functions** / ~1.6 M lines of `.hasm`.

## Bundle override mechanism

`VrHome`'s dex exposes a bundle-override path (strings in `classes.dex`):
`fetchAndApplyBundleOverride`, `getOverrideBundle` / `getDebugOverrideBundle` /
`nativeGetOverrideBundle`, `SHARED_PREFERENCES_OVERRIDE_BUNDLE_KEY`,
`checkAssetBundleSignature` / `assetBundleTrustSpec`, plus the log strings
"JS bundle override checksum was invalid" and "Applying manual override bundle".

So a modified bundle could in principle be injected **without repacking the APK**, but
it is signature/checksum checked. See *Leads for future UI work* below — the route was
mapped and never needed.

## Toolchain viability (proven)

Hermes v74 round-trips byte-exact through `hbctool`:

```
disasm reactnative.bcbundle -> hbc_out/   (27,289 functions)
asm    hbc_out/ -> roundtrip.bcbundle
md5(original) == md5(roundtrip) == d05fcdcc0fce2785eeb800b414209ccd
```

A `.hasm` edit therefore produces a valid bundle differing only by the change.
This removes the usual reassembly-corruption risk.

## Deployment: what shipped, and why

Any modified system app must survive Android 7.1's APK signature check at scan time,
which is why the framework's `compareSignatures` is patched. That covers *PackageManager*
only — apps that check signatures themselves are patched individually, and every member of
the `com.oculus.uid` shared user has to carry the same key (hence MiniHome is re-signed
although its code is untouched). The delivery mechanism is
a **reflash of the assembled `system_b` image**, not a Magisk module: this kernel has
no overlayfs, so Magisk's module engine cannot mount over `/system`
([device-constraints.md](device-constraints.md)). Recovery is the stock A/B slot
([recovery.md](recovery.md)).

No bundle was modified in the end — the library renders from the patched OCMS data
layer with the **stock** Hermes bundle (see the project README).

## Leads for future UI work (unused)

None of this is needed for what ships; it is the reconnaissance that was done before
the OCMS data layer turned out to be sufficient. Kept because it is the only mapped
path to changing the library *UI* itself.

**Injecting a bundle without repacking the APK.** `libhome.so` reads a manual override
from `/data/data/com.oculus.vrshell.home/files/js_bundles/reactnative.*` via
`getDebugOverrideBundle`, driven by the SharedPreference `JSBundleManualOverride`; the
default bundle otherwise comes from `apk:///assets/reactnative.bcbundle`. That path
skips the checksum verification the server path performs — but it is gated by a
MobileConfig gatekeeper, native string `_oc_gk:oculus_mobile_home_js_bundle` at file
offset `0x4e5955` in `.rodata`. Editing horizon's `gatekeeper_preferences.xml` has no
effect (the value comes from the native FBMobileConfig store). The gatekeeper is not
referenced by a direct literal-pool pointer, so locating the branch means mapping the
generated registry or the `js_bundles_enabled` consumer in `.text` (Thumb-2 MOVW/MOVT
address builds). This was never completed.

**Where the library UI lives.** The library is React Native + Undux. Installed apps
appear in the `UNKNOWN_SOURCES` (`THIRD_PARTY`) and `INSTALLED` sections, fed by a
native module at `/library/installed` that is independent of the login. Located in
`instruction.hasm`: section nav in `Function 22207` (`_getUnknownSourcesEnabled`, nav id
`library-disco:nav:unknown-sources`), section render in `Function 21943/22002`, and the
login state via `isLoggedIn` (string id 23347) / `setIsLoggedIn` (23369) /
`SET_IS_LOGGED_IN` (22513).

## The rendering constraint (why we patch Home, not ship a launcher)

2D Android apps on the Go render only inside a `vrshell` **panel**; they cannot
be the standalone home. A native VR app can be the home, but only a plain one.
Patching the **stock** Home keeps the native VR rendering and the system
integration while changing only what the library lists — the one path that
avoids both limitations.
