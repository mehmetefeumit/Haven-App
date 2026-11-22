# geolocator_android 5.0.2, patched for Haven

Upstream: pub.dev `geolocator_android` 5.0.2 (MIT, Baseflow), archive
sha256 `179c3cb66dfa674fc9ccbf2be872a02658724d1c067634e2c427cf6df7df901a`
(the hash `haven/pubspec.lock` pinned before this copy replaced it).
`haven/pubspec.yaml` selects this copy through `dependency_overrides`.

## Why

Upstream links `com.google.android.gms:play-services-location`
unconditionally, so every APK that uses geolocator ships Google Play Services
classes, and Haven's listing on Zapstore read "Google services" because of
them. Upstream offers no build without it (Baseflow/flutter-geolocator#841,
#1481). Haven already asks for every position, last-known read and stream with
`forceLocationManager: true`; the one call that still reached Play Services
was `isLocationServiceEnabled`, which upstream always routes through the
fused client when Play Services is installed.

## The patch

- `FusedLocationClient.java` is deleted.
- `GeolocationManager.createLocationClient` always returns the platform
  `LocationManagerClient`; `isGooglePlayServicesAvailable` and its imports
  are gone.
- `android/build.gradle` no longer declares `play-services-location`.
- `example/` and `test/` are not copied; `publish_to: none` is added.

Nothing else differs from the upstream archive. Upstream's Dart doc for
`AndroidSettings.forceLocationManager` still describes the fused fallback; in
this copy that flag changes nothing, because every client is the
`LocationManagerClient`.
`scripts/ci/check_no_google_services.sh` fails if a Play Services, Firebase
or ML Kit class, manifest entry or dependency comes back.

## Upgrading

Download the new archive from `https://pub.dev/api/archives/geolocator_android-<version>.tar.gz`,
record its sha256 here, unpack it over this directory, delete `example/` and
`test/`, and re-apply the three edits above. Upstream's own changes come with
it unreviewed, so read the upstream changelog first.

```diff
diff -ru upstream/android/build.gradle ./android/build.gradle
--- upstream/android/build.gradle
+++ ./android/build.gradle
@@ -41,7 +41,6 @@
 }
 
 dependencies {
-    implementation 'com.google.android.gms:play-services-location:21.2.0'
     implementation 'androidx.core:core:1.16.0'
 
     testImplementation 'junit:junit:4.13.2'
deleted: android/src/main/java/com/baseflow/geolocator/location/FusedLocationClient.java
diff -ru upstream/android/src/main/java/com/baseflow/geolocator/location/GeolocationManager.java ./android/src/main/java/com/baseflow/geolocator/location/GeolocationManager.java
--- upstream/android/src/main/java/com/baseflow/geolocator/location/GeolocationManager.java
+++ ./android/src/main/java/com/baseflow/geolocator/location/GeolocationManager.java
@@ -9,8 +9,6 @@
 
 import com.baseflow.geolocator.errors.ErrorCallback;
 import com.baseflow.geolocator.errors.ErrorCodes;
-import com.google.android.gms.common.ConnectionResult;
-import com.google.android.gms.common.GoogleApiAvailability;
 
 import java.util.List;
 import java.util.concurrent.CopyOnWriteArrayList;
@@ -69,31 +67,12 @@
     locationClient.stopPositionUpdates();
   }
 
+  // Haven: always the platform LocationManager; the Play Services client is removed (HAVEN_PATCH.md).
   public LocationClient createLocationClient(
       Context context,
       boolean forceAndroidLocationManager,
       @Nullable LocationOptions locationOptions) {
-    if (forceAndroidLocationManager) {
-      return new LocationManagerClient(context, locationOptions);
-    }
-
-    return isGooglePlayServicesAvailable(context)
-        ? new FusedLocationClient(context, locationOptions)
-        : new LocationManagerClient(context, locationOptions);
-  }
-
-  private boolean isGooglePlayServicesAvailable(Context context) {
-    try {
-      GoogleApiAvailability googleApiAvailability = GoogleApiAvailability.getInstance();
-      int resultCode = googleApiAvailability.isGooglePlayServicesAvailable(context);
-      return resultCode == ConnectionResult.SUCCESS;
-    }
-    // If the Google API class is not available conclude that the play services
-    // are unavailable. This might happen when the GMS package has been excluded by
-    // the app developer due to its proprietary license.
-    catch(NoClassDefFoundError e) {
-      return false;
-    }
+    return new LocationManagerClient(context, locationOptions);
   }
 
   @Override
```
