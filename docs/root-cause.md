# Root cause: why the library is empty offline

The analysis behind `patch_ocms.sh`, backed by on-device runtime evidence. It explains
why the stock library shows nothing without a Meta account, and what a replacement data
source has to provide.

> **This analysis held up and shipped.** It also turned out to be *sufficient*: the
> library grid gates on the in-memory entitlement cache (`LibraryStorage.loadAll` →
> `mData`), not on a Hermes flag, so repointing that cursor at the OCMS provider makes
> the grid render — **no bundle edit was needed**. Two further conditions had to hold:
> every `AppConverter.isValid` field non-empty, and an app-scoped user id from Horizon's
> `ProfileContentProvider`. See [reproduce.md](reproduce.md).

## Runtime evidence (logcat, home running offline)

```
LibraryProvider: running queryApp(com.oculus.vrshell) for com.oculus.uid:10046
LibraryProvider: Cannot find entitlement for com.oculus.vrshell
OVRLibrary:      null cursor received for query content://com.oculus.ocms.library/apps/com.oculus.vrshell
LibraryCacheRefresher: Unable to refresh library due to being logged out
```

Direct provider probe confirms the store is empty:

```
$ adb shell content query --uri content://com.oculus.ocms.library/apps
SecurityException: Component access not allowed.   # FB secure caller check (shell is not a trusted caller)
# rows visible to a trusted caller: 0
```

## The data path

The VrHome library UI is a *view* over a ContentProvider. It holds no app data
itself; it queries `content://com.oculus.ocms.library/apps`.

```
VrHome (Hermes UI)
  └─ OVRLibrary  ── content://com.oculus.ocms.library/apps ──▶  OCMS
                                                                 └─ LibraryProvider.queryAllApps()
                                                                      └─ LibraryStorage.getAll()   (SQLite)
```

- `LibraryProvider.queryAllApps()` returns `SharedAppsHelper.filterSharedApps(LibraryStorage.getAll())`.
- `LibraryStorage` is a local SQLite cache.
- The cache is populated **only** by `LibraryCacheRefresher.refreshCache()`,
  which starts with `if (mCredentialsManager.getCredentials() == null) →
  "Unable to refresh library due to being logged out"` and aborts.
- Refresh otherwise does `fetchEntitlements()` → `fetchUpdates()` →
  `fetchAssets()` against Meta servers (dead).

So with no login and dead servers the cache is **permanently empty**. The UI
receives an empty/`null` cursor and shows an infinite spinner, or dereferences
`null` and crashes ("Oculus Home has stopped"). The Hermes bundle is a
**symptom surface**, not the cause: `Function 22024/22026` render an `OCGrid`
*with* a `ListEmptyComponent`, i.e. they render gracefully-empty when given
data — patching the UI alone yields an empty library, not installed apps.

Sideloaded apps do not self-register: `ThirdPartyPackageStartedReceiver` only
*reads* `LibraryStorage.get(pkg)` on launch; `EntitlementsInstallerEventListener`
updates entries via `App.Editor` but early-returns when `getApp(pkg) == null`,
i.e. it never creates rows for packages that aren't already entitlements.

## The store

Same mechanism, worse: store browse/landing require login + live catalog
servers. No local patch resurrects a dead backend. A "Store click → Library"
redirect is only a Hermes route change and, given the empty cache above, would
land on an empty Library. No benefit without solving the data source first.

## The three candidate patch layers

| Layer | Target | Verdict |
|---|---|---|
| Hermes bundle (`VrHome`) | render/route gate | **Symptom only.** UI renders empty-graceful from data; no offline data source to render. Route/render edits don't create apps. |
| Native `libhome.so` GK | force override GK | **Dead end.** Stripped Thumb-2, GK via hashed MobileConfig registry, no literal-pool xref to patch. |
| **OCMS (`LibraryProvider`)** | make `queryAllApps()` return installed apps | **The real gate. Tractable Java, but non-trivial.** |

## What the payload has to satisfy

The provider side is the easy part: it is `android:exported="true"` with no manifest
permission, its runtime caller trust is `FbPermissionsContentProvider.onCheckReadOnlyPermissions()`
(the source of "Component access not allowed") which the patch overrides to `true`, and
its privileged permissions (`INSTALL_PACKAGES` etc.) are privapp-whitelisted by package
name on API 25 rather than by signature — so they survive re-signing.

The hard part is the *cursor contract*, and it is why
`patch/java/.../InstalledApps.java` looks the way it does. `AppsCursor.fill()`
dereferences, per app:

* `app.images.get(SOURCE_SQUARE / SOURCE_MAIN / SOURCE_TINY / LANDSCAPE_SMALL / HERO).uri`
  — all five image entries,
* `.name()` on seven non-null enums (`comfortRating`, `microphoneUsage`, `platform`,
  `category`, `headTracking`, `grantReason`, plus `status`),
* `AppConverter.convert*` on the device / media / permission lists.

A null in any of those consumed fields crashes the provider, so every installed package
is synthesised with a full images map, a safe value for each enum, and empty lists for
input devices, media capabilities, play modes and permissions — 52 columns in total.
(Columns nothing reads may stay null: `is_demo_of` does, deliberately.) `AppConverter.isValid`
additionally rejects any row with an empty field, which is what makes seemingly cosmetic
columns load-bearing (see [reproduce.md](reproduce.md) for the one that was found last).

## Bottom line

There is **no offline data source** for the stock Home library; creating one at
the OCMS layer is the only route that reaches "installed apps in stock Home
offline". The store stays dead regardless. That route is the one this project
took, and it works — see [reproduce.md](reproduce.md).
