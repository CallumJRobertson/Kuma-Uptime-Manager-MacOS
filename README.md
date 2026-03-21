# KumaUptime (macOS)

![macOS](https://img.shields.io/badge/platform-macOS-blue)
![License](https://img.shields.io/github/license/CallumJRobertson/Kuma-Uptime-Manager-MacOS)
![Release](https://img.shields.io/github/v/release/CallumJRobertson/Kuma-Uptime-Manager-MacOS)

<p align="center">
  <a href="https://apps.apple.com/gb/app/kuma-uptime-manager/id6760319527?mt=12">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" height="80">
  </a>
</p>

![KumaUptime Screenshot](docs/demo.png)

A lightweight **menu bar app for macOS** that lets you monitor your **[Uptime Kuma](https://github.com/louislam/uptime-kuma)** servers at a glance.

KumaUptime runs quietly in the macOS menu bar and shows the current status of your monitors without needing to open a browser.

---

## Download

### 🖥 App Store

Download directly from the Mac App Store:

➡️ https://apps.apple.com/gb/app/kuma-uptime-manager/id6760319527?mt=12

---

### 📦 Manual Install (DMG)

➡️ https://github.com/CallumJRobertson/KumaUptime/releases

1. Download `KumaUptime.dmg`
2. Open the DMG
3. Drag **KumaUptime.app** into **Applications**
4. Launch the app

---

## Features

- Menu bar status indicator with monitor count and down alerts
- Down monitors automatically prioritized to the top
- Multiple dashboard views:
  - Compact list
  - Status cards
  - Analytics view
- Monitor detail view with target URL and ping trend
- In-app monitor creation (private servers)
- Local notifications for monitor down / recovery
- Configurable polling interval (5–300 seconds)
- Optional Wi-Fi-only refresh mode
- Optional Launch at Login

---

## Requirements

- **macOS 14.6 or newer**
- A running **[Uptime Kuma](https://github.com/louislam/uptime-kuma)** server

KumaUptime works with both **private servers** and **public status pages**.

---

## Connecting to your server

Open **Settings** inside the app and choose your connection mode.

### Private Mode (recommended)

Provides full functionality.

Required fields:

- Host URL
- **Metrics API Key** (from `/settings/api-keys` in **Uptime Kuma**)

Optional:

- Management username/password  
  Enables **in-app monitor creation**.

---

### Public Mode

Uses status page APIs provided by **Uptime Kuma**.

Required:

- Host URL

Optional:

- Status page slug

Public mode does **not allow authenticated actions**.

---

## Creating monitors from the app

When using **Private Mode**, you can create monitors directly.

1. Open the menu bar popover
2. Click the **+** button
3. Enter monitor name and target URL
4. Click **Create**

Currently supported monitor type:

- HTTP

---

## Notifications

The app can send macOS notifications when:

- A monitor goes **down**
- A monitor **recovers**

Multiple events are grouped into a single notification to avoid spam.

---

## Data & Security

Sensitive information is stored securely.

- API keys and credentials are stored in **macOS Keychain**
- UI settings are stored in **UserDefaults**
- Secret authentication payloads are never logged

See **SECURITY.md** for more details.

---

## Development

To build the app locally:

1. Open `UptimeKuma Mac.xcodeproj` in **Xcode 16+**
2. Configure signing settings
3. Run the **UptimeKuma Mac** target

### Swift typecheck example

```bash
SDK=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-macos14.0 \
  "UptimeKuma Mac/UptimeKumaStatusStore.swift" \
  "UptimeKuma Mac/SettingsView.swift" \
  "UptimeKuma Mac/ContentView.swift" \
  "UptimeKuma Mac/UptimeKuma_MacApp.swift" \
  "UptimeKuma Mac/WebLoginSheet.swift"
