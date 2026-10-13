# Push Notification Setup

This document covers the one-time setup required to enable Home Assistant push notifications
in Hassonic via Firebase Cloud Messaging (FCM) and APNs.

---

## Overview

```
Home Assistant automation
  → notify.mobile_app_<device>
  → POST to push relay URL (Firebase Cloud Function)
  → FCM → APNs
  → Hassonic app
```

---

## Prerequisites

- Apple Developer account (for APNs key)
- Firebase project on the **Blaze** (pay-as-you-go) plan — required for Cloud Functions even
  when usage stays within the free quota tier
- [Firebase CLI](https://firebase.google.com/docs/cli): `npm install -g firebase-tools`
- Node 20 (for function deployment)

---

## Step 1 — Create a Firebase project

1. Go to [Firebase Console](https://console.firebase.google.com/) and click **Add project**.
2. Name it e.g. `hassonic-push`.
3. Disable Google Analytics (not needed).
4. Upgrade the project to the **Blaze** plan under Project Settings → Usage and billing.

---

## Step 2 — Set a budget alert

1. In Firebase Console → Project settings → Usage and billing → **Manage budget alerts**.
2. Add an alert at **$5/month** — this project should cost $0 at normal load, so $5 is an early
   warning of anything unexpected.

---

## Step 3 — Register the iOS app in Firebase

1. In Firebase Console → Project overview → **Add app** → iOS+.
2. Enter bundle ID: the app's bundle ID, `APP_BUNDLE_ID` from `Config/Base.xcconfig` (by default `<BUNDLE_ID_PREFIX>.Hassonic`).
3. Download `GoogleService-Info.plist`.
4. Replace `Hassonic/GoogleService-Info.plist` in the Xcode project with the downloaded file
   (it is already added to the target; just overwrite the placeholder).

---

## Step 4 — Create and upload the APNs Auth Key

1. Sign in to [Apple Developer](https://developer.apple.com/) → Certificates, Identifiers & Profiles
   → **Keys** → "+" to create a new key.
2. Name it e.g. `Hassonic APNs`, enable **Apple Push Notifications service (APNs)**, and click
   Continue → Register.
3. Download the `.p8` file — **this can only be downloaded once**. Store it securely.
4. Note the **Key ID** shown on the key detail page.
5. Note your **Team ID** from Membership details.
6. In Firebase Console → Project settings → **Cloud Messaging** tab → Apple app configuration →
   **APNs Auth Key** → Upload.
   - Upload the `.p8` file.
   - Enter the Key ID and Team ID.

---

## Step 5 — Enable Push Notifications entitlement in Xcode

1. Open the Xcode project (after running `xcodegen generate`).
2. Select the **Hassonic** target → Signing & Capabilities.
3. Click "+" → **Push Notifications**.
4. Also confirm **Background Modes → Remote notifications** is checked (it is already set in
   `project.yml`).

---

## Step 6 — Deploy the relay Cloud Function

```bash
cd relay
firebase login          # authenticate once
firebase use --add      # select the Firebase project created in Step 1
cd functions
npm install
cd ..
firebase deploy --only functions,firestore:rules
```

After deployment the CLI prints the function URL, e.g.:

```
Function URL (pushRelay): https://us-central1-hassonic-push.cloudfunctions.net/pushRelay
```

Copy this URL — it is the **Push Relay URL** entered in the app's Connection screen.

---

## Step 7 — Configure the app

1. Build and run the app on a real device (APNs does not work in the simulator).
2. On the Connection screen:
   - Enter the Home Assistant URL and long-lived access token as usual.
   - Enter the **Push Relay URL** from Step 6.
   - Tap **Connect**.
3. The app requests notification permission, obtains an FCM registration token, and registers the
   device with Home Assistant via the `mobile_app` integration.
4. Home Assistant automatically creates a `notify.mobile_app_<device_name>` service.

---

## Step 8 — Test end-to-end

In Home Assistant Developer Tools → Services, call:

```yaml
service: notify.mobile_app_<your_device_name>
data:
  message: "Hello from Home Assistant"
  title: "Test"
```

The notification should appear on the device within a few seconds.

---

## Rate limiting

The relay enforces a limit of **150 notifications per FCM token per calendar day** (UTC).
This protects against runaway automations and keeps Cloud Function invocations well within
the free quota. Adjust `MAX_PER_TOKEN_PER_DAY` in `relay/functions/src/index.ts` if needed.
