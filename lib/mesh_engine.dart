import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatMessage {
  final String msgId;
  final String peerId; // ID собеседника или 'BROADCAST' для общего эфира
  final String senderId;
  final String senderName;
  final String text;
  final int timestamp;
  final bool isMe;
  bool isDelivered;

  ChatMessage({
    required this.msgId,
    required this.peerId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    required this.isMe,
    this.isDelivered = false,
  });

  String get timeFormatted {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
      );
}

class ContactProfile {
  final String nodeId;
  final String dhPubHex;
  final String signPubHex;
  String nickname;
  bool isOnline;
  bool isDirectPeer;
  String lastAddress;
  int unreadCount;

  ContactProfile({
    required this.nodeId,
    required this.dhPubHex,
    required this.signPubHex,
    required this.nickname,
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
        'addr': lastAddress,
      };

  factory ContactProfile.fromJson(Map<String, dynamic> j) => ContactProfile(
        nodeId: j['id'] as String,
        dhPubHex: j['dh'] as String,
        signPubHex: j['sg'] as String,
        nickname: (j['nick'] as String?) ?? 'Узел ${j['id']}',
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
  static const int maxBufferPackets = 300;
  static const String serviceId = 'com.p2pmesh.intercom';
  static const MethodChannel _nativeChannel = MethodChannel('mayak/native');

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _cipher = Chacha20.poly1305Aead();
  final _sha256 = Sha256();

  late SimpleKeyPair _signKeyPair;
  late SimpleKeyPair _dhKeyPair;
  String nodeId = '';
  String nickname = '';
  String dhPubHex = '';
  String signPubHex = '';

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpBeacon;
  Timer? _beaconTimer;
  Timer? _autoScanTimer;
  int listenPort = 0;
  bool bleMeshActive = false;
  bool isScanningSubnet = false;
  bool vpnDetected = false;
  bool gpsDisabledOnAndroid = false;
  bool notificationsEnabled = true;
  String? activeOpenChatId;
  int unreadBroadcastCount = 0;
  String lastStatusLog = 'Запуск ядра...';
  final List<String> debugLogs = [];

  final Map<Socket, String> _tcpPeers = {};
  final Set<String> _connectingHosts = {};
  final Map<String, String> _blePeers = {};
  final Set<String> _seenBroadcastIds = {};

  final Map<String, MeshPacket> transitBuffer = {};
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

  void _addLog(String msg) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    debugLogs.insert(0, '[$ts] $msg');
    if (debugLogs.length > 80) {
      debugLogs.removeLast();
    }
    lastStatusLog = msg;
    onStateChanged();
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

    await _startLanAutoDiscovery();
    _addLog('Wi-Fi / Hotspot готов (порт $listenPort)');

    unawaited(scanLocalSubnet());

    // Регулярный фоновый автопоиск новых друзей каждые 15 секунд
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!isScanningSubnet) {
        unawaited(scanLocalSubnet(silent: true));
      }
    });
  }

  Future<void> _loadOrCreateIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSignSeed = prefs.getString('sign_seed');
      final savedDhSeed = prefs.getString('dh_seed');

      if (savedSignSeed != null && savedDhSeed != null) {
        _signKeyPair =
            await _ed25519.newKeyPairFromSeed(_fromHex(savedSignSeed));
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
      });

  /// Протокол PEER_SYNC: делимся известными контактами с подключенным другом (чтобы видеть друзей через рукопожатие!)
  String _buildPeerSyncJson() {
    final peers = knownContacts.values
        .map((c) => {
              'id': c.nodeId,
              'nick': c.nickname,
              'dh': c.dhPubHex,
              'sg': c.signPubHex,
            })
        .toList();
    return jsonEncode({'peer_sync': peers});
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

  Future<String> getInviteCode() async {
    if (nodeId.isEmpty) return '';
    final ips = await getLocalIPv4Addresses();
    final bundle = {
      'ips': ips,
      'p': listenPort,
      'id': nodeId,
      'nick': nickname,
      'dh': dhPubHex,
      'sg': signPubHex,
    };
    return base64UrlEncode(utf8.encode(jsonEncode(bundle)));
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
      address: candidateIps.isNotEmpty ? '${candidateIps.first}:$port' : '',
    );

    for (final ip in candidateIps) {
      unawaited(connectToHost(ip, port, expectedNodeId: targetId));
    }
    unawaited(_saveContactsAndChats());
    onStateChanged();
    return targetId;
  }

  Future<void> scanLocalSubnet({bool silent = false}) async {
    if (isScanningSubnet) return;
    isScanningSubnet = true;
    if (!silent) _addLog('Поиск устройств в локальной Wi-Fi сети...');
    onStateChanged();
    try {
      final myIps = await getLocalIPv4Addresses();
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
        final priorityHosts = <int>[1, 2, 100, 101, 102, 103, 104, 105];
        for (final lastOctet in priorityHosts) {
          final targetIp = '$prefix.$lastOctet';
          if (!myIps.contains(targetIp)) {
            unawaited(connectToHost(targetIp, defaultTcpPort,
                timeout: const Duration(milliseconds: 500)));
          }
        }

        final batch = <Future<void>>[];
        for (int i = 1; i <= 254; i++) {
          final targetIp = '$prefix.$i';
          if (myIps.contains(targetIp)) continue;
          batch.add(connectToHost(
            targetIp,
            defaultTcpPort,
            timeout: const Duration(milliseconds: 350),
          ));
          if (batch.length >= 30) {
            await Future.wait(batch);
            batch.clear();
          }
        }
        if (batch.isNotEmpty) {
          await Future.wait(batch);
        }
      }
      if (!silent) {
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

  Future<void> _triggerIncomingNotification(
      String senderName, String text) async {
    try {
      await SystemSound.play(SystemSoundType.alert);
      await HapticFeedback.heavyImpact();
    } catch (_) {}

    if (Platform.isAndroid && notificationsEnabled) {
      try {
        await _nativeChannel.invokeMethod('showNotification', {
          'title': 'Маяк: $senderName',
          'body': text,
        });
      } catch (_) {}
    }
  }

  void _upsertContact({
    required String nodeId,
    required String dhPubHex,
    required String signPubHex,
    String? nick,
    String? address,
  }) {
    if (nodeId.isEmpty || nodeId == this.nodeId) return;
    final existing = knownContacts[nodeId];
    final isPeerConnected =
        _tcpPeers.containsValue(nodeId) || _blePeers.containsValue(nodeId);
    if (existing != null) {
      if (nick != null &&
          nick.trim().isNotEmpty &&
          !nick.startsWith('Узел ')) {
        existing.nickname = nick.trim();
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
        nickname: (nick != null && nick.trim().isNotEmpty)
            ? nick.trim()
            : 'Узел $nodeId',
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
    // Проверяем, нет ли уже открытого сокета с этим IP
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
              // ФИКС ГОНКИ ВСТРЕЧНЫХ СОЕДИНЕНИЙ: НЕ убиваем новый сокет, чтобы оба телефона не разорвали связь!
              _tcpPeers[socket] = peerId;
              _refreshOnlineStatuses();
              _addLog('Подключен: $peerNick ($peerId)');

              // Делимся списком известных узлов (Mesh Gossip)
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
        _upsertContact(
          nodeId: peerId,
          dhPubHex: map['dh'] as String,
          signPubHex: map['sg'] as String,
          nick: peerNick,
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

  /// Отправка сообщения в личный чат ИЛИ в Общий эфир (BROADCAST)
  Future<void> sendMessage(String targetNodeId, String plainText) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = _randomHex(16);

    if (targetNodeId == broadcastChannelId) {
      final sigPayload =
          utf8.encode('$msgId|$broadcastChannelId|${ base64Encode(utf8.encode(plainText)) }');
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
        ciphertextHex: base64Encode(utf8.encode(plainText)),
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

    final ephKeyPair = await _x25519.newKeyPair();
    final ephPub = await ephKeyPair.extractPublicKey();

    final recipientDhPub = SimplePublicKey(
      _fromHex(contact.dhPubHex),
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

    final sigPayload =
        utf8.encode('$msgId|$targetNodeId|${_toHex(secretBox.cipherText)}');
    final sig = await _ed25519.sign(sigPayload, keyPair: _signKeyPair);

    final pkt = MeshPacket(
      type: 'DATA',
      msgId: msgId,
      dstNodeId: targetNodeId,
      srcNickname: nickname,
      srcSignPubHex: signPubHex,
      srcDhPubHex: dhPubHex,
      dstSignPubHex: contact.signPubHex,
      ephPubHex: _toHex(ephPub.bytes),
      nonceHex: _toHex(nonce),
      ciphertextHex: _toHex(secretBox.cipherText),
      macHex: _toHex(secretBox.mac.bytes),
      signatureHex: _toHex(sig.bytes),
      expiresAt: now + 3600 * 1000,
      ttl: 7,
    );

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

    transitBuffer[msgId] = pkt;
    _floodAllTransports(pkt);
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

    // Обработка широковещательного сообщения в Общий эфир
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
      unawaited(
          _triggerIncomingNotification('Общий эфир ($senderName)', decodedText));
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

    final sigValid = await _ed25519.verify(
      utf8.encode('${pkt.msgId}|${pkt.dstNodeId}|${pkt.ciphertextHex}'),
      signature: Signature(
        _fromHex(pkt.signatureHex),
        publicKey: SimplePublicKey(
            _fromHex(pkt.srcSignPubHex), type: KeyPairType.ed25519),
      ),
    );
    if (!sigValid) return;

    if (pkt.dstNodeId == nodeId) {
      final shared = await _x25519.sharedSecretKey(
        keyPair: _dhKeyPair,
        remotePublicKey:
            SimplePublicKey(_fromHex(pkt.ephPubHex), type: KeyPairType.x25519),
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
      _upsertContact(
        nodeId: senderId,
        dhPubHex: pkt.srcDhPubHex,
        signPubHex: pkt.srcSignPubHex,
        nick: pkt.srcNickname,
      );
      final contact = knownContacts[senderId]!;
      final decodedText = utf8.decode(clearBytes);

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
      unawaited(_triggerIncomingNotification(contact.displayTitle, decodedText));
      unawaited(_saveContactsAndChats());

      final ackSig = await _ed25519.sign(
        utf8.encode('ACK:${pkt.msgId}'),
        keyPair: _signKeyPair,
      );
      final ackPkt = MeshPacket(
        type: 'ACK',
        msgId: pkt.msgId,
        dstNodeId: senderId,
        srcNickname: nickname,
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
          publicKey: SimplePublicKey(
              _fromHex(stored.dstSignPubHex), type: KeyPairType.ed25519),
        ),
      );
      if (!valid) return;
      transitBuffer.remove(ack.msgId);
    }

    // Отмечаем галочкой ✓✓ доставленное сообщение в истории чата
    for (final list in chatHistory.values) {
      for (final m in list) {
        if (m.msgId == ack.msgId) {
          m.isDelivered = true;
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
              if (peerId != nodeId) {
                _upsertContact(
                  nodeId: peerId,
                  dhPubHex: data['dh'] as String,
                  signPubHex: data['sg'] as String,
                  nick: peerNick,
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

      _beaconTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
        if (nodeId.isEmpty || listenPort <= 0) return;
        final beacon = utf8.encode(jsonEncode({
          'id': nodeId,
          'nick': nickname,
          'p': listenPort,
          'dh': dhPubHex,
          'sg': signPubHex,
        }));
        try {
          _udpBeacon?.send(
              beacon, InternetAddress('255.255.255.255'), discoveryPort);
        } catch (_) {}

        final ips = await getLocalIPv4Addresses();
        for (final ip in ips) {
          final parts = ip.split('.');
          if (parts.length == 4 && parts[0] != '127') {
            final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            try {
              _udpBeacon?.send(
                  beacon, InternetAddress(subnetBroadcast), discoveryPort);
            } catch (_) {}

            try {
              final ifaceSocket =
                  await RawDatagramSocket.bind(InternetAddress(ip), 0);
              ifaceSocket.broadcastEnabled = true;
              ifaceSocket.send(
                  beacon, InternetAddress(subnetBroadcast), discoveryPort);
              ifaceSocket.close();
            } catch (_) {}
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
