# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `DisplayFormatters` enum for centralized formatting logic (SRP separation from `MenuBarView`)
- `UsageFetching` and `MetricsPolling` protocols for dependency inversion (DIP) in `AppState`
- `isNetworkError` flag on `AppState` for type-safe error classification in views
- `Makefile.local` support — local cert/team credentials separated from version-controlled `Makefile`
- Fallback to `~/.claude/.credentials.json` when the Keychain item is missing — supports setups where Claude Code CLI stores credentials in a file instead of the Keychain

### Changed
- Popover background changed to native macOS menu bar style (removed per-section glass cards, using system dividers)
- UI labels switched to English: "Current session", "Current week (all models)", "Current week (Sonnet only)"
- Reset time now shows absolute time in Asia/Seoul timezone (e.g., "Resets 2pm (Asia/Seoul)")
- README.md simplified to essentials (description, install, update)
- `Makefile` cert/team values now use environment variable overrides (`?=`) instead of hardcoded strings
- `URLSession` and `ISO8601DateFormatter` reused as instance/static properties instead of per-call allocation
- Startup backoff delay values extracted to named constant `startupBackoffDelays`
- Environment variable token fallback (`CLAUDE_CODE_OAUTH_TOKEN`) restricted to `#if DEBUG` builds only
- Error message length capped at 100 characters to prevent oversized UI states
- Network error detection in `MenuBarView` uses `state.isNetworkError` flag instead of string matching

### Fixed
- `Timer` resources now properly invalidated in `AppState.deinit` — prevents duplicate timer leak on restart
- Prometheus metric parsing now correctly extracts the value token (index 1), avoiding timestamp misparse
- URL query parameters use `URLComponents` percent-encoding instead of raw string interpolation
- "Updated just now" text no longer stuck — footer now properly re-renders every second via `tickCount` dependency
- App now auto-fetches usage data on launch with retry (1s delay + retry on failure)
- Reduced Keychain access frequency to mitigate repeated password prompt — cached refresh token is used for HTTP renewal before falling back to Keychain
- Keychain password popup no longer appears — credentials are now read via a `/usr/bin/security` subprocess (the same path Claude Code CLI uses to write them) instead of `SecItemCopyMatching`, so the keychain item's creator and accessor always match; `make setup-keychain` removed as it is no longer needed
- DEBUG-only env var fallback now reads `CLAUDE_CODE_OAUTH_TOKEN` as documented (code previously read `CLAUDE_OAUTH_TOKEN`)

## [0.2.0] - 2026-03-31

### Added
- Liquid Glass UI components for macOS 26+ (`LiquidGlassModifier.swift`)
- Custom status bar icon (`icon_status_bar.png`)
- Glass card and glass chip view modifiers with macOS 14-15 fallback

## [0.1.0] - 2026-03-31

### Added
- Initial release
- macOS menu bar app showing Claude Pro/Max usage in real-time
- OAuth token auto-loading from macOS Keychain (Claude Code CLI credentials)
- Auto token refresh via `platform.claude.com/v1/oauth/token`
- 5-hour session, 7-day cap, 7-day Sonnet usage windows
- Optional OTel Prometheus metrics display (tokens, cost, sessions)
- Launch at login support via `SMAppService`
- `make install` / `make update` / `make uninstall` build system

[Unreleased]: https://github.com/cyb9701/ClaudeUsageBar/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/cyb9701/ClaudeUsageBar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/cyb9701/ClaudeUsageBar/releases/tag/v0.1.0
