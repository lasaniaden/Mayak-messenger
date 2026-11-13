import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _MciSendStringNative = Int32 Function(
  Pointer<Uint16> command,
  Pointer<Uint16> buffer,
  Uint32 bufferSize,
  IntPtr callback,
);
typedef _MciSendStringDart = int Function(
  Pointer<Uint16> command,
  Pointer<Uint16> buffer,
  int bufferSize,
  int callback,
);
typedef _CoTaskMemAllocNative = Pointer<Void> Function(IntPtr cb);
typedef _CoTaskMemAllocDart = Pointer<Void> Function(int cb);
typedef _CoTaskMemFreeNative = Void Function(Pointer<Void> pv);
typedef _CoTaskMemFreeDart = void Function(Pointer<Void> pv);

class WindowsMciAudioBridge {
  static _MciSendStringDart? _mciSend;
  static _CoTaskMemAllocDart? _alloc;
  static _CoTaskMemFreeDart? _free;
  static bool _initialized = false;

  static void _init() {
    if (_initialized || !Platform.isWindows) return;
    _initialized = true;
    try {
      final winmm = DynamicLibrary.open('winmm.dll');
      final ole32 = DynamicLibrary.open('ole32.dll');
      _mciSend = winmm
          .lookupFunction<_MciSendStringNative, _MciSendStringDart>(
              'mciSendStringW');
      _alloc = ole32.lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAllocDart>(
          'CoTaskMemAlloc');
      _free = ole32.lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
          'CoTaskMemFree');
    } catch (_) {}
  }

  static String cmd(String command) {
    _init();
    if (_mciSend == null || _alloc == null || _free == null) return '';
    final cmdUnits = command.codeUnits;
    final cmdPtr = _alloc!((cmdUnits.length + 1) * 2).cast<Uint16>();
    final bufPtr = _alloc!(512 * 2).cast<Uint16>();
    try {
      for (int i = 0; i < cmdUnits.length; i++) {
        cmdPtr[i] = cmdUnits[i];
      }
      cmdPtr[cmdUnits.length] = 0;
      for (int i = 0; i < 512; i++) {
        bufPtr[i] = 0;
      }
      _mciSend!(cmdPtr, bufPtr, 510, 0);
      final outUnits = <int>[];
      for (int i = 0; i < 510; i++) {
        final c = bufPtr[i];
        if (c == 0) break;
        outUnits.add(c);
      }
      return String.fromCharCodes(outUnits).trim();
    } finally {
      _free!(cmdPtr.cast());
      _free!(bufPtr.cast());
    }
  }
}

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
  double transferProgress;
  Map<String, String> reactions;

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
    Map<String, String>? reactions,
  }) : reactions = reactions ?? {};

  bool get isImageFile {
    final name = (fileName ?? filePath ?? '').toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.webp') ||
        name.endsWith('.gif') ||
        name.endsWith('.bmp');
  }

  bool get isVideoFile {
    final name = (fileName ?? filePath ?? '').toLowerCase();
    return name.endsWith('.mp4') ||
        name.endsWith('.mkv') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm') ||
        name.endsWith('.avi') ||
        name.endsWith('.3gp');
  }

  bool get isAudioFile {
    final name = (fileName ?? filePath ?? '').toLowerCase();
    return name.endsWith('.m4a') ||
        name.endsWith('.mp3') ||
        name.endsWith('.wav') ||
        name.endsWith('.ogg') ||
        name.endsWith('.flac') ||
        name.endsWith('.aac') ||
        name.endsWith('.opus');
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
        'rx': reactions,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final rawRx = j['rx'];
    final rxMap = <String, String>{};
    if (rawRx is Map) {
      rawRx.forEach((k, v) {
        rxMap[k.toString()] = v.toString();
      });
    }
    return ChatMessage(
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
      reactions: rxMap,
    );
  }
}

class PendingFileJob {
  final String fileId;
  final String targetNodeId;
  final String filePath;
  final String fileName;
  int nextChunkIndex;
  bool isSending;

  PendingFileJob({
    required this.fileId,
    required this.targetNodeId,
    required this.filePath,
    required this.fileName,
    this.nextChunkIndex = 0,
    this.isSending = false,
  });

  Map<String, dynamic> toJson() => {
        'fid': fileId,
        'dst': targetNodeId,
        'fp': filePath,
        'fn': fileName,
        'nxt': nextChunkIndex,
      };

  factory PendingFileJob.fromJson(Map<String, dynamic> j) => PendingFileJob(
        fileId: j['fid'] as String,
        targetNodeId: j['dst'] as String,
        filePath: j['fp'] as String,
        fileName: j['fn'] as String,
        nextChunkIndex: (j['nxt'] as int?) ?? 0,
      );
}

/// Потоковый сборщик больших файлов (до 1 ГБ) с единым открытым дескриптором RandomAccessFile!
class IncomingFileStreamAssembly {
  final String fileId;
  final String fileName;
  final int totalSize;
  final int totalChunks;
  final String partFilePath;
  final int createdAtMs;
  RandomAccessFile? openRaf;
  final Set<int> receivedChunkIndices = {};

  IncomingFileStreamAssembly({
    required this.fileId,
    required this.fileName,
    required this.totalSize,
    required this.totalChunks,
    required this.partFilePath,
    required this.createdAtMs,
    this.openRaf,
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
  int lastPingMs;
  int packetsSeenCount;
  int lastSeenTimestamp;

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
    this.lastPingMs = -1,
    this.packetsSeenCount = 0,
    this.lastSeenTimestamp = 0,
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
  final String type;
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

class BenchmarkReport {
  final double chachaMbPerSec;
  final int x25519HandshakesPerSec;
  final int ed25519SignsPerSec;
  final Map<String, int> peerPingsMs;
  final bool readyForVoicePtt;
  final bool readyForVideoCalls;

  BenchmarkReport({
    required this.chachaMbPerSec,
    required this.x25519HandshakesPerSec,
    required this.ed25519SignsPerSec,
    required this.peerPingsMs,
    required this.readyForVoicePtt,
    required this.readyForVideoCalls,
  });
}

class MeshEngine {
  static const String broadcastChannelId = 'BROADCAST';
  static const int discoveryPort = 42069;
  static const int defaultTcpPort = 42070;
  static const int maxBufferPackets = 400;
  static const int maxLineLengthBytes = 220 * 1024;
  static const int maxConcurrentIncomingFiles = 8;
  static const int fileChunkSize = 32 * 1024;
  static const String serviceId = 'com.p2pmesh.intercom';
  static const MethodChannel _nativeChannel = MethodChannel('mayak/native');

  // КРИПТОГРАФИЧЕСКАЯ ЗАЩИТА КОНСОЛИ АДМИНА (сама секретная фраза в коде НЕ хранится!)
  static const String _adminAuthHashHex =
      'f6e05d33ffb089dd5dc55f21aac369b78f87cf2f6bdeceff4b90769fb9b7e4cb';
  static const String _adminMasterPubHex =
      'c8710970e7334ca7849340676b1b3e7210b4ad1f6b24325c36b9c747df30a47f';

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _cipher = Chacha20.poly1305Aead();
  final _sha256 = Sha256();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  late SimpleKeyPair _signKeyPair;
  late SimpleKeyPair _dhKeyPair;
  SimpleKeyPair? _unlockedAdminMasterKeyPair;
  bool isAdminUnlocked = false;

  String nodeId = '';
  String nickname = '';
  String dhPubHex = '';
  String signPubHex = '';
  String myHwFingerprint = '';

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpBeacon;
  Timer? _beaconTimer;
  Timer? _audioProgressTimer;
  int listenPort = 0;
  bool bleMeshActive = false;
  bool bgServiceActive = false;
  bool isScanningSubnet = false;
  bool vpnDetected = false;
  bool gpsDisabledOnAndroid = false;
  bool notificationsEnabled = true;

  bool isRecordingVoice = false;
  int _winVoiceStartMs = 0;
  String? currentlyPlayingAudioPath;
  bool isAudioPlaying = false;
  int audioPositionMs = 0;
  int audioDurationMs = 1;

  String? activeOpenChatId;
  int unreadBroadcastCount = 0;
  String lastStatusLog = 'Запуск ядра...';
  final List<String> debugLogs = [];

  List<String> cachedIps = ['127.0.0.1'];
  String _previousPrimaryIp = '';
  String cachedInviteCode = '';
  int _lastIpRefreshMs = 0;

  final Map<Socket, String> _tcpPeers = {};
  final Set<String> _connectingHosts = {};
  final Map<String, String> _blePeers = {};

  final Queue<String> _seenPacketQueue = Queue<String>();
  final Set<String> _seenPacketSet = {};
  final Set<String> deletedContactIds = {};

  // Глобальный список забаненных администратором узлов и их аппаратных отпечатков
  final Set<String> bannedNodeIds = {};
  final Set<String> bannedHwFingerprints = {};

  final Map<String, List<int>> _staticSharedSecretCache = {};
  final Map<String, IncomingFileStreamAssembly> _incomingFiles = {};
  final Map<String, PendingFileJob> pendingFileJobs = {};
  final Map<String, Completer<void>> _fileWindowAckWaiters = {};
  final Map<String, int> _pendingPingTimestamps = {};
  final Map<String, Completer<int>> _pingCompleters = {};

  Future<void> _rxProcessingChain = Future.value();

  final Map<String, MeshPacket> transitBuffer = {};
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

  MethodChannel get nativeChannel => _nativeChannel;

  bool isNodeBanned(String targetNodeId, [String hw = '']) {
    if (bannedNodeIds.contains(targetNodeId)) return true;
    if (hw.isNotEmpty && bannedHwFingerprints.contains(hw)) return true;
    final c = knownContacts[targetNodeId];
    if (c != null &&
        c.hwFingerprint.isNotEmpty &&
        bannedHwFingerprints.contains(c.hwFingerprint)) {
      return true;
    }
    return false;
  }

  /// Проверка секретной фразы для открытия скрытой консоли Админа и генерации мастер-ключа Ed25519 в ОЗУ
  Future<bool> tryUnlockAdminConsole(String candidatePhrase) async {
    final clean = candidatePhrase.trim();
    final digest =
        await _sha256.hash(utf8.encode('MAYAK-ADMIN-AUTH-SALT-V1|$clean'));
    if (_toHex(digest.bytes) != _adminAuthHashHex) {
      return false;
    }
    final seedDigest =
        await _sha256.hash(utf8.encode('MAYAK-ADMIN-ED25519-SEED-V1|$clean'));
    _unlockedAdminMasterKeyPair =
        await _ed25519.newKeyPairFromSeed(seedDigest.bytes);
    isAdminUnlocked = true;
    onStateChanged();
    return true;
  }

  /// Подписанная мастер-ключом команда глобального Бана или Разбана узла по всей сети
  Future<void> executeAdminBanOrUnban({
    required String targetNodeId,
    required bool ban,
  }) async {
    final masterKp = _unlockedAdminMasterKeyPair;
    if (masterKp == null) return;

    final targetHw = knownContacts[targetNodeId]?.hwFingerprint ?? '';
    final action = ban ? 'BAN' : 'UNBAN';
    if (ban) {
      bannedNodeIds.add(targetNodeId);
      if (targetHw.isNotEmpty) bannedHwFingerprints.add(targetHw);
      _disconnectBannedPeerImmediately(targetNodeId);
    } else {
      bannedNodeIds.remove(targetNodeId);
      if (targetHw.isNotEmpty) bannedHwFingerprints.remove(targetHw);
    }
    await _saveContactsAndChats();
    onStateChanged();

    final now = DateTime.now().millisecondsSinceEpoch;
    final pktId = _randomHex(12);
    final expiresAt = now + 24 * 3600 * 1000;
    final cmdPayloadJson = jsonEncode({
      'act': action,
      'target': targetNodeId,
      'hw': targetHw,
      'ts': now,
    });
    final b64Payload = base64Encode(utf8.encode(cmdPayloadJson));
    final sigBytes =
        utf8.encode('ADMIN_CMD|$pktId|$expiresAt|$b64Payload');
    final adminSig = await _ed25519.sign(sigBytes, keyPair: masterKp);

    final pkt = MeshPacket(
      type: 'BROADCAST',
      msgId: pktId,
      dstNodeId: broadcastChannelId,
      srcNickname: '',
      srcSignPubHex: _adminMasterPubHex,
      srcDhPubHex: dhPubHex,
      dstSignPubHex: '',
      ephPubHex: 'ADMIN_CMD',
      nonceHex: '',
      ciphertextHex: b64Payload,
      macHex: '',
      signatureHex: _toHex(adminSig.bytes),
      expiresAt: expiresAt,
      ttl: 7,
    );

    _markPacketSeen(pktId);
    transitBuffer[pktId] = pkt;
    _floodAllTransports(pkt);
  }

  void _disconnectBannedPeerImmediately(String targetNodeId) {
    for (final entry in _tcpPeers.entries.toList()) {
      if (entry.value == targetNodeId) {
        _cleanupSocket(entry.key);
      }
    }
    _blePeers.removeWhere((_, v) => v == targetNodeId);
    transitBuffer.removeWhere((_, p) => p.dstNodeId == targetNodeId);
    _refreshOnlineStatuses();
  }

  bool _markPacketSeen(String id) {
    if (_seenPacketSet.contains(id)) return false;
    _seenPacketSet.add(id);
    _seenPacketQueue.addLast(id);
    while (_seenPacketQueue.length > 4000) {
      final oldest = _seenPacketQueue.removeFirst();
      _seenPacketSet.remove(oldest);
    }
    return true;
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

  Future<void> clearChatHistoryOnly(String targetNodeId) async {
    chatHistory[targetNodeId] = [];
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> deleteContact(String targetNodeId) async {
    deletedContactIds.add(targetNodeId);
    knownContacts.remove(targetNodeId);
    chatHistory.remove(targetNodeId);
    _staticSharedSecretCache.remove(targetNodeId);
    pendingFileJobs.removeWhere((_, job) => job.targetNodeId == targetNodeId);
    myPersistentOutbox.removeWhere((_, pkt) => pkt.dstNodeId == targetNodeId);
    transitBuffer.removeWhere((_, pkt) => pkt.dstNodeId == targetNodeId);
    if (activeOpenChatId == targetNodeId) {
      activeOpenChatId = null;
    }
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> stopAllAndExitApp() async {
    await stopAudioPlayback();
    for (final a in _incomingFiles.values) {
      try {
        await a.openRaf?.close();
      } catch (_) {}
    }
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

  Future<BenchmarkReport> runBenchmarkAndPing() async {
    final sampleBlock = _randomBytes(256 * 1024);
    final tempKey = SecretKey(_randomBytes(32));
    final tempNonce = _randomBytes(12);
    final swCipher = Stopwatch()..start();
    for (int i = 0; i < 8; i++) {
      await _cipher.encrypt(sampleBlock, secretKey: tempKey, nonce: tempNonce);
    }
    swCipher.stop();
    final elapsedSec = max(swCipher.elapsedMicroseconds / 1000000.0, 0.001);
    final mbPerSec = 2.0 / elapsedSec;

    final remoteKp = await _x25519.newKeyPair();
    final remotePub = await remoteKp.extractPublicKey();
    final swDh = Stopwatch()..start();
    const dhIterations = 20;
    for (int i = 0; i < dhIterations; i++) {
      final shared = await _x25519.sharedSecretKey(
        keyPair: _dhKeyPair,
        remotePublicKey: remotePub,
      );
      await _hkdf.deriveKey(
        secretKey: shared,
        nonce: const [1, 2, 3, 4],
        info: const [5, 6],
      );
    }
    swDh.stop();
    final dhPerSec =
        (dhIterations / max(swDh.elapsedMicroseconds / 1000000.0, 0.001))
            .round();

    final msgBytes = utf8.encode('Mayak benchmark payload verification test');
    final swSign = Stopwatch()..start();
    const signIterations = 20;
    for (int i = 0; i < signIterations; i++) {
      final sig = await _ed25519.sign(msgBytes, keyPair: _signKeyPair);
      await _ed25519.verify(msgBytes, signature: sig);
    }
    swSign.stop();
    final signsPerSec =
        (signIterations / max(swSign.elapsedMicroseconds / 1000000.0, 0.001))
            .round();

    final pings = <String, int>{};
    final activePeerIds = {..._tcpPeers.values, ..._blePeers.values};
    for (final pid in activePeerIds) {
      final rtt = await pingPeer(pid);
      final name = knownContacts[pid]?.displayTitle ?? pid;
      pings[name] = rtt;
    }

    return BenchmarkReport(
      chachaMbPerSec: mbPerSec,
      x25519HandshakesPerSec: dhPerSec,
      ed25519SignsPerSec: signsPerSec,
      peerPingsMs: pings,
      readyForVoicePtt: mbPerSec >= 1.5 && dhPerSec >= 10,
      readyForVideoCalls: mbPerSec >= 8.0 && dhPerSec >= 25,
    );
  }

  Future<int> pingPeer(String peerId) async {
    final pingId = _randomHex(8);
    final comp = Completer<int>();
    _pendingPingTimestamps[pingId] = DateTime.now().millisecondsSinceEpoch;
    _pingCompleters[pingId] = comp;

    final payload = jsonEncode({
      'ping_req': pingId,
      'from': nodeId,
    });

    for (final entry in _tcpPeers.entries) {
      if (entry.value == peerId) {
        _sendTcpLine(entry.key, payload);
      }
    }
    for (final entry in _blePeers.entries) {
      if (entry.value == peerId) {
        unawaited(_sendBleLine(entry.key, payload));
      }
    }

    return comp.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _pendingPingTimestamps.remove(pingId);
        _pingCompleters.remove(pingId);
        return -1;
      },
    );
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
        case 'onAudioCompleted':
          currentlyPlayingAudioPath = null;
          isAudioPlaying = false;
          audioPositionMs = 0;
          _audioProgressTimer?.cancel();
          onStateChanged();
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

    await refreshNetworkCache(force: true);
    await _startLanAutoDiscovery();
    _addLog('Защищенный узел v1.3 готов (порт $listenPort)');

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

  Future<File> _getExternalBackupFile() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download/Mayak');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File('${dir.path}/.mayak_backup_v12.json');
    } else {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '.';
      final dir = Directory('$home/Downloads/Mayak');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File('${dir.path}/.mayak_backup_v12.json');
    }
  }

  Future<void> _loadPersistedContactsAndChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deletedRaw = prefs.getStringList('deleted_contacts_v11') ?? [];
      deletedContactIds.addAll(deletedRaw);

      final bannedIdsRaw = prefs.getStringList('banned_nodes_v13') ?? [];
      bannedNodeIds.addAll(bannedIdsRaw);

      final bannedHwRaw = prefs.getStringList('banned_hw_v13') ?? [];
      bannedHwFingerprints.addAll(bannedHwRaw);

      String? contactsRaw = prefs.getString('saved_contacts_v7');
      String? chatsRaw = prefs.getString('saved_chats_v7');

      if ((contactsRaw == null || contactsRaw.isEmpty) &&
          (chatsRaw == null || chatsRaw.isEmpty)) {
        try {
          final bkpFile = await _getExternalBackupFile();
          if (await bkpFile.exists()) {
            final bkpMap = jsonDecode(await bkpFile.readAsString())
                as Map<String, dynamic>;
            contactsRaw = bkpMap['contacts'] as String?;
            chatsRaw = bkpMap['chats'] as String?;
            if (bkpMap['nick'] is String &&
                (bkpMap['nick'] as String).isNotEmpty) {
              nickname = bkpMap['nick'] as String;
              await prefs.setString('user_nickname', nickname);
            }
          }
        } catch (_) {}
      }

      if (contactsRaw != null && contactsRaw.isNotEmpty) {
        final list = jsonDecode(contactsRaw) as List;
        for (final item in list) {
          final c =
              ContactProfile.fromJson(Map<String, dynamic>.from(item as Map));
          if (c.nodeId != nodeId && !deletedContactIds.contains(c.nodeId)) {
            knownContacts[c.nodeId] = c;
          }
        }
      }

      if (chatsRaw != null && chatsRaw.isNotEmpty) {
        final map = jsonDecode(chatsRaw) as Map<String, dynamic>;
        map.forEach((peerId, msgsJson) {
          if (deletedContactIds.contains(peerId)) return;
          final list = (msgsJson as List)
              .map((m) =>
                  ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
              .toList();
          chatHistory[peerId] = list;
        });
      }

      final outboxRaw = prefs.getString('saved_outbox_v9');
      if (outboxRaw != null && outboxRaw.isNotEmpty) {
        final list = jsonDecode(outboxRaw) as List;
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final item in list) {
          final pkt =
              MeshPacket.fromJson(Map<String, dynamic>.from(item as Map));
          if (pkt.expiresAt > now &&
              !deletedContactIds.contains(pkt.dstNodeId)) {
            myPersistentOutbox[pkt.msgId] = pkt;
            transitBuffer[pkt.msgId] = pkt;
          }
        }
      }

      final pendingFilesRaw = prefs.getString('saved_pending_files_v11');
      if (pendingFilesRaw != null && pendingFilesRaw.isNotEmpty) {
        final list = jsonDecode(pendingFilesRaw) as List;
        for (final item in list) {
          final job =
              PendingFileJob.fromJson(Map<String, dynamic>.from(item as Map));
          if (!deletedContactIds.contains(job.targetNodeId) &&
              File(job.filePath).existsSync()) {
            pendingFileJobs[job.fileId] = job;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveContactsAndChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'deleted_contacts_v11', deletedContactIds.toList());
      await prefs.setStringList('banned_nodes_v13', bannedNodeIds.toList());
      await prefs.setStringList('banned_hw_v13', bannedHwFingerprints.toList());

      final contactsJson =
          jsonEncode(knownContacts.values.map((c) => c.toJson()).toList());
      await prefs.setString('saved_contacts_v7', contactsJson);

      final chatsMap = <String, dynamic>{};
      chatHistory.forEach((peerId, list) {
        final trimmed =
            list.length > 100 ? list.sublist(list.length - 100) : list;
        chatsMap[peerId] = trimmed.map((m) => m.toJson()).toList();
      });
      final chatsJson = jsonEncode(chatsMap);
      await prefs.setString('saved_chats_v7', chatsJson);

      final outboxList =
          myPersistentOutbox.values.map((p) => p.toJson()).toList();
      await prefs.setString('saved_outbox_v9', jsonEncode(outboxList));

      final filesList =
          pendingFileJobs.values.map((j) => j.toJson()).toList();
      await prefs.setString('saved_pending_files_v11', jsonEncode(filesList));

      try {
        final bkpFile = await _getExternalBackupFile();
        await bkpFile.writeAsString(jsonEncode({
          'nick': nickname,
          'contacts': contactsJson,
          'chats': chatsJson,
        }));
      } catch (_) {}
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

    await refreshNetworkCache(force: true);
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
        .where((c) => !isNodeBanned(c.nodeId, c.hwFingerprint))
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

  Future<void> refreshNetworkCache({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastIpRefreshMs < 4000 && cachedInviteCode.isNotEmpty) {
      return;
    }
    _lastIpRefreshMs = now;
    final newIps = await getLocalIPv4Addresses();
    final primaryIp = newIps.isNotEmpty ? newIps.first : '127.0.0.1';

    if (_previousPrimaryIp.isNotEmpty && _previousPrimaryIp != primaryIp) {
      _addLog(
          'Смена сети ($_previousPrimaryIp -> $primaryIp), обновление связей...');
      for (final s in _tcpPeers.keys.toList()) {
        _cleanupSocket(s);
      }
      if (Platform.isAndroid) {
        try {
          await _nativeChannel.invokeMethod('acquireMulticastLock');
        } catch (_) {}
      }
      unawaited(scanLocalSubnet(quickOnly: true));
    }
    _previousPrimaryIp = primaryIp;
    cachedIps = newIps;

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
      await connectToHost(host, port, forceNewConnection: true);
      return null;
    }

    final decoded = jsonDecode(utf8.decode(base64Url.decode(input)))
        as Map<String, dynamic>;
    final port = (decoded['p'] as int?) ?? defaultTcpPort;
    final targetId = decoded['id'] as String;
    final targetDh = decoded['dh'] as String;
    final targetSign = decoded['sg'] as String;
    final targetNick = (decoded['nick'] as String?) ?? 'Узел $targetId';
    final targetHw = (decoded['hw'] as String?) ?? '';

    final verifiedId = await _calcNodeId(_fromHex(targetDh));
    if (verifiedId != targetId) {
      _addLog('⚠️ Отклонен поддельный инвайт-код (не совпадает хеш ключа)!');
      return null;
    }

    deletedContactIds.remove(targetId);

    final List<String> candidateIps = [];
    if (decoded['ips'] is List) {
      candidateIps.addAll((decoded['ips'] as List).map((e) => e.toString()));
    } else if (decoded['ip'] is String) {
      candidateIps.add(decoded['ip'] as String);
    }

    _upsertContact(
      nodeId: targetId,
      dhPubHex: targetDh,
      signPubHex: targetSign,
      nick: targetNick,
      hwFingerprint: targetHw,
      address: candidateIps.isNotEmpty ? '${candidateIps.first}:$port' : '',
      allowEvenIfDeleted: true,
    );

    for (final ip in candidateIps) {
      unawaited(connectToHost(ip, port,
          expectedNodeId: targetId, forceNewConnection: true));
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
      await refreshNetworkCache(force: true);
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
      notificationsEnabled = true;
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

  Future<Map<String, dynamic>?> pickFileForChat({String mode = 'all'}) async {
    try {
      if (Platform.isAndroid) {
        final res = await _nativeChannel.invokeMapMethod<String, dynamic>(
          'pickFile',
          {'mode': mode},
        );
        return res;
      } else if (Platform.isWindows) {
        final filter = mode == 'media'
            ? 'Media (*.jpg;*.jpeg;*.png;*.webp;*.gif;*.mp4;*.mkv;*.mov;*.webm)|*.jpg;*.jpeg;*.png;*.webp;*.gif;*.mp4;*.mkv;*.mov;*.webm|All files (*.*)|*.*'
            : (mode == 'audio'
                ? 'Audio (*.mp3;*.m4a;*.wav;*.ogg;*.flac;*.aac)|*.mp3;*.m4a;*.wav;*.ogg;*.flac;*.aac|All files (*.*)|*.*'
                : 'All files (*.*)|*.*');
        final psScript =
            "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
            "Add-Type -AssemblyName System.Windows.Forms; "
            "\$f = New-Object System.Windows.Forms.Form; \$f.TopMost = \$true; "
            "\$dlg = New-Object System.Windows.Forms.OpenFileDialog; "
            "\$dlg.Filter = '$filter'; "
            "if (\$dlg.ShowDialog(\$f) -eq 'OK') { [Console]::Out.WriteLine(\$dlg.FileName) }";
        final proc = await Process.run(
          'powershell',
          ['-NoProfile', '-STA', '-Command', psScript],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        final selectedPath = proc.stdout.toString().trim();
        if (selectedPath.isEmpty) return null;
        final file = File(selectedPath);
        if (!await file.exists()) {
          _addLog('Файл не найден по пути: $selectedPath');
          return null;
        }
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

  Future<bool> startVoiceRecording() async {
    if (Platform.isAndroid) {
      try {
        final ok =
            await _nativeChannel.invokeMethod<bool>('startVoiceRecord') ??
                false;
        isRecordingVoice = ok;
        onStateChanged();
        return ok;
      } catch (_) {
        return false;
      }
    } else if (Platform.isWindows) {
      try {
        WindowsMciAudioBridge.cmd('close mayak_rec');
        WindowsMciAudioBridge.cmd('open new type waveaudio alias mayak_rec');
        WindowsMciAudioBridge.cmd('record mayak_rec');
        _winVoiceStartMs = DateTime.now().millisecondsSinceEpoch;
        isRecordingVoice = true;
        onStateChanged();
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<Map<String, dynamic>?> stopVoiceRecording() async {
    isRecordingVoice = false;
    onStateChanged();
    if (Platform.isAndroid) {
      try {
        final res = await _nativeChannel
            .invokeMapMethod<String, dynamic>('stopVoiceRecord');
        return res;
      } catch (_) {
        return null;
      }
    } else if (Platform.isWindows) {
      try {
        final dir = await _getReceivedFilesDir();
        final durSec =
            ((DateTime.now().millisecondsSinceEpoch - _winVoiceStartMs) / 1000)
                .round()
                .clamp(1, 3600);
        final outPath =
            '${dir.path}\\voice_${DateTime.now().millisecondsSinceEpoch}.wav';
        WindowsMciAudioBridge.cmd('stop mayak_rec');
        WindowsMciAudioBridge.cmd('save mayak_rec "$outPath"');
        WindowsMciAudioBridge.cmd('close mayak_rec');
        final f = File(outPath);
        if (await f.exists() && await f.length() > 0) {
          return {
            'path': outPath,
            'name': 'Голосовое_${durSec}сек.wav',
            'size': await f.length(),
            'durationSec': durSec,
          };
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> togglePlayAudioFile(String filePath) async {
    if (Platform.isAndroid) {
      final info = await _nativeChannel
          .invokeMapMethod<String, dynamic>('playAudioFile', {'path': filePath});
      if (info != null) {
        currentlyPlayingAudioPath = filePath;
        isAudioPlaying = (info['isPlaying'] as bool?) ?? false;
        audioPositionMs = (info['positionMs'] as int?) ?? 0;
        audioDurationMs = max((info['durationMs'] as int?) ?? 1, 1);
        _startAudioProgressPolling();
        onStateChanged();
      }
    } else if (Platform.isWindows) {
      if (currentlyPlayingAudioPath == filePath) {
        if (isAudioPlaying) {
          WindowsMciAudioBridge.cmd('pause mayak_audio');
          isAudioPlaying = false;
        } else {
          WindowsMciAudioBridge.cmd('resume mayak_audio');
          isAudioPlaying = true;
        }
        onStateChanged();
        return;
      }
      WindowsMciAudioBridge.cmd('close mayak_audio');
      final cleanPath = filePath.replaceAll('/', '\\');
      WindowsMciAudioBridge.cmd(
          'open "$cleanPath" type mpegvideo alias mayak_audio');
      final lenStr = WindowsMciAudioBridge.cmd('status mayak_audio length');
      audioDurationMs = max(int.tryParse(lenStr) ?? 1000, 1);
      audioPositionMs = 0;
      WindowsMciAudioBridge.cmd('play mayak_audio');
      currentlyPlayingAudioPath = filePath;
      isAudioPlaying = true;
      _startAudioProgressPolling();
      onStateChanged();
    }
  }

  Future<void> seekAudioFile(int newPositionMs) async {
    final targetMs = newPositionMs.clamp(0, audioDurationMs);
    audioPositionMs = targetMs;
    onStateChanged();
    if (Platform.isAndroid) {
      await _nativeChannel
          .invokeMethod('seekAudioFile', {'positionMs': targetMs});
    } else if (Platform.isWindows && currentlyPlayingAudioPath != null) {
      WindowsMciAudioBridge.cmd('seek mayak_audio to $targetMs');
      if (isAudioPlaying) {
        WindowsMciAudioBridge.cmd('play mayak_audio');
      }
    }
  }

  Future<void> stopAudioPlayback() async {
    _audioProgressTimer?.cancel();
    currentlyPlayingAudioPath = null;
    isAudioPlaying = false;
    audioPositionMs = 0;
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopAudioFile');
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsMciAudioBridge.cmd('close mayak_audio');
    }
    onStateChanged();
  }

  void _startAudioProgressPolling() {
    _audioProgressTimer?.cancel();
    _audioProgressTimer =
        Timer.periodic(const Duration(milliseconds: 300), (_) async {
      if (currentlyPlayingAudioPath == null) {
        _audioProgressTimer?.cancel();
        return;
      }
      if (Platform.isAndroid) {
        final st = await _nativeChannel
            .invokeMapMethod<String, dynamic>('getAudioStatus');
        if (st == null) {
          currentlyPlayingAudioPath = null;
          isAudioPlaying = false;
          _audioProgressTimer?.cancel();
        } else {
          isAudioPlaying = (st['isPlaying'] as bool?) ?? false;
          audioPositionMs = (st['positionMs'] as int?) ?? 0;
          audioDurationMs = max((st['durationMs'] as int?) ?? 1, 1);
        }
        onStateChanged();
      } else if (Platform.isWindows) {
        final posStr = WindowsMciAudioBridge.cmd('status mayak_audio position');
        final modeStr = WindowsMciAudioBridge.cmd('status mayak_audio mode');
        final pos = int.tryParse(posStr) ?? audioPositionMs;
        audioPositionMs = pos;
        if (modeStr.contains('stopped') && pos >= audioDurationMs - 200) {
          WindowsMciAudioBridge.cmd('close mayak_audio');
          currentlyPlayingAudioPath = null;
          isAudioPlaying = false;
          audioPositionMs = 0;
          _audioProgressTimer?.cancel();
        }
        onStateChanged();
      }
    });
  }

  Future<void> openFileExternal(String filePath) async {
    try {
      if (Platform.isAndroid) {
        await _nativeChannel
            .invokeMethod('openFileExternal', {'path': filePath});
      } else if (Platform.isWindows) {
        await Process.run('explorer', [filePath.replaceAll('/', '\\')]);
      }
    } catch (_) {}
  }

  Future<String> saveReceivedFileToDownloads(
      String srcPath, String fileName) async {
    try {
      final safeName = _sanitizeFileName(fileName);
      if (Platform.isAndroid) {
        final res = await _nativeChannel.invokeMethod<String>(
          'saveFileToDownloads',
          {'path': srcPath, 'name': safeName},
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
        final dstPath = '${dlDir.path}/$safeName';
        await File(srcPath).copy(dstPath);
        return 'Сохранено в: $dstPath';
      }
    } catch (e) {
      return 'Ошибка сохранения: $e';
    }
  }

  Future<void> sendReaction(
    String peerId,
    String targetMsgId,
    String emoji,
  ) async {
    final msgs = getMessagesFor(peerId);
    for (final m in msgs) {
      if (m.msgId == targetMsgId) {
        if (m.reactions[nodeId] == emoji) {
          m.reactions.remove(nodeId);
        } else {
          m.reactions[nodeId] = emoji;
        }
        break;
      }
    }
    unawaited(_saveContactsAndChats());
    onStateChanged();

    if (peerId == broadcastChannelId) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pktId = _randomHex(12);
      final expiresAt = now + 3600 * 1000;
      final rxJson = jsonEncode({
        'rx_msg': targetMsgId,
        'emoji': emoji,
      });
      final b64Payload = base64Encode(utf8.encode(rxJson));
      final sigPayload = utf8.encode(
          '$pktId|$broadcastChannelId|$dhPubHex|$expiresAt|$b64Payload');
      final sig = await _ed25519.sign(sigPayload, keyPair: _signKeyPair);

      final pkt = MeshPacket(
        type: 'BROADCAST',
        msgId: pktId,
        dstNodeId: broadcastChannelId,
        srcNickname: nickname,
        srcSignPubHex: signPubHex,
        srcDhPubHex: dhPubHex,
        dstSignPubHex: '',
        ephPubHex: 'REACTION',
        nonceHex: '',
        ciphertextHex: b64Payload,
        macHex: '',
        signatureHex: _toHex(sig.bytes),
        expiresAt: expiresAt,
        ttl: 5,
      );
      _markPacketSeen(pktId);
      _floodAllTransports(pkt);
      return;
    }

    final contact = knownContacts[peerId];
    if (contact == null) return;

    final pktId = _randomHex(12);
    final envelopeJson = jsonEncode({
      'v': 2,
      'kind': 'REACTION',
      'targetId': targetMsgId,
      'emoji': emoji,
      'nick': nickname,
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: peerId,
      contact: contact,
      msgId: pktId,
      sealedPayloadBytes: utf8.encode(envelopeJson),
      persistInOutbox: true,
    );
  }

  Future<void> sendFileMessage(
    String targetNodeId, {
    required String filePath,
    required String fileName,
    String? existingFileId,
  }) async {
    final contact = knownContacts[targetNodeId];
    if (contact == null || isNodeBanned(targetNodeId)) return;

    final file = File(filePath);
    if (!await file.exists()) {
      _addLog('Не удалось прочитать выбранный файл: $filePath');
      return;
    }
    final totalSize = await file.length();
    if (totalSize == 0) return;

    if (totalSize > 1024 * 1024 * 1024) {
      _addLog('Максимальный размер файла: 1 ГБ (1024 МБ)');
      return;
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      final headerBytes = await raf.read(min(16, totalSize));
      String cleanFileName = _sanitizeFileName(fileName);
      if (!cleanFileName.contains('.')) {
        final detectedExt = _detectMediaExtensionFromBytes(headerBytes);
        if (detectedExt != null) {
          cleanFileName = '$cleanFileName.$detectedExt';
        }
      }

      final fileId = existingFileId ?? _randomHex(12);
      final now = DateTime.now().millisecondsSinceEpoch;
      final totalChunks = (totalSize / fileChunkSize).ceil();

      ChatMessage? myMsg;
      for (final m in getMessagesFor(targetNodeId)) {
        if (m.msgId == fileId) {
          myMsg = m;
          break;
        }
      }
      if (myMsg == null) {
        myMsg = ChatMessage(
          msgId: fileId,
          peerId: targetNodeId,
          senderId: nodeId,
          senderName: nickname,
          text: '📎 $cleanFileName',
          timestamp: now,
          isMe: true,
          isDelivered: false,
          filePath: filePath,
          fileName: cleanFileName,
          fileSize: totalSize,
          transferProgress: 0.01,
        );
        getMessagesFor(targetNodeId).add(myMsg);
      }

      final job = pendingFileJobs.putIfAbsent(
        fileId,
        () => PendingFileJob(
          fileId: fileId,
          targetNodeId: targetNodeId,
          filePath: filePath,
          fileName: cleanFileName,
        ),
      );
      if (job.isSending) return;
      job.isSending = true;
      await _saveContactsAndChats();
      onStateChanged();

      try {
        final fileEphKeyPair = await _x25519.newKeyPair();
        final fileEphPub = await fileEphKeyPair.extractPublicKey();
        final fileEphPubHex = _toHex(fileEphPub.bytes);

        for (int idx = job.nextChunkIndex; idx < totalChunks; idx++) {
          if (!_tcpPeers.containsValue(targetNodeId) &&
              !_blePeers.containsValue(targetNodeId) &&
              totalChunks > 8) {
            _addLog('Пауза передачи $cleanFileName (ожидание подключения)...');
            break;
          }

          await raf.setPosition(idx * fileChunkSize);
          final chunkLen = min(fileChunkSize, totalSize - idx * fileChunkSize);
          final chunkBytes = await raf.read(chunkLen);

          final isLastChunk = (idx == totalChunks - 1);
          final needWindowAck = ((idx + 1) % 16 == 0) && !isLastChunk;
          Completer<void>? winWaiter;
          if (needWindowAck) {
            winWaiter = Completer<void>();
            _fileWindowAckWaiters['${fileId}_$idx'] = winWaiter;
          }

          final chunkEnvelopeJson = jsonEncode({
            'v': 2,
            'kind': 'FILE_CHUNK',
            'fid': fileId,
            'fn': cleanFileName,
            'fs': totalSize,
            'idx': idx,
            'tot': totalChunks,
            'wack': needWindowAck,
            'nick': nickname,
            'b64': base64Encode(chunkBytes),
          });

          final chunkMsgId = isLastChunk ? fileId : '${fileId}_$idx';

          await _encryptAndQueueSealedDataPacket(
            targetNodeId: targetNodeId,
            contact: contact,
            msgId: chunkMsgId,
            sealedPayloadBytes: utf8.encode(chunkEnvelopeJson),
            precomputedEphKeyPair: fileEphKeyPair,
            precomputedEphPubHex: fileEphPubHex,
            keepInTransitBuffer: isLastChunk || totalChunks <= 6,
            persistInOutbox: false,
          );

          job.nextChunkIndex = idx + 1;
          myMsg.transferProgress = (idx + 1) / totalChunks;
          if (idx % 4 == 0 || isLastChunk) {
            onStateChanged();
          }

          if (winWaiter != null) {
            await winWaiter.future.timeout(
              const Duration(milliseconds: 1200),
              onTimeout: () {},
            );
            _fileWindowAckWaiters.remove('${fileId}_$idx');
          } else {
            await Future.delayed(const Duration(milliseconds: 6));
          }
        }
      } finally {
        job.isSending = false;
      }
    } finally {
      await raf.close();
    }

    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> _resumePendingFilesForPeer(String peerId) async {
    if (isNodeBanned(peerId)) return;
    final jobs = pendingFileJobs.values
        .where((j) => j.targetNodeId == peerId && !j.isSending)
        .toList();
    for (final job in jobs) {
      if (File(job.filePath).existsSync()) {
        _addLog('Авто-докачка файла ${job.fileName}...');
        unawaited(sendFileMessage(
          peerId,
          filePath: job.filePath,
          fileName: job.fileName,
          existingFileId: job.fileId,
        ));
      } else {
        pendingFileJobs.remove(job.fileId);
      }
    }
  }

  String? _detectMediaExtensionFromBytes(List<int> b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'png';
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'webp';
    }
    if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
      return 'mp4';
    }
    if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
      return 'mkv';
    }
    if ((b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) ||
        (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0)) {
      return 'mp3';
    }
    if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
      return 'ogg';
    }
    return null;
  }

  String _sanitizeFileName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .replaceAll('..', '_')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '_') {
      return 'file_${DateTime.now().millisecondsSinceEpoch}.bin';
    }
    return cleaned.length > 80
        ? cleaned.substring(cleaned.length - 80)
        : cleaned;
  }

  Future<Directory> _getReceivedFilesDir() async {
    if (Platform.isAndroid) {
      try {
        final path = await _nativeChannel
            .invokeMethod<String>('getPersistentStorageDir');
        if (path != null && path.isNotEmpty) {
          final d = Directory(path);
          if (!await d.exists()) await d.create(recursive: true);
          return d;
        }
      } catch (_) {}
    } else if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '.';
      final d = Directory('$home/Downloads/Mayak/Received');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
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
    bool allowEvenIfDeleted = false,
  }) {
    if (nodeId.isEmpty || nodeId == this.nodeId) return;
    if (dhPubHex.length != 64 || signPubHex.length != 64) return;
    if (!allowEvenIfDeleted && deletedContactIds.contains(nodeId)) {
      return;
    }

    final cleanNick = (nick ?? '').trim();
    final cleanHw = (hwFingerprint ?? '').trim();
    final cleanIp = (address != null && address.contains(':'))
        ? address.split(':').first
        : (address ?? '');

    final existing = knownContacts[nodeId];
    if (existing != null) {
      if (existing.dhPubHex != dhPubHex || existing.signPubHex != signPubHex) {
        _addLog('⚠️ Блокирована попытка подмены ключа для узла $nodeId!');
        return;
      }
    }

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
      _staticSharedSecretCache.remove(oldId);
    }

    final isPeerConnected =
        _tcpPeers.containsValue(nodeId) || _blePeers.containsValue(nodeId);
    final now = DateTime.now().millisecondsSinceEpoch;
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
      existing.packetsSeenCount++;
      existing.lastSeenTimestamp = now;
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
        packetsSeenCount: 1,
        lastSeenTimestamp: now,
      );
    }
  }

  Future<void> connectToHost(
    String host,
    int port, {
    String? expectedNodeId,
    Duration timeout = const Duration(seconds: 2),
    bool forceNewConnection = false,
  }) async {
    if (port <= 0 || host == '127.0.0.1') return;
    if (expectedNodeId != null && isNodeBanned(expectedNodeId)) return;
    if (!forceNewConnection) {
      for (final s in _tcpPeers.keys) {
        try {
          if (s.remoteAddress.address == host) return;
        } catch (_) {}
      }
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
          (line) {
            if (line.length > maxLineLengthBytes) return;
            _rxProcessingChain = _rxProcessingChain.then((_) =>
                _processIncomingJsonLine(
                  line,
                  remoteAddr: remoteAddr,
                  onHello: (peerId, peerNick) async {
                    if (isNodeBanned(peerId)) {
                      _cleanupSocket(socket);
                      return;
                    }
                    for (final entry in _tcpPeers.entries.toList()) {
                      if (entry.value == peerId && entry.key != socket) {
                        try {
                          if (entry.key.remoteAddress.address !=
                              socket.remoteAddress.address) {
                            _cleanupSocket(entry.key);
                          }
                        } catch (_) {
                          _cleanupSocket(entry.key);
                        }
                      }
                    }

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
                    unawaited(_resumePendingFilesForPeer(peerId));
                  },
                  replyDirect: (replyJson) => _sendTcpLine(socket, replyJson),
                  excludeTcpSocket: socket,
                ));
          },
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

      if (map.containsKey('file_win_ack')) {
        final key = map['file_win_ack'] as String;
        final waiter = _fileWindowAckWaiters.remove(key);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete();
        }
        return;
      }

      if (map.containsKey('ping_req')) {
        replyDirect(jsonEncode({
          'ping_resp': map['ping_req'],
          'from': nodeId,
        }));
        return;
      }
      if (map.containsKey('ping_resp')) {
        final pid = map['ping_resp'] as String;
        final fromNode = (map['from'] as String?) ?? '';
        final sentAt = _pendingPingTimestamps.remove(pid);
        final comp = _pingCompleters.remove(pid);
        if (sentAt != null && comp != null && !comp.isCompleted) {
          final rtt = DateTime.now().millisecondsSinceEpoch - sentAt;
          knownContacts[fromNode]?.lastPingMs = rtt;
          comp.complete(rtt);
        }
        return;
      }

      if (map.containsKey('hello')) {
        final peerId = map['hello'] as String;
        final peerHw = (map['hw'] as String?) ?? '';
        if (peerId == nodeId ||
            deletedContactIds.contains(peerId) ||
            isNodeBanned(peerId, peerHw)) {
          return;
        }
        final peerDh = (map['dh'] as String?) ?? '';
        final peerSign = (map['sg'] as String?) ?? '';
        final expectedId = await _calcNodeId(_fromHex(peerDh));
        if (expectedId != peerId) return;

        final peerNick = (map['nick'] as String?) ?? '';
        _upsertContact(
          nodeId: peerId,
          dhPubHex: peerDh,
          signPubHex: peerSign,
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
          final pdh = (m['dh'] as String?) ?? '';
          final psg = (m['sg'] as String?) ?? '';
          final phw = (m['hw'] as String?) ?? '';
          if (pid != nodeId &&
              !deletedContactIds.contains(pid) &&
              !isNodeBanned(pid, phw) &&
              !knownContacts.containsKey(pid)) {
            final expectedId = await _calcNodeId(_fromHex(pdh));
            if (expectedId == pid) {
              _upsertContact(
                nodeId: pid,
                dhPubHex: pdh,
                signPubHex: psg,
                nick: (m['nick'] as String?) ?? 'Узел $pid',
                hwFingerprint: phw,
                address: 'Через Mesh',
              );
              addedAny = true;
            }
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
    required SimpleKeyPair ephKeyPair,
    required SimplePublicKey ephRemotePub,
    required String peerNodeId,
    required String peerStaticDhHex,
    required String msgId,
    required String dstNodeId,
  }) async {
    final secret1 = await _x25519.sharedSecretKey(
      keyPair: ephKeyPair,
      remotePublicKey: ephRemotePub,
    );

    List<int>? staticSecretBytes = _staticSharedSecretCache[peerNodeId];
    if (staticSecretBytes == null) {
      final secret2 = await _x25519.sharedSecretKey(
        keyPair: _dhKeyPair,
        remotePublicKey: SimplePublicKey(
          _fromHex(peerStaticDhHex),
          type: KeyPairType.x25519,
        ),
      );
      staticSecretBytes = await secret2.extractBytes();
      _staticSharedSecretCache[peerNodeId] = staticSecretBytes;
    }

    final combinedIkm = <int>[
      ...(await secret1.extractBytes()),
      ...staticSecretBytes,
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
    SimpleKeyPair? precomputedEphKeyPair,
    String? precomputedEphPubHex,
    bool keepInTransitBuffer = true,
    bool persistInOutbox = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ephKeyPair = precomputedEphKeyPair ?? await _x25519.newKeyPair();
    final ephPubHex = precomputedEphPubHex ??
        _toHex((await ephKeyPair.extractPublicKey()).bytes);

    final recipientDhPub = SimplePublicKey(
      _fromHex(contact.dhPubHex),
      type: KeyPairType.x25519,
    );

    final sessionKey = await _deriveHardenedConversationKey(
      ephKeyPair: ephKeyPair,
      ephRemotePub: recipientDhPub,
      peerNodeId: targetNodeId,
      peerStaticDhHex: contact.dhPubHex,
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

    _markPacketSeen(msgId);
    if (keepInTransitBuffer) {
      transitBuffer[msgId] = pkt;
    }
    if (persistInOutbox) {
      myPersistentOutbox[msgId] = pkt;
    }
    _floodAllTransports(pkt);
  }

  Future<void> sendMessage(String targetNodeId, String plainText) async {
    if (isNodeBanned(nodeId, myHwFingerprint)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = _randomHex(16);

    if (targetNodeId == broadcastChannelId) {
      final expiresAt = now + 3600 * 1000;
      final b64Payload = base64Encode(utf8.encode(plainText));
      final sigPayload = utf8.encode(
          '$msgId|$broadcastChannelId|$dhPubHex|$expiresAt|$b64Payload');
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
        expiresAt: expiresAt,
        ttl: 5,
      );

      _markPacketSeen(msgId);
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

    if (isNodeBanned(targetNodeId)) return;
    deletedContactIds.remove(targetNodeId);
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
    final now = DateTime.now().millisecondsSinceEpoch;

    if (pkt.expiresAt <= now || pkt.expiresAt > now + 25 * 3600 * 1000) {
      return;
    }

    if (deliveredAcks.containsKey(pkt.msgId)) {
      replyDirect(jsonEncode(deliveredAcks[pkt.msgId]!.toJson()));
      return;
    }

    if (!_markPacketSeen(pkt.msgId)) return;

    // 1. ПРОВЕРКА ПОДПИСАННОЙ КОМАНДЫ АДМИНИСТРАТОРА (ADMIN_CMD: BAN / UNBAN)
    if (pkt.type == 'BROADCAST' && pkt.ephPubHex == 'ADMIN_CMD') {
      final adminSigValid = await _ed25519.verify(
        utf8.encode(
            'ADMIN_CMD|${pkt.msgId}|${pkt.expiresAt}|${pkt.ciphertextHex}'),
        signature: Signature(
          _fromHex(pkt.signatureHex),
          publicKey: SimplePublicKey(
              _fromHex(_adminMasterPubHex), type: KeyPairType.ed25519),
        ),
      );
      if (!adminSigValid) return;

      final cmdMap = jsonDecode(utf8.decode(base64Decode(pkt.ciphertextHex)))
          as Map<String, dynamic>;
      final act = (cmdMap['act'] as String?) ?? '';
      final target = (cmdMap['target'] as String?) ?? '';
      final hw = (cmdMap['hw'] as String?) ?? '';

      if (act == 'BAN' && target.isNotEmpty) {
        bannedNodeIds.add(target);
        if (hw.isNotEmpty) bannedHwFingerprints.add(hw);
        _disconnectBannedPeerImmediately(target);
        _addLog('🛡️ Узел $target заблокирован администратором сети');
      } else if (act == 'UNBAN' && target.isNotEmpty) {
        bannedNodeIds.remove(target);
        if (hw.isNotEmpty) bannedHwFingerprints.remove(hw);
        _addLog('🛡️ Блокировка узла $target снята администратором');
      }
      await _saveContactsAndChats();
      if (pkt.ttl > 1) {
        pkt.ttl -= 1;
        transitBuffer[pkt.msgId] = pkt;
        _floodAllTransports(
          pkt,
          excludeTcpSocket: excludeTcpSocket,
          excludeBleId: excludeBleId,
        );
      }
      onStateChanged();
      return;
    }

    final senderId = await _calcNodeId(_fromHex(pkt.srcDhPubHex));
    if (isNodeBanned(senderId) || isNodeBanned(pkt.dstNodeId)) {
      return;
    }

    if (pkt.type == 'BROADCAST') {
      final sigValid = await _ed25519.verify(
        utf8.encode(
            '${pkt.msgId}|$broadcastChannelId|${pkt.srcDhPubHex}|${pkt.expiresAt}|${pkt.ciphertextHex}'),
        signature: Signature(
          _fromHex(pkt.signatureHex),
          publicKey: SimplePublicKey(
              _fromHex(pkt.srcSignPubHex), type: KeyPairType.ed25519),
        ),
      );
      if (!sigValid) return;
      if (senderId == nodeId) return;

      if (pkt.ephPubHex == 'REACTION') {
        final rxMap = jsonDecode(utf8.decode(base64Decode(pkt.ciphertextHex)))
            as Map<String, dynamic>;
        final targetId = rxMap['rx_msg'] as String;
        final emoji = rxMap['emoji'] as String;
        for (final m in getMessagesFor(broadcastChannelId)) {
          if (m.msgId == targetId) {
            if (m.reactions[senderId] == emoji) {
              m.reactions.remove(senderId);
            } else {
              m.reactions[senderId] = emoji;
            }
            break;
          }
        }
        unawaited(_saveContactsAndChats());
        onStateChanged();
        return;
      }

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
        timestamp: now,
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

      final sessionKey = await _deriveHardenedConversationKey(
        ephKeyPair: _dhKeyPair,
        ephRemotePub: senderEphPub,
        peerNodeId: senderId,
        peerStaticDhHex: pkt.srcDhPubHex,
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

      deletedContactIds.remove(senderId);
      _upsertContact(
        nodeId: senderId,
        dhPubHex: pkt.srcDhPubHex,
        signPubHex: pkt.srcSignPubHex,
        nick: senderNickInside,
        allowEvenIfDeleted: true,
      );
      final contact = knownContacts[senderId];
      if (contact == null) return;

      bool shouldSendAck = true;
      if (kind == 'FILE_CHUNK') {
        final idx = (envelope['idx'] as int?) ?? 0;
        final tot = (envelope['tot'] as int?) ?? 1;
        final wack = (envelope['wack'] as bool?) ?? false;
        if (wack) {
          final fid = (envelope['fid'] as String?) ?? '';
          replyDirect(jsonEncode({'file_win_ack': '${fid}_$idx'}));
        }
        shouldSendAck = (idx == tot - 1) || (tot <= 4);
        await _handleIncomingFileChunk(senderId, contact, envelope);
      } else if (kind == 'REACTION') {
        final targetId = (envelope['targetId'] as String?) ?? '';
        final emoji = (envelope['emoji'] as String?) ?? '👍';
        for (final m in getMessagesFor(senderId)) {
          if (m.msgId == targetId) {
            if (m.reactions[senderId] == emoji) {
              m.reactions.remove(senderId);
            } else {
              m.reactions[senderId] = emoji;
            }
            break;
          }
        }
        unawaited(_triggerIncomingNotification(
            senderId, contact.displayTitle, 'Реакция $emoji на сообщение'));
        unawaited(_saveContactsAndChats());
      } else {
        final decodedText = (envelope['txt'] as String?) ?? '';
        final chatMsg = ChatMessage(
          msgId: pkt.msgId,
          peerId: senderId,
          senderId: senderId,
          senderName: contact.displayTitle,
          text: decodedText,
          timestamp: now,
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

      if (shouldSendAck) {
        final ackSig = await _ed25519.sign(
          utf8.encode('ACK|${pkt.msgId}|$senderId'),
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
      }
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

  /// ФИКС ЗАПИСИ ФАЙЛОВ ДО 1 ГБ: держим единый RandomAccessFile (FileMode.write) в сборщике, чтобы setPosition работал точно по смещению!
  Future<void> _handleIncomingFileChunk(
    String senderId,
    ContactProfile contact,
    Map<String, dynamic> env,
  ) async {
    final fileId = env['fid'] as String;
    final rawName = (env['fn'] as String?) ?? 'file.bin';
    final fileName = _sanitizeFileName(rawName);
    final totalSize = (env['fs'] as int?) ?? 0;
    final idx = (env['idx'] as int?) ?? 0;
    final tot = (env['tot'] as int?) ?? 1;
    final chunkBytes = base64Decode((env['b64'] as String?) ?? '');

    if (tot <= 0 || tot > 40000 || totalSize > 1050 * 1024 * 1024) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredIds = <String>[];
    _incomingFiles.forEach((k, a) {
      if (now - a.createdAtMs > 3600000) expiredIds.add(k);
    });
    for (final k in expiredIds) {
      final old = _incomingFiles.remove(k);
      try {
        await old?.openRaf?.close();
      } catch (_) {}
    }

    if (!_incomingFiles.containsKey(fileId) &&
        _incomingFiles.length >= maxConcurrentIncomingFiles) {
      return;
    }

    final dir = await _getReceivedFilesDir();
    final partPath = '${dir.path}/${fileId}_$fileName.part';

    var assembly = _incomingFiles[fileId];
    if (assembly == null) {
      final partFile = File(partPath);
      final raf = await partFile.open(mode: FileMode.write);
      assembly = IncomingFileStreamAssembly(
        fileId: fileId,
        fileName: fileName,
        totalSize: totalSize,
        totalChunks: tot,
        partFilePath: partPath,
        createdAtMs: now,
        openRaf: raf,
      );
      _incomingFiles[fileId] = assembly;
    }

    if (!assembly.receivedChunkIndices.contains(idx)) {
      final raf = assembly.openRaf;
      if (raf != null) {
        await raf.setPosition(idx * fileChunkSize);
        await raf.writeFrom(chunkBytes);
        assembly.receivedChunkIndices.add(idx);
      }
    }

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
        text: '📎 Прием: $fileName...',
        timestamp: now,
        isMe: false,
        isDelivered: false,
        fileName: fileName,
        fileSize: totalSize,
        transferProgress: assembly.receivedChunkIndices.length / tot,
      );
      msgs.add(existingMsg);
    } else {
      existingMsg.transferProgress =
          assembly.receivedChunkIndices.length / tot;
    }

    if (assembly.receivedChunkIndices.length >= tot) {
      _incomingFiles.remove(fileId);
      try {
        await assembly.openRaf?.flush();
        await assembly.openRaf?.close();
      } catch (_) {}

      final partFile = File(partPath);
      String finalFileName = fileName;
      if (!finalFileName.contains('.')) {
        final rafRead = await partFile.open(mode: FileMode.read);
        final head = await rafRead.read(min(16, totalSize));
        await rafRead.close();
        final ext = _detectMediaExtensionFromBytes(head);
        if (ext != null) {
          finalFileName = '$finalFileName.$ext';
        }
      }

      final finalPath = '${dir.path}/${fileId}_$finalFileName';
      if (await File(finalPath).exists()) {
        await File(finalPath).delete();
      }
      final savedFile = await partFile.rename(finalPath);

      existingMsg.fileName = finalFileName;
      existingMsg.filePath = savedFile.path;
      existingMsg.text = '📎 $finalFileName';
      existingMsg.isDelivered = true;
      existingMsg.transferProgress = 1.0;

      if (activeOpenChatId != senderId) {
        contact.unreadCount++;
      }
      onMessageReceived(existingMsg);
      unawaited(_triggerIncomingNotification(
          senderId, contact.displayTitle, '📎 Получен файл: $finalFileName'));
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

    final stored = transitBuffer[ack.msgId] ?? myPersistentOutbox[ack.msgId];
    if (stored != null) {
      final valid = await _ed25519.verify(
        utf8.encode('ACK|${ack.msgId}|${ack.dstNodeId}'),
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

    pendingFileJobs.remove(ack.msgId);

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
              final peerDh = (data['dh'] as String?) ?? '';
              final peerSign = (data['sg'] as String?) ?? '';
              final peerNick = (data['nick'] as String?) ?? '';
              final peerHw = (data['hw'] as String?) ?? '';
              if (peerId != nodeId &&
                  !deletedContactIds.contains(peerId) &&
                  !isNodeBanned(peerId, peerHw) &&
                  peerDh.length == 64) {
                _upsertContact(
                  nodeId: peerId,
                  dhPubHex: peerDh,
                  signPubHex: peerSign,
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

      _beaconTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
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

        for (final c in knownContacts.values) {
          if (!c.isOnline &&
              !isNodeBanned(c.nodeId, c.hwFingerprint) &&
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
        _addLog('BLE Mesh активен');
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
      if (line.trim().isEmpty || line.length > maxLineLengthBytes) continue;
      _rxProcessingChain = _rxProcessingChain.then((_) =>
          _processIncomingJsonLine(
            line,
            remoteAddr: 'BLE:$endpointId',
            onHello: (peerId, peerNick) async {
              if (isNodeBanned(peerId)) return;
              _blePeers[endpointId] = peerId;
              _refreshOnlineStatuses();
              _addLog('Подключен по BLE: $peerNick ($peerId)');
              await _sendBleLine(endpointId, _buildPeerSyncJson());
              _evictExpired();
              for (final ack in deliveredAcks.values) {
                await _sendBleLine(endpointId, jsonEncode(ack.toJson()));
              }
              for (final entry in transitBuffer.entries.toList()) {
                await _sendBleLine(
                    endpointId, jsonEncode(entry.value.toJson()));
              }
              unawaited(_resumePendingFilesForPeer(peerId));
            },
            replyDirect: (replyJson) =>
                unawaited(_sendBleLine(endpointId, replyJson)),
            excludeBleId: endpointId,
          ));
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

  static String formatDurationMs(int ms) {
    final totalSec = (ms / 1000).floor().clamp(0, 86400);
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

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
