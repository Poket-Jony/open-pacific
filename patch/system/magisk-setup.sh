#!/system/bin/sh
# OpenPacific: set Magisk up on the device itself, on every boot.
#
# WHY THIS LIVES IN THE IMAGE. A factory reset clears /data, and with it everything
# Magisk keeps there: its binaries in /data/adb/magisk, the su policy database, and any
# service.d script. The boot image still brings up the daemon, so `su` works over adb —
# but the manager app is gone and the environment is empty, and the user would have to
# run deploy.sh again. Shipping this script inside the system image instead means the
# first boot after a wipe repairs everything unattended.
#
# WHY IT RUNS EVERY BOOT, NOT ONCE. Three pieces of state are not stable on their own:
#   * the daemon starts in post-fs-data, before the PackageManager exists, so it cannot
#     verify the manager package,
#   * a reinstall of the app gives it a NEW uid, silently invalidating the su policy
#     written for the old one,
#   * Magisk's own "additional setup" reinstalls the app and does exactly that.
# Re-asserting them costs milliseconds and removes a whole class of failure.
#
# WHAT IT DELIBERATELY DOES NOT DO. It never writes a "requester" row. That string marks
# a *repackaged* manager; setting it for the stock package makes the daemon search for a
# "dyn APK" that does not exist, so get_manager() returns NotInstalled, Zygisk never sets
# ZYGISK_ENABLED for the app, and the app then reports Zygisk as disabled — while the
# daemon logs "pkg: no dyn APK, ignore" forever.
MAGISKBIN=/data/adb/magisk
APK=${APK:-/system/etc/openpacific/magisk.apk}      # overridable for testing
SRCDIR=${SRCDIR:-/system/etc/openpacific/magisk}   # ready-to-copy Magisk files
LOG=/data/adb/openpacific-setup.log

# One line per boot, so the file would grow forever otherwise. Keep the last 50.
log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 50 ]; then
    tail -50 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
  fi
}

# Magisk must be up; without it there is nothing to set up.
[ -x /sbin/magisk ] || exit 0

# Wait for the PackageManager. `pm` is what installs the app and what tells us its uid,
# and this script is started at boot-completed, where it can still be a moment away.
i=0
while [ $i -lt 60 ]; do
  pm path android >/dev/null 2>&1 && break
  sleep 2
  i=$((i + 1))
done

# 1) The manager app. Testing that *something* named com.topjohnwu.magisk is installed is
#    not enough: when no manager is present the daemon installs its own ~70 KB stub, which
#    shows the generic icon and asks to "connect to the internet" for the real app. Look
#    for the real entry point instead.
# Whether the FULL manager app is installed. `pm path` is the only reliable probe here:
# pm dump / dumpsys package also print the usage statistics, which keep naming old
# activities like ui.MainActivity long after the package is gone (measured: 10 matches
# for an uninstalled app). Size tells the full app from Magisk's own ~70 KB stub, which
# it installs whenever no manager is present.
magisk_apk_path=$(pm path com.topjohnwu.magisk 2>/dev/null | head -1 | sed 's/^package://')
magisk_apk_size=0
# shellcheck disable=SC2012  # pm path yields a plain path; ls is fine and always present
[ -n "$magisk_apk_path" ] && magisk_apk_size=$(ls -l "$magisk_apk_path" 2>/dev/null | tr -s ' ' | cut -d' ' -f5)
case "$magisk_apk_size" in ''|*[!0-9]*) magisk_apk_size=0 ;; esac
if [ "$magisk_apk_size" -lt 1000000 ]; then
  if [ -f "$APK" ]; then
    log "installing the full Magisk app (was: ${magisk_apk_size} bytes)"
    pm install -r "$APK" >/dev/null 2>&1 || log "pm install failed"
  else
    log "no apk at $APK — cannot install the manager"
  fi
fi

# 2) The environment in /data/adb/magisk. Magisk's own env_check (app_functions.sh)
#    requires exactly this set, and the app shows "Requires additional setup" on every
#    start while anything is missing. util_functions.sh and boot_patch.sh are not
#    optional — env_check greps the former for MAGISK_VER/MAGISK_VER_CODE.
need_env=0
for f in busybox magiskboot magiskinit magiskpolicy util_functions.sh boot_patch.sh magisk32; do
  [ -f "$MAGISKBIN/$f" ] || need_env=1
done
if [ "$need_env" = 1 ] && [ ! -d "$SRCDIR" ]; then
  # Nothing to copy from: an older image without /system/etc/openpacific, or a partial
  # flash. Say so instead of finishing "successfully" with an incomplete environment.
  log "environment incomplete but $SRCDIR is missing — reflash to get it"
fi
if [ "$need_env" = 1 ] && [ -d "$SRCDIR" ]; then
  # Straight copy — no unzip. This build of Android ships no unzip binary, and Magisk's
  # own busybox is exactly what may be missing here, so extracting from the apk on the
  # device would be a chicken-and-egg problem. build_system_image.sh therefore unpacks
  # the apk on the host and ships the files ready to use.
  log "populating $MAGISKBIN from $SRCDIR"
  mkdir -p "$MAGISKBIN" 2>/dev/null
  for f in "$SRCDIR"/*; do
    [ -f "$f" ] || continue
    cp -f "$f" "$MAGISKBIN/$(basename "$f")" && chmod 755 "$MAGISKBIN/$(basename "$f")"
  done
  chown -R 0:0 "$MAGISKBIN" 2>/dev/null
fi

# 3) su for the adb shell (uid 2000) and for the app itself. Without the latter the app
#    cannot query the daemon at all and shows Magisk as "N/A" with the tabs greyed out.
#    policy=2 means allow. The app uid is read back every time because a reinstall
#    changes it.
/sbin/magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,1,1)" >/dev/null 2>&1
# The data dir is owned by the app, so its owner IS the uid — and unlike `dumpsys |
# grep -m1`, this cannot lose to a SIGPIPE race that truncates the dump.
uid=$(stat -c %u /data/data/com.topjohnwu.magisk 2>/dev/null)
case "$uid" in
  ''|*[!0-9]*) log "could not determine the app uid" ;;
  *) /sbin/magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES($uid,2,0,1,1)" >/dev/null 2>&1 ;;
esac

# 4) Zygisk. The daemon decides whether to load it when it starts, in post-fs-data, so a
#    value written here takes effect on the NEXT boot — which is why this runs every time
#    rather than once.
/sbin/magisk --sqlite "REPLACE INTO settings (key,value) VALUES(\"zygisk\",1)" >/dev/null 2>&1

# On the very first boot after a wipe the environment was empty, which means the daemon
# came up before Zygisk was switched on and did not load it. One reboot fixes that, and
# doing it here is what makes the headset usable without anyone running anything. Only
# on that first run — a normal boot never reaches this.
if [ "$need_env" = 1 ] && [ -z "$(getprop persist.openpacific.setup_done)" ]; then
  setprop persist.openpacific.setup_done 1
  log "first setup complete — rebooting once so Zygisk loads"
  sleep 5
  /system/bin/reboot
fi

log "setup done (app uid ${uid:-unknown})"
exit 0
