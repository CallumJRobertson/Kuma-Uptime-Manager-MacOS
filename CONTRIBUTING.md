# Contributing

Thanks for contributing to Kuma Uptime Manager.

## Development setup

1. Install full Xcode (not only Command Line Tools).
2. Clone the repo.
3. Open `UptimeKuma Mac.xcodeproj`.
4. Select the `UptimeKuma Mac` target and your signing team.
5. Build and run.

## Pull request guidelines

- Keep PRs focused and small.
- Include a clear summary of behavior changes.
- Call out any settings migrations or credential handling changes.
- Update `README.md` when user-visible behavior changes.

## Testing checklist

Before opening a PR, verify:

1. App launches and menu bar UI opens reliably.
2. Settings can save and reconnect without clearing secrets.
3. Private mode connects using API key.
4. Public mode connects to status-page endpoint.
5. Polling interval respects 5-300 second bounds.
6. Wi-Fi-only mode blocks refresh when not on Wi-Fi.
7. Notifications trigger on down/recovery transitions.
8. Add Monitor flow works with management credentials.
9. No secrets are printed in logs.

## Code style

- Follow existing SwiftUI style and naming.
- Keep state ownership in `UptimeKumaStatusStore` unless view-local.
- Avoid adding dependencies unless necessary.
- Prefer explicit, user-actionable error messages.

## Security expectations

- Never add plaintext credential persistence.
- Never log passwords, API keys, tokens, or cookie values.
- Use Keychain for secrets.

For security disclosures, see `SECURITY.md`.
