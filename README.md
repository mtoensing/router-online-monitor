# FRITZ!Box Bandwidth Menu Bar

A native macOS menu-bar app which connects directly to the FRITZ!Box TR-064 API. It samples total WAN download and upload traffic, shows a graph for the retained history, and stores credentials in the macOS Keychain.

Requirements: macOS 13 or newer and Xcode (or the Xcode Command Line Tools).

## Run from source

```sh
swift run FritzBoxBandwidthMenuBar
```

Click the new up/down-arrows status item in the menu bar and enter the FRITZ!Box host, username, and password. The password is written only to Keychain; the graph history is stored at:

```text
~/Library/Application Support/FritzBoxBandwidth/samples.json
```

## Build an app bundle

```sh
sh scripts/build-app.sh
open FritzBoxBandwidth.app
```

The development bundle above is unsigned. For normal distribution or automatic launch at login, create an Xcode macOS App target and sign/notarize it with your Apple Developer identity.

## Data model

- Sample interval: 10 seconds.
- Retention: 12 hours.
- Data source: the FRITZ!Box TR-064 `WANCommonInterfaceConfig` byte counters.

## Disclaimer

FRITZ!Box is a FRITZ! product. This independent project is not affiliated with, endorsed by, or sponsored by FRITZ!.
- Scope: whole-router Internet traffic, not individual devices.
