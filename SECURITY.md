# Security Policy

## Supported versions

Security fixes are applied to the latest main branch version.

## Reporting a vulnerability

Please do not open public issues for security bugs.

Instead, report privately to the project maintainer with:

- A clear description of the issue
- Reproduction steps
- Impact assessment
- Suggested mitigation (if available)

## Credential handling in this app

- API keys and management credentials are stored in macOS Keychain.
- App preferences are stored in `UserDefaults` and should not include secrets.
- Secret values must not be logged.

## Scope notes

This app connects to user-supplied Uptime Kuma servers. Server-side security, account configuration, and API key lifecycle are controlled by the server operator.
