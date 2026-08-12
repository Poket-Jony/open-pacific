---
name: Bug report
about: Something does not work on your headset
labels: bug
---

**Please check [docs/troubleshooting.md](https://github.com/Poket-Jony/open-pacific/blob/main/docs/troubleshooting.md) first** — it
covers boot loops, `No command`, empty library, 0-byte odex and `su: not found`.

## What happens

<!-- Symptom, and at which step: extract / build / flash / boot / in VR -->

## Environment

```
Host OS + version:
Firmware build on the headset:   adb shell getprop ro.build.version.incremental
Unlock ZIP build:                grep -a -m1 -o 'ro.build.version.incremental=[0-9]*' work/firmware/system.img
Active slot:                     adb shell getprop ro.boot.slot_suffix
smali/baksmali version:          ls tools/
Magisk version:                  ls downloads/Magisk-*.apk
Root (if that is the problem):   adb shell su -c id ; adb shell ls /sbin
```

## Slot state (if it does not boot)

```
fastboot getvar all 2>&1 | grep -E "current-slot|slot-(success|unbootable|retry)"
```

## Output

<!-- The failing script's output. For a boot problem also:
     adb logcat -d | grep -iE "dex2oat|ocms|vrshell|AndroidRuntime" | tail -50 -->

```
```
