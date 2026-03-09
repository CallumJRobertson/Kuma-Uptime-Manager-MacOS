# Kuma Uptime Manager (macOS)

A lightweight macOS menu bar app for monitoring [Uptime Kuma](https://github.com/louislam/uptime-kuma) status at a glance.

The app runs as an `LSUIElement` utility (menu bar only), supports both public and private server modes, and includes in-app monitor creation for private servers.

## Features

- Menu bar status indicator with monitor count / down count
- Down monitors automatically prioritized to the top (with per-monitor dismiss)
- Quick info bar for large monitor sets (up/down/attention/avg ping)
- Multiple dashboard styles:
  - Compact list
  - Status cards
  - Analytics view
- Monitor detail view with target URL and ping trend
- Private mode authentication via API key
- Public mode support via status-page endpoints
- In-app HTTP monitor creation (private mode, management credentials required)
- Local notifications for down/recovered transitions (batched)
- Configurable polling interval (5-300 seconds)
- Optional Wi-Fi-only refresh mode
- Optional Launch at Login

## Requirements

- macOS 14.6+
- Xcode 16+ (full Xcode app, not Command Line Tools only)
- An Uptime Kuma server (public or private)

## Setup (User)

1. Launch the app.
2. Open `Settings`.
3. Choose connection mode:
   - `Private`: recommended for full functionality.
   - `Public`: uses status-page API endpoints.
4. Enter your `Host` URL.
5. For `Private` mode:
   - Add `Metrics API Key` (from `/settings/api-keys` in Uptime Kuma).
   - (Optional) Add `Mgmt User` + `Mgmt Password` to enable in-app Add Monitor.
6. Click `Save & Connect`.

## Private vs Public mode

### Private mode

- Polls `/metrics` using API key auth.
- Supports in-app monitor creation through Uptime Kuma socket API.
- Does not require status page slug.

### Public mode

- Uses status-page APIs.
- Optional status page slug field for non-default pages.
- No authenticated management actions.

## Add Monitor (In-App)

In the menu popover:

1. Click the `+` button.
2. Enter monitor name, target URL, and interval.
3. Click `Create`.

Prerequisites:

- Private mode is configured
- Management username/password are saved in Settings

## Notifications

- The app requests notification permission on first run.
- Down and recovered events are grouped into a single notification when multiple changes occur.

## Data and Security

- API key and management credentials are stored in macOS Keychain.
- Non-sensitive settings (host, UI preferences, poll interval, etc.) are stored in `UserDefaults`.
- The app does not log raw secret payloads from auth frames.

See [SECURITY.md](SECURITY.md) for details.

## Development

1. Open `UptimeKuma Mac.xcodeproj` in Xcode.
2. Update signing/team settings if needed.
3. Build and run the `UptimeKuma Mac` target.

### Useful checks

- Swift typecheck (CLI):

```bash
SDK=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-macos14.0 \
  "UptimeKuma Mac/UptimeKumaStatusStore.swift" \
  "UptimeKuma Mac/SettingsView.swift" \
  "UptimeKuma Mac/ContentView.swift" \
  "UptimeKuma Mac/UptimeKuma_MacApp.swift" \
  "UptimeKuma Mac/WebLoginSheet.swift"
```

## Known limitations

- Browser/session login flow is intentionally disabled in this build for stability.
- In-app monitor creation currently targets HTTP monitor type only.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
