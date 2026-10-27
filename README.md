# Technician Tracker

A small Flutter app for Android 7.0+ and iPhone with iOS 15+ that sends native phone GPS to the existing Salesforce tracking session. Technicians paste their **phone invitation**, connect it, and explicitly start sharing. No Salesforce technician account, tracking vendor, or Google Maps API key is required in this app.

The existing Salesforce Case history, agent maps, private customer links, routes and ETA continue to use the same session. This app is the GPS publisher; the existing web pages remain the map viewers.

## Repository scope

This repository contains the Flutter mobile app, its native Android and iOS publishers, and app tests. The Salesforce objects, Apex endpoint, invitation pages, agent/customer maps, and deployment manifests are maintained separately in the Salesforce project. Deploy and configure that backend before connecting an invitation. This repository alone does not deploy Salesforce metadata.

The app currently targets the Salesforce site shown below. Its public hostname is configuration, not a credential; no invitation tokens, Salesforce credentials, signing keys, SDK installations, or compiled apps are included.

## Use it

1. On the laptop, create or open the tracking session and generate a **new phone invitation**.
2. Install Technician Tracker and paste the complete invitation link into the app. Tap **Connect invitation**.
3. Tap **Start sharing** and allow location access. Precise location gives better results. On Android, allow notifications so the tracking notification and its Stop action are visible.
4. Wait until **Last saved to Salesforce** shows a time. Then lock the phone and check the same session on the laptop/customer map.
5. Tap **Stop sharing** in the app, or Stop in the Android notification. GPS collection stops immediately. When online, this also revokes the phone invitation; generate a new invitation to start again.

The token is kept only in memory. The app does not save invitation links, tokens, or a location trail to disk. It does not automatically restart tracking after a reboot or force-stop. A force-quit, revoked permission, disabled location, network outage, or OS battery restriction can interrupt updates. Reopen the app and connect a valid invitation after a process restart. The session currently expires after two hours according to the Salesforce session's expiry.

## Build on Windows / Android

Clone this repository and open its root folder in VS Code. Use Flutter 3.47.7 (the tested version), the Android SDK, and a compatible Java JDK, then ensure `flutter` is on PATH. The VS Code Flutter extension alone does not install these build tools.

```powershell
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

For a USB-connected Android phone with developer mode and USB debugging enabled:

```powershell
flutter devices
flutter run
```

For the original Windows workspace, `tool/flutter.ps1` can also use portable tools from the sibling `myorg/.mobile-build/tools` directory; elsewhere it falls back to Flutter on PATH. Those tools are not included in this repository.

The debug APK is `build/app/outputs/flutter-apk/app-debug.apk`. It is for testing. The Android release build currently also uses debug signing as a development placeholder; configure your own release signing key before distribution. Do not commit signing keys or `android/key.properties`. Review the application ID before publishing.

## Build on macOS / iPhone

Install Flutter 3.47.7 (the tested version) and Xcode on a Mac, clone this repository, then run:

```sh
flutter pub get
flutter analyze
flutter test
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

In Xcode choose your signing team and a unique bundle ID. The app already declares **Background Modes → Location updates** and location permission descriptions. Keep that capability enabled. Run on a physical iPhone; a simulator does not prove screen-locked GPS behavior. For wider installation use your Apple developer distribution setup, such as TestFlight. Windows cannot build or sign the iPhone app. The generated, git-ignored `.vscode/settings.json` is local to this Windows tool setup; remove that local settings file on the Mac so VS Code uses its Mac Flutter installation.

The app asks for location permission when Start is tapped. An ongoing user-started location session can continue with **While Using the App** and the background location indicator; iOS may also offer the **Always** upgrade. Do not force-quit the app while sharing. There is no silent tracking or attempt to bypass permission controls.

## Salesforce API

```text
POST https://ddm00000pb3etuay-dev-ed.develop.my.site.com/LiveTracking/services/apexrest/technician-tracking/v1/publisher
Content-Type: application/json
```

`validate`, `publish` and `stop` are sent in the JSON body's `action`. The 64-character publisher token is sent only in the body. `publish` includes `latitude`, `longitude`, `accuracy` in metres and `capturedAtMs` from the real OS location sample timestamp. No record ID or API key is accepted by the endpoint.

The endpoint delegates to the existing invitation authorization service. The Salesforce site guest profile needs access to **TechnicianMobilePublisherApi** only; it does not need Case access, tracking-object permissions, or access to the agent controllers. In the separate Salesforce project, the class and its tests are included in `manifest/technician-live-tracking.xml` and `manifest/technician-tracking-poc.xml`. Existing phone and customer tokens remain separate; a customer link cannot publish GPS.

The server rejects stale, future-dated, invalid, expired, and revoked requests. It ignores duplicate/older fixes and returns the accepted capture time plus Salesforce receipt time. The native publishers send at most one request at a time, keep only the newest pending real fix, and retry transient failures with bounded backoff. Offline gaps remain visible as old receipt times; the app does not invent fresh coordinates or replay a stale trail.

## Implementation

- `lib/`: Flutter invitation parsing, status and Start/Stop UI. No Dart background timer collects GPS.
- `android/app/src/main/kotlin/com/arun/technician_tracker/`: native Android foreground location service, notification, location callbacks and HTTPS publisher.
- `ios/Runner/AppDelegate.swift`: native Core Location publisher and URLSession networking, registered with Flutter's platform channels.
- `test/`: invitation boundary and UI lifecycle tests.

The app accepts only this org's HTTPS publisher URL, without query parameters, with `#invite=` followed by exactly 64 hex characters. Upload origins are fixed independently in Dart, Android and iOS; network redirects are refused. If the Salesforce site changes, update all three endpoint definitions and the parser tests together. Automatic Universal Links/App Links are not configured; paste the link as requested.

## Real-device acceptance check

Validation on 16 October 2026: Flutter 3.47.7 / Dart 3.13.5 analysis passed, all 6 Flutter tests passed, and the Android debug APK compiled. Salesforce deployment passed all 46 Apex tests; real anonymous API checks passed for validation, GPS upload, Stop and revoked-token rejection. iOS project configuration checks passed. No Android phone was connected, and this Windows machine cannot compile iOS; native screen-locked tracking still needs the physical-device checks below.

Use a fresh session and invitation for each device:

1. Verify no location permission is requested or GPS collected before Start.
2. Start, then confirm a real Salesforce receipt time and the correct phone position on the laptop.
3. Walk outdoors with the screen locked for at least 5 minutes. Confirm the map and receipt time continue to change. Repeat after switching to another app.
4. Disable network briefly: the app must show unconfirmed/retrying status, then send a fresh fix after reconnection. Confirm it never reports a fake successful save.
5. Stop from the app/Android notification. Confirm location collection stops and the old invitation cannot restart when revocation succeeded.
6. Revoke or replace the invitation on the laptop and confirm the app stops once it receives the rejection. Check expiry, denied permissions and location disabled as well.
7. Force-stop the app: updates should cease and tracking must require an explicit restart. Do not treat force-stop behavior as a background tracking failure.

Physical screen-lock checks are required on both platforms, particularly Android phones with manufacturer battery restrictions. Automated tests and a successful build do not establish those OS/device behaviors.

References: [Flutter Android deployment](https://docs.flutter.dev/deployment/android), [Flutter iOS deployment](https://docs.flutter.dev/deployment/ios), [Android location foreground services](https://developer.android.com/develop/background-work/services/fgs/service-types#location), [Apple background location](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background).
