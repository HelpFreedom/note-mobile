// Обнаружение пиров в локальной сети по mDNS (плагин nsd, как discovery.py).
// Анонсируем сервис `_qtnotes._tcp` с device_id/именем в TXT и слушаем появление/
// исчезновение пиров. Свой сервис из выдачи отфильтровывается.
//
// Тестируется только компиляцией: nsd — нативный плагин (работает на устройстве).

import 'dart:convert';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import 'identity.dart';

const String serviceType = '_qtnotes._tcp';

class FoundPeer {
  final String deviceId;
  final String name;
  final String host;
  final int port;
  FoundPeer(this.deviceId, this.name, this.host, this.port);
}

class Discovery {
  final Identity identity;
  final int port;
  final void Function(FoundPeer)? onFound;
  final void Function(String deviceId)? onLost;

  nsd.Registration? _reg;
  nsd.Discovery? _disc;

  Discovery(this.identity, this.port, {this.onFound, this.onLost});

  Future<void> start() async {
    _reg = await nsd.register(nsd.Service(
      name: identity.deviceId,
      type: serviceType,
      port: port,
      txt: {
        'id': _bytes(identity.deviceId),
        'name': _bytes(identity.name),
      },
    ));
    _disc = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
    _disc!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        final peer = _parse(service);
        if (peer != null) onFound?.call(peer);
      } else if (status == nsd.ServiceStatus.lost) {
        final id = _txt(service, 'id');
        if (id != null && id != identity.deviceId) onLost?.call(id);
      }
    });
  }

  Future<void> stop() async {
    final d = _disc;
    final r = _reg;
    _disc = null;
    _reg = null;
    if (d != null) await nsd.stopDiscovery(d);
    if (r != null) await nsd.unregister(r);
  }

  Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

  String? _txt(nsd.Service s, String key) {
    final v = s.txt?[key];
    return v == null ? null : utf8.decode(v);
  }

  FoundPeer? _parse(nsd.Service s) {
    final did = _txt(s, 'id');
    if (did == null || did == identity.deviceId) return null; // свой/без id
    final host = (s.addresses != null && s.addresses!.isNotEmpty)
        ? s.addresses!.first.address
        : s.host;
    final port = s.port;
    if (host == null || port == null) return null;
    return FoundPeer(did, _txt(s, 'name') ?? '', host, port);
  }
}
