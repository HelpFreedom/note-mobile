// Аппаратный гейт ПИНа (зеркало qtnotes/crypto/hwbackend.py).
//
// HardwareKey.mac(salt, pin) считает MAC на неизвлекаемом ключе. ПИН — вход MAC, не
// auth ключа, поэтому различение прямой/обратный/неверный остаётся в app-логике.
//
// - SoftwareHardwareKey — имитация для тестов и переходного периода.
// - KeystoreHardwareKey (Ф5b) — боевой бэкенд через Android Keystore.

import 'dart:convert';
import 'dart:typed_data';

import 'primitives.dart' as primitives;

abstract class HardwareKey {
  /// Детерминированный MAC от (salt, pin). Одинаковые входы → одинаковый результат.
  Future<Uint8List> mac(Uint8List salt, String pin);
}

class SoftwareHardwareKey implements HardwareKey {
  final Uint8List _deviceKey;
  SoftwareHardwareKey(this._deviceKey);

  factory SoftwareHardwareKey.generate() =>
      SoftwareHardwareKey(primitives.randomBytes(32));

  @override
  Future<Uint8List> mac(Uint8List salt, String pin) async {
    final msg = Uint8List.fromList([...salt, ...utf8.encode(pin)]);
    return primitives.hmacSha256(_deviceKey, msg);
  }
}
