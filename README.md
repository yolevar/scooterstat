# ⚡ Scooter BLE Monitor — Flutter App

Native App für iOS & Android zum Auslesen von Ninebot/Xiaomi Scooter Telemetriedaten via Bluetooth.

## Funktionen
- BLE-Scan mit Geräteliste und Signalstärke
- Live-Telemetrie: Geschwindigkeit, Motortemperatur, Akku, Spannung, Strom
- RAW HEX-Anzeige für Debugging
- Funktioniert auf iPhone & Android

---

## Setup (einmalig)

### 1. Flutter installieren
https://flutter.dev/docs/get-started/install

### 2. Abhängigkeiten installieren
```bash
cd scooter_app
flutter pub get
```

### 3. App starten

**Android (USB-Debugging aktiviert):**
```bash
flutter run
```

**iOS (Mac + Xcode nötig):**
```bash
cd ios
pod install
cd ..
flutter run
```

---

## Als APK bauen (Android, kein PC nötig nach dem Bauen)
```bash
flutter build apk --release
# APK liegt in: build/app/outputs/flutter-apk/app-release.apk
```

## Als IPA bauen (iOS, Mac + Apple Developer Account nötig)
```bash
flutter build ipa
```

---

## Hinweise zum Protokoll

Das Ninebot/Xiaomi UART-Protokoll verwendet folgende UUIDs:
- **Service:**  `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- **TX (Senden):** `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- **RX (Empfangen):** `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

Telemetrie-Offsets (M365/G30, firmware-abhängig):
| Byte | Wert |
|------|------|
| 14   | Akku % |
| 18-19 | Strom (Int16, /100) |
| 20-21 | Spannung (UInt16, /100) |
| 24-25 | Geschwindigkeit (UInt16, /1000) |
| 28   | Motortemperatur °C |

Bei anderen Firmware-Versionen → RAW HEX-Anzeige nutzen und Offsets in `main.dart` in der Funktion `copyWith()` anpassen.
