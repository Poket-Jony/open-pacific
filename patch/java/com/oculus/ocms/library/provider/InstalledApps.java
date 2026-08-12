package com.oculus.ocms.library.provider;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Offline replacement data source for the Oculus Home library.
 *
 * The stock library reads entitlements from a server-synced SQLite cache that
 * stays empty without a Meta login. This enumerates installed launchable /VR
 * apps from PackageManager and returns them in the exact column contract the
 * library UI expects, so the stock Home shows installed apps offline.
 *
 * The consumer parses several columns back into enums via strict valueOf, so
 * every enum-typed column carries a valid enum name.
 *
 * Icons are inlined as data: URIs. The Home's image loader (Oculus' RCTVR/OVR
 * pipeline, not Android's ContentResolver) only resolves data:/network URIs —
 * cross-package android.resource:// and even content:// fail (it treats them as
 * asset paths inside its own APK). A base64 PNG in the cursor is the one scheme
 * that loads offline. To stay under the 2 MB CursorWindow the icon is rendered
 * small and placed only in the three square image columns the grid reads; the
 * large hero/landscape slots get a 1 px transparent placeholder.
 */
public final class InstalledApps {

    private static final String VR_CATEGORY = "com.oculus.intent.category.VR";

    /** Rendered icon edge length in px — small enough to keep the cursor light. */
    private static final int ICON_SIZE = 128;

    /**
     * Total budget for inlined icon bytes, well under Android's 2 MB CursorWindow.
     *
     * Icon size varies enormously: a flat-coloured launcher icon is a few hundred bytes
     * as PNG, a photographic VR icon tens of kilobytes — and each one is written into
     * three columns. A user with many rich icons could therefore overflow the window,
     * and the library would come back short or empty, which is exactly the failure this
     * whole patch exists to fix. So icons are dropped once the budget is spent: every
     * app still appears with its name, the later ones just show the placeholder.
     */
    private static final long ICON_BUDGET_BYTES = 1536 * 1024;

    /** 1x1 transparent PNG as a data: URI, for image slots the grid doesn't show. */
    private static final String TRANSPARENT_PX =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
        + "AAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

    private static final String[] COLS = {
        "item_id", "name", "application_grouping_id",
        "image_source_square", "image_source_main", "image_source_tiny",
        "small_landscape_image", "hero_image", "package_name",
        "latest_version_code", "latest_version_name", "latest_target_sdk_version",
        "installation_size", "downloaded_size", "permissions",
        "installable_on_external_storage", "user_quality_rating", "status",
        "cloud_storage_status", "supported_input_devices", "entitlement_hash",
        "app_scoped_user_id", "recent_activity", "comfort_rating", "favorite",
        "unseen", "livestreaming_status", "livestreaming_status_audio_hooking",
        "chromecast_audio_enabled", "min_recommended_version_code",
        "min_required_version_code", "microphone_usage", "total_activity",
        "patch_download_size", "apk_full_size", "obb_full_size", "is_demo_of",
        "platform", "app_media_capabilities", "play_modes", "category",
        "head_tracking", "grant_reason", "grant_time", "grant_expiration",
        "current_langauge_pack", "android_permissions", "internet_connection",
        "trusted_binary_status", "is_concept", "is_tv_app",
        "system_ui_as_overlay_mode"
    };

    private InstalledApps() {}

    public static Cursor all(Context ctx) {
        MatrixCursor c = new MatrixCursor(COLS);
        if (ctx == null) {
            return c;
        }
        PackageManager pm = ctx.getPackageManager();
        Set<String> pkgs = new LinkedHashSet<String>();
        collect(pm, new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), pkgs);
        collect(pm, new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_INFO), pkgs);
        collect(pm, new Intent(Intent.ACTION_MAIN).addCategory(VR_CATEGORY), pkgs);

        long budget = ICON_BUDGET_BYTES;
        for (String pkg : pkgs) {
            try {
                budget -= addApp(c, pm, pkg, budget > 0);
            } catch (Throwable ignored) {
            }
        }
        return c;
    }

    public static Cursor one(Context ctx, String pkg) {
        MatrixCursor c = new MatrixCursor(COLS);
        if (ctx == null || pkg == null) {
            return c;
        }
        try {
            addApp(c, ctx.getPackageManager(), pkg, true);
        } catch (Throwable ignored) {
        }
        return c;
    }

    /** Renders an app's launcher icon to a bounded PNG data: URI (or transparent). */
    private static String iconDataUri(PackageManager pm, String pkg) {
        try {
            Drawable d = pm.getApplicationIcon(pkg);
            Bitmap bmp = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bmp);
            d.setBounds(0, 0, ICON_SIZE, ICON_SIZE);
            d.draw(canvas);
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            bmp.compress(Bitmap.CompressFormat.PNG, 100, baos);
            bmp.recycle();
            return "data:image/png;base64," + Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP);
        } catch (Throwable t) {
            return TRANSPARENT_PX;
        }
    }

    private static void collect(PackageManager pm, Intent intent, Set<String> out) {
        try {
            List<ResolveInfo> ris = pm.queryIntentActivities(intent, 0);
            if (ris == null) {
                return;
            }
            for (ResolveInfo ri : ris) {
                if (ri.activityInfo != null && ri.activityInfo.packageName != null) {
                    out.add(ri.activityInfo.packageName);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    /** Adds one row; returns the icon bytes it spent (0 when withIcon is false). */
    private static int addApp(MatrixCursor c, PackageManager pm, String pkg, boolean withIcon)
            throws Exception {
        PackageInfo pi = pm.getPackageInfo(pkg, 0);
        ApplicationInfo ai = pi.applicationInfo;
        String label = pkg;
        if (ai != null) {
            CharSequence l = pm.getApplicationLabel(ai);
            if (l != null) {
                label = l.toString();
            }
        }
        long versionCode = pi.versionCode;
        String versionName = pi.versionName != null ? pi.versionName : "";
        int targetSdk = ai != null ? ai.targetSdkVersion : 0;
        String icon = withIcon ? iconDataUri(pm, pkg) : TRANSPARENT_PX;

        c.addRow(new Object[] {
            pkg,                              // item_id
            label,                            // name
            pkg,                              // application_grouping_id
            icon,                             // image_source_square  (grid tile)
            icon,                             // image_source_main
            icon,                             // image_source_tiny
            TRANSPARENT_PX,                   // small_landscape_image (unused big slot)
            TRANSPARENT_PX,                   // hero_image            (unused big slot)
            pkg,                              // package_name
            Long.valueOf(versionCode),        // latest_version_code
            versionName,                      // latest_version_name
            Integer.valueOf(targetSdk),       // latest_target_sdk_version
            Long.valueOf(0L),                 // installation_size
            Long.valueOf(0L),                 // downloaded_size
            "",                               // permissions
            Integer.valueOf(0),               // installable_on_external_storage
            Integer.valueOf(0),               // user_quality_rating
            "INSTALLED",                      // status
            "DISABLED",                       // cloud_storage_status
            "",                               // supported_input_devices
            pkg,                              // entitlement_hash (must be non-empty: App() throws on empty)
            "1",                              // app_scoped_user_id (isValid requires non-empty)
            Long.valueOf(0L),                 // recent_activity
            "NOT_RATED",                      // comfort_rating (bundle rejects UNKNOWN)
            Integer.valueOf(0),               // favorite
            Integer.valueOf(0),               // unseen
            "UNKNOWN",                        // livestreaming_status
            Integer.valueOf(0),               // livestreaming_status_audio_hooking
            Integer.valueOf(0),               // chromecast_audio_enabled
            Long.valueOf(0L),                 // min_recommended_version_code
            Long.valueOf(0L),                 // min_required_version_code
            "NONE",                           // microphone_usage
            Long.valueOf(0L),                 // total_activity
            Long.valueOf(0L),                 // patch_download_size
            Long.valueOf(0L),                 // apk_full_size
            Long.valueOf(0L),                 // obb_full_size
            null,                             // is_demo_of
            "ANDROID",                        // platform
            "",                               // app_media_capabilities
            "",                               // play_modes
            "APPS",                           // category
            "REQUIRE_3DOF",                   // head_tracking
            "UNKNOWN",                        // grant_reason
            Long.valueOf(0L),                 // grant_time
            Long.valueOf(0L),                 // grant_expiration
            "",                               // current_langauge_pack
            "",                               // android_permissions
            "",                               // internet_connection
            "TRUSTED",                        // trusted_binary_status
            Integer.valueOf(0),               // is_concept
            Integer.valueOf(0),               // is_tv_app
            "DISABLED"                        // system_ui_as_overlay_mode (isValid requires non-empty)
        });
        // Three columns carry the icon, so that is what it costs against the budget.
        // The placeholder is free — it is also what iconDataUri returns when it fails.
        return TRANSPARENT_PX.equals(icon) ? 0 : icon.length() * 3;
    }
}
