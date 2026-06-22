# QtNotes Mobile

[Русская версия](README.md)

A **Flutter / Android** companion to [QtNotes Desktop](../qtnotes-desktop) — a
Telegram-style notes app where folders are chats and notes are messages.

It is **offline-first** (no servers, no telemetry) and speaks the exact same
peer-to-peer sync protocol and on-disk crypto format as the desktop app, so your phone
and your computer converge to the same notes over your local network.

> Desktop app (PySide6 / Qt 6): **[qtnotes-desktop](../qtnotes-desktop)**.

---

## Features

- **Folders as chats, notes as messages** — the same mental model as the desktop app.
- Text and rich-text notes, image and file attachments, captions.
- **Peer-to-peer sync** with the desktop and other phones:
  - mutual-TLS with certificate pinning, **mDNS** discovery, **QR pairing**;
  - append-only **operation log** with **version vectors** and last-writer-wins;
  - deletions are tombstoned; a cross-language conformance suite keeps phone and
    desktop semantics byte-compatible.
- **Local encryption** behind a PIN:
  - whole-vault **AES-256-GCM** (per-file subkeys via HKDF);
  - hardware gate via the **Android Keystore** (StrongBox-backed where available),
    with an integrity-MAC over the keyring;
  - optional **biometric binding** — the gate key requires user authentication and an
    unlocked device, so a stolen, locked device cannot be brute-forced offline;
  - a **duress** mode (reverse PIN) that crypto-erases the keyring, wipes owned paths
    and shows decoy notes.
- **Lock-on-background**: the master key is forgotten and the decrypted media cache is
  wiped whenever the app leaves the foreground.
- **`FLAG_SECURE`** (no screenshots, blank thumbnail in the recents switcher) and
  clipboard marked sensitive on Android 13+.

---

## Requirements

- The [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel) with
  the Dart SDK it bundles.
- Android SDK / a device or emulator (developed against a physical Android device).

## Build & run

```bash
flutter pub get

# run on a connected device / emulator
flutter run

# release APK (obfuscated, with split debug symbols)
flutter build apk --release --obfuscate --split-debug-info=build/symbols
# -> build/app/outputs/flutter-apk/app-release.apk
```

> Release signing uses Flutter's debug keystore by default. For a real release,
> configure your own signing key in `android/` (do **not** commit keystores or
> `key.properties`).

## Tests

The pure-Dart logic (sync, oplog, crypto, storage, search) runs **headless** with the
plain Dart test runner — no device or emulator needed:

```bash
dart test                              # whole suite
dart test test/sync_tombstones_test.dart   # a single file
```

The cross-language conformance tests (`golden_conformance_test.dart`,
`convergence_conformance_test.dart`) are driven by the desktop project's Python harness
when both projects are present; on their own they are skipped.

## Project structure

```
lib/
  main.dart
  app/        app_service (lifecycle, lock/unlock, engine), repository
  storage/    models, vault, search_index, notes cache
  sync/       engine, oplog, apply, wire, transport, discovery, pairing, identity
  crypto/     unlock, keyvault, keystore, crypto_fs, blob_crypto, duress, primitives
  ui/         screens and widgets (chat, folders, calendar, search, sync, pin)
android/      Kotlin host (Keystore HMAC gate, FLAG_SECURE, sensitive clipboard)
test/         headless Dart logic + conformance tests
```

---

## Security note

This is a personal project, not a professionally audited security product. The
encryption and duress features are **defense-in-depth**, aimed mainly at device theft
and coercion while the device is locked. Once an attacker has root on a device where the
app is currently unlocked, the key is in memory and no software scheme can protect it.
Hardware guarantees (StrongBox, rollback-resistant counters) vary by device. Do not rely
on this app as the sole protection for life-critical secrets without your own review.

If you find a security issue, please open an issue (or report privately if you prefer).

## License

[GNU GPL v3.0](LICENSE) — you may use, study, modify and redistribute it, but
derivative works must also be released under the GPL.
