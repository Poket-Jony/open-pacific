#!/usr/bin/env bash
# Reproduce the Horizon (com.oculus.horizon) patches from a stock Horizon.apk.
#
# Ten patches, each numbered and explained at its own step below. In short: an offline
# "empty account" login, the FB-secure trust checks neutralised so the re-signed system
# app runs at all, the platform/OVR init made to succeed offline, the account/profile
# first-time NUX removed at its root, an offline app-scoped user id served from
# ProfileContentProvider, and the device-auth-token fetch dropped (the platform-signed
# DeviceAuthServer rejects the re-signed caller, which crashed Horizon).
#
# Requires apktool, build-tools (zipalign, apksigner), and a signing keystore ($KS).

# Usage: patch_horizon.sh [in.apk] [out.apk] (defaults: work/apks/Horizon.apk ->
#        work/horizon/Horizon_signed.apk)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_sdk
need apktool python3
IN="${1:-$ROOT/work/apks/Horizon.apk}"
OUT="${2:-$ROOT/work/horizon/Horizon_signed.apk}"
[ -f "$IN" ] || die "stock Horizon.apk not found: $IN (run extract_firmware.sh or extract_apks.sh first)"
[ -f "$KS" ] || die "keystore not found: $KS (run patch_ocms.sh first — it creates the shared key)"
WORK="$ROOT/work/horizon/smali"

echo "[*] decompile $IN"
# -r: smali-only patch, so keep resources.arsc raw (no aapt re-encode on build).
apktool d -r -f -o "$WORK" "$IN" >/dev/null

py() { python3 - "$@"; }

# 1) getCredentials(): always return a local empty account (uid + dummy token)
py "$WORK/smali/com/oculus/horizon/auth/shared_datastore/HorizonAuthDatastore.smali" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
new='''.method public getCredentials()Lcom/oculus/auth/credentials/Credentials;
    .locals 3
    .annotation runtime Ljavax/annotation/Nullable;
    .end annotation

    new-instance v0, Lcom/oculus/auth/credentials/Credentials;
    const-string v1, "1"
    const-string v2, "offline-local-session"
    invoke-direct {v0, v1, v2}, Lcom/oculus/auth/credentials/Credentials;-><init>(Ljava/lang/String;Ljava/lang/String;)V
    return-object v0
.end method'''
s2=re.sub(r'\.method public getCredentials\(\)Lcom/oculus/auth/credentials/Credentials;.*?\.end method', new, s, count=1, flags=re.S)
assert s2 != s, "getCredentials not patched"; s = s2
# clearCredentials(): no-op so the offline session is never wiped
newc='''.method public clearCredentials()V
    .locals 0

    return-void
.end method'''
s2=re.sub(r'\.method public clearCredentials\(\)V.*?\.end method', newc, s, count=1, flags=re.S)
assert s2 != s, "clearCredentials not patched"; s = s2
open(p,'w').write(s); print("  patched HorizonAuthDatastore")
PY

# 2) FB-secure oxygen TrustedCallerVerifier: force isTrusted, never throw
TCI="$WORK/smali/com/facebook/oxygen/common/verification/TrustedCallerVerifier\$TrustedCallerInfo.smali"
py "$TCI" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=s.replace(
 'invoke-direct {p0}, Ljava/lang/Object;-><init>()V\n\n    .line 231\n    iput-boolean p1',
 'invoke-direct {p0}, Ljava/lang/Object;-><init>()V\n\n    .line 231\n    const/4 p1, 0x1\n\n    iput-boolean p1',1)
assert s2 != s, "TrustedCallerInfo ctor not patched"
open(p,'w').write(s2); print("  patched TrustedCallerInfo ctor")
PY
py "$WORK/smali/com/facebook/oxygen/common/verification/TrustedCallerVerifier.smali" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
# enforceTrustedCaller(): return the info immediately, never throw
s2=s.replace(
 'checkTrustedCallerInfo()Lcom/facebook/oxygen/common/verification/TrustedCallerVerifier$TrustedCallerInfo;\n\n    move-result-object v0\n\n    .line 124',
 'checkTrustedCallerInfo()Lcom/facebook/oxygen/common/verification/TrustedCallerVerifier$TrustedCallerInfo;\n\n    move-result-object v0\n\n    return-object v0\n\n    .line 124',1)
assert s2 != s, "enforceTrustedCaller not patched"
open(p,'w').write(s2); print("  patched enforceTrustedCaller")
PY

# 3) FB-secure trustedapp TrustedApp.isAppIdentityTrusted(...;Z)Z -> true
py "$WORK/smali/com/facebook/secure/trustedapp/TrustedApp.smali" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=s.replace(
 '.end param\n\n    const/4 v0, 0x0\n\n    if-eqz p1, :cond_6\n\n    .line 458',
 '.end param\n\n    const/4 v0, 0x1\n\n    return v0\n\n    const/4 v0, 0x0\n\n    if-eqz p1, :cond_6\n\n    .line 458',1)
assert s2 != s, "isAppIdentityTrusted not patched"
open(p,'w').write(s2); print("  patched isAppIdentityTrusted")
PY

# 4) VrCastService is removed from the image, so Horizon's teardown NPEs when it
#    tries to unbind the (never-bound) cast service on VR session end, crashing
#    the home. Make VrCastServiceConnection.unbindService() a no-op.
VCS="$(find_one "$WORK" '*service_media/vrcast/VrCastServiceConnection.smali' VrCastServiceConnection.smali)"
py "$VCS" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=re.sub(r'(\.method public unbindService\(\)V\n\s*\.locals \d+\n)', r'\1\n    return-void\n', s, count=1)
assert s2!=s, "unbindService not patched"
open(p,'w').write(s2); print("  patched unbindService -> no-op")
PY

# 5) com.oculus.platform.OVR (OVR platform SDK, shared into the home panel) throws
#    IllegalStateException("Nobody is logged in!") from assertIsInitialized() when
#    mProfile is null (profile only resolves online). Offline that hard-crashes the
#    home panel. Make assertIsInitialized() a no-op so platform calls proceed.
OVRS="$(find_one "$WORK" '*com/oculus/platform/OVR.smali' OVR.smali)"
py "$OVRS" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s2=re.sub(r'(\.method private assertIsInitialized\(\)V\n\s*\.locals \d+\n)', r'\1\n    return-void\n', s, count=1)
assert s2!=s, "assertIsInitialized not patched"
open(p,'w').write(s2); print("  patched assertIsInitialized -> no-op")
PY

# 6) ROOT of the "incompatible version of Home/Horizon" spinner: the platform
#    client (OVRServiceSynchronous.connect, shared into the home panel) refuses to
#    connect unless getServiceAvailability() == SIGNATURE_VERIFIED, i.e. Horizon's
#    OVRService is signed with Meta's cert. Re-signed -> SIGNATURE_INVALID ->
#    STORE_INSTALLATION_ERROR (code 4). Force getServiceAvailability() to return
#    SIGNATURE_VERIFIED so the panel connects to our re-signed platform service.
OSS="$(find_one "$WORK" '*com/oculus/platform/OVRServiceSynchronous.smali' OVRServiceSynchronous.smali)"
py "$OSS" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
m=re.search(r'(\.method public getServiceAvailability\(Landroid/content/pm/PackageManager;\)Lcom/oculus/platform/OVRServiceSynchronous\$ServiceState;\n\s*\.locals \d+\n)', s)
assert m, "getServiceAvailability not found"
ins='    sget-object p1, Lcom/oculus/platform/OVRServiceSynchronous$ServiceState;->SIGNATURE_VERIFIED:Lcom/oculus/platform/OVRServiceSynchronous$ServiceState;\n    return-object p1\n\n'
s=s[:m.end()]+ins+s[m.end():]
open(p,'w').write(s); print("  patched getServiceAvailability -> SIGNATURE_VERIFIED")
PY

# 7) getAppScopedAccessToken() is network-only for non-horizon callers (hits
#    graph.oculus.com). Offline the OCPlatformModule access-token fetch fails and
#    the home spins forever waiting for it. Return a local dummy token so the
#    platform initializes offline (downstream authed calls still no-op via the
#    other patches; the library renders from the local OCMS module).
EPN="$(find_one "$WORK" '*horizon/service/ExternalPlatformNetwork.smali' ExternalPlatformNetwork.smali)"
py "$EPN" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
m=re.search(r'(\.method public getAppScopedAccessToken\(Landroid/content/Context;Landroid/os/Bundle;Ljava/lang/String;\)Ljava/lang/String;\n\s*\.locals \d+\n\s*\.annotation system Ldalvik/annotation/Throws;.*?\.end annotation\n)', s, re.S)
assert m, "getAppScopedAccessToken not found"
ins='\n    const-string v0, "offline-local-session"\n\n    return-object v0\n'
s=s[:m.end()]+ins+s[m.end():]
open(p,'w').write(s); print("  patched getAppScopedAccessToken -> local dummy token")
PY

# 8) Remove the First-Time-NUX at the root. The shell decides whether to run the
#    VR NUX by reading the user profile's NUX-completion columns from Horizon's
#    ProfileContentProvider, which sources them from UserProfileHelper. Offline the
#    profile never syncs, so every "has finished / has seen NUX" getter returns
#    false and the shell launches the NUX flow (com.oculus.vrshell.home:vrnux),
#    which then spins forever because it can't fetch its content offline. Force the
#    NUX-completion getters to true so the profile always reports the NUX as done
#    and the shell routes straight to Home.
UPH="$(find_one "$WORK" '*horizon/profile/UserProfileHelper.smali' UserProfileHelper.smali)"
py "$UPH" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
getters = ["getHasFinishedNux", "getHasFinishedFullVrNux", "getHasFinishedMontereyNux",
           "getHasSeenNux", "getHasSeenHandTrackingNux"]
for g in getters:
    pat = r'\.method public '+g+r'\(\)Z\n.*?\.end method'
    repl = '.method public '+g+'()Z\n    .locals 1\n\n    const/4 v0, 0x1\n\n    return v0\n.end method'
    s2 = re.sub(pat, repl, s, count=1, flags=re.S)
    assert s2 != s, g+" not patched"
    s = s2
open(p,'w').write(s); print("  patched NUX getters -> true (%s)" % ", ".join(getters))
PY

# 9) ProfileContentProvider.doQuery(): the shell polls this provider for the
#    app-scoped user id of the calling app (com.oculus.vrshell.home). For a
#    caller that is not recognised as a first-party app (our re-signed Home is
#    not signed with Meta's prod cert, so callingAppHasSystemPlatformSDKPermission
#    and verifyProductionFirstPartyApplication both fail), it falls through to
#    getAppScopedUserID(), which throws PackageNotInLibraryException offline ->
#    "not found in library. Not sending scoped user id" -> the library UI never
#    gets an id and spins. Force the system-permission check to true so every
#    caller takes the first-party branch and receives Credentials.getUserId()
#    (our offline "1"). Also unblocks future first-party Home panels querying the
#    profile provider offline.
py "$WORK/smali/com/oculus/horizon/provider/ProfileContentProvider.smali" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='''    invoke-static {v3}, Lcom/oculus/content/PermissionChecks;->callingAppHasSystemPlatformSDKPermission(Landroid/content/Context;)Z

    move-result v5

    if-nez v5, :cond_3'''
new='''    invoke-static {v3}, Lcom/oculus/content/PermissionChecks;->callingAppHasSystemPlatformSDKPermission(Landroid/content/Context;)Z

    move-result v5

    const/4 v5, 0x1

    if-nez v5, :cond_3'''
assert old in s, "doQuery system-permission check not found"
open(p,'w').write(s.replace(old,new,1)); print("  patched doQuery -> first-party branch (offline scoped user id)")
PY

# 10) DeviceAuthTokenStore: don't fetch a device auth token at all.
#     com.oculus.deviceauthserver verifies its callers against Meta's certs, so the
#     re-signed Horizon is rejected and the SecurityException escapes the callback:
#       FATAL EXCEPTION: com.oculus.horizon
#       SecurityException: Access denied. Caller is not trusted: TrustedCallerInfo{
#         isTrusted=false, uid=10046, signature=...}
#         at IDeviceAuthService$Stub$Proxy.getDeviceAuthToken
#         at DeviceAuthTokenStore$1.onServiceConnected
#     The existing try/catch there only covers RemoteException. Patching the *client*
#     is the safe side: DeviceAuthServer.apk is platform-signed and carries no odex, so
#     re-signing it would drop seinfo=platform. The token is a server credential and
#     useless offline anyway.
DAT="$(find_one "$WORK" "*auth/device/DeviceAuthTokenStore\$1.smali" "DeviceAuthTokenStore\$1.smali")"
py "$DAT" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
new = '''.method public onServiceConnected(Landroid/content/ComponentName;Landroid/os/IBinder;)V
    .locals 1

    return-void
.end method'''
s2 = re.sub(r'\.method public onServiceConnected\(Landroid/content/ComponentName;Landroid/os/IBinder;\)V.*?\.end method',
            new, s, count=1, flags=re.S)
assert s2 != s, "onServiceConnected not patched"
open(p, 'w').write(s2)
print("  patched DeviceAuthTokenStore.onServiceConnected -> no-op (no device auth token)")
PY

echo "[*] build + sign"
build_sign_apk "$WORK" "$OUT"
