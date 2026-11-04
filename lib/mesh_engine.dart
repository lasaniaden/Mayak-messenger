import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatMessage {
  final String msgId;
  final String peerId;
  final String senderId;
  final String senderName;
  String text;
  final int timestamp;
  final bool isMe;
  bool isDelivered;
  String? filePath;
  String? fileName;
  int? fileSize;
  double transferProgress; // 0.0 .. 1.0

  ChatMessage({
    required this.msgId,
    required this.peerId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    required this.isMe,
    this.isDelivered = false,
    this.filePath,
    this.fileName,
    this.fileSize,
    this.transferProgress = 1.0,
  });

  bool get isImageFile {
    final name = (fileName ?? filePath ?? '').toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp') ||
        name.endsWith('.gif') ||
        name.endsWith('.bmp');
  }

  String get timeFormatted {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String get fileSizeFormatted {
    final sz = fileSize ?? 0;
    if (sz < 1024) return '$sz Б';
    if (sz < 1024 * 1024) return '${(sz / 1024).toStringAsFixed(1)} КБ';
    return '${(sz / (1024 * 1024)).toStringAsFixed(2)} МБ';
  }

  Map<String, dynamic> toJson() => {
        'id': msgId,
        'p': peerId,
        's': senderId,
        'sn': senderName,
        'txt': text,
        'ts': timestamp,
        'me': isMe,
        'ack': isDelivered,
        'fp': filePath,
        'fn': fileName,
        'fs': fileSize,
        'pr': transferProgress,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        msgId: j['id'] as String,
        peerId: j['p'] as String,
        senderId: j['s'] as String,
        senderName: j['sn'] as String,
        text: j['txt'] as String,
        timestamp: j['ts'] as int,
        isMe: j['me'] as bool,
        isDelivered: (j['ack'] as bool?) ?? false,
        filePath: j['fp'] as String?,
        fileName: j['fn'] as String?,
        fileSize: j['fs'] as int?,
        transferProgress: ((j['pr'] as num?) ?? 1.0).toDouble(),
      );
}

class IncomingFileAssembly {
  final String fileId;
  final String fileName;
  final int totalSize;
  final int totalChunks;
  final String sha256Hex;
  final Map<int, List<int>> chunks = {};

  IncomingFileAssembly({
    required this.fileId,
    required this.fileName,
    required this.totalSize,
    required this.totalChunks,
    required this.sha256Hex,
  });
}

class ContactProfile {
  final String nodeId;
  final String dhPubHex;
  final String signPubHex;
  String nickname;
  String hwFingerprint;
  bool isOnline;
  bool isDirectPeer;
  String lastAddress;
  int unreadCount;

  ContactProfile({
    required this.nodeId,
    required this.dhPubHex,
    required this.signPubHex,
    required this.nickname,
    this.hwFingerprint = '',
    this.isOnline = false,
    this.isDirectPeer = false,
    this.lastAddress = '',
    this.unreadCount = 0,
  });

  String get displayTitle =>
      nickname.trim().isNotEmpty ? nickname.trim() : 'Узел $nodeId';

  Map<String, dynamic> toJson() => {
        'id': nodeId,
        'dh': dhPubHex,
        'sg': signPubHex,
        'nick': nickname,
        'hw': hwFingerprint,
        'addr': lastAddress,
      };

  factory ContactProfile.fromJson(Map<String, dynamic> j) => ContactProfile(
        nodeId: j['id'] as String,
        dhPubHex: j['dh'] as String,
        signPubHex: j['sg'] as String,
        nickname: (j['nick'] as String?) ?? 'Узел ${j['id']}',
        hwFingerprint: (j['hw'] as String?) ?? '',
        lastAddress: (j['addr'] as String?) ?? '',
      );
}

class MeshPacket {
  final String type; // 'DATA', 'BROADCAST' или 'ACK'
  final String msgId;
  final String dstNodeId;
  final String srcNickname;
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
    required this.srcNickname,
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
        'nick': srcNickname,
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
        srcNickname: (j['nick'] as String?) ?? '',
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
  static const String broadcastChannelId = 'BROADCAST';
  static const int discoveryPort = 42069;
  static const int defaultTcpPort = 42070;
  static const int maxBufferPackets = 400;
  static const int fileChunkSize = 24 * 1024; // 24 КБ на чанк
  static const String serviceId = 'com.p2pmesh.intercom';
  static const MethodChannel _nativeChannel = MethodChannel('mayak/native');

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _cipher = Chacha20.poly1305Aead();
  final _sha256 = Sha256();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  late SimpleKeyPair _signKeyPair;
  late SimpleKeyPair _dhKeyPair;
  String nodeId = '';
  String nickname = '';
  String dhPubHex = '';
  String signPubHex = '';
  String myHwFingerprint = '';

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpBeacon;
  Timer? _beaconTimer;
  int listenPort = 0;
  bool bleMeshActive = false;
  bool bgServiceActive = false;
  bool isScanningSubnet = false;
  bool vpnDetected = false;
  bool gpsDisabledOnAndroid = false;
  bool notificationsEnabled = true;
  String? activeOpenChatId;
  int unreadBroadcastCount = 0;
  String lastStatusLog = 'Запуск ядра...';
  final List<String> debugLogs = [];

  List<String> cachedIps = ['127.0.0.1'];
  String cachedInviteCode = '';
  int _lastIpRefreshMs = 0;

  final Map<Socket, String> _tcpPeers = {};
  final Set<String> _connectingHosts = {};
  final Map<String, String> _blePeers = {};
  final Set<String> _seenBroadcastIds = {};
  final Map<String, IncomingFileAssembly> _incomingFiles = {};

  final Map<String, MeshPacket> transitBuffer = {};
  // Вечная очередь своих собственных исходящих пакетов (сохраняется на диск!)
  final Map<String, MeshPacket> myPersistentOutbox = {};
  final Map<String, MeshPacket> deliveredAcks = {};
  final Map<String, ContactProfile> knownContacts = {};
  final Map<String, List<ChatMessage>> chatHistory = {};

  final void Function(ChatMessage message) onMessageReceived;
  final void Function() onStateChanged;

  MeshEngine({
    required this.onMessageReceived,
    required this.onStateChanged,
  }) {
    if (Platform.isAndroid) {
      _nativeChannel.setMethodCallHandler(_handleNativeCallback);
    }
  }

  List<ChatMessage> getMessagesFor(String peerId) {
    return chatHistory.putIfAbsent(peerId, () => []);
  }

  ChatMessage? getLastMessageFor(String peerId) {
    final list = chatHistory[peerId];
    if (list == null || list.isEmpty) return null;
    return list.last;
  }

  void markChatAsRead(String? peerId) {
    activeOpenChatId = peerId;
    if (peerId == null) return;
    if (peerId == broadcastChannelId) {
      unreadBroadcastCount = 0;
    } else {
      knownContacts[peerId]?.unreadCount = 0;
    }
    onStateChanged();
  }

  Future<void> deleteContact(String targetNodeId) async {
    knownContacts.remove(targetNodeId);
    chatHistory.remove(targetNodeId);
    if (activeOpenChatId == targetNodeId) {
      activeOpenChatId = null;
    }
    await _saveContactsAndChats();
    onStateChanged();
  }

  /// Честный полный выход из программы и остановка фоновой службы Android в ноль
  Future<void> stopAllAndExitApp() async {
    await _saveContactsAndChats();
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopBackgroundServiceAndExit');
      } catch (_) {
        exit(0);
      }
    } else {
      exit(0);
    }
  }

  Future<String> computeSafetyNumber(String peerNodeId) async {
    final c = knownContacts[peerNodeId];
    if (c == null) return 'Нет данных';
    final keys = [dhPubHex, c.dhPubHex]..sort();
    final combined = utf8.encode('MAYAK-SAFETY-V2|${keys[0]}|${keys[1]}');
    final hash = (await _sha256.hash(combined)).bytes;
    final groups = <String>[];
    for (int i = 0; i < 12; i += 3) {
      final numVal =
          ((hash[i] << 16) | (hash[i + 1] << 8) | hash[i + 2]) % 1000;
      groups.add(numVal.toString().padLeft(3, '0'));
    }
    return groups.join(' - ');
  }

  void _addLog(String msg, {bool triggerUi = true}) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    debugLogs.insert(0, '[$ts] $msg');
    if (debugLogs.length > 80) {
      debugLogs.removeLast();
    }
    lastStatusLog = msg;
    if (triggerUi) onStateChanged();
  }

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onNearbyConnected':
          final endpointId = call.arguments as String;
          _addLog('BLE подключен: $endpointId');
          await _sendBleLine(endpointId, _buildHelloJson());
          await _sendBleLine(endpointId, _buildPeerSyncJson());
          break;
        case 'onNearbyDisconnected':
          final endpointId = call.arguments as String;
          _blePeers.remove(endpointId);
          _refreshOnlineStatuses();
          onStateChanged();
          break;
        case 'onNearbyPayload':
          final map = Map<String, dynamic>.from(call.arguments as Map);
          final endpointId = map['endpointId'] as String;
          final data = map['data'] as String;
          await _onBlePayload(endpointId, data);
          break;
        case 'onNativeLog':
          final msg = call.arguments as String;
          _addLog(msg);
          break;
      }
    } catch (_) {}
  }

  Future<void> init() async {
    try {
      await _loadOrCreateIdentity();
      await _loadPersistedContactsAndChats();
    } catch (e) {
      _addLog('Ошибка ключей: $e');
    }

    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('acquireMulticastLock');
        await _nativeChannel.invokeMethod('startBackgroundService');
        bgServiceActive = true;
      } catch (_) {}
    }

    for (final candidatePort in [defaultTcpPort, defaultTcpPort + 1, 0]) {
      if (_tcpServer != null) break;
      try {
        _tcpServer = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          candidatePort,
          shared: true,
        );
      } catch (_) {}
    }

    if (_tcpServer != null) {
      listenPort = _tcpServer!.port;
      _tcpServer!.listen(
        _setupTcpSocket,
        onError: (_) {},
      );
    }

    await refreshNetworkCache();
    await _startLanAutoDiscovery();
    _addLog('Защищенный узел готов (порт $listenPort)');

    unawaited(scanLocalSubnet(quickOnly: true));
  }

  Future<void> _loadOrCreateIdentity() async {
    String rawHwId = '';
    try {
      if (Platform.isAndroid) {
        rawHwId =
            await _nativeChannel.invokeMethod<String>('getHardwareId') ?? '';
      } else {
        rawHwId =
            '${Platform.localHostname}_${Platform.operatingSystem}_${Platform.environment["USERNAME"] ?? "user"}';
      }
    } catch (_) {}

    if (rawHwId.isNotEmpty) {
      final hwHashBytes =
          (await _sha256.hash(utf8.encode('MAYAK-HW|$rawHwId'))).bytes;
      myHwFingerprint = _toHex(hwHashBytes.sublist(0, 8));
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      String? savedSignSeed = prefs.getString('sign_seed');
      String? savedDhSeed = prefs.getString('dh_seed');

      if (savedSignSeed == null || savedDhSeed == null) {
        if (rawHwId.isNotEmpty && rawHwId.length > 5) {
          final signDigest =
              await _sha256.hash(utf8.encode('MAYAK-SIGN-SEED-V1|$rawHwId'));
          final dhDigest =
              await _sha256.hash(utf8.encode('MAYAK-DH-SEED-V1|$rawHwId'));
          savedSignSeed = _toHex(signDigest.bytes);
          savedDhSeed = _toHex(dhDigest.bytes);
        } else {
          savedSignSeed = _toHex(_randomBytes(32));
          savedDhSeed = _toHex(_randomBytes(32));
        }
        await prefs.setString('sign_seed', savedSignSeed);
        await prefs.setString('dh_seed', savedDhSeed);
      }

      _signKeyPair =
          await _ed25519.newKeyPairFromSeed(_fromHex(savedSignSeed));
      _dhKeyPair = await _x25519.newKeyPairFromSeed(_fromHex(savedDhSeed));

      final dhPub = await _dhKeyPair.extractPublicKey();
      final signPub = await _signKeyPair.extractPublicKey();
      dhPubHex = _toHex(dhPub.bytes);
      signPubHex = _toHex(signPub.bytes);
      nodeId = await _calcNodeId(dhPub.bytes);

      final defaultName =
          Platform.isAndroid ? 'Android-$nodeId' : 'PC-$nodeId';
      nickname = prefs.getString('user_nickname') ?? defaultName;
    } catch (_) {
      final signSeed = _randomBytes(32);
      final dhSeed = _randomBytes(32);
      _signKeyPair = await _ed25519.newKeyPairFromSeed(signSeed);
      _dhKeyPair = await _x25519.newKeyPairFromSeed(dhSeed);
      final dhPub = await _dhKeyPair.extractPublicKey();
      final signPub = await _signKeyPair.extractPublicKey();
      dhPubHex = _toHex(dhPub.bytes);
      signPubHex = _toHex(signPub.bytes);
      nodeId = await _calcNodeId(dhPub.bytes);
      nickname = Platform.isAndroid ? 'Android-$nodeId' : 'PC-$nodeId';
    }
  }

  Future<void> _loadPersistedContactsAndChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final contactsRaw = prefs.getString('saved_contacts_v7');
      if (contactsRaw != null && contactsRaw.isNotEmpty) {
        final list = jsonDecode(contactsRaw) as List;
        for (final item in list) {
          final c =
              ContactProfile.fromJson(Map<String, dynamic>.from(item as Map));
          if (c.nodeId != nodeId) {
            knownContacts[c.nodeId] = c;
          }
        }
      }

      final chatsRaw = prefs.getString('saved_chats_v7');
      if (chatsRaw != null && chatsRaw.isNotEmpty) {
        final map = jsonDecode(chatsRaw) as Map<String, dynamic>;
        map.forEach((peerId, msgsJson) {
          final list = (msgsJson as List)
              .map((m) =>
                  ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
              .toList();
          chatHistory[peerId] = list;
        });
      }

      // Восстанавливаем вечную очередь своих собственных недоставленных сообщений (Outbox) после перезагрузки!
      final outboxRaw = prefs.getString('saved_outbox_v9');
      if (outboxRaw != null && outboxRaw.isNotEmpty) {
        final list = jsonDecode(outboxRaw) as List;
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final item in list) {
          final pkt =
              MeshPacket.fromJson(Map<String, dynamic>.from(item as Map));
          if (pkt.expiresAt > now) {
            myPersistentOutbox[pkt.msgId] = pkt;
            transitBuffer[pkt.msgId] = pkt;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveContactsAndChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final contactsList =
          knownContacts.values.map((c) => c.toJson()).toList();
      await prefs.setString('saved_contacts_v7', jsonEncode(contactsList));

      final chatsMap = <String, dynamic>{};
      chatHistory.forEach((peerId, list) {
        final trimmed =
            list.length > 100 ? list.sublist(list.length - 100) : list;
        chatsMap[peerId] = trimmed.map((m) => m.toJson()).toList();
      });
      await prefs.setString('saved_chats_v7', jsonEncode(chatsMap));

      final outboxList =
          myPersistentOutbox.values.map((p) => p.toJson()).toList();
      await prefs.setString('saved_outbox_v9', jsonEncode(outboxList));
    } catch (_) {}
  }

  Future<void> updateNickname(String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) return;
    nickname = clean;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_nickname', nickname);
    } catch (_) {}

    await refreshNetworkCache();
    final hello = _buildHelloJson();
    for (final s in _tcpPeers.keys.toList()) {
      _sendTcpLine(s, hello);
    }
    for (final bleId in _blePeers.keys.toList()) {
      await _sendBleLine(bleId, hello);
    }
    onStateChanged();
  }

  String _buildHelloJson() => jsonEncode({
        'hello': nodeId,
        'nick': nickname,
        'dh': dhPubHex,
        'sg': signPubHex,
        'hw': myHwFingerprint,
      });

  String _buildPeerSyncJson() {
    final peers = knownContacts.values
        .map((c) => {
              'id': c.nodeId,
              'nick': c.nickname,
              'dh': c.dhPubHex,
              'sg': c.signPubHex,
              'hw': c.hwFingerprint,
            })
        .toList();
    return jsonEncode({'peer_sync': peers});
  }

  Future<void> refreshNetworkCache() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastIpRefreshMs < 8000 && cachedInviteCode.isNotEmpty) {
      return;
    }
    _lastIpRefreshMs = now;
    cachedIps = await getLocalIPv4Addresses();
    if (nodeId.isNotEmpty) {
      final bundle = {
        'ips': cachedIps,
        'p': listenPort,
        'id': nodeId,
        'nick': nickname,
        'dh': dhPubHex,
        'sg': signPubHex,
        'hw': myHwFingerprint,
      };
      cachedInviteCode = base64UrlEncode(utf8.encode(jsonEncode(bundle)));
    }
  }

  Future<List<String>> getLocalIPv4Addresses() async {
    final preferredLan = <String>[];
    final fallbackLan = <String>[];
    bool detectedVpnInterface = false;

    if (Platform.isAndroid) {
      try {
        final res = await _nativeChannel
            .invokeMapMethod<String, dynamic>('getWifiIpAndVpnState');
        if (res != null) {
          final wifiIp = (res['wifiIp'] as String?) ?? '';
          final isVpn = (res['vpnActive'] as bool?) ?? false;
          final gpsOn = (res['gpsEnabled'] as bool?) ?? true;
          gpsDisabledOnAndroid = !gpsOn;
          if (isVpn) detectedVpnInterface = true;
          if (wifiIp.isNotEmpty && wifiIp != '0.0.0.0') {
            preferredLan.add(wifiIp);
          }
        }
      } catch (_) {}
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final lower = iface.name.toLowerCase();
        if (lower.contains('tun') ||
            lower.contains('tap') ||
            lower.contains('ppp') ||
            lower.contains('wg') ||
            lower.contains('utun') ||
            lower.contains('wintun') ||
            lower.contains('wireguard') ||
            lower.contains('proton') ||
            lower.contains('amnezia') ||
            lower.contains('clash') ||
            lower.contains('sing') ||
            lower.contains('nekobox') ||
            lower.contains('v2ray') ||
            lower.contains('outline') ||
            lower.contains('tailscale') ||
            lower.contains('zerotier') ||
            lower.contains('radmin') ||
            lower.contains('hamachi') ||
            lower.contains('nordlynx')) {
          detectedVpnInterface = true;
          continue;
        }
        if (lower.contains('wsl') ||
            lower.contains('docker') ||
            lower.contains('vbox') ||
            lower.contains('vethernet') ||
            lower.contains('vmware') ||
            lower.contains('hyper-v')) {
          continue;
        }

        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.') ||
              ip.startsWith('198.18.') ||
              ip.startsWith('198.19.') ||
              ip.startsWith('100.')) {
            detectedVpnInterface = true;
            continue;
          }

          if (ip.startsWith('192.168.')) {
            if (!preferredLan.contains(ip)) preferredLan.add(ip);
          } else {
            if (!fallbackLan.contains(ip)) fallbackLan.add(ip);
          }
        }
      }
    } catch (_) {}

    vpnDetected = detectedVpnInterface;
    final result = [...preferredLan, ...fallbackLan];
    if (result.isEmpty) result.add('127.0.0.1');
    return result;
  }

  Future<String?> connectWithInviteOrIp(String rawInput) async {
    final input = rawInput.trim();
    if (input.isEmpty) return null;

    final ipRegex =
        RegExp(r'^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?::(\d+))?$');
    final match = ipRegex.firstMatch(input);
    if (match != null) {
      final host = match.group(1)!;
      final port = int.tryParse(match.group(2) ?? '') ?? defaultTcpPort;
      _addLog('Прямое подключение к $host:$port...');
      await connectToHost(host, port);
      return null;
    }

    final decoded = jsonDecode(utf8.decode(base64Url.decode(input)))
        as Map<String, dynamic>;
    final port = (decoded['p'] as int?) ?? defaultTcpPort;
    final targetId = decoded['id'] as String;
    final targetNick = (decoded['nick'] as String?) ?? 'Узел $targetId';
    final targetHw = (decoded['hw'] as String?) ?? '';

    final List<String> candidateIps = [];
    if (decoded['ips'] is List) {
      candidateIps.addAll((decoded['ips'] as List).map((e) => e.toString()));
    } else if (decoded['ip'] is String) {
      candidateIps.add(decoded['ip'] as String);
    }

    _upsertContact(
      nodeId: targetId,
      dhPubHex: decoded['dh'] as String,
      signPubHex: decoded['sg'] as String,
      nick: targetNick,
      hwFingerprint: targetHw,
      address: candidateIps.isNotEmpty ? '${candidateIps.first}:$port' : '',
    );

    for (final ip in candidateIps) {
      unawaited(connectToHost(ip, port, expectedNodeId: targetId));
    }
    unawaited(_saveContactsAndChats());
    onStateChanged();
    return targetId;
  }

  Future<void> scanLocalSubnet({bool quickOnly = false}) async {
    if (isScanningSubnet) return;
    isScanningSubnet = true;
    if (!quickOnly) _addLog('Поиск устройств в локальной Wi-Fi сети...');
    onStateChanged();
    try {
      await refreshNetworkCache();
      final myIps = cachedIps;
      final prefixes = <String>{};
      for (final ip in myIps) {
        final parts = ip.split('.');
        if (parts.length == 4 && parts[0] != '127') {
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
      if (prefixes.isEmpty) {
        prefixes
            .addAll(['192.168.1', '192.168.0', '192.168.43', '192.168.137']);
      }

      for (final prefix in prefixes) {
        final priorityHosts = <int>[
          1, 2, 3, 4, 5, 10, 20, 50, 100, 101, 102, 103, 104, 105, 150, 200
        ];
        final priorityBatch = <Future<void>>[];
        for (final lastOctet in priorityHosts) {
          final targetIp = '$prefix.$lastOctet';
          if (!myIps.contains(targetIp)) {
            priorityBatch.add(connectToHost(targetIp, defaultTcpPort,
                timeout: const Duration(milliseconds: 350)));
          }
        }
        await Future.wait(priorityBatch);

        if (!quickOnly) {
          final batch = <Future<void>>[];
          for (int i = 1; i <= 254; i++) {
            if (priorityHosts.contains(i)) continue;
            final targetIp = '$prefix.$i';
            if (myIps.contains(targetIp)) continue;
            batch.add(connectToHost(
              targetIp,
              defaultTcpPort,
              timeout: const Duration(milliseconds: 250),
            ));
            if (batch.length >= 15) {
              await Future.wait(batch);
              batch.clear();
              await Future.delayed(const Duration(milliseconds: 15));
            }
          }
          if (batch.isNotEmpty) {
            await Future.wait(batch);
          }
        }
      }
      if (!quickOnly) {
        _addLog('Поиск завершен (пиров онлайн: $connectedPeersCount)');
      }
    } catch (_) {
    } finally {
      isScanningSubnet = false;
      onStateChanged();
    }
  }

  Future<String> configureWindowsPublicFirewall() async {
    if (!Platform.isWindows) return 'Только для Windows';
    try {
      final cmdArgs =
          '/c netsh advfirewall firewall delete rule name="Mayak P2P TCP 42070" >nul 2>&1 & '
          'netsh advfirewall firewall delete rule name="Mayak P2P UDP 42069" >nul 2>&1 & '
          'netsh advfirewall firewall add rule name="Mayak P2P TCP 42070" dir=in action=allow protocol=TCP localport=42070 profile=public,private,domain & '
          'netsh advfirewall firewall add rule name="Mayak P2P UDP 42069" dir=in action=allow protocol=UDP localport=42069 profile=public,private,domain';

      final res = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Start-Process cmd -ArgumentList '$cmdArgs' -Verb RunAs -Wait"
      ]);
      if (res.exitCode == 0) {
        _addLog(
            'Правила Брандмауэра Windows для Общественной сети успешно добавлены!');
        return 'OK';
      } else {
        _addLog('Не удалось применить правила автоматически: ${res.stderr}');
        return 'ERROR';
      }
    } catch (e) {
      _addLog('Ошибка вызова UAC: $e');
      return 'ERROR';
    }
  }

  Future<bool> requestAndroidNotifications() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _nativeChannel
              .invokeMethod<bool>('requestNotificationPermission') ??
          false;
      notificationsEnabled = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// Выбор фото или любого файла на Android и Windows (без внешних падающих плагинов!)
  Future<Map<String, dynamic>?> pickFileForChat({bool onlyImages = false}) async {
    try {
      if (Platform.isAndroid) {
        final res = await _nativeChannel.invokeMapMethod<String, dynamic>(
          'pickFile',
          {'onlyImages': onlyImages},
        );
        return res;
      } else if (Platform.isWindows) {
        final filter = onlyImages
            ? 'Images (*.jpg;*.jpeg;*.png;*.webp;*.gif)|*.jpg;*.jpeg;*.png;*.webp;*.gif|All files (*.*)|*.*'
            : 'All files (*.*)|*.*';
        final psScript =
            "Add-Type -AssemblyName System.Windows.Forms; "
            "\$dlg = New-Object System.Windows.Forms.OpenFileDialog; "
            "\$dlg.Filter = '$filter'; "
            "if (\$dlg.ShowDialog() -eq 'OK') { Write-Output \$dlg.FileName }";
        final proc = await Process.run('powershell', [
          '-NoProfile',
          '-STA',
          '-Command',
          psScript,
        ]);
        final selectedPath = proc.stdout.toString().trim();
        if (selectedPath.isEmpty) return null;
        final file = File(selectedPath);
        if (!await file.exists()) return null;
        final name = selectedPath.split(RegExp(r'[\\/]')).last;
        return {
          'path': selectedPath,
          'name': name,
          'size': await file.length(),
        };
      }
    } catch (e) {
      _addLog('Ошибка выбора файла: $e');
    }
    return null;
  }

  /// Сохранение полученного файла в папку «Загрузки/Mayak»
  Future<String> saveReceivedFileToDownloads(
      String srcPath, String fileName) async {
    try {
      if (Platform.isAndroid) {
        final res = await _nativeChannel.invokeMethod<String>(
          'saveFileToDownloads',
          {'path': srcPath, 'name': fileName},
        );
        return res ?? 'Сохранено';
      } else {
        final home = Platform.environment['USERPROFILE'] ??
            Platform.environment['HOME'] ??
            '.';
        final dlDir = Directory('$home/Downloads/Mayak');
        if (!await dlDir.exists()) {
          await dlDir.create(recursive: true);
        }
        final dstPath = '${dlDir.path}/$fileName';
        await File(srcPath).copy(dstPath);
        return 'Сохранено в: $dstPath';
      }
    } catch (e) {
      return 'Ошибка сохранения: $e';
    }
  }

  /// Отправка выбранного фото или файла в личный чат с нарезкой на чанки по 24 КБ и сквозным шифрованием E2EE v2
  Future<void> sendFileMessage(
    String targetNodeId, {
    required String filePath,
    required String fileName,
  }) async {
    final contact = knownContacts[targetNodeId];
    if (contact == null) return;

    final file = File(filePath);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final totalSize = bytes.length;
    if (totalSize == 0) return;

    if (totalSize > 25 * 1024 * 1024) {
      _addLog('Максимальный размер файла для Mesh-передачи: 25 МБ');
      return;
    }

    final fileId = _randomHex(12);
    final fileHash = _toHex((await _sha256.hash(bytes)).bytes);
    final totalChunks = (totalSize / fileChunkSize).ceil();
    final now = DateTime.now().millisecondsSinceEpoch;

    final myMsg = ChatMessage(
      msgId: fileId,
      peerId: targetNodeId,
      senderId: nodeId,
      senderName: nickname,
      text: '📎 Файл: $fileName',
      timestamp: now,
      isMe: true,
      isDelivered: false,
      filePath: filePath,
      fileName: fileName,
      fileSize: totalSize,
      transferProgress: 0.05,
    );
    getMessagesFor(targetNodeId).add(myMsg);
    onStateChanged();

    for (int idx = 0; idx < totalChunks; idx++) {
      final start = idx * fileChunkSize;
      final end = min(start + fileChunkSize, totalSize);
      final chunkBytes = bytes.sublist(start, end);

      final chunkEnvelopeJson = jsonEncode({
        'v': 2,
        'kind': 'FILE_CHUNK',
        'fid': fileId,
        'fn': fileName,
        'fs': totalSize,
        'sha': fileHash,
        'idx': idx,
        'tot': totalChunks,
        'nick': nickname,
        'b64': base64Encode(chunkBytes),
      });

      final chunkMsgId = (idx == totalChunks - 1) ? fileId : '${fileId}_$idx';
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: targetNodeId,
        contact: contact,
        msgId: chunkMsgId,
        sealedPayloadBytes: utf8.encode(chunkEnvelopeJson),
        persistInOutbox: totalSize <= 512 * 1024,
      );

      myMsg.transferProgress = (idx + 1) / totalChunks;
      onStateChanged();
      // Небольшая пауза между чанками, чтобы не забивать сокет и UI
      await Future.delayed(const Duration(milliseconds: 18));
    }

    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<Directory> _getReceivedFilesDir() async {
    final base = Directory.systemTemp;
    final dir = Directory('${base.path}/mayak_received_files');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _triggerIncomingNotification(
    String senderId,
    String senderName,
    String text,
  ) async {
    final isChatCurrentlyVisible = (activeOpenChatId == senderId);
    try {
      await HapticFeedback.mediumImpact();
      if (!isChatCurrentlyVisible) {
        await SystemSound.play(SystemSoundType.alert);
      }
    } catch (_) {}

    if (Platform.isAndroid && notificationsEnabled) {
      try {
        await _nativeChannel.invokeMethod('showNotification', {
          'title': 'Маяк: $senderName',
          'body': text,
          'forceWhenOpen': !isChatCurrentlyVisible,
        });
      } catch (_) {}
    }
  }

  void _upsertContact({
    required String nodeId,
    required String dhPubHex,
    required String signPubHex,
    String? nick,
    String? hwFingerprint,
    String? address,
  }) {
    if (nodeId.isEmpty || nodeId == this.nodeId) return;

    final cleanNick = (nick ?? '').trim();
    final cleanHw = (hwFingerprint ?? '').trim();
    final cleanIp = (address != null && address.contains(':'))
        ? address.split(':').first
        : (address ?? '');

    final duplicateIds = <String>[];
    knownContacts.forEach((oldId, oldContact) {
      if (oldId == nodeId) return;
      final sameHw = cleanHw.isNotEmpty &&
          oldContact.hwFingerprint.isNotEmpty &&
          oldContact.hwFingerprint == cleanHw;
      final oldIp = oldContact.lastAddress.contains(':')
          ? oldContact.lastAddress.split(':').first
          : oldContact.lastAddress;
      final sameOfflineDeviceByNameOrIp = !oldContact.isOnline &&
          ((cleanNick.isNotEmpty &&
                  !cleanNick.startsWith('Android-') &&
                  !cleanNick.startsWith('PC-') &&
                  !cleanNick.startsWith('Узел ') &&
                  oldContact.nickname == cleanNick) ||
              (cleanIp.isNotEmpty &&
                  cleanIp != 'Через Mesh' &&
                  oldIp == cleanIp));

      if (sameHw || sameOfflineDeviceByNameOrIp) {
        duplicateIds.add(oldId);
      }
    });

    for (final oldId in duplicateIds) {
      final oldHistory = chatHistory.remove(oldId);
      if (oldHistory != null && oldHistory.isNotEmpty) {
        final currentHistory = getMessagesFor(nodeId);
        currentHistory.insertAll(0, oldHistory);
      }
      if (activeOpenChatId == oldId) {
        activeOpenChatId = nodeId;
      }
      knownContacts.remove(oldId);
    }

    final existing = knownContacts[nodeId];
    final isPeerConnected =
        _tcpPeers.containsValue(nodeId) || _blePeers.containsValue(nodeId);
    if (existing != null) {
      if (cleanNick.isNotEmpty && !cleanNick.startsWith('Узел ')) {
        existing.nickname = cleanNick;
      }
      if (cleanHw.isNotEmpty) {
        existing.hwFingerprint = cleanHw;
      }
      if (address != null && address.isNotEmpty) {
        existing.lastAddress = address;
      }
      existing.isOnline = isPeerConnected;
      existing.isDirectPeer = isPeerConnected;
    } else {
      knownContacts[nodeId] = ContactProfile(
        nodeId: nodeId,
        dhPubHex: dhPubHex,
        signPubHex: signPubHex,
        nickname: cleanNick.isNotEmpty ? cleanNick : 'Узел $nodeId',
        hwFingerprint: cleanHw,
        isOnline: isPeerConnected,
        isDirectPeer: isPeerConnected,
        lastAddress: address ?? '',
      );
    }
  }

  Future<void> connectToHost(
    String host,
    int port, {
    String? expectedNodeId,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (port <= 0 || host == '127.0.0.1') return;
    if (expectedNodeId != null && _tcpPeers.containsValue(expectedNodeId)) {
      return;
    }
    for (final s in _tcpPeers.keys) {
      try {
        if (s.remoteAddress.address == host) return;
      } catch (_) {}
    }

    final key = '$host:$port';
    if (_connectingHosts.contains(key)) return;
    _connectingHosts.add(key);
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: timeout,
      );
      _setupTcpSocket(socket);
    } catch (_) {
    } finally {
      _connectingHosts.remove(key);
    }
  }

  void _setupTcpSocket(Socket socket) {
    String remoteAddr = '';
    try {
      remoteAddr = '${socket.remoteAddress.address}:${socket.remotePort}';
    } catch (_) {}

    _sendTcpLine(socket, _buildHelloJson());
    _sendTcpLine(socket, _buildPeerSyncJson());

    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          (line) => _processIncomingJsonLine(
            line,
            remoteAddr: remoteAddr,
            onHello: (peerId, peerNick) async {
              _tcpPeers[socket] = peerId;
              _refreshOnlineStatuses();
              _addLog('Подключен: $peerNick ($peerId)');

              _sendTcpLine(socket, _buildPeerSyncJson());

              _evictExpired();
              for (final ack in deliveredAcks.values) {
                _sendTcpLine(socket, jsonEncode(ack.toJson()));
              }
              for (final entry in transitBuffer.entries.toList()) {
                _sendTcpLine(socket, jsonEncode(entry.value.toJson()));
              }
            },
            replyDirect: (replyJson) => _sendTcpLine(socket, replyJson),
            excludeTcpSocket: socket,
          ),
          onDone: () => _cleanupSocket(socket),
          onError: (_) => _cleanupSocket(socket),
          cancelOnError: true,
        );
  }

  Future<void> _processIncomingJsonLine(
    String line, {
    String remoteAddr = '',
    required Future<void> Function(String peerId, String peerNick) onHello,
    required void Function(String jsonLine) replyDirect,
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) async {
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      if (map.containsKey('hello')) {
        final peerId = map['hello'] as String;
        if (peerId == nodeId) return;
        final peerNick = (map['nick'] as String?) ?? '';
        final peerHw = (map['hw'] as String?) ?? '';
        _upsertContact(
          nodeId: peerId,
          dhPubHex: map['dh'] as String,
          signPubHex: map['sg'] as String,
          nick: peerNick,
          hwFingerprint: peerHw,
          address: remoteAddr,
        );
        await onHello(peerId, peerNick);
        _refreshOnlineStatuses();
        unawaited(_saveContactsAndChats());
        onStateChanged();
        return;
      }

      if (map.containsKey('peer_sync')) {
        final list = map['peer_sync'] as List;
        bool addedAny = false;
        for (final item in list) {
          final m = Map<String, dynamic>.from(item as Map);
          final pid = m['id'] as String;
          if (pid != nodeId && !knownContacts.containsKey(pid)) {
            _upsertContact(
              nodeId: pid,
              dhPubHex: m['dh'] as String,
              signPubHex: m['sg'] as String,
              nick: (m['nick'] as String?) ?? 'Узел $pid',
              hwFingerprint: (m['hw'] as String?) ?? '',
              address: 'Через Mesh',
            );
            addedAny = true;
          }
        }
        if (addedAny) {
          unawaited(_saveContactsAndChats());
          onStateChanged();
        }
        return;
      }

      final pkt = MeshPacket.fromJson(map);
      if (pkt.type == 'DATA' || pkt.type == 'BROADCAST') {
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

  Future<SecretKey> _deriveHardenedConversationKey({
    required SimpleKeyPair firstKeyPair,
    required SimplePublicKey firstRemotePub,
    required SimpleKeyPair secondKeyPair,
    required SimplePublicKey secondRemotePub,
    required String msgId,
    required String dstNodeId,
  }) async {
    final secret1 = await _x25519.sharedSecretKey(
      keyPair: firstKeyPair,
      remotePublicKey: firstRemotePub,
    );
    final secret2 = await _x25519.sharedSecretKey(
      keyPair: secondKeyPair,
      remotePublicKey: secondRemotePub,
    );
    final combinedIkm = <int>[
      ...(await secret1.extractBytes()),
      ...(await secret2.extractBytes()),
    ];
    return _hkdf.deriveKey(
      secretKey: SecretKey(combinedIkm),
      nonce: utf8.encode('MAYAK-SALT-V2|$msgId'),
      info: utf8.encode('MAYAK-E2EE-V2|$dstNodeId'),
    );
  }

  List<int> _packSealedEnvelope(String senderNick, String plainText, int ts) {
    final padLen = 16 + Random.secure().nextInt(48);
    final randomPad = base64Encode(_randomBytes(padLen));
    final envelopeJson = jsonEncode({
      'v': 2,
      'kind': 'TEXT',
      'nick': senderNick,
      'txt': plainText,
      'ts': ts,
      'pad': randomPad,
    });
    return utf8.encode(envelopeJson);
  }

  Map<String, dynamic> _unpackSealedEnvelope(List<int> clearBytes) {
    final decodedStr = utf8.decode(clearBytes);
    try {
      final map = jsonDecode(decodedStr) as Map<String, dynamic>;
      if (map.containsKey('v')) {
        return map;
      }
    } catch (_) {}
    return {'kind': 'TEXT', 'nick': '', 'txt': decodedStr};
  }

  Future<void> _encryptAndQueueSealedDataPacket({
    required String targetNodeId,
    required ContactProfile contact,
    required String msgId,
    required List<int> sealedPayloadBytes,
    bool persistInOutbox = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ephKeyPair = await _x25519.newKeyPair();
    final ephPub = await ephKeyPair.extractPublicKey();
    final ephPubHex = _toHex(ephPub.bytes);

    final recipientDhPub = SimplePublicKey(
      _fromHex(contact.dhPubHex),
      type: KeyPairType.x25519,
    );

    final sessionKey = await _deriveHardenedConversationKey(
      firstKeyPair: ephKeyPair,
      firstRemotePub: recipientDhPub,
      secondKeyPair: _dhKeyPair,
      secondRemotePub: recipientDhPub,
      msgId: msgId,
      dstNodeId: targetNodeId,
    );

    final nonce = _randomBytes(12);
    final expiresAt = now + 24 * 3600 * 1000;
    final aadBytes =
        utf8.encode('$msgId|$targetNodeId|$ephPubHex|$dhPubHex|$expiresAt');

    final secretBox = await _cipher.encrypt(
      sealedPayloadBytes,
      secretKey: sessionKey,
      nonce: nonce,
      aad: aadBytes,
    );

    final cipherHex = _toHex(secretBox.cipherText);
    final macHex = _toHex(secretBox.mac.bytes);
    final sigPayload = utf8
        .encode('$msgId|$targetNodeId|$ephPubHex|$dhPubHex|$cipherHex|$macHex');
    final sig = await _ed25519.sign(sigPayload, keyPair: _signKeyPair);

    final pkt = MeshPacket(
      type: 'DATA',
      msgId: msgId,
      dstNodeId: targetNodeId,
      srcNickname: '',
      srcSignPubHex: signPubHex,
      srcDhPubHex: dhPubHex,
      dstSignPubHex: contact.signPubHex,
      ephPubHex: ephPubHex,
      nonceHex: _toHex(nonce),
      ciphertextHex: cipherHex,
      macHex: macHex,
      signatureHex: _toHex(sig.bytes),
      expiresAt: expiresAt,
      ttl: 7,
    );

    transitBuffer[msgId] = pkt;
    if (persistInOutbox) {
      myPersistentOutbox[msgId] = pkt;
    }
    _floodAllTransports(pkt);
  }

  Future<void> sendMessage(String targetNodeId, String plainText) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = _randomHex(16);

    if (targetNodeId == broadcastChannelId) {
      final b64Payload = base64Encode(utf8.encode(plainText));
      final sigPayload = utf8.encode('$msgId|$broadcastChannelId|$b64Payload');
      final sig = await _ed25519.sign(sigPayload, keyPair: _signKeyPair);

      final pkt = MeshPacket(
        type: 'BROADCAST',
        msgId: msgId,
        dstNodeId: broadcastChannelId,
        srcNickname: nickname,
        srcSignPubHex: signPubHex,
        srcDhPubHex: dhPubHex,
        dstSignPubHex: '',
        ephPubHex: '',
        nonceHex: '',
        ciphertextHex: b64Payload,
        macHex: '',
        signatureHex: _toHex(sig.bytes),
        expiresAt: now + 3600 * 1000,
        ttl: 5,
      );

      _seenBroadcastIds.add(msgId);
      final myMsg = ChatMessage(
        msgId: msgId,
        peerId: broadcastChannelId,
        senderId: nodeId,
        senderName: nickname,
        text: plainText,
        timestamp: now,
        isMe: true,
        isDelivered: connectedPeersCount > 0,
      );
      getMessagesFor(broadcastChannelId).add(myMsg);
      _floodAllTransports(pkt);
      unawaited(_saveContactsAndChats());
      onStateChanged();
      return;
    }

    final contact = knownContacts[targetNodeId];
    if (contact == null) return;

    final myMsg = ChatMessage(
      msgId: msgId,
      peerId: targetNodeId,
      senderId: nodeId,
      senderName: nickname,
      text: plainText,
      timestamp: now,
      isMe: true,
      isDelivered: false,
    );
    getMessagesFor(targetNodeId).add(myMsg);

    final sealedPayload = _packSealedEnvelope(nickname, plainText, now);
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: targetNodeId,
      contact: contact,
      msgId: msgId,
      sealedPayloadBytes: sealedPayload,
      persistInOutbox: true,
    );

    unawaited(_saveContactsAndChats());
    onStateChanged();
  }

  Future<void> _handleDataPacket(
    MeshPacket pkt, {
    required void Function(String) replyDirect,
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) async {
    _evictExpired();

    if (pkt.type == 'BROADCAST') {
      if (_seenBroadcastIds.contains(pkt.msgId)) return;
      final sigValid = await _ed25519.verify(
        utf8.encode('${pkt.msgId}|$broadcastChannelId|${pkt.ciphertextHex}'),
        signature: Signature(
          _fromHex(pkt.signatureHex),
          publicKey: SimplePublicKey(
              _fromHex(pkt.srcSignPubHex), type: KeyPairType.ed25519),
        ),
      );
      if (!sigValid) return;
      _seenBroadcastIds.add(pkt.msgId);

      final senderId = await _calcNodeId(_fromHex(pkt.srcDhPubHex));
      if (senderId == nodeId) return;

      _upsertContact(
        nodeId: senderId,
        dhPubHex: pkt.srcDhPubHex,
        signPubHex: pkt.srcSignPubHex,
        nick: pkt.srcNickname,
      );
      final senderName = knownContacts[senderId]?.displayTitle ?? senderId;
      final decodedText = utf8.decode(base64Decode(pkt.ciphertextHex));
      final chatMsg = ChatMessage(
        msgId: pkt.msgId,
        peerId: broadcastChannelId,
        senderId: senderId,
        senderName: senderName,
        text: decodedText,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isMe: false,
        isDelivered: true,
      );
      getMessagesFor(broadcastChannelId).add(chatMsg);
      if (activeOpenChatId != broadcastChannelId) {
        unreadBroadcastCount++;
      }
      onMessageReceived(chatMsg);
      unawaited(_triggerIncomingNotification(
          broadcastChannelId, 'Общий эфир ($senderName)', decodedText));
      unawaited(_saveContactsAndChats());

      if (pkt.ttl > 1) {
        pkt.ttl -= 1;
        _floodAllTransports(
          pkt,
          excludeTcpSocket: excludeTcpSocket,
          excludeBleId: excludeBleId,
        );
      }
      onStateChanged();
      return;
    }

    if (deliveredAcks.containsKey(pkt.msgId)) {
      replyDirect(jsonEncode(deliveredAcks[pkt.msgId]!.toJson()));
      return;
    }
    if (transitBuffer.containsKey(pkt.msgId)) return;

    final v2SigPayload = utf8.encode(
        '${pkt.msgId}|${pkt.dstNodeId}|${pkt.ephPubHex}|${pkt.srcDhPubHex}|${pkt.ciphertextHex}|${pkt.macHex}');
    final sigValid = await _ed25519.verify(
      v2SigPayload,
      signature: Signature(
        _fromHex(pkt.signatureHex),
        publicKey: SimplePublicKey(
            _fromHex(pkt.srcSignPubHex), type: KeyPairType.ed25519),
      ),
    );
    if (!sigValid) return;

    if (pkt.dstNodeId == nodeId) {
      final senderEphPub =
          SimplePublicKey(_fromHex(pkt.ephPubHex), type: KeyPairType.x25519);
      final senderStaticDhPub =
          SimplePublicKey(_fromHex(pkt.srcDhPubHex), type: KeyPairType.x25519);

      final sessionKey = await _deriveHardenedConversationKey(
        firstKeyPair: _dhKeyPair,
        firstRemotePub: senderEphPub,
        secondKeyPair: _dhKeyPair,
        secondRemotePub: senderStaticDhPub,
        msgId: pkt.msgId,
        dstNodeId: pkt.dstNodeId,
      );

      final aadBytes = utf8.encode(
          '${pkt.msgId}|${pkt.dstNodeId}|${pkt.ephPubHex}|${pkt.srcDhPubHex}|${pkt.expiresAt}');
      final secretBox = SecretBox(
        _fromHex(pkt.ciphertextHex),
        nonce: _fromHex(pkt.nonceHex),
        mac: Mac(_fromHex(pkt.macHex)),
      );
      final clearBytes = await _cipher.decrypt(
        secretBox,
        secretKey: sessionKey,
        aad: aadBytes,
      );

      final envelope = _unpackSealedEnvelope(clearBytes);
      final kind = (envelope['kind'] as String?) ?? 'TEXT';
      final senderNickInside =
          (envelope['nick'] as String?) ?? pkt.srcNickname;
      final senderId = await _calcNodeId(_fromHex(pkt.srcDhPubHex));

      _upsertContact(
        nodeId: senderId,
        dhPubHex: pkt.srcDhPubHex,
        signPubHex: pkt.srcSignPubHex,
        nick: senderNickInside,
      );
      final contact = knownContacts[senderId]!;

      if (kind == 'FILE_CHUNK') {
        await _handleIncomingFileChunk(senderId, contact, envelope);
      } else {
        final decodedText = (envelope['txt'] as String?) ?? '';
        final chatMsg = ChatMessage(
          msgId: pkt.msgId,
          peerId: senderId,
          senderId: senderId,
          senderName: contact.displayTitle,
          text: decodedText,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          isMe: false,
          isDelivered: true,
        );
        getMessagesFor(senderId).add(chatMsg);
        if (activeOpenChatId != senderId) {
          contact.unreadCount++;
        }
        onMessageReceived(chatMsg);
        unawaited(_triggerIncomingNotification(
            senderId, contact.displayTitle, decodedText));
        unawaited(_saveContactsAndChats());
      }

      // Отправляем подписанный ACK
      final ackSig = await _ed25519.sign(
        utf8.encode('ACK:${pkt.msgId}'),
        keyPair: _signKeyPair,
      );
      final ackPkt = MeshPacket(
        type: 'ACK',
        msgId: pkt.msgId,
        dstNodeId: senderId,
        srcNickname: '',
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

  Future<void> _handleIncomingFileChunk(
    String senderId,
    ContactProfile contact,
    Map<String, dynamic> env,
  ) async {
    final fileId = env['fid'] as String;
    final fileName = (env['fn'] as String?) ?? 'file.bin';
    final totalSize = (env['fs'] as int?) ?? 0;
    final shaHex = (env['sha'] as String?) ?? '';
    final idx = (env['idx'] as int?) ?? 0;
    final tot = (env['tot'] as int?) ?? 1;
    final chunkBytes = base64Decode((env['b64'] as String?) ?? '');

    final assembly = _incomingFiles.putIfAbsent(
      fileId,
      () => IncomingFileAssembly(
        fileId: fileId,
        fileName: fileName,
        totalSize: totalSize,
        totalChunks: tot,
        sha256Hex: shaHex,
      ),
    );
    assembly.chunks[idx] = chunkBytes;

    final msgs = getMessagesFor(senderId);
    ChatMessage? existingMsg;
    for (final m in msgs) {
      if (m.msgId == fileId) {
        existingMsg = m;
        break;
      }
    }

    if (existingMsg == null) {
      existingMsg = ChatMessage(
        msgId: fileId,
        peerId: senderId,
        senderId: senderId,
        senderName: contact.displayTitle,
        text: '📎 Прием файла: $fileName...',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isMe: false,
        isDelivered: false,
        fileName: fileName,
        fileSize: totalSize,
        transferProgress: assembly.chunks.length / tot,
      );
      msgs.add(existingMsg);
    } else {
      existingMsg.transferProgress = assembly.chunks.length / tot;
    }

    if (assembly.chunks.length >= tot) {
      final combined = <int>[];
      for (int i = 0; i < tot; i++) {
        final part = assembly.chunks[i];
        if (part == null) return;
        combined.addAll(part);
      }
      _incomingFiles.remove(fileId);

      final actualHash = _toHex((await _sha256.hash(combined)).bytes);
      if (shaHex.isNotEmpty && actualHash != shaHex) {
        existingMsg.text = '⚠️ Ошибка контрольной суммы файла $fileName';
        onStateChanged();
        return;
      }

      final dir = await _getReceivedFilesDir();
      final safeName =
          fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._а-яА-ЯёЁ-]'), '_');
      final savedFile = File('${dir.path}/${fileId}_$safeName');
      await savedFile.writeAsBytes(combined, flush: true);

      existingMsg.filePath = savedFile.path;
      existingMsg.text = '📎 Файл: $fileName';
      existingMsg.isDelivered = true;
      existingMsg.transferProgress = 1.0;

      if (activeOpenChatId != senderId) {
        contact.unreadCount++;
      }
      onMessageReceived(existingMsg);
      unawaited(_triggerIncomingNotification(
          senderId, contact.displayTitle, '📎 Прислан файл: $fileName'));
      unawaited(_saveContactsAndChats());
    }
    onStateChanged();
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
          publicKey: SimplePublicKey(
              _fromHex(stored.dstSignPubHex), type: KeyPairType.ed25519),
        ),
      );
      if (!valid) return;
      transitBuffer.remove(ack.msgId);
      myPersistentOutbox.remove(ack.msgId);
    }

    for (final list in chatHistory.values) {
      for (final m in list) {
        if (m.msgId == ack.msgId) {
          m.isDelivered = true;
          m.transferProgress = 1.0;
        }
      }
    }

    deliveredAcks[ack.msgId] = ack;
    _floodAllTransports(
      ack,
      excludeTcpSocket: excludeTcpSocket,
      excludeBleId: excludeBleId,
    );
    unawaited(_saveContactsAndChats());
    onStateChanged();
  }

  void _floodAllTransports(
    MeshPacket pkt, {
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) {
    final serialized = jsonEncode(pkt.toJson());
    final sentPeerIds = <String>{};

    for (final entry in _tcpPeers.entries.toList()) {
      if (entry.key == excludeTcpSocket) continue;
      if (sentPeerIds.contains(entry.value)) continue;
      sentPeerIds.add(entry.value);
      _sendTcpLine(entry.key, serialized);
    }

    for (final entry in _blePeers.entries.toList()) {
      if (entry.key == excludeBleId) continue;
      if (sentPeerIds.contains(entry.value)) continue;
      sentPeerIds.add(entry.value);
      unawaited(_sendBleLine(entry.key, serialized));
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
      _udpBeacon!.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            final dg = _udpBeacon!.receive();
            if (dg == null) return;
            try {
              final data =
                  jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
              final peerId = data['id'] as String;
              final peerPort = data['p'] as int;
              final peerNick = (data['nick'] as String?) ?? '';
              final peerHw = (data['hw'] as String?) ?? '';
              if (peerId != nodeId) {
                _upsertContact(
                  nodeId: peerId,
                  dhPubHex: data['dh'] as String,
                  signPubHex: data['sg'] as String,
                  nick: peerNick,
                  hwFingerprint: peerHw,
                  address: '${dg.address.address}:$peerPort',
                );
                connectToHost(dg.address.address, peerPort,
                    expectedNodeId: peerId);
              }
            } catch (_) {}
          }
        },
        onError: (_) {},
      );

      _beaconTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
        if (nodeId.isEmpty || listenPort <= 0) return;
        await refreshNetworkCache();
        final beacon = utf8.encode(jsonEncode({
          'id': nodeId,
          'nick': nickname,
          'p': listenPort,
          'dh': dhPubHex,
          'sg': signPubHex,
          'hw': myHwFingerprint,
        }));
        try {
          _udpBeacon?.send(
              beacon, InternetAddress('255.255.255.255'), discoveryPort);
        } catch (_) {}

        for (final ip in cachedIps) {
          final parts = ip.split('.');
          if (parts.length == 4 && parts[0] != '127') {
            final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            try {
              _udpBeacon?.send(
                  beacon, InternetAddress(subnetBroadcast), discoveryPort);
            } catch (_) {}
          }
        }

        // Авто-реконнект по сохраненным домашним IP известных друзей (при возвращении домой)
        for (final c in knownContacts.values) {
          if (!c.isOnline &&
              c.lastAddress.isNotEmpty &&
              c.lastAddress.contains(':')) {
            final addrParts = c.lastAddress.split(':');
            if (addrParts.length == 2 && !addrParts[0].startsWith('BLE')) {
              final port = int.tryParse(addrParts[1]) ?? defaultTcpPort;
              unawaited(connectToHost(
                addrParts[0],
                port,
                expectedNodeId: c.nodeId,
                timeout: const Duration(milliseconds: 500),
              ));
            }
          }
        }
      });
    } catch (e) {
      _addLog('UDP автопоиск недоступен: $e');
    }
  }

  Future<bool> toggleAndroidBleMesh() async {
    if (!Platform.isAndroid) return false;
    try {
      if (bleMeshActive) {
        await _nativeChannel.invokeMethod('stopNearby');
        bleMeshActive = false;
        _blePeers.clear();
        _refreshOnlineStatuses();
        _addLog('BLE Mesh остановлен пользователем');
        return false;
      }

      _addLog('Запрос разрешений для BLE Mesh...');
      final granted =
          await _nativeChannel.invokeMethod<bool>('requestNearbyPermissions') ??
              false;
      if (!granted) {
        _addLog(
            'Для Bluetooth Mesh нужно разрешить Геолокацию и Устройства рядом в настройках');
        return false;
      }

      final res = await _nativeChannel.invokeMethod<String>('startNearby', {
        'nodeId': nodeId,
        'serviceId': serviceId,
      });

      if (res == 'OK') {
        bleMeshActive = true;
        _addLog('Wi-Fi + BLE Mesh активны');
        return true;
      } else {
        _addLog('Статус BLE: $res');
        return false;
      }
    } catch (e) {
      _addLog('Ошибка запуска BLE: $e');
      return false;
    }
  }

  Future<bool> requestCameraPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _nativeChannel
              .invokeMethod<bool>('requestCameraPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sendBleLine(String endpointId, String line) async {
    try {
      await _nativeChannel.invokeMethod('sendNearbyPayload', {
        'endpointId': endpointId,
        'data': line,
      });
    } catch (_) {}
  }

  Future<void> _onBlePayload(String endpointId, String data) async {
    for (final line in const LineSplitter().convert(data)) {
      if (line.trim().isEmpty) continue;
      await _processIncomingJsonLine(
        line,
        remoteAddr: 'BLE:$endpointId',
        onHello: (peerId, peerNick) async {
          _blePeers[endpointId] = peerId;
          _refreshOnlineStatuses();
          _addLog('Подключен по BLE: $peerNick ($peerId)');
          await _sendBleLine(endpointId, _buildPeerSyncJson());
          _evictExpired();
          for (final ack in deliveredAcks.values) {
            await _sendBleLine(endpointId, jsonEncode(ack.toJson()));
          }
          for (final entry in transitBuffer.entries.toList()) {
            await _sendBleLine(endpointId, jsonEncode(entry.value.toJson()));
          }
        },
        replyDirect: (replyJson) =>
            unawaited(_sendBleLine(endpointId, replyJson)),
        excludeBleId: endpointId,
      );
    }
  }

  void _refreshOnlineStatuses() {
    final activeIds = {..._tcpPeers.values, ..._blePeers.values};
    for (final c in knownContacts.values) {
      c.isOnline = activeIds.contains(c.nodeId);
      c.isDirectPeer = activeIds.contains(c.nodeId);
    }
  }

  Future<String> _calcNodeId(List<int> dhPubBytes) async {
    final hash = await _sha256.hash(dhPubBytes);
    return _toHex(hash.bytes.sublist(0, 8));
  }

  void _evictExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    transitBuffer.removeWhere((_, pkt) => pkt.expiresAt <= now);
    myPersistentOutbox.removeWhere((_, pkt) => pkt.expiresAt <= now);
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
    try {
      s.destroy();
    } catch (_) {}
    _refreshOnlineStatuses();
    onStateChanged();
  }

  int get connectedPeersCount =>
      {..._tcpPeers.values, ..._blePeers.values}.length;
  int get blePeersCount => _blePeers.values.toSet().length;

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
