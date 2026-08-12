# Recovery

No backup routine is needed: `deploy.sh` puts the **stock, unlocked** firmware on slot
`_a` and OpenPacific on `_b`, so the fallback is a known, untouched stock image rather
than "whatever was there before".

## Why factory reset is not enough

`fastboot -w` wipes `userdata` only. A broken `/system` or `services.jar`
survives it. Recovering a system-level mistake means booting the untouched slot
or re-flashing the system partition from the official OTA — not a userdata wipe.

## The bootloader is the safety net

Patching `/system`, framework, or boot does **not** touch the bootloader
(`aboot`). Fastboot stays reachable no matter how badly the OS boots, as long as
`aboot`/`persist`/`modem` are left alone (this project never touches them). So a
hard brick is not reachable by the changes here.

## Recovery points (in order of preference)

### 1. The stock A/B slot (instant, free)

Slot `_a` holds the stock unlocked firmware (`deploy.sh` puts it there; `flash.sh`
writes only `_b` and never touches `_a`). If a flash misboots, switch back to it —
this is also what the A/B bootloader does on its own after repeated failed boots of
`_b`, as observed on device:

```sh
adb reboot bootloader      # or force it from the bootloader if the OS won't boot
fastboot set_active a      # boot the untouched stock slot
fastboot reboot
```

Then re-flash `_b` once the image is fixed (`deploy.sh` or
`flash.sh work/ocms/system_final.img`). Keep `_a` stock — never flash patches to both
slots at once, or you lose this fallback.

### 2. Official Meta unlock OTA (complete, authoritative)

`unlocked_build.zip` from Meta's [Oculus Go SW Unlock](https://developers.meta.com/horizon/downloads/package/oculus-go-sw-unlock/)
package is a full signed A/B OTA. Its `payload.bin` carries 13 partitions — `system`,
`boot`, `modem` and the whole bootloader chain (`aboot`, `xbl`, `rpm`, `hyp`, `ovrtz`,
`pmic`, `devcfg`, `keymaster`, `cmnlib`, `cmnlib64`) — so it restores far more than the
two partitions this project writes. There is no `vendor` partition on this device
(`/vendor` lives inside `/system`). Because the device is **already unlocked**, re-applying it restores
everything **without** a factory reset (the wipe only happens on the initial
`fastboot oem unlock`):

```sh
adb reboot sideload
adb sideload unlocked_build.zip
```

It is the same ZIP the build reads, so you already have it. Afterwards, re-install
OpenPacific with `deploy.sh` (or `flash.sh` if the artifacts are still in `work/`).

## What a factory reset costs

Measured after `fastboot -w` with **no** reflash:

| | Survives? | Why |
|---|---|---|
| Offline library (22 apps) | **yes** | every patch lives in the system image |
| First-run gates (OTA dialog, NUX flow) | **yes** | same — `patch_companionserver.sh` and `patch_systemux.sh` are baked in, so the headset boots straight to Home |
| `su` / Magisk environment | **no** | Magisk stores its binaries and its su policy under `/data/adb`, which the wipe clears |

So a wipe alone leaves a fully working offline headset; only root needs one more
`scripts/deploy.sh` run, which rebuilds nothing and finishes in about a minute.

## Regenerating the boot image

`patch_boot_magisk.sh` re-creates the patched boot
(`downloads/magisk<ver>_patched_boot_<slot>.img`) headlessly, so it never has to be kept
as a precious backup. The stock boot it patches comes from the base image extracted from
the ZIP, or — only if that is unavailable — is dumped from the device.

## Slot awareness

OpenPacific runs from slot **`_b`**; `_a` stays stock. The active slot can change
without you asking: after repeated failed boots of `_b` this bootloader activates `_a`
on its own (observed on device). So if the headset suddenly behaves like stock again,
check the slot before assuming a patch was lost:

```sh
adb shell getprop ro.boot.slot_suffix   # or, from the bootloader:
fastboot getvar current-slot
fastboot set_active b
```
