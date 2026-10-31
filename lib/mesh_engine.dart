import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MeshPacket {
  final String type; // 'DATA' или 'ACK'
  final String msgId;
  final String dstNodeId;
  final String srcSignPubHex;
  final String srcDhPubHex;
  final String dstSignPubHex;
  final String ephPubHex;
  final String nonceHex;
  final String ciphertextHex;
  final String macHex;
  final String signatureHex;
  final int expiresAt;
  int ttl;

  MeshPacket({
    required this.type,
    required this.msgId,
    required this.dstNodeId,
    required this.srcSignPubHex,
    required this.srcDhPubHex,
    required this.dstSignPubHex,
    required this.ephPubHex,
    required this.nonceHex,
    required this.ciphertextHex,
    required this.macHex,
    required this.signatureHex,
    required this.expiresAt,
    required this.ttl,
  });

  Map<String, dynamic> toJson() => {
        't': type,
        'id': msgId,
        'dst': dstNodeId,
        'sp': srcSignPubHex,
        'dp': srcDhPubHex,
        'dsp': dstSignPubHex,
        'ep': ephPubHex,
        'n': nonceHex,
        'c': ciphertextHex,
        'm': macHex,
        's': signatureHex,
        'exp': expiresAt,
        'ttl': ttl,
      };

  factory MeshPacket.fromJson(Map<String, dynamic> j) => MeshPacket(
        type: j['t'] as String,
        msgId: j['id'] as String,
        dstNodeId: j['dst'] as String,
        srcSignPubHex: j['sp'] as String,
        srcDhPubHex: j['dp'] as String,
        dstSignPubHex: j['dsp'] as String,
        ephPubHex: j['ep'] as String,
        nonceHex: j['n'] as String,
        ciphertextHex: j['c'] as String,
        macHex: j['m'] as String,
        signatureHex: j['s'] as String,
        expiresAt: j['exp'] as int,
        ttl: j['ttl'] as int,
      );
}

class MeshEngine {
  static const int discoveryPort = 42069;
  static const int maxBufferPackets = 300;
  static const String serviceId = 'com.p2pmesh.intercom';

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _cipher = Chacha20.poly1305Aead();
  final _sha256 = Sha256();

  late SimpleKeyPair _signKeyPair;
  late SimpleKeyPair _dhKeyPair;
  String nodeId = '';
  String dhPubHex = '';
  String signPubHex = '';

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpBeacon;
  Timer? _beaconTimer;
  int listenPort = 0;
  bool bleMeshActive = false;

  // TCP-пиры (LAN / Hotspot / Direct IP): Socket -> peerNodeId
  final Map<Socket, String> _tcpPeers = {};
  final Set<String> _connectedEndpoints = {};

  // Bluetooth / Wi-Fi Direct пиры (Android Nearby): endpointId -> peerNodeId
  final Map<String, String> _blePeers = {};

  // Временный транзитный буфер (Store-and-Forward)
  final Map<String, MeshPacket> transitBuffer = {};
  // Квитанции доставки (ACK)
  final Map<String, MeshPacket> deliveredAcks = {};
  // Контакты: nodeId -> {dh, sg}
  final Map<String, Map<String, String>> knownContacts = {};

  final void Function(String senderId, String text) onMessageReceived;
  final void Function() onStateChanged;

  MeshEngine({
    required this.onMessageReceived,
    required this.onStateChanged,
  });

  Future<void> init({int preferredPort = 0}) async {
    await _loadOrCreateIdentity();

    _tcpServer = await ServerSocket.bind(
      InternetAddress.anyIPv6,
      preferredPort,
      v6Only: false,
      shared: true,
    );
    listenPort = _tcpServer!.port;
    _tcpServer!.listen(_setupTcpSocket);

    await _startLanAutoDiscovery();
    if (Platform.isAndroid) {
      await startAndroidBleMesh();
    }
    onStateChanged();
  }

  /// Сохраняем ключи на устройстве, чтобы ID пользователя был постоянным
  Future<void> _loadOrCreateIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSignSeed = prefs.getString('sign_seed');
    final savedDhSeed = prefs.getString('dh_seed');

    if (savedSignSeed != null && savedDhSeed != null) {
      _signKeyPair = await _ed25519.newKeyPairFromSeed(_fromHex(savedSignSeed));
      _dhKeyPair = await _x25519.newKeyPairFromSeed(_fromHex(savedDhSeed));
    } else {
      final signSeed = _randomBytes(32);
      final dhSeed = _randomBytes(32);
      await prefs.setString('sign_seed', _toHex(signSeed));
      await prefs.setString('dh_seed', _toHex(dhSeed));
      _signKeyPair = await _ed25519.newKeyPairFromSeed(signSeed);
      _dhKeyPair = await _x25519.newKeyPairFromSeed(dhSeed);
    }

    final dhPub = await _dhKeyPair.extractPublicKey();
    final signPub = await _signKeyPair.extractPublicKey();
    dhPubHex = _toHex(dhPub.bytes);
    signPubHex = _toHex(signPub.bytes);
    nodeId = await _calcNodeId(dhPub.bytes);
  }

  /// Запуск Bluetooth LE + Wi-Fi Direct Mesh на Android (Strategy.P2P_CLUSTER)
  Future<void> startAndroidBleMesh() async {
    if (!Platform.isAndroid || bleMeshActive) return;
    try {
      await [
        Permission.bluetooth,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.nearbyWifiDevices,
        Permission.locationWhenInUse,
      ].request();

      final nearby = Nearby();
      await nearby.startAdvertising(
        nodeId,
        Strategy.P2P_CLUSTER,
        serviceId: serviceId,
        onConnectionInitiated: (String endpointId, ConnectionInfo info) {
          nearby.acceptConnection(
            endpointId,
            onPayLoadRecieved: (endId, payload) => _onBlePayload(endId, payload),
          );
        },
        onConnectionResult: (String endpointId, Status status) {
          if (status == Status.CONNECTED) {
            _sendBleHello(endpointId);
          } else {
            _blePeers.remove(endpointId);
            onStateChanged();
          }
        },
        onDisconnected: (String endpointId) {
          _blePeers.remove(endpointId);
          onStateChanged();
        },
      );

      await nearby.startDiscovery(
        nodeId,
        Strategy.P2P_CLUSTER,
        serviceId: serviceId,
        onEndpointFound: (String endpointId, String name, String srvId) {
          // Чтобы два телефона не ломились друг к другу одновременно, инициатор — тот, чей ID лексикографически меньше
          if (nodeId.compareTo(name) < 0) {
            nearby.requestConnection(
              nodeId,
              endpointId,
              onConnectionInitiated: (id, info) {
                nearby.acceptConnection(
                  id,
                  onPayLoadRecieved: (endId, payload) => _onBlePayload(endId, payload),
                );
              },
              onConnectionResult: (id, status) {
                if (status == Status.CONNECTED) {
                  _sendBleHello(id);
                }
              },
              onDisconnected: (id) {
                _blePeers.remove(id);
                onStateChanged();
              },
            );
          }
        },
        onEndpointLost: (String? endpointId) {
          if (endpointId != null) {
            _blePeers.remove(endpointId);
            onStateChanged();
          }
        },
      );

      bleMeshActive = true;
      onStateChanged();
    } catch (_) {}
  }

  void _sendBleHello(String endpointId) {
    final hello = jsonEncode({
      'hello': nodeId,
      'dh': dhPubHex,
      'sg': signPubHex,
    });
    _sendBleLine(endpointId, hello);
  }

  void _sendBleLine(String endpointId, String line) {
    try {
      final bytes = Uint8List.fromList(utf8.encode(line));
      Nearby().sendBytesPayload(endpointId, bytes);
    } catch (_) {}
  }

  Future<void> _onBlePayload(String endpointId, Payload payload) async {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;
    final line = utf8.decode(payload.bytes!);
    await _processIncomingJsonLine(
      line,
      onHello: (peerId) async {
        _blePeers[endpointId] = peerId;
        onStateChanged();
        _evictExpired();
        for (final ack in deliveredAcks.values) {
          _sendBleLine(endpointId, jsonEncode(ack.toJson()));
        }
        for (final entry in transitBuffer.entries.toList()) {
          _sendBleLine(endpointId, jsonEncode(entry.value.toJson()));
          if (peerId == entry.value.dstNodeId) {
            transitBuffer.remove(entry.key);
          }
        }
      },
      replyDirect: (replyJson) => _sendBleLine(endpointId, replyJson),
      excludeBleId: endpointId,
    );
  }

  Future<String> _calcNodeId(List<int> dhPubBytes) async {
    final hash = await _sha256.hash(dhPubBytes);
    return _toHex(hash.bytes.sublist(0, 8));
  }

  Future<String> getInviteCode() async {
    final ips = <String>[];
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.any,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLinkLocal) {
          ips.add(addr.address);
        }
      }
    }
    final primaryIp = ips.isNotEmpty ? ips.first : '127.0.0.1';
    final bundle = {
      'ip': primaryIp,
      'p': listenPort,
      'id': nodeId,
      'dh': dhPubHex,
      'sg': signPubHex,
    };
    return base64UrlEncode(utf8.encode(jsonEncode(bundle)));
  }

  Future<String> connectWithInviteCode(String code) async {
    final decoded = jsonDecode(utf8.decode(base64Url.decode(code.trim())));
    final ip = decoded['ip'] as String;
    final port = decoded['p'] as int;
    final targetId = decoded['id'] as String;
    knownContacts[targetId] = {
      'dh': decoded['dh'] as String,
      'sg': decoded['sg'] as String,
    };
    await connectToHost(ip, port);
    onStateChanged();
    return targetId;
  }

  Future<void> connectToHost(String host, int port) async {
    final key = '$host:$port';
    if (_connectedEndpoints.contains(key)) return;
    try {
      _connectedEndpoints.add(key);
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 4),
      );
      _setupTcpSocket(socket);
    } catch (_) {
      _connectedEndpoints.remove(key);
    }
  }

  void _setupTcpSocket(Socket socket) {
    final hello = jsonEncode({
      'hello': nodeId,
      'dh': dhPubHex,
      'sg': signPubHex,
    });
    _sendTcpLine(socket, hello);

    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          (line) => _processIncomingJsonLine(
            line,
            onHello: (peerId) async {
              _tcpPeers[socket] = peerId;
              onStateChanged();
              _evictExpired();
              for (final ack in deliveredAcks.values) {
                _sendTcpLine(socket, jsonEncode(ack.toJson()));
              }
              for (final entry in transitBuffer.entries.toList()) {
                _sendTcpLine(socket, jsonEncode(entry.value.toJson()));
                if (peerId == entry.value.dstNodeId) {
                  transitBuffer.remove(entry.key);
                }
              }
            },
            replyDirect: (replyJson) => _sendTcpLine(socket, replyJson),
            excludeTcpSocket: socket,
          ),
          onDone: () => _cleanupSocket(socket),
          onError: (_) => _cleanupSocket(socket),
        );
  }

  Future<void> _processIncomingJsonLine(
    String line, {
    required Future<void> Function(String peerId) onHello,
    required void Function(String jsonLine) replyDirect,
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) async {
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      if (map.containsKey('hello')) {
        final peerId = map['hello'] as String;
        knownContacts[peerId] = {
          'dh': map['dh'] as String,
          'sg': map['sg'] as String,
        };
        await onHello(peerId);
        onStateChanged();
        return;
      }

      final pkt = MeshPacket.fromJson(map);
      if (pkt.type == 'DATA') {
        await _handleDataPacket(
          pkt,
          replyDirect: replyDirect,
          excludeTcpSocket: excludeTcpSocket,
          excludeBleId: excludeBleId,
        );
      } else if (pkt.type == 'ACK') {
        await _handleAckPacket(
          pkt,
          excludeTcpSocket: excludeTcpSocket,
          excludeBleId: excludeBleId,
        );
      }
    } catch (_) {}
  }

  Future<void> sendMessage(String targetNodeId, String plainText) async {
    final contact = knownContacts[targetNodeId];
    if (contact == null) return;

    final msgId = _randomHex(16);
    final ephKeyPair = await _x25519.newKeyPair();
    final ephPub = await ephKeyPair.extractPublicKey();

    final recipientDhPub = SimplePublicKey(
      _fromHex(contact['dh']!),
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephKeyPair,
      remotePublicKey: recipientDhPub,
    );
    final secretBytes = await sharedSecret.extractBytes();
    final aesKey = SecretKey((await _sha256.hash(secretBytes)).bytes);

    final nonce = _randomBytes(12);
    final secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: aesKey,
      nonce: nonce,
      aad: utf8.encode(msgId),
    );

    final sigPayload = utf8.encode('$msgId|$targetNodeId|${_toHex(secretBox.cipherText)}');
    final sig = await _ed25519.sign(sigPayload, keyPair: _signKeyPair);

    final pkt = MeshPacket(
      type: 'DATA',
      msgId: msgId,
      dstNodeId: targetNodeId,
      srcSignPubHex: signPubHex,
      srcDhPubHex: dhPubHex,
      dstSignPubHex: contact['sg']!,
      ephPubHex: _toHex(ephPub.bytes),
      nonceHex: _toHex(nonce),
      ciphertextHex: _toHex(secretBox.cipherText),
      macHex: _toHex(secretBox.mac.bytes),
      signatureHex: _toHex(sig.bytes),
      expiresAt: DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
      ttl: 7,
    );

    transitBuffer[msgId] = pkt;
    _floodAllTransports(pkt);
    onStateChanged();
  }

  Future<void> _handleDataPacket(
    MeshPacket pkt, {
    required void Function(String) replyDirect,
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) async {
    _evictExpired();
    if (deliveredAcks.containsKey(pkt.msgId)) {
      replyDirect(jsonEncode(deliveredAcks[pkt.msgId]!.toJson()));
      return;
    }
    if (transitBuffer.containsKey(pkt.msgId)) return;

    final sigValid = await _ed25519.verify(
      utf8.encode('${pkt.msgId}|${pkt.dstNodeId}|${pkt.ciphertextHex}'),
      signature: Signature(
        _fromHex(pkt.signatureHex),
        publicKey: SimplePublicKey(_fromHex(pkt.srcSignPubHex), type: KeyPairType.ed25519),
      ),
    );
    if (!sigValid) return;

    if (pkt.dstNodeId == nodeId) {
      final shared = await _x25519.sharedSecretKey(
        keyPair: _dhKeyPair,
        remotePublicKey: SimplePublicKey(_fromHex(pkt.ephPubHex), type: KeyPairType.x25519),
      );
      final keyBytes = (await _sha256.hash(await shared.extractBytes())).bytes;
      final secretBox = SecretBox(
        _fromHex(pkt.ciphertextHex),
        nonce: _fromHex(pkt.nonceHex),
        mac: Mac(_fromHex(pkt.macHex)),
      );
      final clearBytes = await _cipher.decrypt(
        secretBox,
        secretKey: SecretKey(keyBytes),
        aad: utf8.encode(pkt.msgId),
      );
      final senderId = await _calcNodeId(_fromHex(pkt.srcDhPubHex));
      knownContacts[senderId] = {
        'dh': pkt.srcDhPubHex,
        'sg': pkt.srcSignPubHex,
      };
      onMessageReceived(senderId, utf8.decode(clearBytes));

      final ackSig = await _ed25519.sign(
        utf8.encode('ACK:${pkt.msgId}'),
        keyPair: _signKeyPair,
      );
      final ackPkt = MeshPacket(
        type: 'ACK',
        msgId: pkt.msgId,
        dstNodeId: senderId,
        srcSignPubHex: signPubHex,
        srcDhPubHex: dhPubHex,
        dstSignPubHex: pkt.dstSignPubHex,
        ephPubHex: '',
        nonceHex: '',
        ciphertextHex: '',
        macHex: '',
        signatureHex: _toHex(ackSig.bytes),
        expiresAt: pkt.expiresAt,
        ttl: 7,
      );
      deliveredAcks[pkt.msgId] = ackPkt;
      _floodAllTransports(ackPkt);
      onStateChanged();
      return;
    }

    if (pkt.ttl > 1 && transitBuffer.length < maxBufferPackets) {
      pkt.ttl -= 1;
      transitBuffer[pkt.msgId] = pkt;
      _floodAllTransports(
        pkt,
        excludeTcpSocket: excludeTcpSocket,
        excludeBleId: excludeBleId,
      );
      onStateChanged();
    }
  }

  Future<void> _handleAckPacket(
    MeshPacket ack, {
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) async {
    if (deliveredAcks.containsKey(ack.msgId)) return;

    final stored = transitBuffer[ack.msgId];
    if (stored != null) {
      final valid = await _ed25519.verify(
        utf8.encode('ACK:${ack.msgId}'),
        signature: Signature(
          _fromHex(ack.signatureHex),
          publicKey: SimplePublicKey(_fromHex(stored.dstSignPubHex), type: KeyPairType.ed25519),
        ),
      );
      if (!valid) return;
      transitBuffer.remove(ack.msgId);
    }

    deliveredAcks[ack.msgId] = ack;
    _floodAllTransports(
      ack,
      excludeTcpSocket: excludeTcpSocket,
      excludeBleId: excludeBleId,
    );
    onStateChanged();
  }

  /// Рассылка пакета сразу по всем активным каналам (Wi-Fi/TCP + Bluetooth/Wi-Fi Direct)
  void _floodAllTransports(
    MeshPacket pkt, {
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) {
    final serialized = jsonEncode(pkt.toJson());

    for (final entry in _tcpPeers.entries.toList()) {
      if (entry.key == excludeTcpSocket) continue;
      _sendTcpLine(entry.key, serialized);
      if (pkt.type == 'DATA' && entry.value == pkt.dstNodeId) {
        transitBuffer.remove(pkt.msgId);
      }
    }

    for (final entry in _blePeers.entries.toList()) {
      if (entry.key == excludeBleId) continue;
      _sendBleLine(entry.key, serialized);
      if (pkt.type == 'DATA' && entry.value == pkt.dstNodeId) {
        transitBuffer.remove(pkt.msgId);
      }
    }
  }

  Future<void> _startLanAutoDiscovery() async {
    try {
      _udpBeacon = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _udpBeacon!.broadcastEnabled = true;
      _udpBeacon!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpBeacon!.receive();
          if (dg == null) return;
          try {
            final data = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
            final peerId = data['id'] as String;
            final peerPort = data['p'] as int;
            if (peerId != nodeId) {
              knownContacts[peerId] = {
                'dh': data['dh'] as String,
                'sg': data['sg'] as String,
              };
              connectToHost(dg.address.address, peerPort);
            }
          } catch (_) {}
        }
      });

      _beaconTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final beacon = utf8.encode(jsonEncode({
          'id': nodeId,
          'p': listenPort,
          'dh': dhPubHex,
          'sg': signPubHex,
        }));
        _udpBeacon?.send(beacon, InternetAddress('255.255.255.255'), discoveryPort);
      });
    } catch (_) {}
  }

  void _evictExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    transitBuffer.removeWhere((_, pkt) => pkt.expiresAt <= now);
  }

  void _sendTcpLine(Socket s, String line) {
    try {
      s.writeln(line);
    } catch (_) {
      _cleanupSocket(s);
    }
  }

  void _cleanupSocket(Socket s) {
    _tcpPeers.remove(s);
    s.destroy();
    onStateChanged();
  }

  int get connectedPeersCount => _tcpPeers.length + _blePeers.length;
  int get blePeersCount => _blePeers.length;

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  static Uint8List _randomBytes(int len) {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(len, (_) => rnd.nextInt(256)));
  }

  static String _randomHex(int byteLen) => _toHex(_randomBytes(byteLen));
}
