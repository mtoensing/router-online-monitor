# Router Online Monitor workspace notes

## Confirmed connectivity

- FRITZ!Box web interface: `http://192.168.178.1/` (HTTP 200 observed).
- TR-064 discovery document: `http://192.168.178.1:49000/tr64desc.xml` (HTTP 200 observed).
- The HTTPS TR-064 endpoint at `https://192.168.178.1:49443/tr64desc.xml` presents a self-signed certificate.

## API access

TR-064 is available on the local network. Reading protected data or changing router configuration requires FRITZ!Box credentials; do not store credentials in this repository.

## Git workflow

- Push completed changes directly to `main`. Do not create pull requests.
- Ignore `.DS_Store` files in all status checks, reviews, commits, and other repository work.
- Always create new app versions through the `Release new version` GitHub Actions workflow. Do not manually edit release version files, create release commits, create version tags, or publish GitHub Releases unless repairing a failed workflow run.
- For releasable work, first push the completed non-version changes to `main`, then trigger the release-version action. The action must increment the semantic version, increment `CFBundleVersion`, update the visible in-app version label, commit directly to `main`, create the matching `v*` tag, build the app artifact, ad-hoc sign it, and publish the GitHub Release.
- Every version tag must produce a GitHub Release with the matching tag and the GitHub Actions-built app artifact before the work is complete. Releases are intentionally not Apple-notarized unless Apple Developer ID credentials are explicitly added later; release notes must include the Gatekeeper quarantine workaround.

## macOS app design

- Follow Apple’s Human Interface Guidelines for macOS. Use native SwiftUI/AppKit controls, system typography and system colors rather than custom imitations.
- Prefer native SwiftUI/AppKit solutions first, and reuse the existing code and local patterns as much as possible before introducing custom layout, controls, or new abstractions.
- Prefer clear hierarchy, familiar macOS menu-bar and settings patterns, and concise action labels.
- Windows must adapt to their content: provide adequate content margins and minimum sizes, allow text to wrap where appropriate, and verify that no label, control, or helper text is clipped at the supported window sizes.
- Keep configuration in a standard `Form` with meaningful sections and only show controls that are relevant to the selected mode.
- For this menu-bar app, show monitoring controls and configuration in one native transient popover. Do not place editable controls inside a standard `NSMenu`, and do not require a separate Settings window or nested submenu for routine configuration.
- For charts, use high-contrast semantic system colors and redundant encoding such as solid versus dashed lines. Do not rely on color alone; reserve system red for the near-capacity warning.
- Every GitHub release must increment the semantic version and update both `CFBundleShortVersionString` and the visible in-app version label; increment `CFBundleVersion` for each release build.
