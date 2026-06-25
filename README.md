# Router Online Monitor

<p align="center">
  <img src="docs/images/router-online-monitor-logo.svg" alt="Router Online Monitor app icon: white down and up arrows on a red background" width="180">
</p>

A native macOS menu-bar app for monitoring router Internet traffic. It connects directly to compatible FRITZ!Box routers through the TR-064 API, samples total WAN download and upload traffic, shows a graph for the retained history, and stores credentials in the macOS Keychain.

## Screenshots

<img src="docs/images/router-online-monitor-menubar.png" alt="Router Online Monitor menu bar" width="460">

<img src="docs/images/router-online-monitor-menu.png" alt="Router Online Monitor popover" width="500">

Requirements: macOS 13 or newer and Xcode (or the Xcode Command Line Tools).

## Installation

Download the latest `Router-Online-Monitor-macOS.zip` from the GitHub releases page and move `Router Online Monitor.app` to `/Applications`.

The release app is ad-hoc signed but not Apple-notarized. On first launch, macOS may still require Control-clicking the app and choosing Open. Full click-to-open distribution requires signing and notarizing with an Apple Developer ID certificate.

## Compatible FRITZ!Box models

Router Online Monitor works with FRITZ!Box routers that expose the TR-064 `WANCommonInterfaceConfig` service for WAN statistics. The current FRITZ!Box catalogue lists these compatible models:

### Fibre optic

- FRITZ!Box 5530 Fiber
- FRITZ!Box 5590 Fiber
- FRITZ!Box 5690
- FRITZ!Box 5690 Pro Int.
- FRITZ!Box 5690 XGS

### DSL and G.fast

- FRITZ!Box 7510
- FRITZ!Box 7530 AX
- FRITZ!Box 7590 AX
- FRITZ!Box 7630
- FRITZ!Box 7632
- FRITZ!Box 7682
- FRITZ!Box 7690
- FRITZ!Box 5690 Pro Int.
- FRITZ!Box 6890 LTE

### Cable

- FRITZ!Box 6670 Cable
- FRITZ!Box 6690 Cable

### Mobile network

- FRITZ!Box 6820 LTE
- FRITZ!Box 6825 4G
- FRITZ!Box 6850 LTE
- FRITZ!Box 6850 5G
- FRITZ!Box 6860 5G
- FRITZ!Box 6890 LTE

### Router for modem / network

- FRITZ!Box 4050
- FRITZ!Box 4630
- FRITZ!Box 4690

Older, discontinued, regional, or ISP-branded FRITZ!Box models may also work if TR-064 access is enabled and the router exposes `WANCommonInterfaceConfig` in `tr64desc.xml`.

Note: automatic line-rate detection uses the DSL-specific `WANDSLInterfaceConfig` service. On fibre, cable, mobile, or modem/network setups, traffic monitoring can still work, but capacity limits may need to be entered manually.

## Data model

- Sample interval: 10 seconds.
- Retention: 12 hours.
- Data source: FRITZ!Box TR-064 `WANCommonInterfaceConfig` byte counters.
- Scope: whole-router Internet traffic, not individual devices.

## Disclaimer

FRITZ!Box is a FRITZ! product. This independent project is not affiliated with, endorsed by, or sponsored by FRITZ!.
