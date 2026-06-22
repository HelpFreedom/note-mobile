// Доверенные (сопряжённые) устройства — trust-store в peers.json.
// Формат идентичен десктопу (qtnotes/sync/peers.py): список объектов
// {device_id, name, cert_pem, paired_at}.

import 'dart:convert';
import 'dart:io';

import '../storage/models.dart' show nowIso;

class Peer {
  final String deviceId;
  final String name;
  final String certPem;
  final String pairedAt;
  Peer(this.deviceId, this.name, this.certPem, this.pairedAt);

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'name': name,
        'cert_pem': certPem,
        'paired_at': pairedAt,
      };

  factory Peer.fromJson(Map<String, dynamic> d) => Peer(
        d['device_id'] as String,
        (d['name'] ?? '') as String,
        (d['cert_pem'] ?? '') as String,
        (d['paired_at'] ?? '') as String,
      );
}

class PeerStore {
  final File file;
  PeerStore(this.file);

  Future<List<Peer>> list() async {
    try {
      if (!await file.exists()) return [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return [];
      return data.map((e) => Peer.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Peer> peers) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(peers.map((p) => p.toJson()).toList()));
    await tmp.rename(file.path);
  }

  Future<Peer?> get(String deviceId) async {
    for (final p in await list()) {
      if (p.deviceId == deviceId) return p;
    }
    return null;
  }

  Future<bool> isTrusted(String deviceId) async => (await get(deviceId)) != null;

  Future<Peer> add(String deviceId, String name, String certPem) async {
    final peers = (await list()).where((p) => p.deviceId != deviceId).toList();
    final peer = Peer(deviceId, name, certPem, nowIso());
    peers.add(peer);
    await _save(peers);
    return peer;
  }

  Future<void> remove(String deviceId) async {
    await _save((await list()).where((p) => p.deviceId != deviceId).toList());
  }
}
