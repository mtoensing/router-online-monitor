# Router Online Monitor

<p align="center">
  <img src="docs/images/router-online-monitor-logo.svg" alt="Router Online Monitor app icon: white lightning bolt on a red background" width="180">
</p>

A native macOS menu-bar app for monitoring router Internet traffic. It connects directly to compatible FRITZ!Box routers through the TR-064 API, samples total WAN download and upload traffic, shows a graph for the retained history, and stores credentials in the macOS Keychain.

## Screenshots

<img src="docs/images/router-online-monitor-menubar.png" alt="Router Online Monitor menu bar" width="460">

<img src="docs/images/router-online-monitor-menu.png" alt="Router Online Monitor popover" width="500">

Requirements: macOS 13 or newer and Xcode (or the Xcode Command Line Tools).

The development bundle above is unsigned. For normal distribution or automatic launch at login, create an Xcode macOS App target and sign/notarize it with your Apple Developer identity.

## Data model

- Sample interval: 10 seconds.
- Retention: 12 hours.
- Data source: FRITZ!Box TR-064 `WANCommonInterfaceConfig` byte counters.
- Scope: whole-router Internet traffic, not individual devices.

## Disclaimer

FRITZ!Box is a FRITZ! product. This independent project is not affiliated with, endorsed by, or sponsored by FRITZ!.
