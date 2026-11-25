import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Статический Маяк-ID без привязки к IP:
/// 38 байт = Ed25519_pub(32) + nospam(4) + CRC16-CCITT(2) -> ровно 61 символ Crockford Base32
class MayakStaticId {
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static int crc16Ccitt(List<int> data) {
    int crc = 0xFFFF;
    for (final b in data) {
      crc ^= (b & 0xFF) << 8;
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }

  static String encodeCrockford(Uint8List bytes) {
    final sb = StringBuffer();
    int buffer = 0;
    int bitsLeft = 0;
    for (final b in bytes) {
      buffer = (buffer << 8) | (b & 0xFF);
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        sb.write(_alphabet[(buffer >> bitsLeft) & 0x1F]);
      }
    }
    if (bitsLeft > 0) {
      sb.write(_alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return sb.toString();
  }

  static Uint8List? decodeCrockford(String raw) {
    final clean = raw
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-_]'), '')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('O', '0');
    if (clean.isEmpty) return null;
    final out = <int>[];
    int buffer = 0;
    int bitsLeft = 0;
    for (int i = 0; i < clean.length; i++) {
      final idx = _alphabet.indexOf(clean[i]);
      if (idx < 0) return null;
      buffer = (buffer << 5) | idx;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        out.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    return Uint8List.fromList(out);
  }

  static String formatGrouped(String raw61) {
    final sb = StringBuffer();
    for (int i = 0; i < raw61.length; i++) {
      if (i > 0 && i % 5 == 0) sb.write('-');
      sb.write(raw61[i]);
    }
    return sb.toString();
  }

  static String buildFromPubAndNospam(Uint8List ed25519Pub32, Uint8List nospam4) {
    if (ed25519Pub32.length != 32 || nospam4.length != 4) return '';
    final payload = Uint8List(38);
    payload.setRange(0, 32, ed25519Pub32);
    payload.setRange(32, 36, nospam4);
    final crc = crc16Ccitt(payload.sublist(0, 36));
    payload[36] = (crc >> 8) & 0xFF;
    payload[37] = crc & 0xFF;
    return formatGrouped(encodeCrockford(payload));
  }

  static ({Uint8List ed25519Pub, Uint8List nospam})? parse(String input) {
    var s = input.trim();
    if (s.startsWith('mayak://id/')) {
      s = s.substring(11);
    }
    final bytes = decodeCrockford(s);
    if (bytes == null || bytes.length != 38) return null;
    final expectedCrc = crc16Ccitt(bytes.sublist(0, 36));
    final actualCrc = ((bytes[36] & 0xFF) << 8) | (bytes[37] & 0xFF);
    if (expectedCrc != actualCrc) return null;
    return (
      ed25519Pub: Uint8List.fromList(bytes.sublist(0, 32)),
      nospam: Uint8List.fromList(bytes.sublist(32, 36)),
    );
  }
}

/// Строгий канонический Bencode поверх Uint8List (лексикографическая сортировка ключей без UTF-8 искажений)
class MayakBencode {
  static Uint8List encode(dynamic value) {
    final bb = BytesBuilder(copy: false);
    _encodeInto(value, bb);
    return bb.toBytes();
  }

  static void _encodeInto(dynamic v, BytesBuilder bb) {
    if (v is int) {
      bb.add(ascii.encode('i${v}e'));
    } else if (v is Uint8List) {
      bb.add(ascii.encode('${v.length}:'));
      bb.add(v);
    } else if (v is String) {
      final raw = utf8.encode(v);
      bb.add(ascii.encode('${raw.length}:'));
      bb.add(raw);
    } else if (v is List) {
      bb.addByte(0x6C); // 'l'
      for (final item in v) {
        _encodeInto(item, bb);
      }
      bb.addByte(0x65); // 'e'
    } else if (v is Map) {
      bb.addByte(0x64); // 'd'
      final entries = v.entries
          .map((e) => MapEntry(
                e.key is Uint8List ? e.key as Uint8List : Uint8List.fromList(utf8.encode(e.key.toString())),
                e.value,
              ))
          .toList()
        ..sort((a, b) => _compareBytes(a.key, b.key));
      for (final e in entries) {
        bb.add(ascii.encode('${e.key.length}:'));
        bb.add(e.key);
        _encodeInto(e.value, bb);
      }
      bb.addByte(0x65); // 'e'
    } else {
      throw ArgumentError('Unsupported bencode type: ${v.runtimeType}');
    }
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final m = min(a.length, b.length);
    for (int i = 0; i < m; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  static dynamic decode(Uint8List data) {
    final state = _DecState(data);
    return _decodeNext(state);
  }

  static dynamic _decodeNext(_DecState st) {
    if (st.pos >= st.data.length) return null;
    final b = st.data[st.pos];
    if (b == 0x69) {
      // 'i' integer
      st.pos++;
      final end = st.data.indexOf(0x65, st.pos);
      if (end < 0) return null;
      final numStr = ascii.decode(st.data.sublist(st.pos, end));
      st.pos = end + 1;
      return int.tryParse(numStr) ?? 0;
    } else if (b == 0x6C) {
      // 'l' list
      st.pos++;
      final list = <dynamic>[];
      while (st.pos < st.data.length && st.data[st.pos] != 0x65) {
        final item = _decodeNext(st);
        if (item == null) break;
        list.add(item);
      }
      if (st.pos < st.data.length && st.data[st.pos] == 0x65) st.pos++;
      return list;
    } else if (b == 0x64) {
      // 'd' dict
      st.pos++;
      final map = <String, dynamic>{};
      while (st.pos < st.data.length && st.data[st.pos] != 0x65) {
        final kRaw = _decodeNext(st);
        if (kRaw is! Uint8List) break;
        final kStr = utf8.decode(kRaw, allowMalformed: true);
        final val = _decodeNext(st);
        map[kStr] = val;
      }
      if (st.pos < st.data.length && st.data[st.pos] == 0x65) st.pos++;
      return map;
    } else if (b >= 0x30 && b <= 0x39) {
      // byte string
      final colon = st.data.indexOf(0x3A, st.pos);
      if (colon < 0) return null;
      final len = int.tryParse(ascii.decode(st.data.sublist(st.pos, colon))) ?? -1;
      if (len < 0 || colon + 1 + len > st.data.length) return null;
      final start = colon + 1;
      st.pos = start + len;
      return Uint8List.fromList(st.data.sublist(start, st.pos));
    }
    return null;
  }
}

class _DecState {
  final Uint8List data;
  int pos = 0;
  _DecState(this.data);
}

/// BEP-42 CRC32C (Castagnoli 0x82F63B78) генерация NodeID
class MayakBep42 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final t = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? ((crc >>> 1) ^ 0x82F63B78) : (crc >>> 1);
      }
      t[i] = crc;
    }
    return t;
  }

  static int crc32c(Uint8List bytes) {
    int crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint8List generateNodeIdForIpv4(String ipv4Str) {
    final rnd = Random.secure();
    final id = Uint8List.fromList(List.generate(20, (_) => rnd.nextInt(256)));
    final parts = ipv4Str.split('.');
    if (parts.length != 4) return id;
    final b0 = int.tryParse(parts[0]) ?? 0;
    final b1 = int.tryParse(parts[1]) ?? 0;
    final b2 = int.tryParse(parts[2]) ?? 0;
    final b3 = int.tryParse(parts[3]) ?? 0;
    final rByte = rnd.nextInt(256);
    final r = rByte & 0x07;
    final masked = Uint8List.fromList([
      (b0 & 0x03) | (r << 5),
      b1 & 0x0F,
      b2 & 0x3F,
      b3 & 0xFF,
    ]);
    final c = crc32c(masked);
    id[0] = (c >>> 24) & 0xFF;
    id[1] = (c >>> 16) & 0xFF;
    id[2] = ((c >>> 8) & 0xF8) | (rnd.nextInt(8) & 0x07);
    id[19] = rByte;
    return id;
  }
}

/// Локальный CIDR-фильтр (защита от 10-минутной коллатеральной блокировки ТСПУ на Scaleway/GlobalTeleHost и bogon-адресов)
class MayakCidrFilter {
  static final List<(int net, int mask)> _blockedIpv4 = [
    // Уровень 1: Безусловный блок-лист DHT UDP (триггеры 10-мин блока ТСПУ)
    _cidr('62.210.0.0', 17),   // Scaleway AS12876
    _cidr('51.159.0.0', 16),   // Scaleway AS12876
    _cidr('134.195.196.0', 22), // GlobalTeleHost AS62563
    // Уровень 3: Приватные, CGNAT и bogon подсети
    _cidr('0.0.0.0', 8),
    _cidr('10.0.0.0', 8),
    _cidr('100.64.0.0', 10),
    _cidr('127.0.0.0', 8),
    _cidr('169.254.0.0', 16),
    _cidr('172.16.0.0', 12),
    _cidr('192.168.0.0', 16),
    _cidr('224.0.0.0', 4),
    _cidr('240.0.0.0', 4),
  ];

  static (int, int) _cidr(String ip, int prefix) {
    final p = ip.split('.').map(int.parse).toList();
    final ipInt = ((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]) & 0xFFFFFFFF;
    final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return (ipInt & mask, mask);
  }

  static bool isBlockedIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return true;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    final d = int.tryParse(parts[3]);
    if (a == null || b == null || c == null || d == null) return true;
    final ipInt = ((a << 24) | (b << 16) | (c << 8) | d) & 0xFFFFFFFF;
    for (final rule in _blockedIpv4) {
      if ((ipInt & rule.$2) == rule.$1) return true;
    }
    return false;
  }
}

class DhtNodeInfo {
  final Uint8List id;
  final String ip;
  final int port;
  int lastSeenMs;

  DhtNodeInfo({
    required this.id,
    required this.ip,
    required this.port,
    required this.lastSeenMs,
  });

  String get key => '$ip:$port';
}

class Bep44GetResult {
  final Uint8List value;
  final int seq;
  final Uint8List publicKey;

  const Bep44GetResult({
    required this.value,
    required this.seq,
    required this.publicKey,
  });
}

/// Компактный клиент Mainline DHT (BEP-5 + BEP-42 + BEP-43 ro=1 + BEP-44 get/put)
/// Делит один общий RawDatagramSocket с P2P-движком (демультиплекс по byte[0] == 0x64 'd')
class MayakDhtClient {
  final RawDatagramSocket? Function() getSocket;
  final void Function(String msg) onLog;

  static const List<(String, int)> bootstrapNodes = [
    ('dht.transmissionbt.com', 6881),
    ('dht.libtorrent.org', 25401),
    ('router.bittorrent.com', 6881),
    ('router.utorrent.com', 6881),
    ('router.bitcomet.com', 6881),
  ];

  Uint8List _ownNodeId = Uint8List.fromList(
    List.generate(20, (_) => Random.secure().nextInt(256)),
  );
  bool _bep42Applied = false;
  final Map<String, DhtNodeInfo> _nodes = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingTx = {};
  int _txSeq = 1;
  bool isBootstrapping = false;
  final Sha1 _sha1 = Sha1();
  final Ed25519 _ed25519 = Ed25519();

  MayakDhtClient({required this.getSocket, required this.onLog});

  int get knownNodesCount => _nodes.length;

  List<String> exportCachedNodes({int limit = 120}) {
    final sorted = _nodes.values.toList()
      ..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return sorted.take(limit).map((n) {
      final idHex = n.id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return '$idHex|${n.ip}|${n.port}';
    }).toList();
  }

  void importCachedNodes(List<String> lines) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final line in lines) {
      final p = line.split('|');
      if (p.length != 3) continue;
      final idHex = p[0];
      final ip = p[1];
      final port = int.tryParse(p[2]) ?? 0;
      if (idHex.length != 40 || port <= 0 || MayakCidrFilter.isBlockedIpv4(ip)) continue;
      final idBytes = Uint8List(20);
      for (int i = 0; i < 20; i++) {
        idBytes[i] = int.tryParse(idHex.substring(i * 2, i * 2 + 2), radix: 16) ?? 0;
      }
      _nodes['$ip:$port'] = DhtNodeInfo(id: idBytes, ip: ip, port: port, lastSeenMs: now);
    }
  }

  /// Вызывается из _onCallUdpDatagram при dg.data[0] == 0x64 ('d')
  void handleIncomingDatagram(Datagram dg) {
    try {
      final decoded = MayakBencode.decode(dg.data);
      if (decoded is! Map<String, dynamic>) return;
      final yRaw = decoded['y'];
      final y = yRaw is Uint8List ? utf8.decode(yRaw, allowMalformed: true) : '';
      if (y != 'r' && y != 'e') return;

      // BEP-42: если роутер вернул наш внешний IP, один раз привязываем NodeID
      final ipRaw = decoded['ip'];
      if (!_bep42Applied && ipRaw is Uint8List && ipRaw.length == 6) {
        final extIp = '${ipRaw[0]}.${ipRaw[1]}.${ipRaw[2]}.${ipRaw[3]}';
        if (!MayakCidrFilter.isBlockedIpv4(extIp)) {
          _ownNodeId = MayakBep42.generateNodeIdForIpv4(extIp);
          _bep42Applied = true;
        }
      }

      final tRaw = decoded['t'];
      if (tRaw is! Uint8List) return;
      final txKey = base64Encode(tRaw);
      final comp = _pendingTx.remove(txKey);

      final r = decoded['r'];
      if (r is Map<String, dynamic>) {
        final rId = r['id'];
        if (rId is Uint8List && rId.length == 20 && !MayakCidrFilter.isBlockedIpv4(dg.address.address)) {
          _addNode(DhtNodeInfo(
            id: rId,
            ip: dg.address.address,
            port: dg.port,
            lastSeenMs: DateTime.now().millisecondsSinceEpoch,
          ));
        }
        final nodesRaw = r['nodes'];
        if (nodesRaw is Uint8List) {
          _parseCompactNodes(nodesRaw);
        }
      }

      if (comp != null && !comp.isCompleted) {
        comp.complete(decoded);
      }
    } catch (_) {}
  }

  void _addNode(DhtNodeInfo n) {
    if (MayakCidrFilter.isBlockedIpv4(n.ip) || n.port <= 0) return;
    _nodes[n.key] = n;
    if (_nodes.length > 260) {
      final oldest = _nodes.values.reduce((a, b) => a.lastSeenMs < b.lastSeenMs ? a : b);
      _nodes.remove(oldest.key);
    }
  }

  void _parseCompactNodes(Uint8List raw) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (int off = 0; off + 26 <= raw.length; off += 26) {
      final id = Uint8List.fromList(raw.sublist(off, off + 20));
      final ip = '${raw[off + 20]}.${raw[off + 21]}.${raw[off + 22]}.${raw[off + 23]}';
      final port = ((raw[off + 24] & 0xFF) << 8) | (raw[off + 25] & 0xFF);
      if (port > 0 && !MayakCidrFilter.isBlockedIpv4(ip)) {
        _nodes.putIfAbsent('$ip:$port', () => DhtNodeInfo(id: id, ip: ip, port: port, lastSeenMs: now));
      }
    }
  }

  Future<Map<String, dynamic>?> _sendKrpc(
    String ip,
    int port,
    String q,
    Map<String, dynamic> a, {
    Duration timeout = const Duration(milliseconds: 2200),
  }) async {
    if (MayakCidrFilter.isBlockedIpv4(ip) || port <= 0) return null;
    final sock = getSocket();
    if (sock == null) return null;
    final txId = Uint8List(4);
    final seq = _txSeq++;
    txId[0] = (seq >> 24) & 0xFF;
    txId[1] = (seq >> 16) & 0xFF;
    txId[2] = (seq >> 8) & 0xFF;
    txId[3] = seq & 0xFF;
    final txKey = base64Encode(txId);
    final comp = Completer<Map<String, dynamic>>();
    _pendingTx[txKey] = comp;

    final packet = MayakBencode.encode({
      'a': a,
      'q': q,
      'ro': 1, // BEP-43 read-only: экономим трафик и батарею!
      't': txId,
      'y': 'q',
    });

    try {
      sock.send(packet, InternetAddress(ip), port);
    } catch (_) {
      _pendingTx.remove(txKey);
      return null;
    }

    return comp.future.timeout(timeout, onTimeout: () {
      _pendingTx.remove(txKey);
      return <String, dynamic>{};
    }).then((m) => m.isEmpty ? null : m);
  }

  Future<void> bootstrap() async {
    if (isBootstrapping) return;
    isBootstrapping = true;
    try {
      // 1. Если есть кэшированные узлы, сперва опрашиваем их
      if (_nodes.length >= 12) {
        final sample = _nodes.values.take(6).toList();
        await Future.wait(sample.map((n) => _sendKrpc(n.ip, n.port, 'find_node', {
              'id': _ownNodeId,
              'target': _ownNodeId,
            })));
        if (_nodes.length >= 20) return;
      }
      // 2. Иначе опрашиваем чистый пул bootstrap-узлов параллельно
      final futures = <Future<void>>[];
      for (final b in bootstrapNodes) {
        futures.add(() async {
          try {
            final addrs = await InternetAddress.lookup(b.$1).timeout(const Duration(seconds: 2));
            for (final addr in addrs) {
              if (addr.type == InternetAddressType.IPv4 && !MayakCidrFilter.isBlockedIpv4(addr.address)) {
                await _sendKrpc(addr.address, b.$2, 'find_node', {
                  'id': _ownNodeId,
                  'target': _ownNodeId,
                });
                break;
              }
            }
          } catch (_) {}
        }());
      }
      await Future.wait(futures);
      onLog('[DHT] Bootstrap завершён, узлов в таблице: ${_nodes.length}');
    } finally {
      isBootstrapping = false;
    }
  }

  static int _xorCompare(Uint8List target, Uint8List a, Uint8List b) {
    for (int i = 0; i < 20; i++) {
      final da = target[i] ^ a[i];
      final db = target[i] ^ b[i];
      if (da != db) return da - db;
    }
    return 0;
  }

  List<DhtNodeInfo> _closestNodes(Uint8List target, int count) {
    final all = _nodes.values.toList()
      ..sort((a, b) => _xorCompare(target, a.id, b.id));
    return all.take(count).toList();
  }

  Future<Uint8List> _calcTarget(Uint8List pubKey32, Uint8List? salt) async {
    final bb = BytesBuilder(copy: false)..add(pubKey32);
    if (salt != null && salt.isNotEmpty) bb.add(salt);
    final h = await _sha1.hash(bb.toBytes());
    return Uint8List.fromList(h.bytes);
  }

  /// Канонический буфер подписи BEP-44 (БЕЗ внешних d...e!)
  static Uint8List _buildSignBuffer(Uint8List? salt, int seq, Uint8List valueBytes) {
    final bb = BytesBuilder(copy: false);
    if (salt != null && salt.isNotEmpty) {
      bb.add(ascii.encode('4:salt${salt.length}:'));
      bb.add(salt);
    }
    bb.add(ascii.encode('3:seqi${seq}e1:v'));
    bb.add(MayakBencode.encode(valueBytes));
    return bb.toBytes();
  }

  /// Итеративный BEP-44 PUT мутабельной записи (k = 20, сырой value <= 880 байт)
  Future<int> putMutable({
    required SimpleKeyPair slotKeyPair,
    required Uint8List valueBytes,
    required int seq,
    Uint8List? salt,
  }) async {
    if (valueBytes.length > 880) return 0;
    if (_nodes.length < 16) await bootstrap();
    if (_nodes.isEmpty) return 0;

    final pub = await slotKeyPair.extractPublicKey();
    final pubBytes = Uint8List.fromList(pub.bytes);
    final target = await _calcTarget(pubBytes, salt);
    final signBuf = _buildSignBuffer(salt, seq, valueBytes);
    final signature = await _ed25519.sign(signBuf, keyPair: slotKeyPair);
    final sigBytes = Uint8List.fromList(signature.bytes);

    final queried = <String>{};
    final writeTargets = <(DhtNodeInfo node, Uint8List token)>[];

    // 2 итерации поиска ближайших узлов + сбор write-токенов
    for (int round = 0; round < 2; round++) {
      final batch = _closestNodes(target, 24).where((n) => !queried.contains(n.key)).take(10).toList();
      if (batch.isEmpty) break;
      await Future.wait(batch.map((n) async {
        queried.add(n.key);
        final resp = await _sendKrpc(n.ip, n.port, 'get', {
          'id': _ownNodeId,
          'target': target,
        });
        final r = resp?['r'];
        if (r is Map<String, dynamic> && r['token'] is Uint8List) {
          writeTargets.add((n, r['token'] as Uint8List));
        }
      }));
    }

    if (writeTargets.isEmpty) return 0;
    writeTargets.sort((a, b) => _xorCompare(target, a.$1.id, b.$1.id));
    final top20 = writeTargets.take(20).toList();

    int stored = 0;
    await Future.wait(top20.map((entry) async {
      final a = <String, dynamic>{
        'id': _ownNodeId,
        'k': pubBytes,
        'seq': seq,
        'sig': sigBytes,
        'token': entry.$2,
        'v': valueBytes,
      };
      if (salt != null && salt.isNotEmpty) {
        a['salt'] = salt;
      }
      final resp = await _sendKrpc(entry.$1.ip, entry.$1.port, 'put', a);
      final yRaw = resp?['y'];
      if (yRaw is Uint8List && utf8.decode(yRaw, allowMalformed: true) == 'r') {
        stored++;
      }
    }));
    return stored;
  }

  /// Итеративный BEP-44 GET с проверкой Ed25519 подписи и выбором максимального seq
  Future<Bep44GetResult?> getMutable({
    required Uint8List pubKey32,
    Uint8List? salt,
  }) async {
    if (_nodes.length < 16) await bootstrap();
    if (_nodes.isEmpty) return null;

    final target = await _calcTarget(pubKey32, salt);
    final queried = <String>{};
    Bep44GetResult? best;

    for (int round = 0; round < 3; round++) {
      final batch = _closestNodes(target, 24).where((n) => !queried.contains(n.key)).take(10).toList();
      if (batch.isEmpty) break;
      await Future.wait(batch.map((n) async {
        queried.add(n.key);
        final resp = await _sendKrpc(n.ip, n.port, 'get', {
          'id': _ownNodeId,
          'target': target,
        });
        final r = resp?['r'];
        if (r is! Map<String, dynamic>) return;
        final v = r['v'];
        final seq = r['seq'];
        final sig = r['sig'];
        final k = r['k'];
        if (v is! Uint8List || seq is! int || sig is! Uint8List || k is! Uint8List) return;
        if (k.length != 32 || sig.length != 64) return;
        if (best != null && seq <= best!.seq) return;
        final signBuf = _buildSignBuffer(salt, seq, v);
        final ok = await _ed25519.verify(
          signBuf,
          signature: Signature(sig, publicKey: SimplePublicKey(pubKey32, type: KeyPairType.ed25519)),
        );
        if (ok) {
          best = Bep44GetResult(value: v, seq: seq, publicKey: pubKey32);
        }
      }));
      if (best != null && round >= 1) break;
    }
    return best;
  }
}
