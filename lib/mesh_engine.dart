import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

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

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _cipher = Chacha20.poly1305Aead();
  final _sha256 = Sha256();

  late SimpleKeyPair _signKeyPair;
  late SimpleKeyPair _dhKeyPair;
  late String nodeId;
  late String dhPubHex;
  late String signPubHex;

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpBeacon;
  Timer? _beaconTimer;
  int listenPort = 0;

  // Подключенные соседние узлы: Socket -> peerNodeId
  final Map<Socket, String> _peers = {};
  final Set<String> _connectedEndpoints = {};

  // Временный транзитный буфер (Store-and-Forward) в RAM
  final Map<String, MeshPacket> transitBuffer = {};
  // Кэш доставленных сообщений (ACK tombstones)
  final Map<String, MeshPacket> deliveredAcks = {};
  // Известные контакты: nodeId -> {dhPubHex, signPubHex}
  final Map<String, Map<String, String>> knownContacts = {};

  final void Function(String senderId, String text) onMessageReceived;
  final void Function() onStateChanged;

  MeshEngine({
    required this.onMessageReceived,
    required this.onStateChanged,
  });

  Future<void> init({int preferredPort = 0}) async {
    _signKeyPair = await _ed25519.newKeyPair();
    _dhKeyPair = await _x25519.newKeyPair();

    final dhPub = await _dhKeyPair.extractPublicKey();
    final signPub = await _signKeyPair.extractPublicKey();
    dhPubHex = _toHex(dhPub.bytes);
    signPubHex = _toHex(signPub.bytes);
    nodeId = await _calcNodeId(dhPub.bytes);

    // Поднимаем TCP-сервер на самом устройстве (IPv6 + IPv4 Dual-Stack)
    _tcpServer = await ServerSocket.bind(
      InternetAddress.anyIPv6,
      preferredPort,
      v6Only: false,
      shared: true,
    );
    listenPort = _tcpServer!.port;
    _tcpServer!.listen(_handleIncomingSocket);

    await _startLanAutoDiscovery();
    onStateChanged();
  }

  Future<String> _calcNodeId(List<int> dhPubBytes) async {
    final hash = await _sha256.hash(dhPubBytes);
    return _toHex(hash.bytes.sublist(0, 8));
  }

  /// Строка приглашения (можно передать через QR или скопировать)
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

  /// Подключение к другому человеку по его коду приглашения
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
      _setupSocket(socket);
    } catch (_) {
      _connectedEndpoints.remove(key);
    }
  }

  void _handleIncomingSocket(Socket socket) {
    _setupSocket(socket);
  }

  void _setupSocket(Socket socket) {
    // Отправляем свой анонс при рукопожатии
    final hello = jsonEncode({
      'hello': nodeId,
      'dh': dhPubHex,
      'sg': signPubHex,
    });
    _sendLine(socket, hello);

    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          (line) => _onSocketLine(socket, line),
          onDone: () => _cleanupSocket(socket),
          onError: (_) => _cleanupSocket(socket),
        );
  }

  Future<void> _onSocketLine(Socket socket, String line) async {
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      if (map.containsKey('hello')) {
        final peerId = map['hello'] as String;
        _peers[socket] = peerId;
        knownContacts[peerId] = {
          'dh': map['dh'] as String,
          'sg': map['sg'] as String,
        };
        onStateChanged();
        await _syncBufferWithPeer(socket, peerId);
        return;
      }

      final pkt = MeshPacket.fromJson(map);
      if (pkt.type == 'DATA') {
        await _handleDataPacket(pkt, socket);
      } else if (pkt.type == 'ACK') {
        await _handleAckPacket(pkt, socket);
      }
    } catch (_) {}
  }

  Future<void> _syncBufferWithPeer(Socket socket, String peerId) async {
    _evictExpired();
    for (final ack in deliveredAcks.values) {
      _sendLine(socket, jsonEncode(ack.toJson()));
    }
    for (final entry in transitBuffer.entries.toList()) {
      _sendLine(socket, jsonEncode(entry.value.toJson()));
      if (peerId == entry.value.dstNodeId) {
        transitBuffer.remove(entry.key);
      }
    }
    onStateChanged();
  }

  /// Отправка зашифрованного сообщения (работает напрямую и через промежуточные узлы)
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
    _floodPacket(pkt, exclude: null);
    onStateChanged();
  }

  Future<void> _handleDataPacket(MeshPacket pkt, Socket sender) async {
    _evictExpired();
    if (deliveredAcks.containsKey(pkt.msgId)) {
      _sendLine(sender, jsonEncode(deliveredAcks[pkt.msgId]!.toJson()));
      return;
    }
    if (transitBuffer.containsKey(pkt.msgId)) return;

    // Проверяем подпись отправителя
    final sigValid = await _ed25519.verify(
      utf8.encode('${pkt.msgId}|${pkt.dstNodeId}|${pkt.ciphertextHex}'),
      signature: Signature(
        _fromHex(pkt.signatureHex),
        publicKey: SimplePublicKey(_fromHex(pkt.srcSignPubHex), type: KeyPairType.ed25519),
      ),
    );
    if (!sigValid) return;

    // Если пакет адресован нам — расшифровываем и рассылаем ACK на удаление из памяти
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

      // Формируем крипто-квитанцию (ACK), которая сотрет пакет из памяти всех ретрансляторов
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
      _floodPacket(ackPkt, exclude: null);
      onStateChanged();
      return;
    }

    // Иначе мы промежуточный узел ("три улицы"): временно храним и пересылаем дальше
    if (pkt.ttl > 1 && transitBuffer.length < maxBufferPackets) {
      pkt.ttl -= 1;
      transitBuffer[pkt.msgId] = pkt;
      _floodPacket(pkt, exclude: sender);
      onStateChanged();
    }
  }

  Future<void> _handleAckPacket(MeshPacket ack, Socket sender) async {
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
      // Мгновенно очищаем оперативную память от доставленного сообщения
      transitBuffer.remove(ack.msgId);
    }

    deliveredAcks[ack.msgId] = ack;
    _floodPacket(ack, exclude: sender);
    onStateChanged();
  }

  void _floodPacket(MeshPacket pkt, {Socket? exclude}) {
    final serialized = jsonEncode(pkt.toJson());
    for (final entry in _peers.entries.toList()) {
      if (entry.key == exclude) continue;
      _sendLine(entry.key, serialized);
      if (pkt.type == 'DATA' && entry.value == pkt.dstNodeId) {
        transitBuffer.remove(pkt.msgId);
      }
    }
  }

  /// Автопоиск устройств в одной Wi-Fi сети / точке доступа без интернета
  Future<void> _startLanAutoDiscovery() async {
    try {
      _udpBeacon = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
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

  void _sendLine(Socket s, String line) {
    try {
      s.writeln(line);
    } catch (_) {
      _cleanupSocket(s);
    }
  }

  void _cleanupSocket(Socket s) {
    _peers.remove(s);
    s.destroy();
    onStateChanged();
  }

  int get connectedPeersCount => _peers.length;

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
