import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2p_mesh/mesh_engine.dart';
import 'package:p2p_mesh/mayak_dht.dart';

void main() {
  group('MeshEngine.parseEndpoint', () {
    test('parses IPv4 with port', () {
      final ep = MeshEngine.parseEndpoint('192.168.1.15:42070');
      expect(ep.host, '192.168.1.15');
      expect(ep.port, 42070);
      expect(ep.isUdp, false);
    });

    test('parses udp:IPv4:port without returning literal udp host', () {
      final ep = MeshEngine.parseEndpoint('udp:91.78.175.77:14782');
      expect(ep.host, '91.78.175.77');
      expect(ep.port, 14782);
      expect(ep.isUdp, true);
    });

    test('parses bracketed IPv6 and bare IPv6 safely', () {
      final ep1 = MeshEngine.parseEndpoint('[2a03:6f00:1::1]:42070');
      expect(ep1.host, '2a03:6f00:1::1');
      expect(ep1.port, 42070);

      final ep2 = MeshEngine.parseEndpoint('2a03:6f00:1::1');
      expect(ep2.host, '2a03:6f00:1::1');
      expect(ep2.port, 42070);
    });

    test('rejects BLE and Mesh labels', () {
      expect(MeshEngine.parseEndpoint('BLE:AA:BB').host, '');
      expect(MeshEngine.parseEndpoint('Через Mesh').host, '');
    });
  });

  group('MeshEngine.isPrivateLanIpv4', () {
    test('detects RFC1918 LAN IPv4 only', () {
      expect(MeshEngine.isPrivateLanIpv4('192.168.0.10'), true);
      expect(MeshEngine.isPrivateLanIpv4('10.0.0.5'), true);
      expect(MeshEngine.isPrivateLanIpv4('91.78.175.77'), false);
      expect(MeshEngine.isPrivateLanIpv4('udp'), false);
      expect(MeshEngine.isPrivateLanIpv4('2a03:6f00::1'), false);
    });
  });

  group('MayakDhtClient PEX', () {
    test('imports and exports external IPv4 DHT nodes', () {
      final dht = MayakDhtClient(getSocket: () => null, onLog: (_) {});
      final fakeId = base64Encode(Uint8List.fromList(List.filled(20, 7)));
      final added = dht.importExternalNodes([
        {'ip': '91.78.175.77', 'p': 14782, 'id': fakeId},
        {'ip': '2a03::1', 'p': 6881, 'id': fakeId}, // IPv6 must be skipped
      ]);
      expect(added, 1);
      expect(dht.knownNodesCount, 1);
      final exported = dht.exportActiveNodes(limit: 10);
      expect(exported.length, 1);
      expect(exported.first['ip'], '91.78.175.77');
    });
  });
}
