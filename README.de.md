# Router Online Monitor

[English](README.md) | [Deutsch](README.de.md)

<p align="center">
  <img src="docs/images/router-online-monitor-logo.svg" alt="Router Online Monitor App-Icon: weiße Pfeile für Download und Upload auf rotem Hintergrund" width="180">
</p>

Eine native macOS-Menüleisten-App zum Überwachen des Internetverkehrs am Router. Sie verbindet sich direkt über die TR-064-API mit kompatiblen FRITZ!Box-Routern, erfasst den gesamten WAN-Download- und Upload-Traffic, zeigt ein Diagramm für den gespeicherten Verlauf und legt Zugangsdaten im macOS-Schlüsselbund ab.

## Screenshots

<img src="docs/images/router-online-monitor-menubar.png" alt="Router Online Monitor in der Menüleiste" width="460">

<img src="docs/images/router-online-monitor-menu.png" alt="Router Online Monitor Popover" width="500">

Voraussetzungen: macOS 13 oder neuer und Xcode oder die Xcode Command Line Tools.

## Installation

Lade die aktuelle `Router-Online-Monitor-macOS.zip` von der GitHub-Releases-Seite herunter und verschiebe `Router Online Monitor.app` nach `/Applications`.

Router Online Monitor ist Open Source und wird derzeit ohne Apple-Notarisierung veröffentlicht. Das App-Bundle ist ad-hoc signiert, aber macOS kann den ersten Start trotzdem mit der Meldung blockieren, dass Apple nicht prüfen konnte, ob die App frei von Malware ist.

Wenn du dem heruntergeladenen Release vertraust, nutze eine dieser Optionen für den ersten Start:

### Option 1: In den Systemeinstellungen erlauben

1. Öffne `Router Online Monitor.app` einmal.
2. Wenn macOS die App blockiert, wähle Fertig oder Abbrechen.
3. Öffne die Systemeinstellungen.
4. Gehe zu Datenschutz & Sicherheit.
5. Scrolle zum Abschnitt Sicherheit.
6. Klicke bei Router Online Monitor auf Dennoch öffnen.
7. Bestätige mit Öffnen.

### Option 2: Quarantäne-Attribut entfernen

Führe nach dem Verschieben der App nach `/Applications` diesen Befehl aus:

```sh
xattr -dr com.apple.quarantine "/Applications/Router Online Monitor.app"
```

Starte die App danach erneut.

Eine vollständig warnungsfreie Verteilung würde ein Apple Developer ID-Zertifikat und Apple-Notarisierung erfordern.

## Kompatible FRITZ!Box-Modelle

Router Online Monitor funktioniert mit FRITZ!Box-Routern, die den TR-064-Dienst `WANCommonInterfaceConfig` für WAN-Statistiken bereitstellen. Der aktuelle FRITZ!Box-Katalog listet diese kompatiblen Modelle:

### Glasfaser

- FRITZ!Box 5530 Fiber
- FRITZ!Box 5590 Fiber
- FRITZ!Box 5690
- FRITZ!Box 5690 Pro Int.
- FRITZ!Box 5690 XGS

### DSL und G.fast

- FRITZ!Box 7510
- FRITZ!Box 7530 AX
- FRITZ!Box 7590 AX
- FRITZ!Box 7630
- FRITZ!Box 7632
- FRITZ!Box 7682
- FRITZ!Box 7690
- FRITZ!Box 5690 Pro Int.
- FRITZ!Box 6890 LTE

### Kabel

- FRITZ!Box 6670 Cable
- FRITZ!Box 6690 Cable

### Mobilfunk

- FRITZ!Box 6820 LTE
- FRITZ!Box 6825 4G
- FRITZ!Box 6850 LTE
- FRITZ!Box 6850 5G
- FRITZ!Box 6860 5G
- FRITZ!Box 6890 LTE

### Router für Modem / Netzwerk

- FRITZ!Box 4050
- FRITZ!Box 4630
- FRITZ!Box 4690

Ältere, eingestellte, regionale oder vom Internetanbieter gebrandete FRITZ!Box-Modelle können ebenfalls funktionieren, wenn TR-064-Zugriff aktiviert ist und der Router `WANCommonInterfaceConfig` in `tr64desc.xml` bereitstellt.

Hinweis: Die automatische Erkennung der Leitungskapazität nutzt den DSL-spezifischen Dienst `WANDSLInterfaceConfig`. Bei Glasfaser-, Kabel-, Mobilfunk- oder Modem/Netzwerk-Setups kann die Traffic-Überwachung trotzdem funktionieren, aber Kapazitätsgrenzen müssen eventuell manuell eingetragen werden.

## Datenmodell

- Abtastintervall: standardmäßig 5 Sekunden; in den versteckten Polling-Einstellungen konfigurierbar.
- Aufbewahrung: 12 Stunden.
- Datenquelle: FRITZ!Box TR-064-Bytezähler von `WANCommonInterfaceConfig`.
- Umfang: Internetverkehr des gesamten Routers, nicht einzelner Geräte.
- Kapazitätsbehandlung: Wenn Kapazitätsgrenzen konfiguriert oder vom Router erkannt wurden, werden angezeigte Raten auf diese Grenzen begrenzt, um unmögliche Ausschläge durch störungsanfällige Router-Zählerupdates zu unterdrücken.

## Hinweis

FRITZ!Box ist ein FRITZ!-Produkt. Dieses unabhängige Projekt ist nicht mit FRITZ! verbunden, wird nicht von FRITZ! unterstützt und nicht von FRITZ! gesponsert.
