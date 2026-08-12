#!/usr/bin/env bash
# Reproduce the OCMS (com.oculus.ocms) patch from a stock OCMS.apk.
# Result: LibraryProvider.queryAllApps() serves installed apps from
# PackageManager offline; provider caller check opened; refresh no longer errors
# when logged out. Adds InstalledApps helper (compiled from patch/java) via d8.

# Usage: patch_ocms.sh [in.apk] [out.apk]    (defaults under work/ocms/)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need apktool python3 keytool javac javap zip unzip
IN="${1:-$ROOT/work/ocms/OCMS.apk}"
OUT="${2:-$ROOT/work/ocms/OCMS_signed.apk}"
WORK="$ROOT/work/ocms/smali"
[ -f "$IN" ] || die "stock OCMS.apk not found: $IN (run extract_firmware.sh or extract_apks.sh first)"

[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
  -alias patch -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=OpenPacific"

echo "[*] decompile $IN"
# -r: smali-only patch, so keep resources.arsc raw (no aapt re-encode on build).
apktool d -r -f -o "$WORK" "$IN" >/dev/null

echo "[*] patch LibraryProvider.smali"
python3 - "$WORK/smali/com/oculus/ocms/library/provider/LibraryProvider.smali" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
# queryAllApps(): return InstalledApps.all(getContext()); also add caller-check overrides
new='''.method private queryAllApps()Landroid/database/Cursor;
    .locals 1

    invoke-virtual {p0}, Lcom/oculus/ocms/library/provider/LibraryProvider;->getContext()Landroid/content/Context;

    move-result-object v0

    invoke-static {v0}, Lcom/oculus/ocms/library/provider/InstalledApps;->all(Landroid/content/Context;)Landroid/database/Cursor;

    move-result-object v0

    return-object v0
.end method

.method protected onCheckPermissions()Z
    .locals 1

    const/4 v0, 0x1

    return v0
.end method

.method protected onCheckReadOnlyPermissions()Z
    .locals 1

    const/4 v0, 0x1

    return v0
.end method'''
s2=re.sub(r'\.method private queryAllApps\(\)Landroid/database/Cursor;.*?\.end method', new, s, count=1, flags=re.S)
assert s2 != s, "queryAllApps not patched"; s = s2
# queryApp(pkg): the single-app path reads LibraryStorage (empty entitlement DB)
# and returns null for every package. Route it through InstalledApps.one(ctx,pkg)
# so per-package library lookups resolve from PackageManager offline too.
newone='''.method private queryApp(Ljava/lang/String;)Landroid/database/Cursor;
    .locals 1

    invoke-virtual {p0}, Lcom/oculus/ocms/library/provider/LibraryProvider;->getContext()Landroid/content/Context;

    move-result-object v0

    invoke-static {v0, p1}, Lcom/oculus/ocms/library/provider/InstalledApps;->one(Landroid/content/Context;Ljava/lang/String;)Landroid/database/Cursor;

    move-result-object p1

    return-object p1
.end method'''
s2=re.sub(r'\.method private queryApp\(Ljava/lang/String;\)Landroid/database/Cursor;.*?\.end method', newone, s, count=1, flags=re.S)
assert s2 != s, "queryApp not patched"; s = s2
open(p,'w').write(s); print("  patched queryAllApps + queryApp + onCheck*")
PY

echo "[*] patch LibraryCacheRefresher.smali (logged-out branch -> success/empty list)"
python3 - "$WORK/smali/com/oculus/library/refresher/LibraryCacheRefresher.smali" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=s.replace(
'''    .line 91
    new-instance v1, Ljava/lang/IllegalStateException;

    const-string v2, "Not logged in"

    invoke-direct {v1, v2}, Ljava/lang/IllegalStateException;-><init>(Ljava/lang/String;)V

    invoke-virtual {v0, v1}, Lbolts/TaskCompletionSource;->setError(Ljava/lang/Exception;)V''',
'''    .line 91
    invoke-static {}, Lcom/google/common/collect/ImmutableList;->of()Lcom/google/common/collect/ImmutableList;

    move-result-object v1

    invoke-virtual {v0, v1}, Lbolts/TaskCompletionSource;->setResult(Ljava/lang/Object;)V''',1)
assert s2 != s, "refreshCache logged-out branch not patched"; s = s2
# The Horizon getCredentials patch returns a non-null offline credential, so
# refreshCache() otherwise skips the logged-out empty-success path above and takes
# the logged-in server fetch (getActiveEntitlements -> graph.oculus.com), which
# fails offline and leaves the library UI spinning. Force the credentials
# null-check to fall through to the empty-success path (installed apps still come
# from getAllApps/OCMS, which ignores this server cache).
s2=s.replace(
'''    invoke-interface {v0}, Lcom/oculus/auth/credentials/CredentialsManager;->getCredentials()Lcom/oculus/auth/credentials/Credentials;

    move-result-object v0

    if-nez v0, :cond_1''',
'''    invoke-interface {v0}, Lcom/oculus/auth/credentials/CredentialsManager;->getCredentials()Lcom/oculus/auth/credentials/Credentials;

    move-result-object v0

    const/4 v0, 0x0

    if-nez v0, :cond_1''',1)
assert s2 != s, "refreshCache credentials null-check not patched"; s = s2
open(p,'w').write(s); print("  patched refreshCache logged-out branch + forced offline empty-success")
PY

echo "[*] patch LibraryStorage.smali (loadAll: fill mData from the OCMS provider, not the empty server-synced SQLite)"
python3 - "$WORK/smali/com/oculus/library/database/LibraryStorage.smali" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
# loadAll() populates the in-memory entitlements cache (mData) that the library UI
# gates on ("cache missed" -> spinner). Stock reads a local SQLite "library" table
# that is only ever filled by the (dead) server sync, so offline mData stays empty.
# Swap just the cursor SOURCE to the OCMS provider (uriForAllPackages -> our
# InstalledApps), reusing the existing extractNextAppFromCursor->mData.put loop.
# Same columns, so the loop is unchanged; v5 (projection) and v1 (result cursor)
# are preserved. Context/resolver acquired via the same injection notify() uses.
old='''    const/4 v0, 0x0

    :try_start_1
    const-string v4, "library"

    const/4 v6, 0x0

    const/4 v7, 0x0

    const/4 v8, 0x0

    const/4 v9, 0x0

    const/4 v10, 0x0

    .line 214
    invoke-virtual/range {v3 .. v10}, Landroid/database/sqlite/SQLiteDatabase;->query(Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;

    move-result-object v1'''
new='''    const/4 v0, 0x0

    :try_start_1
    const/4 v4, 0x4

    sget v6, Lcom/facebook/inject/BundledAndroidModule$UL_id;->$ul_$xXXandroid_content_Context$xXXcom_facebook_inject_UnsafeContextInjection$xXXBINDING_ID:I

    iget-object v7, p0, Lcom/oculus/library/database/LibraryStorage;->$ul_mInjectionContext:Lcom/facebook/inject/InjectionContext;

    invoke-static {v4, v6, v7}, Lcom/facebook/inject/FbInjector;->lazyInstance(IILcom/facebook/inject/InjectionContext;)Ljava/lang/Object;

    move-result-object v4

    check-cast v4, Landroid/content/Context;

    invoke-virtual {v4}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object v4

    move-object v6, v5

    invoke-static {}, Lcom/oculus/ocms/library/provider/contract/OCMSLibraryContract;->uriForAllPackages()Landroid/net/Uri;

    move-result-object v5

    const/4 v7, 0x0

    const/4 v8, 0x0

    const/4 v9, 0x0

    invoke-virtual/range {v4 .. v9}, Landroid/content/ContentResolver;->query(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;

    move-result-object v1'''
assert old in s, "loadAll SQLite query block not found"
open(p,'w').write(s.replace(old,new,1)); print("  patched loadAll -> OCMS provider source")
PY

echo "[*] compile InstalledApps + d8-merge into classes.dex"
mkdir -p "$ROOT/work/ocms/classes"
javac --release 8 -cp "$AJ" -d "$ROOT/work/ocms/classes" \
  "$ROOT/patch/java/com/oculus/ocms/library/provider/InstalledApps.java"
# The smali above calls these two by exact signature. A Java-side rename or
# signature change would still build fine here and only blow up on the device as
# NoSuchMethodError, so assert the contract right after compiling.
for sig in "public static android.database.Cursor all(android.content.Context);" \
           "public static android.database.Cursor one(android.content.Context, java.lang.String);"; do
  javap -p -cp "$ROOT/work/ocms/classes" com.oculus.ocms.library.provider.InstalledApps \
    | grep -qF "$sig" || die "InstalledApps is missing the method the smali patch calls: $sig"
done
apktool b -f "$WORK" -o "$ROOT/work/ocms/OCMS_unsigned.apk" >/dev/null
mkdir -p "$ROOT/work/ocms/merge"; rm -f "$ROOT/work/ocms/merge/classes.dex"
( cd "$ROOT/work/ocms/merge" && unzip -o -q ../OCMS_unsigned.apk classes.dex )
"$BT/d8" --min-api 25 --lib "$AJ" --output "$ROOT/work/ocms/merge" \
  "$ROOT/work/ocms/merge/classes.dex" \
  "$ROOT/work/ocms/classes/com/oculus/ocms/library/provider/InstalledApps.class"

echo "[*] repack + align + sign"
cp "$ROOT/work/ocms/OCMS_unsigned.apk" "$ROOT/work/ocms/OCMS_repacked.apk"
( cd "$ROOT/work/ocms" && zip -j -q OCMS_repacked.apk merge/classes.dex )
sign_apk "$ROOT/work/ocms/OCMS_repacked.apk" "$OUT"
