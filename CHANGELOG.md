# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [1.0.0] — Initial public release

First open-source release of the QtNotes mobile (Flutter/Android) companion app.

### Added
- Telegram-style notes UI mirroring the desktop app: folders-as-chats, notes-as-messages.
- Text and rich-text notes with image/file attachments and captions.
- Peer-to-peer sync compatible with QtNotes Desktop: mutual-TLS, mDNS discovery, QR
  pairing, operation log with version vectors, last-writer-wins, tombstones. Wire and
  crypto formats are conformance-tested against the desktop implementation.
- Local encryption behind a PIN: AES-256-GCM whole-vault, Android Keystore hardware gate
  (StrongBox where available) with a keyring integrity-MAC.
- Optional biometric binding: the gate key requires user authentication and an unlocked
  device, plus invalidation on new biometric enrollment.
- Duress mode: reverse-PIN crypto-erase + owned-paths wipe + decoy notes.
- Lock-on-background (master key forgotten, decrypted media cache wiped on leaving the
  foreground), `FLAG_SECURE`, and sensitive-clipboard marking on Android 13+.
- Headless Dart test suite (`dart test`) covering sync, oplog, crypto, storage, search,
  and Python↔Dart conformance.

[1.0.0]: https://example.com/releases/v1.0.0
