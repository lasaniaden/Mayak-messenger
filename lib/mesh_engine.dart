import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
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
  String? thumbB64;
  bool isMediaRevealed;
  bool isDownloading;
  bool isEdited;
  String? forwardedFrom;
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
    this.thumbB64,
    bool? isMediaRevealed,
    this.isDownloading = false,
    this.isEdited = false,
    this.forwardedFrom,
    this.transferProgress = 1.0,
    Map<String, String>? reactions,
  })  : isMediaRevealed = isMediaRevealed ?? isMe,
        reactions = reactions ?? {};

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
        'tb64': thumbB64,
        'rev': isMediaRevealed,
        'edt': isEdited,
        'fwd': forwardedFrom,
        'pr': transferProgress,
        'rx': reactions,
      };

  /// Сериализация для P2P-синхронизации истории чата между своими устройствами (с инверсией поля isMe для получателя)
  Map<String, dynamic> toSyncJson() => {
        'id': msgId,
        's': senderId,
        'sn': senderName,
        'txt': text,
        'ts': timestamp,
        'fn': fileName,
        'fs': fileSize,
        'tb64': thumbB64,
        'edt': isEdited,
        'fwd': forwardedFrom,
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
    final isMeVal = (j['me'] as bool?) ?? false;
    return ChatMessage(
      msgId: (j['id'] ?? '').toString(),
      peerId: (j['p'] ?? '').toString(),
      senderId: (j['s'] ?? '').toString(),
      senderName: (j['sn'] ?? 'Узел').toString(),
      text: (j['txt'] ?? '').toString(),
      timestamp: (j['ts'] as num?)?.toInt() ?? 0,
      isMe: isMeVal,
      isDelivered: (j['ack'] as bool?) ?? false,
      filePath: j['fp'] as String?,
      fileName: j['fn'] as String?,
      fileSize: (j['fs'] as num?)?.toInt(),
      thumbB64: j['tb64'] as String?,
      isMediaRevealed: (j['rev'] as bool?) ?? isMeVal,
      isEdited: (j['edt'] as bool?) ?? false,
      forwardedFrom: j['fwd'] as String?,
      transferProgress: ((j['pr'] as num?) ?? 1.0).toDouble(),
      reactions: rxMap,
    );
  }
}

/// Полное техническое досье сработавшего триггера (включая все реквизиты узла и контекст -5 : +5)
class TriggerHitRecord {
  final String hitId;
  final String chatId;
  final String chatTitle;
  final String triggerWord;
  final String offenderNodeId;
  final String offenderName;
  final String offenderHwFingerprint;
  final String offenderIpAddress;
  final String offenderPlatformInfo;
  final String offenderDhPubHex;
  final String offenderSignPubHex;
  final String triggerMsgId;
  final int timestamp;
  final List<String> beforeLines;
  final String triggerLine;
  final List<String> afterLines;

  TriggerHitRecord({
    required this.hitId,
    required this.chatId,
    required this.chatTitle,
    required this.triggerWord,
    required this.offenderNodeId,
    required this.offenderName,
    this.offenderHwFingerprint = '',
    this.offenderIpAddress = '',
    this.offenderPlatformInfo = '',
    this.offenderDhPubHex = '',
    this.offenderSignPubHex = '',
    required this.triggerMsgId,
    required this.timestamp,
    required this.beforeLines,
    required this.triggerLine,
    required this.afterLines,
  });

  String get formattedDateTime {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  String buildFullSecurityDossierText() {
    final buf = StringBuffer();
    buf.writeln('=== ПРОТОКОЛ ИНЦИДЕНТА БЕЗОПАСНОСТИ СЕТИ «МАЯК» ===');
    buf.writeln('ID инцидента: $hitId');
    buf.writeln('Дата и время фиксации: $formattedDateTime (Unix: $timestamp)');
    buf.writeln('Сработавший триггер: «$triggerWord»');
    buf.writeln('Канал / Чат: $chatTitle (ID: $chatId)');
    buf.writeln('--- ТЕХНИЧЕСКОЕ ДОСЬЕ УЗЛА-ОТПРАВИТЕЛЯ ---');
    buf.writeln('Позывной (Никнейм): $offenderName');
    buf.writeln('Криптографический ID узла: $offenderNodeId');
    buf.writeln(
        'Аппаратный HW-отпечаток устройства: ${offenderHwFingerprint.isNotEmpty ? offenderHwFingerprint : "Не указан"}');
    buf.writeln(
        'Сетевой адрес (IP:Порт / Маршрут): ${offenderIpAddress.isNotEmpty ? offenderIpAddress : "Локальный P2P/Mesh"}');
    buf.writeln(
        'Платформа / Устройство: ${offenderPlatformInfo.isNotEmpty ? offenderPlatformInfo : "Не определена"}');
    buf.writeln(
        'Публичный ключ X25519 (DH): ${offenderDhPubHex.isNotEmpty ? offenderDhPubHex : "Н/Д"}');
    buf.writeln(
        'Публичный ключ Ed25519 (Подпись): ${offenderSignPubHex.isNotEmpty ? offenderSignPubHex : "Н/Д"}');
    buf.writeln('--- КОНТЕКСТ ПЕРЕПИСКИ (-5 : +5 СООБЩЕНИЙ) ---');
    if (beforeLines.isNotEmpty) {
      buf.writeln('[Предыдущие сообщения (-5)]:');
      for (final l in beforeLines) {
        buf.writeln('  $l');
      }
    }
    buf.writeln('[ЦЕЛЕВОЕ СООБЩЕНИЕ С ТРИГГЕРОМ]:');
    buf.writeln('  >>> $triggerLine <<<');
    if (afterLines.isNotEmpty) {
      buf.writeln('[Последующие сообщения (+5)]:');
      for (final l in afterLines) {
        buf.writeln('  $l');
      }
    }
    buf.writeln('===================================================');
    return buf.toString();
  }

  Map<String, dynamic> toJson() => {
        'id': hitId,
        'cid': chatId,
        'ct': chatTitle,
        'tw': triggerWord,
        'oid': offenderNodeId,
        'on': offenderName,
        'ohw': offenderHwFingerprint,
        'oip': offenderIpAddress,
        'oos': offenderPlatformInfo,
        'odh': offenderDhPubHex,
        'osg': offenderSignPubHex,
        'mid': triggerMsgId,
        'ts': timestamp,
        'bef': beforeLines,
        'trg': triggerLine,
        'aft': afterLines,
      };

  factory TriggerHitRecord.fromJson(Map<String, dynamic> j) => TriggerHitRecord(
        hitId: (j['id'] ?? '').toString(),
        chatId: (j['cid'] ?? '').toString(),
        chatTitle: (j['ct'] ?? '').toString(),
        triggerWord: (j['tw'] ?? '').toString(),
        offenderNodeId: (j['oid'] ?? '').toString(),
        offenderName: (j['on'] ?? '').toString(),
        offenderHwFingerprint: (j['ohw'] ?? '').toString(),
        offenderIpAddress: (j['oip'] ?? '').toString(),
        offenderPlatformInfo: (j['oos'] ?? '').toString(),
        offenderDhPubHex: (j['odh'] ?? '').toString(),
        offenderSignPubHex: (j['osg'] ?? '').toString(),
        triggerMsgId: (j['mid'] ?? '').toString(),
        timestamp: (j['ts'] as num?)?.toInt() ?? 0,
        beforeLines:
            ((j['bef'] as List?) ?? []).map((e) => e.toString()).toList(),
        triggerLine: (j['trg'] ?? '').toString(),
        afterLines:
            ((j['aft'] as List?) ?? []).map((e) => e.toString()).toList(),
      );
}

class BanAppealRecord {
  final String appealId;
  final String nodeId;
  final String nickname;
  final String hwFingerprint;
  final String appealText;
  final int timestamp;

  BanAppealRecord({
    required this.appealId,
    required this.nodeId,
    required this.nickname,
    required this.hwFingerprint,
    required this.appealText,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': appealId,
        'nid': nodeId,
        'nick': nickname,
        'hw': hwFingerprint,
        'txt': appealText,
        'ts': timestamp,
      };

  factory BanAppealRecord.fromJson(Map<String, dynamic> j) => BanAppealRecord(
        appealId: (j['id'] ?? '').toString(),
        nodeId: (j['nid'] ?? '').toString(),
        nickname: (j['nick'] ?? '').toString(),
        hwFingerprint: (j['hw'] ?? '').toString(),
        appealText: (j['txt'] ?? '').toString(),
        timestamp: (j['ts'] as num?)?.toInt() ?? 0,
      );
}

class PendingFileJob {
  final String fileId;
  final String targetNodeId;
  final String filePath;
  final String fileName;
  String? thumbB64;
  int confirmedChunkIndex;
  bool isSending;

  PendingFileJob({
    required this.fileId,
    required this.targetNodeId,
    required this.filePath,
    required this.fileName,
    this.thumbB64,
    this.confirmedChunkIndex = 0,
    this.isSending = false,
  });

  Map<String, dynamic> toJson() => {
        'fid': fileId,
        'dst': targetNodeId,
        'fp': filePath,
        'fn': fileName,
        'tb64': thumbB64,
        'nxt': confirmedChunkIndex,
      };

  factory PendingFileJob.fromJson(Map<String, dynamic> j) => PendingFileJob(
        fileId: (j['fid'] ?? '').toString(),
        targetNodeId: (j['dst'] ?? '').toString(),
        filePath: (j['fp'] ?? '').toString(),
        fileName: (j['fn'] ?? '').toString(),
        thumbB64: j['tb64'] as String?,
        confirmedChunkIndex: (j['nxt'] as num?)?.toInt() ?? 0,
      );
}

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
  String platformInfo;
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
    this.platformInfo = '',
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
        'os': platformInfo,
        'addr': lastAddress,
        'ls': lastSeenTimestamp,
      };

  factory ContactProfile.fromJson(Map<String, dynamic> j) => ContactProfile(
        nodeId: (j['id'] ?? '').toString(),
        dhPubHex: (j['dh'] ?? '').toString(),
        signPubHex: (j['sg'] ?? '').toString(),
        nickname: (j['nick'] as String?) ?? 'Узел ${j['id']}',
        hwFingerprint: (j['hw'] as String?) ?? '',
        platformInfo: (j['os'] as String?) ?? '',
        lastAddress: (j['addr'] as String?) ?? '',
        lastSeenTimestamp: (j['ls'] as num?)?.toInt() ?? 0,
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
        type: (j['t'] ?? '').toString(),
        msgId: (j['id'] ?? '').toString(),
        dstNodeId: (j['dst'] ?? '').toString(),
        srcNickname: (j['nick'] as String?) ?? '',
        srcSignPubHex: (j['sp'] ?? '').toString(),
        srcDhPubHex: (j['dp'] ?? '').toString(),
        dstSignPubHex: (j['dsp'] ?? '').toString(),
        ephPubHex: (j['ep'] ?? '').toString(),
        nonceHex: (j['n'] ?? '').toString(),
        ciphertextHex: (j['c'] ?? '').toString(),
        macHex: (j['m'] ?? '').toString(),
        signatureHex: (j['s'] ?? '').toString(),
        expiresAt: (j['exp'] as num?)?.toInt() ?? 0,
        ttl: (j['ttl'] as num?)?.toInt() ?? 1,
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


class GroupChat {
  final String groupId;
  String title;
  final String creatorId;
  final List<String> memberIds;
  final int createdAt;

  GroupChat({
    required this.groupId,
    required this.title,
    required this.creatorId,
    required this.memberIds,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': groupId,
        'title': title,
        'creator': creatorId,
        'members': memberIds,
        'ts': createdAt,
      };

  factory GroupChat.fromJson(Map<String, dynamic> m) => GroupChat(
        groupId: (m['id'] ?? '').toString(),
        title: (m['title'] ?? 'Группа').toString(),
        creatorId: (m['creator'] ?? '').toString(),
        memberIds: (m['members'] is List)
            ? (m['members'] as List).map((e) => e.toString()).toList()
            : <String>[],
        createdAt: (m['ts'] as num?)?.toInt() ?? 0,
      );
}

class MeshEngine {
  static const String broadcastChannelId = 'BROADCAST';
  static const int discoveryPort = 42069;
  static const int defaultTcpPort = 42070;
  static const int maxBufferPackets = 500;
  static const int maxLineLengthBytes = 250 * 1024;
  static const int maxConcurrentIncomingFiles = 8;
  static const int fileChunkSize = 32 * 1024;
  static const String serviceId = 'com.p2pmesh.intercom';
  static const MethodChannel _nativeChannel = MethodChannel('mayak/native');

  // КРИПТОГРАФИЧЕСКАЯ ЗАЩИТА КОНСОЛИ АДМИНА (секретная фраза в коде НЕ хранится!)
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
  String myPlatformInfo = '';
  String _internalDataDirPath = '';

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
  final Set<String> deletedMessageIds = {};
  final Set<String> clearedTriggerHitIds = {};

  // Глобальный список забаненных узлов и аппаратных отпечатков
  final Set<String> bannedNodeIds = {};
  final Set<String> bannedHwFingerprints = {};

  // Триггеры чатов для Панели Админа (диапазон -5 : +5 сообщений + полное досье)
  final List<String> adminTriggerWords = [
    'взлом',
    'спам',
    'опасн',
    'террор',
    'клад',
  ];
  final List<TriggerHitRecord> triggerHits = [];
  final List<BanAppealRecord> banAppeals = [];

  // Каталог отправленных файлов (fileId -> локальный путь на диске отправителя), чтобы получатель мог скачать файл по кнопке (как в ТГ) и перекачать после очистки кэша!
  final Map<String, String> offeredFileCatalog = {};

  final Map<String, List<int>> _staticSharedSecretCache = {};
  final Map<String, IncomingFileStreamAssembly> _incomingFiles = {};
  final Map<String, PendingFileJob> pendingFileJobs = {};
  final Map<String, Completer<void>> _fileWindowAckWaiters = {};
  final Map<String, int> _pendingPingTimestamps = {};
  final Map<String, Completer<int>> _pingCompleters = {};

  Future<void> _rxProcessingChain = Future.value();
  Future<void> _saveLockChain = Future.value();

  final Map<String, MeshPacket> transitBuffer = {};
  final Map<String, MeshPacket> myPersistentOutbox = {};
  final Map<String, MeshPacket> deliveredAcks = {};
  final Map<String, ContactProfile> knownContacts = {};
  final Map<String, List<ChatMessage>> chatHistory = {};
  final Map<String, GroupChat> groupChats = {};
  final Map<String, int> unreadGroupCounts = {};

  // v1.7.0: ГЧ (Голосовой чат) и ВЧ (Видеочат) в реальном времени
  String? activeCallPeerId;
  String activeCallMode = 'voice'; // 'voice' | 'video'
  bool isCallAccepted = false;
  String? incomingCallFromPeerId;
  String incomingCallMode = 'voice';
  Uint8List? remoteVideoFrameBytes;
  String callStatusText = '';
  int _lastCallAudioPlayMs = 0;

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

  int get totalBufferedCount => transitBuffer.length + pendingFileJobs.length;

  bool get isSelfBanned => isNodeBanned(nodeId, myHwFingerprint);

  bool isNodeBanned(String targetNodeId, [String hw = '']) {
    if (targetNodeId.isNotEmpty && bannedNodeIds.contains(targetNodeId)) {
      return true;
    }
    if (hw.isNotEmpty && bannedHwFingerprints.contains(hw)) return true;
    final c = knownContacts[targetNodeId];
    if (c != null &&
        c.hwFingerprint.isNotEmpty &&
        bannedHwFingerprints.contains(c.hwFingerprint)) {
      return true;
    }
    return false;
  }

  bool isPeerDirectlyConnected(String peerId) {
    return _tcpPeers.containsValue(peerId) || _blePeers.containsValue(peerId);
  }

  static String _normalizeAdminPhrase(String raw) {
    const map = {
      'а': 'a', 'е': 'e', 'ё': 'e', 'о': 'o', 'р': 'p', 'с': 'c',
      'у': 'y', 'х': 'x', 'к': 'k', 'м': 'm', 'т': 't', 'н': 'h',
      'в': 'b', 'і': 'i',
    };
    final lower = raw.trim().toLowerCase();
    final sb = StringBuffer();
    for (var i = 0; i < lower.length; i++) {
      final ch = lower[i];
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }

  Future<bool> tryUnlockAdminConsole(String candidatePhrase) async {
    final clean = _normalizeAdminPhrase(candidatePhrase);
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
    _refreshOnlineStatuses();
    unawaited(pingAllKnownNodes());
    onStateChanged();
    return true;
  }


  // ===========================================================================
  // v1.6.0: ГРУППОВЫЕ MESH-ЧАТЫ + БЭКАП/ВОССТАНОВЛЕНИЕ (.mayakbak)
  // ===========================================================================
  String groupChatKey(String groupId) => 'group:$groupId';

  List<ChatMessage> getGroupMessages(String groupId) {
    return chatHistory.putIfAbsent(groupChatKey(groupId), () => []);
  }

  void markGroupRead(String groupId) {
    unreadGroupCounts[groupId] = 0;
    onStateChanged();
  }

  Future<GroupChat> createGroupChat(String title, List<String> memberIds) async {
    final cleanTitle = title.trim().isEmpty ? 'Mesh-комната' : title.trim();
    final gid = _randomHex(12);
    final members = <String>{nodeId, ...memberIds}.toList();
    final group = GroupChat(
      groupId: gid,
      title: cleanTitle,
      creatorId: nodeId,
      memberIds: members,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    groupChats[gid] = group;

    final invitePayload = jsonEncode({
      'v': 2,
      'kind': 'GROUP_INVITE',
      'gid': gid,
      'title': cleanTitle,
      'creator': nodeId,
      'members': members,
      'ts': group.createdAt,
    });
    for (final pid in members) {
      if (pid == nodeId) continue;
      final c = knownContacts[pid];
      if (c == null) continue;
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: pid,
        contact: c,
        msgId: _randomHex(12),
        sealedPayloadBytes: utf8.encode(invitePayload),
        persistInOutbox: true,
      );
    }
    await _saveContactsAndChats();
    onStateChanged();
    return group;
  }

  Future<void> sendGroupMessage(String groupId, String text) async {
    final clean = text.trim();
    final group = groupChats[groupId];
    if (clean.isEmpty || group == null) return;
    final msgId = _randomHex(12);
    final now = DateTime.now().millisecondsSinceEpoch;
    final gKey = groupChatKey(groupId);
    final msg = ChatMessage(
      msgId: msgId,
      peerId: gKey,
      senderId: nodeId,
      senderName: nickname,
      text: clean,
      timestamp: now,
      isMe: true,
      isDelivered: true,
    );
    getGroupMessages(groupId).add(msg);
    _inspectMessageForTriggers(msg, gKey);

    final payload = jsonEncode({
      'v': 2,
      'kind': 'GROUP_MSG',
      'gid': groupId,
      'title': group.title,
      'members': group.memberIds,
      'mid': msgId,
      'sn': nickname,
      'txt': clean,
      'ts': now,
    });
    for (final pid in group.memberIds) {
      if (pid == nodeId) continue;
      final c = knownContacts[pid];
      if (c == null) continue;
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: pid,
        contact: c,
        msgId: '${msgId}_$pid',
        sealedPayloadBytes: utf8.encode(payload),
        persistInOutbox: true,
      );
    }
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<String> exportBackupJsonToDownloads() async {
    await _saveContactsAndChats();
    final signSeedBytes = await _signKeyPair.extractPrivateKeyBytes();
    final dhSeedBytes = await _dhKeyPair.extractPrivateKeyBytes();
    final chatsMap = <String, dynamic>{};
    chatHistory.forEach((k, list) {
      chatsMap[k] = list.map((m) => m.toJson()).toList();
    });
    final payload = jsonEncode({
      'mayak_backup_v': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'sign_seed': _toHex(signSeedBytes),
      'dh_seed': _toHex(dhSeedBytes),
      'nick': nickname,
      'contacts': jsonEncode(knownContacts.values.map((c) => c.toJson()).toList()),
      'chats': jsonEncode(chatsMap),
      'groups': groupChats.values.map((g) => g.toJson()).toList(),
      'deleted_contacts': deletedContactIds.toList(),
      'deleted_msgs': deletedMessageIds.toList(),
    });

    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final fileName = 'mayak_backup_$stamp.mayakbak';

    try {
      if (Platform.isAndroid) {
        final savedPath = await _nativeChannel.invokeMethod<String>(
          'saveFileToDownloads',
          {'fileName': fileName, 'bytes': utf8.encode(payload)},
        );
        if (savedPath != null && savedPath.isNotEmpty) {
          return savedPath;
        }
      }
      final sep = Platform.pathSeparator;
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dl = Directory('$home${sep}Downloads');
      if (!await dl.exists()) await dl.create(recursive: true);
      final f = File('${dl.path}$sep$fileName');
      await f.writeAsString(payload, flush: true);
      return f.path;
    } catch (_) {
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}$fileName');
      await f.writeAsString(payload, flush: true);
      return f.path;
    }
  }

  Future<String> importBackupFromJson(String rawJson) async {
    final map = jsonDecode(rawJson.trim()) as Map<String, dynamic>;
    if (map['sign_seed'] == null || map['dh_seed'] == null) {
      throw Exception('Неверный формат резервной копии');
    }
    final signSeed = _fromHex(map['sign_seed'].toString());
    final dhSeed = _fromHex(map['dh_seed'].toString());
    _signKeyPair = await _ed25519.newKeyPairFromSeed(signSeed);
    _dhKeyPair = await _x25519.newKeyPairFromSeed(dhSeed);
    final dhPub = await _dhKeyPair.extractPublicKey();
    final signPub = await _signKeyPair.extractPublicKey();
    dhPubHex = _toHex(dhPub.bytes);
    signPubHex = _toHex(signPub.bytes);
    final idHash = await _sha256.hash(dhPub.bytes);
    nodeId = _toHex(idHash.bytes).substring(0, 16);

    if (map['nick'] is String && (map['nick'] as String).isNotEmpty) {
      nickname = map['nick'] as String;
    }
    if (map['contacts'] is String) {
      final list = jsonDecode(map['contacts'] as String) as List;
      for (final item in list) {
        final c = ContactProfile.fromJson(Map<String, dynamic>.from(item as Map));
        if (c.nodeId.isNotEmpty) knownContacts[c.nodeId] = c;
      }
    }
    if (map['chats'] is String) {
      final cmap = jsonDecode(map['chats'] as String) as Map<String, dynamic>;
      cmap.forEach((pid, listRaw) {
        if (listRaw is List) {
          final msgs = listRaw
              .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          chatHistory[pid] = msgs;
        }
      });
    }
    if (map['groups'] is List) {
      for (final item in (map['groups'] as List)) {
        final g = GroupChat.fromJson(Map<String, dynamic>.from(item as Map));
        if (g.groupId.isNotEmpty) groupChats[g.groupId] = g;
      }
    }
    await _saveContactsAndChats();
    onStateChanged();
    return 'Профиль ($nickname) и переписка восстановлены!';
  }


  // ===========================================================================
  // v1.7.0: ОЧИСТКА БУФЕРА И ПЕРИОДИЧЕСКИЙ ДОСЫЛ + ГЧ И ВЧ (VOICE/VIDEO CALLS)
  // ===========================================================================
  Future<int> clearOutboxAndTransitBuffer() async {
    final removedCount = transitBuffer.length +
        myPersistentOutbox.length +
        pendingFileJobs.length;
    transitBuffer.clear();
    myPersistentOutbox.clear();
    pendingFileJobs.clear();
    await _saveContactsAndChats();
    _addLog('Буфер отправки очищен ($removedCount пакетов/задач удалено).');
    onStateChanged();
    return removedCount;
  }

  void _flushBufferedPacketsToOnlinePeers() {
    _evictExpired();
    if (_tcpPeers.isEmpty && _blePeers.isEmpty) return;

    // Удаляем пакеты, по которым уже есть ACK доставки
    for (final ackId in deliveredAcks.keys) {
      transitBuffer.remove(ackId);
      myPersistentOutbox.remove(ackId);
    }

    final combined = <String, MeshPacket>{
      ...myPersistentOutbox,
      ...transitBuffer,
    };
    if (combined.isEmpty) return;

    // Отправка на все активные TCP-сокеты с защитой от перегрузки
    int sentCount = 0;
    for (final entry in _tcpPeers.entries.toList()) {
      final sock = entry.key;
      final peerId = entry.value;
      for (final pkt in combined.values) {
        if (pkt.dstNodeId != '*' && pkt.dstNodeId != peerId && pkt.ttl <= 1) {
          continue;
        }
        _sendTcpLine(sock, jsonEncode(pkt.toJson()));
        sentCount++;
        if (sentCount >= 24) break;
      }
    }
  }

  Future<void> startLiveCall(String peerId, String mode) async {
    final contact = knownContacts[peerId];
    if (contact == null) return;
    activeCallPeerId = peerId;
    activeCallMode = mode;
    isCallAccepted = false;
    remoteVideoFrameBytes = null;
    callStatusText = mode == 'video'
        ? 'Вызов ВЧ (Видеочат)...'
        : 'Вызов ГЧ (Голосовой чат)...';
    final payload = jsonEncode({
      'v': 2,
      'kind': 'CALL_INVITE',
      'mode': mode,
      'nick': nickname,
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: peerId,
      contact: contact,
      msgId: _randomHex(12),
      sealedPayloadBytes: utf8.encode(payload),
      persistInOutbox: false,
      keepInTransitBuffer: false,
    );
    onStateChanged();
  }

  Future<void> acceptIncomingCall() async {
    final pid = incomingCallFromPeerId;
    if (pid == null) return;
    final contact = knownContacts[pid];
    activeCallPeerId = pid;
    activeCallMode = incomingCallMode;
    isCallAccepted = true;
    remoteVideoFrameBytes = null;
    incomingCallFromPeerId = null;
    callStatusText = activeCallMode == 'video'
        ? 'ВЧ активен (Видео + Голос)'
        : 'ГЧ активен (Голос)';
    if (contact != null) {
      final payload = jsonEncode({
        'v': 2,
        'kind': 'CALL_ACCEPT',
        'mode': activeCallMode,
      });
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: pid,
        contact: contact,
        msgId: _randomHex(12),
        sealedPayloadBytes: utf8.encode(payload),
        persistInOutbox: false,
      );
    }
    onStateChanged();
  }

  Future<void> rejectIncomingCall() async {
    final pid = incomingCallFromPeerId;
    incomingCallFromPeerId = null;
    if (pid != null) {
      final contact = knownContacts[pid];
      if (contact != null) {
        final payload = jsonEncode({'v': 2, 'kind': 'CALL_REJECT'});
        await _encryptAndQueueSealedDataPacket(
          targetNodeId: pid,
          contact: contact,
          msgId: _randomHex(12),
          sealedPayloadBytes: utf8.encode(payload),
          persistInOutbox: false,
        );
      }
    }
    onStateChanged();
  }

  Future<void> endActiveCall() async {
    final pid = activeCallPeerId;
    activeCallPeerId = null;
    isCallAccepted = false;
    remoteVideoFrameBytes = null;
    callStatusText = '';
    await stopAudioPlayback();
    if (pid != null) {
      final contact = knownContacts[pid];
      if (contact != null) {
        final payload = jsonEncode({'v': 2, 'kind': 'CALL_END'});
        await _encryptAndQueueSealedDataPacket(
          targetNodeId: pid,
          contact: contact,
          msgId: _randomHex(12),
          sealedPayloadBytes: utf8.encode(payload),
          persistInOutbox: false,
        );
      }
    }
    onStateChanged();
  }

  Future<void> sendCallAudioChunk(Uint8List bytes) async {
    final pid = activeCallPeerId;
    if (pid == null || !isCallAccepted || bytes.isEmpty) return;
    final contact = knownContacts[pid];
    if (contact == null) return;
    final payload = jsonEncode({
      'v': 2,
      'kind': 'CALL_AUDIO_CHUNK',
      'b64': base64Encode(bytes),
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: pid,
      contact: contact,
      msgId: _randomHex(10),
      sealedPayloadBytes: utf8.encode(payload),
      persistInOutbox: false,
      keepInTransitBuffer: false,
    );
  }

  Future<void> sendCallVideoFrame(Uint8List jpegBytes) async {
    final pid = activeCallPeerId;
    if (pid == null || !isCallAccepted || jpegBytes.isEmpty) return;
    final contact = knownContacts[pid];
    if (contact == null) return;
    final payload = jsonEncode({
      'v': 2,
      'kind': 'CALL_VIDEO_FRAME',
      'b64': base64Encode(jpegBytes),
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: pid,
      contact: contact,
      msgId: _randomHex(10),
      sealedPayloadBytes: utf8.encode(payload),
      persistInOutbox: false,
      keepInTransitBuffer: false,
    );
  }

  Future<Uint8List?> capturePlatformVideoFrame() async {
    try {
      if (Platform.isAndroid) {
        final bytes =
            await _nativeChannel.invokeMethod<Uint8List>('captureCameraFrame');
        return bytes;
      } else if (Platform.isWindows) {
        final tmpPath =
            '${Directory.systemTemp.path}${Platform.pathSeparator}mayak_vframe.jpg';
        final ps = r"""
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$bmp = New-Object System.Drawing.Bitmap \$b.Width, \$b.Height
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
\$small = New-Object System.Drawing.Bitmap 320, 180
\$g2 = [System.Drawing.Graphics]::FromImage(\$small)
\$g2.DrawImage(\$bmp, 0, 0, 320, 180)
\$small.Save('$tmpPath', [System.Drawing.Imaging.ImageFormat]::Jpeg)
\$g2.Dispose(); \$small.Dispose(); \$g.Dispose(); \$bmp.Dispose()
""";
        final res = await Process.run(
            'powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps]);
        if (res.exitCode == 0) {
          final f = File(tmpPath);
          if (await f.exists()) {
            return await f.readAsBytes();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> pingAllKnownNodes() async {
    _refreshOnlineStatuses();
    final peers = {..._tcpPeers.values, ..._blePeers.values};
    for (final pid in peers) {
      unawaited(pingPeer(pid).then((_) => onStateChanged()));
    }
    onStateChanged();
  }

  Future<void> addAdminTriggerWord(String word) async {
    final clean = word.trim().toLowerCase();
    if (clean.isEmpty || adminTriggerWords.contains(clean)) return;
    adminTriggerWords.add(clean);
    await _saveContactsAndChats();
    await _broadcastSignedAdminTriggers();
    onStateChanged();
  }

  Future<void> removeAdminTriggerWord(String word) async {
    adminTriggerWords.remove(word.trim().toLowerCase());
    await _saveContactsAndChats();
    await _broadcastSignedAdminTriggers();
    onStateChanged();
  }

  /// Удаление одного триггера из журнала Админа
  Future<void> deleteSingleTriggerHit(String hitId) async {
    clearedTriggerHitIds.add(hitId);
    triggerHits.removeWhere((h) => h.hitId == hitId);
    await _saveContactsAndChats();
    onStateChanged();
  }

  /// Очистка всего журнала сработавших триггеров в Панели Админа
  Future<void> clearAllTriggerHits() async {
    for (final h in triggerHits) {
      clearedTriggerHitIds.add(h.hitId);
    }
    triggerHits.clear();
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> _broadcastSignedAdminTriggers() async {
    final masterKp = _unlockedAdminMasterKeyPair;
    if (masterKp == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pktId = _randomHex(12);
    final expiresAt = now + 7 * 24 * 3600 * 1000;
    final payloadJson = jsonEncode({
      'act': 'SYNC_TRIGGERS',
      'words': adminTriggerWords,
      'ts': now,
    });
    final b64Payload = base64Encode(utf8.encode(payloadJson));
    final sigBytes = utf8.encode('ADMIN_CMD|$pktId|$expiresAt|$b64Payload');
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
    } else {
      bannedNodeIds.remove(targetNodeId);
      if (targetHw.isNotEmpty) bannedHwFingerprints.remove(targetHw);
      banAppeals.removeWhere((a) => a.nodeId == targetNodeId);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final pktId = _randomHex(12);
    final expiresAt = now + 7 * 24 * 3600 * 1000;
    final cmdPayloadJson = jsonEncode({
      'act': action,
      'target': targetNodeId,
      'hw': targetHw,
      'ts': now,
    });
    final b64Payload = base64Encode(utf8.encode(cmdPayloadJson));
    final sigBytes = utf8.encode('ADMIN_CMD|$pktId|$expiresAt|$b64Payload');
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
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> sendBanAppealNote(String noteText) async {
    final clean = noteText.trim();
    if (clean.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pktId = _randomHex(12);
    final expiresAt = now + 7 * 24 * 3600 * 1000;

    final appeal = BanAppealRecord(
      appealId: pktId,
      nodeId: nodeId,
      nickname: nickname,
      hwFingerprint: myHwFingerprint,
      appealText: clean,
      timestamp: now,
    );
    banAppeals.removeWhere((a) => a.nodeId == nodeId);
    banAppeals.insert(0, appeal);

    final b64Payload = base64Encode(utf8.encode(jsonEncode(appeal.toJson())));
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
      ephPubHex: 'BAN_APPEAL',
      nonceHex: '',
      ciphertextHex: b64Payload,
      macHex: '',
      signatureHex: _toHex(sig.bytes),
      expiresAt: expiresAt,
      ttl: 7,
    );
    _markPacketSeen(pktId);
    transitBuffer[pktId] = pkt;
    _floodAllTransports(pkt);
    await _saveContactsAndChats();
    _addLog('Записка на разбан отправлена администратору сети');
    onStateChanged();
  }

  /// ИСПРАВЛЕНИЕ ПУНКТОВ 7 и 8: Сбор полного досье узла при срабатывании триггера (-5 : +5) и сохранение для Store-and-Forward доставки Админу даже из другой сети!
  void _inspectMessageForTriggers(ChatMessage msg, String chatId) {
    final lowerText = msg.text.toLowerCase();
    final allMsgs = getMessagesFor(chatId);

    bool updatedExisting = false;
    for (final hit in triggerHits) {
      if (hit.chatId == chatId &&
          hit.triggerMsgId != msg.msgId &&
          hit.afterLines.length < 5 &&
          msg.timestamp >= hit.timestamp) {
        final formatted =
            '[${msg.timeFormatted}] ${msg.senderName} (${msg.senderId}): ${msg.text}';
        if (!hit.afterLines.contains(formatted)) {
          hit.afterLines.add(formatted);
          updatedExisting = true;
          unawaited(_broadcastTriggerHitReport(hit));
        }
      }
    }

    String? matchedTrigger;
    for (final w in adminTriggerWords) {
      if (w.isNotEmpty && lowerText.contains(w.toLowerCase())) {
        matchedTrigger = w;
        break;
      }
    }

    if (matchedTrigger != null) {
      final hitId = '${msg.msgId}_trig';
      if (!clearedTriggerHitIds.contains(hitId)) {
        final idx = allMsgs.indexWhere((m) => m.msgId == msg.msgId);
        final startIdx = max(0, (idx >= 0 ? idx : allMsgs.length) - 5);
        final endBefore = idx >= 0 ? idx : allMsgs.length;
        final beforeList = <String>[];
        for (int i = startIdx; i < endBefore; i++) {
          final m = allMsgs[i];
          beforeList.add(
              '[${m.timeFormatted}] ${m.senderName} (${m.senderId}): ${m.text}');
        }
        final chatTitle = chatId == broadcastChannelId
            ? 'Общий эфир'
            : (knownContacts[chatId]?.displayTitle ?? 'Личный чат $chatId');

        final isOffenderMe = msg.senderId == nodeId;
        final offenderContact = knownContacts[msg.senderId];

        final offenderHw = isOffenderMe
            ? myHwFingerprint
            : (offenderContact?.hwFingerprint ?? '');
        final offenderIp = isOffenderMe
            ? '${cachedIps.join(", ")}:$listenPort'
            : (offenderContact?.lastAddress ?? '');
        final offenderOs = isOffenderMe
            ? myPlatformInfo
            : (offenderContact?.platformInfo ?? '');
        final offenderDh =
            isOffenderMe ? dhPubHex : (offenderContact?.dhPubHex ?? '');
        final offenderSign =
            isOffenderMe ? signPubHex : (offenderContact?.signPubHex ?? '');

        final hit = TriggerHitRecord(
          hitId: hitId,
          chatId: chatId,
          chatTitle: chatTitle,
          triggerWord: matchedTrigger,
          offenderNodeId: msg.senderId,
          offenderName: msg.senderName,
          offenderHwFingerprint: offenderHw,
          offenderIpAddress: offenderIp,
          offenderPlatformInfo: offenderOs,
          offenderDhPubHex: offenderDh,
          offenderSignPubHex: offenderSign,
          triggerMsgId: msg.msgId,
          timestamp: msg.timestamp,
          beforeLines: beforeList,
          triggerLine:
              '[${msg.timeFormatted}] ${msg.senderName} (${msg.senderId}): ${msg.text}',
          afterLines: [],
        );
        triggerHits.removeWhere((h) => h.hitId == hit.hitId);
        triggerHits.insert(0, hit);
        if (triggerHits.length > 100) {
          triggerHits.removeLast();
        }
        updatedExisting = true;
        unawaited(_broadcastTriggerHitReport(hit));
      }
    }

    if (updatedExisting) {
      unawaited(_saveContactsAndChats());
      onStateChanged();
    }
  }

  Future<void> _broadcastTriggerHitReport(TriggerHitRecord hit) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pktId = _randomHex(12);
      final expiresAt = now + 7 * 24 * 3600 * 1000;
      final b64Payload = base64Encode(utf8.encode(jsonEncode(hit.toJson())));
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
        ephPubHex: 'TRIGGER_REPORT',
        nonceHex: '',
        ciphertextHex: b64Payload,
        macHex: '',
        signatureHex: _toHex(sig.bytes),
        expiresAt: expiresAt,
        ttl: 7,
      );
      _markPacketSeen(pktId);
      transitBuffer[pktId] = pkt;
      _floodAllTransports(pkt);
    } catch (_) {}
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

  /// ИСПРАВЛЕНИЕ ПУНКТА 2: Нажатие на кнопку скачивания поверх заблюренного медиа (как в Telegram!)
  Future<void> requestDownloadOrRevealMedia(ChatMessage msg) async {
    // Если файл уже скачан во внутренний кэш — просто снимаем блюр и показываем!
    if (msg.filePath != null && File(msg.filePath!).existsSync()) {
      msg.isMediaRevealed = true;
      msg.isDownloading = false;
      msg.transferProgress = 1.0;
      await _saveContactsAndChats();
      onStateChanged();
      return;
    }

    // Если файла на устройстве нет (еще не скачивали ИЛИ стерли из кэша) — запрашиваем скачивание у отправителя (FILE_PULL_REQ)
    final contact = knownContacts[msg.senderId];
    if (contact == null) {
      _addLog('Отправитель файла не найден в списке контактов');
      return;
    }
    msg.isDownloading = true;
    msg.transferProgress = 0.02;
    onStateChanged();

    final reqId = _randomHex(12);
    final reqPayload = jsonEncode({
      'v': 2,
      'kind': 'FILE_PULL_REQ',
      'fid': msg.msgId,
      'nick': nickname,
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: msg.senderId,
      contact: contact,
      msgId: reqId,
      sealedPayloadBytes: utf8.encode(reqPayload),
      persistInOutbox: true,
    );
    _addLog('Запрошено скачивание файла «${msg.fileName ?? msg.msgId}»...');
  }

  /// Стирание скачанных файлов из кэша с возвратом картинок/видео под блюр и возможностью скачать заново!
  Future<String> clearAllDownloadedMediaFromDevice() async {
    await stopAudioPlayback();
    int freedBytes = 0;
    try {
      if (Platform.isAndroid) {
        try {
          final res =
              await _nativeChannel.invokeMethod<int>('clearDownloadedMediaCache');
          freedBytes += (res ?? 0);
        } catch (_) {}
        final dir = await _getInternalCacheFilesDir();
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              try {
                freedBytes += await entity.length();
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } else {
        final dir = await _getInternalCacheFilesDir();
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              try {
                freedBytes += await entity.length();
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    chatHistory.forEach((_, list) {
      for (final m in list) {
        if (m.fileName != null && m.fileName!.isNotEmpty) {
          if (!m.isMe) {
            m.filePath = null;
            m.isMediaRevealed = false;
            m.isDownloading = false;
            m.transferProgress = 0.0;
          }
        }
      }
    });
    await _saveContactsAndChats();
    onStateChanged();
    final mb = (freedBytes / (1024 * 1024)).toStringAsFixed(2);
    return 'Очищено $mb МБ из кэша. Нажмите на значок загрузки на медиа, чтобы скачать заново!';
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 9: Редактирование сообщения (у себя и у собеседника)
  Future<void> editMessage(
      String chatId, String targetMsgId, String newText) async {
    final clean = newText.trim();
    if (clean.isEmpty || isSelfBanned) return;

    ChatMessage? editedMsg;
    for (final m in getMessagesFor(chatId)) {
      if (m.msgId == targetMsgId && m.isMe) {
        m.text = clean;
        m.isEdited = true;
        editedMsg = m;
        break;
      }
    }
    if (editedMsg == null) return;

    _inspectMessageForTriggers(editedMsg, chatId);
    await _saveContactsAndChats();
    onStateChanged();

    if (chatId == broadcastChannelId) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pktId = _randomHex(12);
      final expiresAt = now + 24 * 3600 * 1000;
      final editJson = jsonEncode({
        'edit_msg': targetMsgId,
        'txt': clean,
      });
      final b64Payload = base64Encode(utf8.encode(editJson));
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
        ephPubHex: 'MSG_EDIT',
        nonceHex: '',
        ciphertextHex: b64Payload,
        macHex: '',
        signatureHex: _toHex(sig.bytes),
        expiresAt: expiresAt,
        ttl: 6,
      );
      _markPacketSeen(pktId);
      transitBuffer[pktId] = pkt;
      _floodAllTransports(pkt);
      return;
    }

    final contact = knownContacts[chatId];
    if (contact == null) return;
    final pktId = _randomHex(12);
    final env = jsonEncode({
      'v': 2,
      'kind': 'MSG_EDIT',
      'targetId': targetMsgId,
      'txt': clean,
      'nick': nickname,
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: chatId,
      contact: contact,
      msgId: pktId,
      sealedPayloadBytes: utf8.encode(env),
      persistInOutbox: true,
    );
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 9: Удаление сообщения у себя и у собеседника
  Future<void> deleteMessageForEveryone(
      String chatId, String targetMsgId) async {
    deletedMessageIds.add(targetMsgId);
    getMessagesFor(chatId).removeWhere((m) => m.msgId == targetMsgId);
    transitBuffer.remove(targetMsgId);
    myPersistentOutbox.remove(targetMsgId);
    await _saveContactsAndChats();
    onStateChanged();

    if (chatId == broadcastChannelId) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pktId = _randomHex(12);
      final expiresAt = now + 24 * 3600 * 1000;
      final delJson = jsonEncode({'del_msg': targetMsgId});
      final b64Payload = base64Encode(utf8.encode(delJson));
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
        ephPubHex: 'MSG_DELETE',
        nonceHex: '',
        ciphertextHex: b64Payload,
        macHex: '',
        signatureHex: _toHex(sig.bytes),
        expiresAt: expiresAt,
        ttl: 6,
      );
      _markPacketSeen(pktId);
      transitBuffer[pktId] = pkt;
      _floodAllTransports(pkt);
      return;
    }

    final contact = knownContacts[chatId];
    if (contact == null) return;
    final pktId = _randomHex(12);
    final env = jsonEncode({
      'v': 2,
      'kind': 'MSG_DELETE',
      'targetId': targetMsgId,
      'nick': nickname,
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: chatId,
      contact: contact,
      msgId: pktId,
      sealedPayloadBytes: utf8.encode(env),
      persistInOutbox: true,
    );
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 9: Пересылка сообщения (текста или файла) в другой чат
  Future<void> forwardMessageToChat(
      ChatMessage srcMsg, String targetChatId) async {
    if (isSelfBanned) return;
    final originAuthor =
        srcMsg.forwardedFrom != null && srcMsg.forwardedFrom!.isNotEmpty
            ? srcMsg.forwardedFrom!
            : srcMsg.senderName;

    if (srcMsg.fileName != null &&
        srcMsg.fileName!.isNotEmpty &&
        srcMsg.filePath != null &&
        File(srcMsg.filePath!).existsSync() &&
        targetChatId != broadcastChannelId) {
      await sendFileMessage(
        targetChatId,
        filePath: srcMsg.filePath!,
        fileName: srcMsg.fileName!,
        thumbB64Arg: srcMsg.thumbB64,
        forwardedFrom: originAuthor,
      );
      return;
    }

    await sendMessage(
      targetChatId,
      srcMsg.text,
      forwardedFrom: originAuthor,
    );
  }

  Future<void> clearChatHistoryOnly(String targetNodeId) async {
    final list = chatHistory[targetNodeId] ?? [];
    for (final m in list) {
      deletedMessageIds.add(m.msgId);
    }
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
    if (Platform.isAndroid) {
      try {
        _internalDataDirPath = await _nativeChannel
                .invokeMethod<String>('getAppInternalDataDir') ??
            '';
        myPlatformInfo =
            await _nativeChannel.invokeMethod<String>('getDeviceOsInfo') ??
                'Android';
      } catch (_) {
        myPlatformInfo = 'Android';
      }
    } else {
      myPlatformInfo =
          '${Platform.operatingSystem.toUpperCase()} (${Platform.localHostname})';
    }

    try {
      await _loadOrCreateIdentity();
      await _loadPersistedContactsAndChats();
    } catch (e) {
      _addLog('Ошибка инициализации хранилища: $e');
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
    _addLog('Защищенный узел v1.5 готов (порт $listenPort)');

    unawaited(scanLocalSubnet(quickOnly: true));
  }

  Future<List<File>> _getLocalDatabaseFiles() async {
    final files = <File>[];
    try {
      if (Platform.isAndroid) {
        final candidateDirs = <String>[
          if (_internalDataDirPath.isNotEmpty) _internalDataDirPath,
          '/data/user/0/com.mayak.mesh.p2p_mesh/files/mayak_data',
          '/data/data/com.mayak.mesh.p2p_mesh/files/mayak_data',
        ];
        for (final dirPath in candidateDirs.toSet()) {
          try {
            final d = Directory(dirPath);
            if (!await d.exists()) await d.create(recursive: true);
            files.add(File('${d.path}/mayak_store_v15.json'));
            files.add(File('${d.path}/mayak_store_v15.bak.json'));
            files.add(File('${d.path}/mayak_store_v14.json'));
          } catch (_) {}
        }
      } else {
        final home = Platform.environment['USERPROFILE'] ??
            Platform.environment['HOME'] ??
            '.';
        final dir = Directory('$home/Downloads/Mayak');
        if (!await dir.exists()) await dir.create(recursive: true);
        files.add(File('${dir.path}/mayak_store_v15.json'));
        files.add(File('${dir.path}/mayak_store_v15.bak.json'));
        files.add(File('${dir.path}/mayak_store_v14.json'));
        files.add(File('${dir.path}/.mayak_backup_v12.json'));
      }
    } catch (_) {}
    return files;
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 3: Многоуровневое чтение БД (нативный синхронный SharedPreferences на Android + файлы v15/v14)
  Future<Map<String, dynamic>> _readMasterStoreMap() async {
    if (Platform.isAndroid) {
      try {
        final nativeJson =
            await _nativeChannel.invokeMethod<String>('loadNativeDbJson');
        if (nativeJson != null && nativeJson.trim().isNotEmpty) {
          final map = jsonDecode(nativeJson) as Map<String, dynamic>;
          if (map.isNotEmpty) return map;
        }
      } catch (_) {}
    }

    final dbFiles = await _getLocalDatabaseFiles();
    for (final f in dbFiles) {
      try {
        if (await f.exists()) {
          final content = await f.readAsString();
          if (content.trim().isNotEmpty) {
            final map = jsonDecode(content) as Map<String, dynamic>;
            if (map.isNotEmpty) return map;
          }
        }
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final spMaster = prefs.getString('mayak_master_store_v15');
      if (spMaster != null && spMaster.trim().isNotEmpty) {
        final map = jsonDecode(spMaster) as Map<String, dynamic>;
        if (map.isNotEmpty) return map;
      }
    } catch (_) {}
    return {};
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

    final storeMap = await _readMasterStoreMap();
    String? savedSignSeed = storeMap['sign_seed'] as String?;
    String? savedDhSeed = storeMap['dh_seed'] as String?;
    String? savedNick = storeMap['nick'] as String?;

    try {
      final prefs = await SharedPreferences.getInstance();
      savedSignSeed ??= prefs.getString('sign_seed');
      savedDhSeed ??= prefs.getString('dh_seed');
      savedNick ??= prefs.getString('user_nickname');
    } catch (_) {}

    if (savedSignSeed == null ||
        savedDhSeed == null ||
        savedSignSeed.length != 64 ||
        savedDhSeed.length != 64) {
      if (rawHwId.isNotEmpty && rawHwId.length > 4) {
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
    }

    _signKeyPair = await _ed25519.newKeyPairFromSeed(_fromHex(savedSignSeed));
    _dhKeyPair = await _x25519.newKeyPairFromSeed(_fromHex(savedDhSeed));

    final dhPub = await _dhKeyPair.extractPublicKey();
    final signPub = await _signKeyPair.extractPublicKey();
    dhPubHex = _toHex(dhPub.bytes);
    signPubHex = _toHex(signPub.bytes);
    nodeId = await _calcNodeId(dhPub.bytes);

    final defaultName = Platform.isAndroid ? 'Android-$nodeId' : 'PC-$nodeId';
    if (savedNick != null && savedNick.trim().isNotEmpty) {
      nickname = savedNick.trim();
    } else {
      nickname = defaultName;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sign_seed', savedSignSeed);
      await prefs.setString('dh_seed', savedDhSeed);
      await prefs.setString('user_nickname', nickname);
    } catch (_) {}
  }

  Future<void> _loadPersistedContactsAndChats() async {
    final storeMap = await _readMasterStoreMap();

    String? contactsRaw = storeMap['contacts'] as String?;
    String? chatsRaw = storeMap['chats'] as String?;
    String? outboxRaw = storeMap['outbox'] as String?;
    String? pendingFilesRaw = storeMap['pending_files'] as String?;

    if (storeMap['deleted_contacts'] is List) {
      deletedContactIds.addAll(
          (storeMap['deleted_contacts'] as List).map((e) => e.toString()));
    }
    if (storeMap['deleted_msgs'] is List) {
      deletedMessageIds
          .addAll((storeMap['deleted_msgs'] as List).map((e) => e.toString()));
    }
    if (storeMap['cleared_triggers'] is List) {
      clearedTriggerHitIds.addAll(
          (storeMap['cleared_triggers'] as List).map((e) => e.toString()));
    }
    if (storeMap['banned_nodes'] is List) {
      bannedNodeIds
          .addAll((storeMap['banned_nodes'] as List).map((e) => e.toString()));
    }
    if (storeMap['banned_hw'] is List) {
      bannedHwFingerprints
          .addAll((storeMap['banned_hw'] as List).map((e) => e.toString()));
    }
    if (storeMap['offered_files'] is Map) {
      (storeMap['offered_files'] as Map).forEach((k, v) {
        offeredFileCatalog[k.toString()] = v.toString();
      });
    }
    if (storeMap['admin_triggers'] is List) {
      final words = (storeMap['admin_triggers'] as List)
          .map((e) => e.toString().trim().toLowerCase())
          .where((w) => w.isNotEmpty)
          .toList();
      if (words.isNotEmpty) {
        adminTriggerWords
          ..clear()
          ..addAll(words);
      }
    }
    if (storeMap['trigger_hits'] is List) {
      for (final item in (storeMap['trigger_hits'] as List)) {
        try {
          final h = TriggerHitRecord.fromJson(
              Map<String, dynamic>.from(item as Map));
          if (!clearedTriggerHitIds.contains(h.hitId)) {
            triggerHits.add(h);
          }
        } catch (_) {}
      }
    }
    if (storeMap['groups'] is List) {
      for (final item in (storeMap['groups'] as List)) {
        try {
          final g = GroupChat.fromJson(Map<String, dynamic>.from(item as Map));
          if (g.groupId.isNotEmpty) {
            groupChats[g.groupId] = g;
          }
        } catch (_) {}
      }
    }
    if (storeMap['ban_appeals'] is List) {
      for (final item in (storeMap['ban_appeals'] as List)) {
        try {
          banAppeals.add(
              BanAppealRecord.fromJson(Map<String, dynamic>.from(item as Map)));
        } catch (_) {}
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      deletedContactIds
          .addAll(prefs.getStringList('deleted_contacts_v11') ?? []);
      bannedNodeIds.addAll(prefs.getStringList('banned_nodes_v13') ?? []);
      bannedHwFingerprints.addAll(prefs.getStringList('banned_hw_v13') ?? []);
      contactsRaw ??= prefs.getString('saved_contacts_v7');
      chatsRaw ??= prefs.getString('saved_chats_v7');
      outboxRaw ??= prefs.getString('saved_outbox_v9');
      pendingFilesRaw ??= prefs.getString('saved_pending_files_v11');
    } catch (_) {}

    if (contactsRaw != null && contactsRaw.isNotEmpty) {
      try {
        final list = jsonDecode(contactsRaw) as List;
        for (final item in list) {
          final c =
              ContactProfile.fromJson(Map<String, dynamic>.from(item as Map));
          if (c.nodeId.isNotEmpty &&
              c.nodeId != nodeId &&
              !deletedContactIds.contains(c.nodeId)) {
            knownContacts[c.nodeId] = c;
          }
        }
      } catch (_) {}
    }

    if (chatsRaw != null && chatsRaw.isNotEmpty) {
      try {
        final map = jsonDecode(chatsRaw) as Map<String, dynamic>;
        map.forEach((peerId, msgsJson) {
          if (deletedContactIds.contains(peerId)) return;
          final list = <ChatMessage>[];
          for (final m in (msgsJson as List)) {
            try {
              final msgObj =
                  ChatMessage.fromJson(Map<String, dynamic>.from(m as Map));
              if (!deletedMessageIds.contains(msgObj.msgId)) {
                list.add(msgObj);
              }
            } catch (_) {}
          }
          if (list.isNotEmpty) {
            chatHistory[peerId] = list;
          }
        });
      } catch (_) {}
    }

    if (outboxRaw != null && outboxRaw.isNotEmpty) {
      try {
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
      } catch (_) {}
    }

    if (pendingFilesRaw != null && pendingFilesRaw.isNotEmpty) {
      try {
        final list = jsonDecode(pendingFilesRaw) as List;
        for (final item in list) {
          final job =
              PendingFileJob.fromJson(Map<String, dynamic>.from(item as Map));
          if (!deletedContactIds.contains(job.targetNodeId) &&
              File(job.filePath).existsSync()) {
            pendingFileJobs[job.fileId] = job;
          }
        }
      } catch (_) {}
    }

    await _saveContactsAndChats();
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 3: Строго последовательное атомарное сохранение БД без гонок записи!
  Future<void> _saveContactsAndChats() {
    _saveLockChain = _saveLockChain.then((_) async {
      try {
        final contactsJson =
            jsonEncode(knownContacts.values.map((c) => c.toJson()).toList());

        final chatsMap = <String, dynamic>{};
        chatHistory.forEach((peerId, list) {
          final trimmed =
              list.length > 200 ? list.sublist(list.length - 200) : list;
          chatsMap[peerId] = trimmed.map((m) => m.toJson()).toList();
        });
        final chatsJson = jsonEncode(chatsMap);

        final outboxJson = jsonEncode(
            myPersistentOutbox.values.map((p) => p.toJson()).toList());
        final filesJson =
            jsonEncode(pendingFileJobs.values.map((j) => j.toJson()).toList());

        final signSeedBytes = await _signKeyPair.extractPrivateKeyBytes();
        final dhSeedBytes = await _dhKeyPair.extractPrivateKeyBytes();

        final fullStorePayload = jsonEncode({
          'sign_seed': _toHex(signSeedBytes),
          'dh_seed': _toHex(dhSeedBytes),
          'nick': nickname,
          'contacts': contactsJson,
          'chats': chatsJson,
          'outbox': outboxJson,
          'pending_files': filesJson,
          'offered_files': offeredFileCatalog,
          'deleted_contacts': deletedContactIds.toList(),
          'deleted_msgs': deletedMessageIds.toList(),
          'cleared_triggers': clearedTriggerHitIds.toList(),
          'banned_nodes': bannedNodeIds.toList(),
          'banned_hw': bannedHwFingerprints.toList(),
          'admin_triggers': adminTriggerWords,
          'trigger_hits': triggerHits.map((h) => h.toJson()).toList(),
          'groups': groupChats.values.map((g) => g.toJson()).toList(),
          'ban_appeals': banAppeals.map((a) => a.toJson()).toList(),
        });

        if (Platform.isAndroid) {
          try {
            await _nativeChannel.invokeMethod(
                'saveNativeDbJson', {'json': fullStorePayload});
          } catch (_) {}
        }

        final dbFiles = await _getLocalDatabaseFiles();
        if (dbFiles.isNotEmpty) {
          final primaryFile = dbFiles.first;
          final tmpFile = File('${primaryFile.path}.tmp');
          await tmpFile.writeAsString(fullStorePayload, flush: true);
          if (await primaryFile.exists() && await primaryFile.length() > 20) {
            try {
              await primaryFile.copy('${primaryFile.path}.bak');
            } catch (_) {}
          }
          await tmpFile.rename(primaryFile.path);
        }

        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('mayak_master_store_v15', fullStorePayload);
          await prefs.setString('user_nickname', nickname);
          await prefs.setString('saved_contacts_v7', contactsJson);
          await prefs.setString('saved_chats_v7', chatsJson);
          await prefs.setString('saved_outbox_v9', outboxJson);
        } catch (_) {}
      } catch (_) {}
    });
    return _saveLockChain;
  }

  Future<void> updateNickname(String newName) async {
    final clean = newName.trim();
    if (clean.isEmpty) return;
    nickname = clean;
    await _saveContactsAndChats();
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
        'os': myPlatformInfo,
      });

  /// Пакет синхронизации при встрече любых двух узлов (передает контакты, баны, триггерные слова, журнал нарушений и апелляции даже между разными сетями!)
  String _buildPeerSyncJson() {
    final peers = knownContacts.values
        .map((c) => {
              'id': c.nodeId,
              'nick': c.nickname,
              'dh': c.dhPubHex,
              'sg': c.signPubHex,
              'hw': c.hwFingerprint,
              'os': c.platformInfo,
            })
        .toList();
    return jsonEncode({
      'peer_sync': peers,
      'banned_ids': bannedNodeIds.toList(),
      'banned_hw': bannedHwFingerprints.toList(),
      'trigger_words': adminTriggerWords,
      'cleared_triggers': clearedTriggerHitIds.toList(),
      'trigger_sync': triggerHits.take(40).map((h) => h.toJson()).toList(),
      'appeal_sync': banAppeals.take(30).map((a) => a.toJson()).toList(),
    });
  }

  /// Двусторонняя синхронизация истории чата между двумя собеседниками при подключении (восстанавливает историю на телефоне после переустановки!)
  String _buildChatHistorySyncForPeer(String peerId) {
    final msgs = getMessagesFor(peerId);
    final recent = msgs.length > 60 ? msgs.sublist(msgs.length - 60) : msgs;
    return jsonEncode({
      'chat_sync_peer': nodeId,
      'msgs': recent.map((m) => m.toSyncJson()).toList(),
      'deleted_ids': deletedMessageIds.toList(),
    });
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
        'os': myPlatformInfo,
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
    final targetOs = (decoded['os'] as String?) ?? '';

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
      platformInfo: targetOs,
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

  /// ИСПРАВЛЕНИЕ ПУНКТА 2: Извлечение мини-превью (JPEG в Base64 прямо в памяти, БЕЗ создания файлов картинок в Загрузках!)
  Future<String?> extractPreviewBase64InMemory(String filePath,
      {required bool isVideo}) async {
    if (filePath.isEmpty || !File(filePath).existsSync()) return null;
    try {
      if (Platform.isAndroid) {
        final b64 = await _nativeChannel.invokeMethod<String>(
          'extractPreviewBase64',
          {'path': filePath, 'isVideo': isVideo},
        );
        if (b64 != null && b64.isNotEmpty) return b64;
      } else if (Platform.isWindows) {
        if (!isVideo) {
          const psImgScript = r'''
Add-Type -AssemblyName System.Drawing
$p = $env:MAYAK_MEDIA_PATH
try {
  $img = [System.Drawing.Image]::FromFile($p)
  $w = 280
  $h = [int]($img.Height * (280.0 / [Math]::Max(1, $img.Width)))
  if ($h -le 0) { $h = 180 }
  $bmp = New-Object System.Drawing.Bitmap($img, $w, $h)
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
  [Console]::Out.WriteLine([Convert]::ToBase64String($ms.ToArray()))
  $ms.Dispose(); $bmp.Dispose(); $img.Dispose()
} catch {}
''';
          final res = await Process.run(
            'powershell',
            ['-NoProfile', '-STA', '-Command', psImgScript],
            environment: {'MAYAK_MEDIA_PATH': filePath.replaceAll('/', '\\')},
          ).timeout(const Duration(seconds: 4),
              onTimeout: () => ProcessResult(0, 1, '', ''));
          final out = res.stdout.toString().trim();
          if (out.isNotEmpty) return out;
        } else {
          const psVidScript = r'''
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$vPath = $env:MAYAK_MEDIA_PATH
try {
  $me = New-Object System.Windows.Controls.MediaElement
  $me.LoadedBehavior = [System.Windows.Controls.MediaState]::Manual
  $me.UnloadedBehavior = [System.Windows.Controls.MediaState]::Manual
  $me.Volume = 0
  $me.ScrubbingEnabled = $true
  $me.Width = 320; $me.Height = 180
  $win = New-Object System.Windows.Window
  $win.Width = 320; $win.Height = 180
  $win.Left = -4000; $win.Top = -4000
  $win.WindowStyle = [System.Windows.WindowStyle]::None
  $win.ShowInTaskbar = $false
  $win.AllowsTransparency = $true
  $win.Opacity = 0.01
  $win.Content = $me
  $win.Show()
  $me.Source = [Uri]::new($vPath)
  $me.Play()
  $t0 = [DateTime]::Now
  while (-not $me.NaturalDuration.HasTimeSpan -and (([DateTime]::Now - $t0).TotalMilliseconds -lt 2500)) {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    Start-Sleep -Milliseconds 30
  }
  $me.Position = [TimeSpan]::FromMilliseconds(400)
  for ($i = 0; $i -lt 8; $i++) {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    Start-Sleep -Milliseconds 35
  }
  $me.Pause()
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(320, 180, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($me)
  $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
  $enc.QualityLevel = 72
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $ms = New-Object System.IO.MemoryStream
  $enc.Save($ms)
  [Console]::Out.WriteLine([Convert]::ToBase64String($ms.ToArray()))
  $ms.Dispose()
  $me.Close()
  $win.Close()
} catch {}
''';
          final res = await Process.run(
            'powershell',
            ['-NoProfile', '-STA', '-Command', psVidScript],
            environment: {'MAYAK_MEDIA_PATH': filePath.replaceAll('/', '\\')},
          ).timeout(const Duration(seconds: 5),
              onTimeout: () => ProcessResult(0, 1, '', ''));
          final out = res.stdout.toString().trim();
          if (out.isNotEmpty) return out;
        }
      }
    } catch (_) {}
    if (!isVideo) {
      try {
        final rawBytes = await File(filePath).readAsBytes();
        final codec = await ui.instantiateImageCodec(rawBytes, targetWidth: 160);
        final frame = await codec.getNextFrame();
        final byteData =
            await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          return base64Encode(byteData.buffer.asUint8List());
        }
      } catch (_) {}
    }
    return null;
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
        final lower = name.toLowerCase();
        final isVid = lower.endsWith('.mp4') ||
            lower.endsWith('.mkv') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.avi') ||
            lower.endsWith('.webm');
        final isImg = lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp') ||
            lower.endsWith('.gif');
        String? thumbB64;
        if (isVid || isImg) {
          thumbB64 = await extractPreviewBase64InMemory(selectedPath,
              isVideo: isVid);
        }
        return {
          'path': selectedPath,
          'name': name,
          'size': await file.length(),
          'thumbB64': thumbB64 ?? '',
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
        final dir = await _getInternalCacheFilesDir();
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

  /// Сохранение в публичную папку «Загрузки/Mayak» ТОЛЬКО когда пользователь сам нажмет кнопку «В Загрузки»!
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
        return 'Сохранено в Загрузки: $dstPath';
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
    if (isSelfBanned) return;
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

  /// ИСПРАВЛЕНИЕ ПУНКТА 2: Отправка файла по модели Telegram (сначала уходит FILE_OFFER с заблюренным мини-превью в памяти, а сами чанки передаются когда получатель нажмет кнопку Скачать!)
  Future<void> sendFileMessage(
    String targetNodeId, {
    required String filePath,
    required String fileName,
    String? existingFileId,
    String? thumbB64Arg,
    String? forwardedFrom,
  }) async {
    if (isSelfBanned) {
      _addLog('Отправка заблокирована: ваш узел находится в бане');
      return;
    }
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
    String cleanFileName = _sanitizeFileName(fileName);
    try {
      final headerBytes = await raf.read(min(16, totalSize));
      if (!cleanFileName.contains('.')) {
        final detectedExt = _detectMediaExtensionFromBytes(headerBytes);
        if (detectedExt != null) {
          cleanFileName = '$cleanFileName.$detectedExt';
        }
      }
    } finally {
      await raf.close();
    }

    String? resolvedThumbB64 = thumbB64Arg;
    final lowerName = cleanFileName.toLowerCase();
    final isVid = lowerName.endsWith('.mp4') ||
        lowerName.endsWith('.mkv') ||
        lowerName.endsWith('.mov') ||
        lowerName.endsWith('.avi') ||
        lowerName.endsWith('.webm');
    final isImg = lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png') ||
        lowerName.endsWith('.webp') ||
        lowerName.endsWith('.gif');

    if ((resolvedThumbB64 == null || resolvedThumbB64.isEmpty) &&
        (isVid || isImg)) {
      resolvedThumbB64 =
          await extractPreviewBase64InMemory(filePath, isVideo: isVid);
    }

    final fileId = existingFileId ?? _randomHex(12);
    final now = DateTime.now().millisecondsSinceEpoch;
    offeredFileCatalog[fileId] = filePath;

    final myMsg = ChatMessage(
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
      thumbB64: resolvedThumbB64,
      isMediaRevealed: true,
      forwardedFrom: forwardedFrom,
      transferProgress: 1.0,
    );
    getMessagesFor(targetNodeId).add(myMsg);

    final offerMap = <String, dynamic>{
      'v': 2,
      'kind': 'FILE_OFFER',
      'fid': fileId,
      'fn': cleanFileName,
      'fs': totalSize,
      'nick': nickname,
    };
    if (resolvedThumbB64 != null && resolvedThumbB64.isNotEmpty) {
      offerMap['tb64'] = resolvedThumbB64;
    }
    if (forwardedFrom != null && forwardedFrom.isNotEmpty) {
      offerMap['fwd'] = forwardedFrom;
    }

    await _encryptAndQueueSealedDataPacket(
      targetNodeId: targetNodeId,
      contact: contact,
      msgId: fileId,
      sealedPayloadBytes: utf8.encode(jsonEncode(offerMap)),
      keepInTransitBuffer: true,
      persistInOutbox: true,
    );

    await _saveContactsAndChats();
    onStateChanged();
  }

  /// Потоковая отдача чанков файла по запросу получателя (когда получатель нажал кнопку «Скачать» на заблюренном превью!)
  Future<void> _streamFileChunksToPeer(
      String targetNodeId, String fileId) async {
    final contact = knownContacts[targetNodeId];
    final filePath = offeredFileCatalog[fileId];
    if (contact == null) return;
    if (filePath == null || !await File(filePath).exists()) {
      final missPayload = jsonEncode({
        'v': 2,
        'kind': 'FILE_MISSING',
        'fid': fileId,
      });
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: targetNodeId,
        contact: contact,
        msgId: _randomHex(12),
        sealedPayloadBytes: utf8.encode(missPayload),
        persistInOutbox: false,
      );
      return;
    }
    final file = File(filePath);

    final totalSize = await file.length();
    if (totalSize <= 0) return;
    final cleanFileName = _sanitizeFileName(filePath.split(RegExp(r'[\\/]')).last);
    final totalChunks = (totalSize / fileChunkSize).ceil();

    final job = pendingFileJobs.putIfAbsent(
      '${fileId}_$targetNodeId',
      () => PendingFileJob(
        fileId: fileId,
        targetNodeId: targetNodeId,
        filePath: filePath,
        fileName: cleanFileName,
        confirmedChunkIndex: 0,
      ),
    );
    if (job.isSending) return;
    job.isSending = true;

    final raf = await file.open(mode: FileMode.read);
    try {
      final fileEphKeyPair = await _x25519.newKeyPair();
      final fileEphPub = await fileEphKeyPair.extractPublicKey();
      final fileEphPubHex = _toHex(fileEphPub.bytes);

      for (int idx = 0; idx < totalChunks; idx++) {
        if (!isPeerDirectlyConnected(targetNodeId)) {
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

        final envMap = <String, dynamic>{
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
        };

        final chunkMsgId = '${fileId}_chk_${idx}_${_randomHex(3)}';

        await _encryptAndQueueSealedDataPacket(
          targetNodeId: targetNodeId,
          contact: contact,
          msgId: chunkMsgId,
          sealedPayloadBytes: utf8.encode(jsonEncode(envMap)),
          precomputedEphKeyPair: fileEphKeyPair,
          precomputedEphPubHex: fileEphPubHex,
          keepInTransitBuffer: false,
          persistInOutbox: false,
        );

        if (winWaiter != null) {
          await winWaiter.future.timeout(const Duration(milliseconds: 1500),
              onTimeout: () {});
          _fileWindowAckWaiters.remove('${fileId}_$idx');
        } else {
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }
    } finally {
      job.isSending = false;
      pendingFileJobs.remove('${fileId}_$targetNodeId');
      await raf.close();
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

  /// Внутренний кэш приложения (НЕ папка «Загрузки»! В «Загрузки» сохраняется только по явному нажатию кнопки «На устройство»)
  Future<Directory> _getInternalCacheFilesDir() async {
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
      try {
        final d = Directory('/data/data/com.mayak.mesh.p2p_mesh/files/mayak_received');
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      } catch (_) {}
    } else if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['TEMP'] ??
          '.';
      final d = Directory('$localAppData/MayakMeshCache');
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
    String? platformInfo,
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
    final cleanOs = (platformInfo ?? '').trim();
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

    final now = DateTime.now().millisecondsSinceEpoch;
    final isPeerConnected =
        _tcpPeers.containsValue(nodeId) || _blePeers.containsValue(nodeId);

    if (existing != null) {
      if (cleanNick.isNotEmpty && !cleanNick.startsWith('Узел ')) {
        existing.nickname = cleanNick;
      }
      if (cleanHw.isNotEmpty) {
        existing.hwFingerprint = cleanHw;
      }
      if (cleanOs.isNotEmpty) {
        existing.platformInfo = cleanOs;
      }
      if (address != null && address.isNotEmpty) {
        existing.lastAddress = address;
      }
      existing.packetsSeenCount++;
      existing.lastSeenTimestamp = now;
      existing.isOnline = true;
      existing.isDirectPeer = isPeerConnected;
    } else {
      knownContacts[nodeId] = ContactProfile(
        nodeId: nodeId,
        dhPubHex: dhPubHex,
        signPubHex: signPubHex,
        nickname: cleanNick.isNotEmpty ? cleanNick : 'Узел $nodeId',
        hwFingerprint: cleanHw,
        platformInfo: cleanOs,
        isOnline: true,
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
                    _sendTcpLine(socket, _buildChatHistorySyncForPeer(peerId));

                    _evictExpired();
                    for (final ack in deliveredAcks.values) {
                      _sendTcpLine(socket, jsonEncode(ack.toJson()));
                    }
                    final toFlush = <String, MeshPacket>{
                      ...myPersistentOutbox,
                      ...transitBuffer,
                    };
                    for (final entry in toFlush.entries) {
                      if (deliveredAcks.containsKey(entry.key)) continue;
                      _sendTcpLine(socket, jsonEncode(entry.value.toJson()));
                      await Future.delayed(const Duration(milliseconds: 10));
                    }
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
        if (fromNode.isNotEmpty && knownContacts.containsKey(fromNode)) {
          knownContacts[fromNode]!.lastSeenTimestamp =
              DateTime.now().millisecondsSinceEpoch;
          knownContacts[fromNode]!.isOnline = true;
        }
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
        final peerOs = (map['os'] as String?) ?? '';
        if (peerId == nodeId || deletedContactIds.contains(peerId)) {
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
          platformInfo: peerOs,
          address: remoteAddr,
        );
        await onHello(peerId, peerNick);
        _refreshOnlineStatuses();
        unawaited(_saveContactsAndChats());
        onStateChanged();
        return;
      }

      // ИСПРАВЛЕНИЕ ПУНКТА 3: Прием синхронизации истории чата от собеседника (восстановление истории на телефоне после переустановки)
      if (map.containsKey('chat_sync_peer')) {
        final fromPeerId = (map['chat_sync_peer'] as String?) ?? '';
        if (fromPeerId.isEmpty ||
            fromPeerId == nodeId ||
            deletedContactIds.contains(fromPeerId)) {
          return;
        }
        bool changed = false;
        if (map['deleted_ids'] is List) {
          final list = getMessagesFor(fromPeerId);
          final beforeLen = list.length;
          for (final d in (map['deleted_ids'] as List)) {
            final delId = d.toString();
            deletedMessageIds.add(delId);
            list.removeWhere((m) => m.msgId == delId);
          }
          if (list.length != beforeLen) changed = true;
        }
        if (map['msgs'] is List) {
          final currentList = getMessagesFor(fromPeerId);
          final existingById = {for (final m in currentList) m.msgId: m};
          for (final item in (map['msgs'] as List)) {
            try {
              final m = Map<String, dynamic>.from(item as Map);
              final mid = (m['id'] ?? '').toString();
              if (mid.isEmpty || deletedMessageIds.contains(mid)) {
                continue;
              }
              if (existingById.containsKey(mid)) {
                final existing = existingById[mid]!;
                final remoteEdited = (m['edt'] as bool?) ?? false;
                final remoteTxt = (m['txt'] ?? '').toString();
                if (remoteEdited && remoteTxt != existing.text) {
                  existing.text = remoteTxt;
                  existing.isEdited = true;
                  changed = true;
                }
                continue;
              }
              final sender = (m['s'] ?? '').toString();
              final isMeHere = (sender == nodeId);
              final fn = m['fn'] as String?;
              final restoredMsg = ChatMessage(
                msgId: mid,
                peerId: fromPeerId,
                senderId: sender,
                senderName: (m['sn'] ?? 'Узел').toString(),
                text: (m['txt'] ?? '').toString(),
                timestamp: (m['ts'] as num?)?.toInt() ?? 0,
                isMe: isMeHere,
                isDelivered: true,
                fileName: fn,
                fileSize: (m['fs'] as num?)?.toInt(),
                thumbB64: m['tb64'] as String?,
                filePath: isMeHere ? offeredFileCatalog[mid] : null,
                isMediaRevealed: isMeHere,
                isEdited: (m['edt'] as bool?) ?? false,
                forwardedFrom: m['fwd'] as String?,
                transferProgress: (fn != null && !isMeHere) ? 0.0 : 1.0,
              );
              currentList.add(restoredMsg);
              existingById[mid] = restoredMsg;
              changed = true;
            } catch (_) {}
          }
          currentList.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
        if (changed) {
          await _saveContactsAndChats();
          onStateChanged();
        }
        return;
      }

      // ИСПРАВЛЕНИЕ ПУНКТОВ 5 и 8: Синхронизация контактов, банов, триггеров и апелляций между сетями (Store-and-Forward)
      if (map.containsKey('peer_sync')) {
        final list = map['peer_sync'] as List;
        bool changedAny = false;
        for (final item in list) {
          final m = Map<String, dynamic>.from(item as Map);
          final pid = m['id'] as String;
          final pdh = (m['dh'] as String?) ?? '';
          final psg = (m['sg'] as String?) ?? '';
          final phw = (m['hw'] as String?) ?? '';
          final pos = (m['os'] as String?) ?? '';
          if (pid != nodeId &&
              !deletedContactIds.contains(pid) &&
              !knownContacts.containsKey(pid)) {
            final expectedId = await _calcNodeId(_fromHex(pdh));
            if (expectedId == pid) {
              _upsertContact(
                nodeId: pid,
                dhPubHex: pdh,
                signPubHex: psg,
                nick: (m['nick'] as String?) ?? 'Узел $pid',
                hwFingerprint: phw,
                platformInfo: pos,
                address: 'Через Mesh',
              );
              changedAny = true;
            }
          }
        }
        if (map['cleared_triggers'] is List) {
          for (final cid in (map['cleared_triggers'] as List)) {
            final s = cid.toString();
            clearedTriggerHitIds.add(s);
            triggerHits.removeWhere((h) => h.hitId == s);
          }
        }
        if (map['trigger_sync'] is List) {
          for (final item in (map['trigger_sync'] as List)) {
            try {
              final hit = TriggerHitRecord.fromJson(
                  Map<String, dynamic>.from(item as Map));
              if (clearedTriggerHitIds.contains(hit.hitId)) continue;
              final existingIdx =
                  triggerHits.indexWhere((h) => h.hitId == hit.hitId);
              if (existingIdx < 0) {
                triggerHits.add(hit);
                changedAny = true;
              } else if (hit.afterLines.length >
                  triggerHits[existingIdx].afterLines.length) {
                triggerHits[existingIdx] = hit;
                changedAny = true;
              }
            } catch (_) {}
          }
          triggerHits.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        }
        if (map['appeal_sync'] is List) {
          for (final item in (map['appeal_sync'] as List)) {
            try {
              final ap = BanAppealRecord.fromJson(
                  Map<String, dynamic>.from(item as Map));
              if (!bannedNodeIds.contains(ap.nodeId)) continue;
              final existingIdx =
                  banAppeals.indexWhere((a) => a.nodeId == ap.nodeId);
              if (existingIdx < 0) {
                banAppeals.add(ap);
                changedAny = true;
              }
            } catch (_) {}
          }
        }
        if (changedAny) {
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

  List<int> _packSealedEnvelope(String senderNick, String plainText, int ts,
      {String? forwardedFrom}) {
    final padLen = 16 + Random.secure().nextInt(48);
    final randomPad = base64Encode(_randomBytes(padLen));
    final map = <String, dynamic>{
      'v': 2,
      'kind': 'TEXT',
      'nick': senderNick,
      'txt': plainText,
      'ts': ts,
      'pad': randomPad,
    };
    if (forwardedFrom != null && forwardedFrom.isNotEmpty) {
      map['fwd'] = forwardedFrom;
    }
    return utf8.encode(jsonEncode(map));
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

  Future<bool> sendMessage(
    String targetNodeId,
    String plainText, {
    String? forwardedFrom,
  }) async {
    if (isSelfBanned) {
      _addLog('🚫 Отправка невозможна: ваш узел заблокирован администратором');
      onStateChanged();
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = _randomHex(16);

    if (targetNodeId == broadcastChannelId) {
      final expiresAt = now + 3600 * 1000;
      final bcastMap = <String, dynamic>{
        'txt': plainText,
      };
      if (forwardedFrom != null && forwardedFrom.isNotEmpty) {
        bcastMap['fwd'] = forwardedFrom;
      }
      final b64Payload = base64Encode(utf8.encode(jsonEncode(bcastMap)));
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
        ephPubHex: 'BCAST_V2',
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
        forwardedFrom: forwardedFrom,
      );
      getMessagesFor(broadcastChannelId).add(myMsg);
      _inspectMessageForTriggers(myMsg, broadcastChannelId);
      _floodAllTransports(pkt);
      unawaited(_saveContactsAndChats());
      onStateChanged();
      return true;
    }

    if (isNodeBanned(targetNodeId)) {
      _addLog('Узел получателя заблокирован в сети');
      return false;
    }
    deletedContactIds.remove(targetNodeId);
    final contact = knownContacts[targetNodeId];
    if (contact == null) return false;

    final myMsg = ChatMessage(
      msgId: msgId,
      peerId: targetNodeId,
      senderId: nodeId,
      senderName: nickname,
      text: plainText,
      timestamp: now,
      isMe: true,
      isDelivered: false,
      forwardedFrom: forwardedFrom,
    );
    getMessagesFor(targetNodeId).add(myMsg);
    _inspectMessageForTriggers(myMsg, targetNodeId);

    final sealedPayload = _packSealedEnvelope(
      nickname,
      plainText,
      now,
      forwardedFrom: forwardedFrom,
    );
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: targetNodeId,
      contact: contact,
      msgId: msgId,
      sealedPayloadBytes: sealedPayload,
      persistInOutbox: true,
    );

    unawaited(_saveContactsAndChats());
    onStateChanged();
    return true;
  }

  Future<void> _handleDataPacket(
    MeshPacket pkt, {
    required void Function(String) replyDirect,
    Socket? excludeTcpSocket,
    String? excludeBleId,
  }) async {
    _evictExpired();
    final now = DateTime.now().millisecondsSinceEpoch;

    if (pkt.expiresAt <= now || pkt.expiresAt > now + 8 * 24 * 3600 * 1000) {
      return;
    }

    if (deliveredAcks.containsKey(pkt.msgId)) {
      replyDirect(jsonEncode(deliveredAcks[pkt.msgId]!.toJson()));
      return;
    }

    if (!_markPacketSeen(pkt.msgId)) return;

    // 1. ПРОВЕРКА ПОДПИСАННОЙ КОМАНДЫ АДМИНИСТРАТОРА (ADMIN_CMD)
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
        if (target == nodeId || (hw.isNotEmpty && hw == myHwFingerprint)) {
          _addLog(
              '🚫 Ваш узел заблокирован администратором. Вы можете отправить записку на разбан.');
        } else {
          _addLog('🛡️ Узел $target заблокирован администратором сети');
        }
      } else if (act == 'UNBAN' && target.isNotEmpty) {
        bannedNodeIds.remove(target);
        if (hw.isNotEmpty) bannedHwFingerprints.remove(hw);
        banAppeals.removeWhere((a) => a.nodeId == target);
        if (target == nodeId || (hw.isNotEmpty && hw == myHwFingerprint)) {
          _addLog('✅ Блокировка вашего узла снята администратором!');
        } else {
          _addLog('🛡️ Блокировка узла $target снята администратором');
        }
      } else if (act == 'SYNC_TRIGGERS' && cmdMap['words'] is List) {
        final words = (cmdMap['words'] as List)
            .map((e) => e.toString().trim().toLowerCase())
            .where((w) => w.isNotEmpty)
            .toList();
        adminTriggerWords
          ..clear()
          ..addAll(words);
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

    // 2. ОБРАБОТКА ЗАПИСКИ-АПЕЛЛЯЦИИ ОТ ЗАБАНЕННОГО ПОЛЬЗОВАТЕЛЯ (BAN_APPEAL)
    if (pkt.type == 'BROADCAST' && pkt.ephPubHex == 'BAN_APPEAL') {
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

      final appealMap =
          jsonDecode(utf8.decode(base64Decode(pkt.ciphertextHex)))
              as Map<String, dynamic>;
      final appeal = BanAppealRecord.fromJson(appealMap);
      if (appeal.nodeId == senderId) {
        banAppeals.removeWhere((a) => a.nodeId == senderId);
        banAppeals.insert(0, appeal);
        unawaited(_saveContactsAndChats());
        if (isAdminUnlocked) {
          _addLog(
              '📨 Новая апелляция на разбан от ${appeal.nickname} ($senderId)');
        }
      }
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

    // 3. ОБРАБОТКА ОТЧЕТА О СРАБОТАВШЕМ ТРИГГЕРЕ (-5 : +5 + ДОСЬЕ)
    if (pkt.type == 'BROADCAST' && pkt.ephPubHex == 'TRIGGER_REPORT') {
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

      final hitMap = jsonDecode(utf8.decode(base64Decode(pkt.ciphertextHex)))
          as Map<String, dynamic>;
      final hit = TriggerHitRecord.fromJson(hitMap);
      if (!clearedTriggerHitIds.contains(hit.hitId)) {
        triggerHits.removeWhere((h) => h.hitId == hit.hitId);
        triggerHits.insert(0, hit);
        if (triggerHits.length > 100) triggerHits.removeLast();
        unawaited(_saveContactsAndChats());
      }

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

      if (pkt.ephPubHex == 'MSG_EDIT') {
        final editMap =
            jsonDecode(utf8.decode(base64Decode(pkt.ciphertextHex)))
                as Map<String, dynamic>;
        final targetId = (editMap['edit_msg'] ?? '').toString();
        final newTxt = (editMap['txt'] ?? '').toString();
        for (final m in getMessagesFor(broadcastChannelId)) {
          if (m.msgId == targetId && m.senderId == senderId) {
            m.text = newTxt;
            m.isEdited = true;
            _inspectMessageForTriggers(m, broadcastChannelId);
            break;
          }
        }
        unawaited(_saveContactsAndChats());
        onStateChanged();
        return;
      }

      if (pkt.ephPubHex == 'MSG_DELETE') {
        final delMap = jsonDecode(utf8.decode(base64Decode(pkt.ciphertextHex)))
            as Map<String, dynamic>;
        final targetId = (delMap['del_msg'] ?? '').toString();
        deletedMessageIds.add(targetId);
        getMessagesFor(broadcastChannelId)
            .removeWhere((m) => m.msgId == targetId && m.senderId == senderId);
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
      String decodedText = utf8.decode(base64Decode(pkt.ciphertextHex));
      String? fwdFrom;
      if (pkt.ephPubHex == 'BCAST_V2') {
        try {
          final m = jsonDecode(decodedText) as Map<String, dynamic>;
          decodedText = (m['txt'] ?? '').toString();
          fwdFrom = m['fwd'] as String?;
        } catch (_) {}
      }

      final chatMsg = ChatMessage(
        msgId: pkt.msgId,
        peerId: broadcastChannelId,
        senderId: senderId,
        senderName: senderName,
        text: decodedText,
        timestamp: now,
        isMe: false,
        isDelivered: true,
        forwardedFrom: fwdFrom,
      );
      getMessagesFor(broadcastChannelId).add(chatMsg);
      _inspectMessageForTriggers(chatMsg, broadcastChannelId);
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
      if (kind == 'FILE_OFFER') {
        final fid = (envelope['fid'] ?? pkt.msgId).toString();
        final fn = _sanitizeFileName((envelope['fn'] ?? 'file.bin').toString());
        final fs = (envelope['fs'] as num?)?.toInt() ?? 0;
        final tb64 = envelope['tb64'] as String?;
        final fwd = envelope['fwd'] as String?;

        final msgs = getMessagesFor(senderId);
        if (!msgs.any((m) => m.msgId == fid) &&
            !deletedMessageIds.contains(fid)) {
          final offerMsg = ChatMessage(
            msgId: fid,
            peerId: senderId,
            senderId: senderId,
            senderName: contact.displayTitle,
            text: '📎 $fn',
            timestamp: now,
            isMe: false,
            isDelivered: true,
            filePath: null,
            fileName: fn,
            fileSize: fs,
            thumbB64: tb64,
            isMediaRevealed: false,
            isDownloading: false,
            forwardedFrom: fwd,
            transferProgress: 0.0,
          );
          msgs.add(offerMsg);
          if (activeOpenChatId != senderId) {
            contact.unreadCount++;
          }
          onMessageReceived(offerMsg);
          unawaited(_triggerIncomingNotification(
              senderId, contact.displayTitle, '📎 Медиа/файл: $fn'));
          unawaited(_saveContactsAndChats());
        }
      } else if (kind == 'FILE_PULL_REQ') {
        final fid = (envelope['fid'] ?? '').toString();
        if (fid.isNotEmpty) {
          unawaited(_streamFileChunksToPeer(senderId, fid));
        }
      } else if (kind == 'CALL_INVITE') {
        final mode = (envelope['mode'] ?? 'voice').toString();
        incomingCallFromPeerId = senderId;
        incomingCallMode = mode;
        unawaited(_triggerIncomingNotification(
          senderId,
          contact.displayTitle,
          mode == 'video' ? '📹 Входящий видеочат (ВЧ)' : '📞 Входящий голосовой чат (ГЧ)',
        ));
      } else if (kind == 'CALL_ACCEPT') {
        if (activeCallPeerId == senderId) {
          isCallAccepted = true;
          callStatusText = activeCallMode == 'video'
              ? 'ВЧ активен (Видео + Голос)'
              : 'ГЧ активен (Голос)';
        }
      } else if (kind == 'CALL_REJECT') {
        if (activeCallPeerId == senderId) {
          activeCallPeerId = null;
          isCallAccepted = false;
          remoteVideoFrameBytes = null;
          callStatusText = 'Вызов отклонён';
        }
      } else if (kind == 'CALL_END') {
        if (activeCallPeerId == senderId || incomingCallFromPeerId == senderId) {
          activeCallPeerId = null;
          incomingCallFromPeerId = null;
          isCallAccepted = false;
          remoteVideoFrameBytes = null;
          callStatusText = '';
          unawaited(stopAudioPlayback());
        }
      } else if (kind == 'CALL_AUDIO_CHUNK') {
        if (activeCallPeerId == senderId && isCallAccepted) {
          final b64 = (envelope['b64'] ?? '').toString();
          if (b64.isNotEmpty) {
            try {
              final nowMs = DateTime.now().millisecondsSinceEpoch;
              if (nowMs - _lastCallAudioPlayMs > 450) {
                _lastCallAudioPlayMs = nowMs;
                final bytes = base64Decode(b64);
                final ext = Platform.isWindows ? 'wav' : 'm4a';
                final f = File(
                    '${Directory.systemTemp.path}${Platform.pathSeparator}mayak_call_rx.$ext');
                await f.writeAsBytes(bytes, flush: true);
                await togglePlayAudioFile(f.path);
              }
            } catch (_) {}
          }
        }
      } else if (kind == 'CALL_VIDEO_FRAME') {
        if (activeCallPeerId == senderId && isCallAccepted) {
          final b64 = (envelope['b64'] ?? '').toString();
          if (b64.isNotEmpty) {
            try {
              remoteVideoFrameBytes = base64Decode(b64);
            } catch (_) {}
          }
        }
      } else if (kind == 'FILE_MISSING') {
        final fid = (envelope['fid'] ?? '').toString();
        for (final list in chatHistory.values) {
          for (final msg in list) {
            if (msg.msgId == fid) {
              msg.isDownloading = false;
              msg.transferProgress = 0.0;
              break;
            }
          }
        }
        _addLog('Файл $fid больше не доступен на устройстве отправителя.');
      } else if (kind == 'GROUP_INVITE') {
        final gid = (envelope['gid'] ?? '').toString();
        final gtitle = (envelope['title'] ?? 'Mesh-комната').toString();
        final gcreator = (envelope['creator'] ?? senderId).toString();
        final gmembers = (envelope['members'] is List)
            ? (envelope['members'] as List).map((e) => e.toString()).toList()
            : <String>[nodeId, senderId];
        if (gid.isNotEmpty) {
          groupChats[gid] = GroupChat(
            groupId: gid,
            title: gtitle,
            creatorId: gcreator,
            memberIds: gmembers,
            createdAt: (envelope['ts'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          );
          await _saveContactsAndChats();
        }
      } else if (kind == 'GROUP_MSG') {
        final gid = (envelope['gid'] ?? '').toString();
        final gtitle = (envelope['title'] ?? 'Mesh-комната').toString();
        final mid = (envelope['mid'] ?? pkt.msgId).toString();
        final gmembers = (envelope['members'] is List)
            ? (envelope['members'] as List).map((e) => e.toString()).toList()
            : <String>[nodeId, senderId];
        if (gid.isNotEmpty && !deletedMessageIds.contains(mid)) {
          groupChats.putIfAbsent(
            gid,
            () => GroupChat(
              groupId: gid,
              title: gtitle,
              creatorId: senderId,
              memberIds: gmembers,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          final gList = getGroupMessages(gid);
          if (!gList.any((m) => m.msgId == mid)) {
            final txt = (envelope['txt'] ?? '').toString();
            final sn = (envelope['sn'] ?? contact.displayTitle).toString();
            final gMsg = ChatMessage(
              msgId: mid,
              peerId: groupChatKey(gid),
              senderId: senderId,
              senderName: sn,
              text: txt,
              timestamp: (envelope['ts'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
              isMe: false,
              isDelivered: true,
            );
            gList.add(gMsg);
            unreadGroupCounts[gid] = (unreadGroupCounts[gid] ?? 0) + 1;
            _inspectMessageForTriggers(gMsg, groupChatKey(gid));
            unawaited(_triggerIncomingNotification(
                groupChatKey(gid), '$gtitle • $sn', txt));
            await _saveContactsAndChats();
          }
        }
      } else if (kind == 'FILE_CHUNK') {
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
      } else if (kind == 'MSG_EDIT') {
        final targetId = (envelope['targetId'] ?? '').toString();
        final newTxt = (envelope['txt'] ?? '').toString();
        for (final m in getMessagesFor(senderId)) {
          if (m.msgId == targetId && m.senderId == senderId) {
            m.text = newTxt;
            m.isEdited = true;
            _inspectMessageForTriggers(m, senderId);
            break;
          }
        }
        unawaited(_saveContactsAndChats());
      } else if (kind == 'MSG_DELETE') {
        final targetId = (envelope['targetId'] ?? '').toString();
        deletedMessageIds.add(targetId);
        getMessagesFor(senderId).removeWhere((m) => m.msgId == targetId);
        unawaited(_saveContactsAndChats());
      } else {
        final decodedText = (envelope['txt'] as String?) ?? '';
        final fwd = envelope['fwd'] as String?;
        if (!deletedMessageIds.contains(pkt.msgId)) {
          final chatMsg = ChatMessage(
            msgId: pkt.msgId,
            peerId: senderId,
            senderId: senderId,
            senderName: contact.displayTitle,
            text: decodedText,
            timestamp: now,
            isMe: false,
            isDelivered: true,
            forwardedFrom: fwd,
          );
          getMessagesFor(senderId).add(chatMsg);
          _inspectMessageForTriggers(chatMsg, senderId);
          if (activeOpenChatId != senderId) {
            contact.unreadCount++;
          }
          onMessageReceived(chatMsg);
          unawaited(_triggerIncomingNotification(
              senderId, contact.displayTitle, decodedText));
          unawaited(_saveContactsAndChats());
        }
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

    final dir = await _getInternalCacheFilesDir();
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
        text: '📎 $fileName',
        timestamp: now,
        isMe: false,
        isDelivered: false,
        fileName: fileName,
        fileSize: totalSize,
        isMediaRevealed: false,
        isDownloading: true,
        transferProgress: assembly.receivedChunkIndices.length / tot,
      );
      msgs.add(existingMsg);
    } else {
      existingMsg.isDownloading = true;
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
      offeredFileCatalog[fileId] = savedFile.path;

      existingMsg.fileName = finalFileName;
      existingMsg.filePath = savedFile.path;
      existingMsg.text = '📎 $finalFileName';
      existingMsg.isDelivered = true;
      existingMsg.isDownloading = false;
      existingMsg.isMediaRevealed = true;
      existingMsg.transferProgress = 1.0;

      if (existingMsg.thumbB64 == null || existingMsg.thumbB64!.isEmpty) {
        if (existingMsg.isVideoFile || existingMsg.isImageFile) {
          existingMsg.thumbB64 = await extractPreviewBase64InMemory(
              savedFile.path,
              isVideo: existingMsg.isVideoFile);
        }
      }

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
              final peerDh = (data['dh'] as String?) ?? '';
              final peerSign = (data['sg'] as String?) ?? '';
              final peerNick = (data['nick'] as String?) ?? '';
              final peerHw = (data['hw'] as String?) ?? '';
              final peerOs = (data['os'] as String?) ?? '';
              if (peerId != nodeId &&
                  !deletedContactIds.contains(peerId) &&
                  peerDh.length == 64) {
                _upsertContact(
                  nodeId: peerId,
                  dhPubHex: peerDh,
                  signPubHex: peerSign,
                  nick: peerNick,
                  hwFingerprint: peerHw,
                  platformInfo: peerOs,
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
        _refreshOnlineStatuses();
        _flushBufferedPacketsToOnlinePeers();
        final beacon = utf8.encode(jsonEncode({
          'id': nodeId,
          'nick': nickname,
          'p': listenPort,
          'dh': dhPubHex,
          'sg': signPubHex,
          'hw': myHwFingerprint,
          'os': myPlatformInfo,
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
          if (!isPeerDirectlyConnected(c.nodeId) &&
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
              _blePeers[endpointId] = peerId;
              _refreshOnlineStatuses();
              _addLog('Подключен по BLE: $peerNick ($peerId)');
              await _sendBleLine(endpointId, _buildPeerSyncJson());
              await _sendBleLine(
                  endpointId, _buildChatHistorySyncForPeer(peerId));
              _evictExpired();
              for (final ack in deliveredAcks.values) {
                await _sendBleLine(endpointId, jsonEncode(ack.toJson()));
              }
              for (final entry in transitBuffer.entries.toList()) {
                await _sendBleLine(
                    endpointId, jsonEncode(entry.value.toJson()));
              }
            },
            replyDirect: (replyJson) =>
                unawaited(_sendBleLine(endpointId, replyJson)),
            excludeBleId: endpointId,
          ));
    }
  }

  void _refreshOnlineStatuses() {
    final activeIds = {..._tcpPeers.values, ..._blePeers.values};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final c in knownContacts.values) {
      final recentlySeen =
          c.lastSeenTimestamp > 0 && (now - c.lastSeenTimestamp) < 14000;
      c.isDirectPeer = activeIds.contains(c.nodeId);
      c.isOnline = c.isDirectPeer || recentlySeen;
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

  int get connectedPeersCount {
    _refreshOnlineStatuses();
    return knownContacts.values.where((c) => c.isOnline).length;
  }

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
