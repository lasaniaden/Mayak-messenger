import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cryptography/cryptography.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart' as zx;
import 'mayak_dht.dart';
import 'mayak_media_rtc.dart';
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

final class _WaveFormatEx extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

final class _WaveHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<Void> lpNext;
  @IntPtr()
  external int reserved;
}

typedef _WaveOutOpenNative = Uint32 Function(
    Pointer<IntPtr>, Uint32, Pointer<_WaveFormatEx>, IntPtr, IntPtr, Uint32);
typedef _WaveOutOpenDart = int Function(
    Pointer<IntPtr>, int, Pointer<_WaveFormatEx>, int, int, int);
typedef _WaveHdrOpNative = Uint32 Function(IntPtr, Pointer<_WaveHdr>, Uint32);
typedef _WaveHdrOpDart = int Function(int, Pointer<_WaveHdr>, int);
typedef _WaveSimpleNative = Uint32 Function(IntPtr);
typedef _WaveSimpleDart = int Function(int);
typedef _WaveGetNumDevsNative = Uint32 Function();
typedef _WaveGetNumDevsDart = int Function();
typedef _WaveGetDevCapsNative = Uint32 Function(IntPtr, Pointer<Uint8>, Uint32);
typedef _WaveGetDevCapsDart = int Function(int, Pointer<Uint8>, int);

class WindowsPcmAudioBridge {
  static const int _waveMapper = 0xFFFFFFFF;
  static const int _whdrDone = 0x00000001;
  static const int _whdrPrepared = 0x00000002;
  static const int _sampleRate = 16000;
  static const int _inChunkBytes = 1280; // 40ms @ 16kHz 16-bit mono
  static const int _inBufCount = 6;
  static const int _outBufCount = 16;
  static const int _outBufCap = 32768;

  static bool _loaded = false;
  static _CoTaskMemAllocDart? _alloc;
  static _CoTaskMemFreeDart? _free;
  static _WaveOutOpenDart? _waveOutOpen;
  static _WaveHdrOpDart? _waveOutPrepare;
  static _WaveHdrOpDart? _waveOutWrite;
  static _WaveHdrOpDart? _waveOutUnprepare;
  static _WaveSimpleDart? _waveOutReset;
  static _WaveSimpleDart? _waveOutClose;

  static _WaveOutOpenDart? _waveInOpen;
  static _WaveHdrOpDart? _waveInPrepare;
  static _WaveHdrOpDart? _waveInAddBuffer;
  static _WaveHdrOpDart? _waveInUnprepare;
  static _WaveSimpleDart? _waveInStart;
  static _WaveSimpleDart? _waveInReset;
  static _WaveSimpleDart? _waveInClose;

  static int _hWaveOut = 0;
  static int _hWaveIn = 0;
  static final List<Pointer<_WaveHdr>> _outHdrs = [];
  static final List<Pointer<Uint8>> _outBufs = [];
  static final List<Pointer<_WaveHdr>> _inHdrs = [];
  static final List<Pointer<Uint8>> _inBufs = [];
  static Timer? _inPollTimer;
  static Timer? _toneTimer;
  static bool _micMuted = false;
  static void Function(Uint8List pcm)? _onCaptured;
  static int selectedOutDeviceId = -1;
  static int selectedInDeviceId = -1;
  static int _lastOutPlayMs = 0;
  static _WaveGetNumDevsDart? _waveOutGetNumDevs;
  static _WaveGetDevCapsDart? _waveOutGetDevCaps;
  static _WaveGetNumDevsDart? _waveInGetNumDevs;
  static _WaveGetDevCapsDart? _waveInGetDevCaps;

  static void _ensureLoaded() {
    if (_loaded || !Platform.isWindows) return;
    _loaded = true;
    try {
      final winmm = DynamicLibrary.open('winmm.dll');
      final ole32 = DynamicLibrary.open('ole32.dll');
      _alloc = ole32.lookupFunction<_CoTaskMemAllocNative, _CoTaskMemAllocDart>(
          'CoTaskMemAlloc');
      _free = ole32.lookupFunction<_CoTaskMemFreeNative, _CoTaskMemFreeDart>(
          'CoTaskMemFree');

      _waveOutOpen = winmm
          .lookupFunction<_WaveOutOpenNative, _WaveOutOpenDart>('waveOutOpen');
      _waveOutPrepare =
          winmm.lookupFunction<_WaveHdrOpNative, _WaveHdrOpDart>(
              'waveOutPrepareHeader');
      _waveOutWrite = winmm
          .lookupFunction<_WaveHdrOpNative, _WaveHdrOpDart>('waveOutWrite');
      _waveOutUnprepare =
          winmm.lookupFunction<_WaveHdrOpNative, _WaveHdrOpDart>(
              'waveOutUnprepareHeader');
      _waveOutReset = winmm
          .lookupFunction<_WaveSimpleNative, _WaveSimpleDart>('waveOutReset');
      _waveOutClose = winmm
          .lookupFunction<_WaveSimpleNative, _WaveSimpleDart>('waveOutClose');

      _waveInOpen = winmm
          .lookupFunction<_WaveOutOpenNative, _WaveOutOpenDart>('waveInOpen');
      _waveInPrepare = winmm.lookupFunction<_WaveHdrOpNative, _WaveHdrOpDart>(
          'waveInPrepareHeader');
      _waveInAddBuffer = winmm.lookupFunction<_WaveHdrOpNative, _WaveHdrOpDart>(
          'waveInAddBuffer');
      _waveInUnprepare = winmm.lookupFunction<_WaveHdrOpNative, _WaveHdrOpDart>(
          'waveInUnprepareHeader');
      _waveInStart = winmm
          .lookupFunction<_WaveSimpleNative, _WaveSimpleDart>('waveInStart');
      _waveInReset = winmm
          .lookupFunction<_WaveSimpleNative, _WaveSimpleDart>('waveInReset');
      _waveInClose = winmm
          .lookupFunction<_WaveSimpleNative, _WaveSimpleDart>('waveInClose');
      _waveOutGetNumDevs = winmm
          .lookupFunction<_WaveGetNumDevsNative, _WaveGetNumDevsDart>('waveOutGetNumDevs');
      _waveOutGetDevCaps = winmm
          .lookupFunction<_WaveGetDevCapsNative, _WaveGetDevCapsDart>('waveOutGetDevCapsW');
      _waveInGetNumDevs = winmm
          .lookupFunction<_WaveGetNumDevsNative, _WaveGetNumDevsDart>('waveInGetNumDevs');
      _waveInGetDevCaps = winmm
          .lookupFunction<_WaveGetDevCapsNative, _WaveGetDevCapsDart>('waveInGetDevCapsW');
    } catch (_) {}
  }

  static Pointer<_WaveFormatEx> _allocFormat() {
    final fmt = _alloc!(sizeOf<_WaveFormatEx>()).cast<_WaveFormatEx>();
    fmt.ref.wFormatTag = 1; // PCM
    fmt.ref.nChannels = 1;
    fmt.ref.nSamplesPerSec = _sampleRate;
    fmt.ref.wBitsPerSample = 16;
    fmt.ref.nBlockAlign = 2;
    fmt.ref.nAvgBytesPerSec = _sampleRate * 2;
    fmt.ref.cbSize = 0;
    return fmt;
  }

  static bool ensureOutputOpen() {
    if (!Platform.isWindows) return false;
    _ensureLoaded();
    if (_hWaveOut != 0) return true;
    if (_waveOutOpen == null || _alloc == null || _free == null) return false;
    final hPtr = _alloc!(sizeOf<IntPtr>()).cast<IntPtr>();
    final fmt = _allocFormat();
    try {
      hPtr.value = 0;
      final devId = selectedOutDeviceId >= 0 ? selectedOutDeviceId : _waveMapper;
      final res = _waveOutOpen!(hPtr, devId, fmt, 0, 0, 0);
      if (res != 0) return false;
      _hWaveOut = hPtr.value;
      _outHdrs.clear();
      _outBufs.clear();
      for (int i = 0; i < _outBufCount; i++) {
        final hdr = _alloc!(sizeOf<_WaveHdr>()).cast<_WaveHdr>();
        final buf = _alloc!(_outBufCap).cast<Uint8>();
        hdr.ref.lpData = buf;
        hdr.ref.dwBufferLength = 0;
        hdr.ref.dwBytesRecorded = 0;
        hdr.ref.dwUser = 0;
        hdr.ref.dwFlags = 0;
        hdr.ref.dwLoops = 0;
        hdr.ref.lpNext = nullptr;
        hdr.ref.reserved = 0;
        _outHdrs.add(hdr);
        _outBufs.add(buf);
      }
      return true;
    } finally {
      _free!(hPtr.cast());
      _free!(fmt.cast());
    }
  }

  static void playPcm(Uint8List pcm) {
    if (!Platform.isWindows || pcm.isEmpty) return;
    if (!ensureOutputOpen()) return;
    final len = pcm.length > _outBufCap ? _outBufCap : pcm.length;
    Pointer<_WaveHdr>? freeHdr;
    Pointer<Uint8>? freeBuf;
    for (int i = 0; i < _outHdrs.length; i++) {
      final hdr = _outHdrs[i];
      final flags = hdr.ref.dwFlags;
      if ((flags & _whdrPrepared) == 0 || (flags & _whdrDone) != 0) {
        if ((flags & _whdrPrepared) != 0) {
          _waveOutUnprepare!(_hWaveOut, hdr, sizeOf<_WaveHdr>());
        }
        freeHdr = hdr;
        freeBuf = _outBufs[i];
        break;
      }
    }
    if (freeHdr == null || freeBuf == null) return;
    freeBuf.asTypedList(len).setRange(0, len, pcm);
    freeHdr.ref.lpData = freeBuf;
    freeHdr.ref.dwBufferLength = len;
    freeHdr.ref.dwFlags = 0;
    freeHdr.ref.dwLoops = 0;
    _lastOutPlayMs = DateTime.now().millisecondsSinceEpoch;
    if (_waveOutPrepare!(_hWaveOut, freeHdr, sizeOf<_WaveHdr>()) == 0) {
      _waveOutWrite!(_hWaveOut, freeHdr, sizeOf<_WaveHdr>());
    }
  }

  static void setMicMuted(bool muted) {
    _micMuted = muted;
  }

  static bool isRecentlyPlaying(int windowMs) {
    if (_lastOutPlayMs <= 0) return false;
    return (DateTime.now().millisecondsSinceEpoch - _lastOutPlayMs) < windowMs;
  }

  static bool startFullDuplex(void Function(Uint8List pcm) onCaptured) {
    if (!Platform.isWindows) return false;
    stopFullDuplex();
    _ensureLoaded();
    ensureOutputOpen();
    if (_waveInOpen == null || _alloc == null || _free == null) return false;
    _onCaptured = onCaptured;
    _micMuted = false;
    final hPtr = _alloc!(sizeOf<IntPtr>()).cast<IntPtr>();
    final fmt = _allocFormat();
    try {
      hPtr.value = 0;
      final devId = selectedInDeviceId >= 0 ? selectedInDeviceId : _waveMapper;
      final res = _waveInOpen!(hPtr, devId, fmt, 0, 0, 0);
      if (res != 0) return _hWaveOut != 0;
      _hWaveIn = hPtr.value;
      _inHdrs.clear();
      _inBufs.clear();
      for (int i = 0; i < _inBufCount; i++) {
        final hdr = _alloc!(sizeOf<_WaveHdr>()).cast<_WaveHdr>();
        final buf = _alloc!(_inChunkBytes).cast<Uint8>();
        hdr.ref.lpData = buf;
        hdr.ref.dwBufferLength = _inChunkBytes;
        hdr.ref.dwBytesRecorded = 0;
        hdr.ref.dwUser = 0;
        hdr.ref.dwFlags = 0;
        hdr.ref.dwLoops = 0;
        hdr.ref.lpNext = nullptr;
        hdr.ref.reserved = 0;
        _waveInPrepare!(_hWaveIn, hdr, sizeOf<_WaveHdr>());
        _waveInAddBuffer!(_hWaveIn, hdr, sizeOf<_WaveHdr>());
        _inHdrs.add(hdr);
        _inBufs.add(buf);
      }
      _waveInStart!(_hWaveIn);
      _inPollTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        if (_hWaveIn == 0) return;
        for (int i = 0; i < _inHdrs.length; i++) {
          final hdr = _inHdrs[i];
          if ((hdr.ref.dwFlags & _whdrDone) != 0) {
            final recLen = hdr.ref.dwBytesRecorded;
            if (recLen > 0 && recLen <= _inChunkBytes && !_micMuted && _onCaptured != null) {
              final copy = Uint8List.fromList(
                  _inBufs[i].asTypedList(recLen));
              _onCaptured!(copy);
            }
            _waveInUnprepare!(_hWaveIn, hdr, sizeOf<_WaveHdr>());
            hdr.ref.dwFlags = 0;
            hdr.ref.dwBytesRecorded = 0;
            hdr.ref.dwBufferLength = _inChunkBytes;
            _waveInPrepare!(_hWaveIn, hdr, sizeOf<_WaveHdr>());
            _waveInAddBuffer!(_hWaveIn, hdr, sizeOf<_WaveHdr>());
          }
        }
      });
      return true;
    } finally {
      _free!(hPtr.cast());
      _free!(fmt.cast());
    }
  }

  static void stopFullDuplex() {
    _inPollTimer?.cancel();
    _inPollTimer = null;
    _onCaptured = null;
    if (_hWaveIn != 0) {
      final hIn = _hWaveIn;
      _hWaveIn = 0;
      try { _waveInReset!(hIn); } catch (_) {}
      for (final hdr in _inHdrs) {
        if ((hdr.ref.dwFlags & _whdrPrepared) != 0) {
          try { _waveInUnprepare!(hIn, hdr, sizeOf<_WaveHdr>()); } catch (_) {}
        }
      }
      try { _waveInClose!(hIn); } catch (_) {}
      for (final hdr in _inHdrs) {
        try { _free!(hdr.cast()); } catch (_) {}
      }
      for (final buf in _inBufs) {
        try { _free!(buf.cast()); } catch (_) {}
      }
      _inHdrs.clear();
      _inBufs.clear();
    }
    if (_hWaveOut != 0 && _toneTimer == null) {
      _closeOutput();
    }
  }

  static void _closeOutput() {
    if (_hWaveOut == 0) return;
    final hOut = _hWaveOut;
    _hWaveOut = 0;
    try { _waveOutReset!(hOut); } catch (_) {}
    for (final hdr in _outHdrs) {
      if ((hdr.ref.dwFlags & _whdrPrepared) != 0) {
        try { _waveOutUnprepare!(hOut, hdr, sizeOf<_WaveHdr>()); } catch (_) {}
      }
    }
    try { _waveOutClose!(hOut); } catch (_) {}
    for (final hdr in _outHdrs) {
      try { _free!(hdr.cast()); } catch (_) {}
    }
    for (final buf in _outBufs) {
      try { _free!(buf.cast()); } catch (_) {}
    }
    _outHdrs.clear();
    _outBufs.clear();
  }

  static Uint8List _synthTone(double freq1, double freq2, int durationMs,
      {double amp = 0.25}) {
    final samples = (_sampleRate * durationMs) ~/ 1000;
    final out = Int16List(samples);
    for (int i = 0; i < samples; i++) {
      final t = i / _sampleRate;
      final fade = (i < 160)
          ? i / 160.0
          : (i > samples - 160 ? (samples - i) / 160.0 : 1.0);
      final v = (sin(2 * pi * freq1 * t) +
              (freq2 > 0 ? sin(2 * pi * freq2 * t) : 0.0)) *
          (freq2 > 0 ? 0.5 : 1.0) *
          amp *
          fade;
      out[i] = (v * 32767).round().clamp(-32767, 32767);
    }
    return out.buffer.asUint8List();
  }

  static void startOutgoingRingback() {
    stopTones();
    if (!Platform.isWindows) return;
    final beep = _synthTone(425.0, 0.0, 950, amp: 0.22);
    playPcm(beep);
    _toneTimer = Timer.periodic(const Duration(milliseconds: 3200), (_) {
      playPcm(beep);
    });
  }

  static void startIncomingRingtone() {
    stopTones();
    if (!Platform.isWindows) return;
    final pulse1 = _synthTone(440.0, 554.37, 380, amp: 0.28);
    final pulse2 = _synthTone(554.37, 659.25, 420, amp: 0.28);
    void ringOnce() {
      playPcm(pulse1);
      Future.delayed(const Duration(milliseconds: 420), () {
        if (_toneTimer != null) playPcm(pulse2);
      });
    }
    ringOnce();
    _toneTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      ringOnce();
    });
  }

  static void playCallEndTone() {
    if (!Platform.isWindows) return;
    playPcm(_synthTone(440.0, 0.0, 140, amp: 0.22));
    Future.delayed(const Duration(milliseconds: 170), () {
      playPcm(_synthTone(330.0, 0.0, 180, amp: 0.22));
    });
  }

  static void playPttSound(bool isStart) {
    if (!Platform.isWindows) return;
    if (isStart) {
      playPcm(_synthTone(1150.0, 0.0, 55, amp: 0.26));
      Future.delayed(const Duration(milliseconds: 55), () {
        playPcm(_synthTone(1600.0, 0.0, 60, amp: 0.26));
      });
    } else {
      playPcm(_synthTone(1750.0, 0.0, 65, amp: 0.26));
      Future.delayed(const Duration(milliseconds: 65), () {
        playPcm(_synthTone(1250.0, 0.0, 80, amp: 0.26));
      });
    }
  }

  static void stopTones() {
    _toneTimer?.cancel();
    _toneTimer = null;
    if (_hWaveIn == 0 && _hWaveOut != 0) {
      _closeOutput();
    }
  }

  static String _readUtf16Name(Pointer<Uint8> caps, int byteOffset) {
    final u16 = caps.elementAt(byteOffset).cast<Uint16>();
    final units = <int>[];
    for (int i = 0; i < 32; i++) {
      final c = u16[i];
      if (c == 0) break;
      units.add(c);
    }
    return String.fromCharCodes(units).trim();
  }

  static List<Map<String, dynamic>> listOutputDevices() {
    final list = <Map<String, dynamic>>[
      {'id': -1, 'name': 'По умолчанию (Windows)'},
    ];
    if (!Platform.isWindows) return list;
    _ensureLoaded();
    if (_waveOutGetNumDevs == null || _waveOutGetDevCaps == null || _alloc == null || _free == null) {
      return list;
    }
    final count = _waveOutGetNumDevs!();
    final caps = _alloc!(128).cast<Uint8>();
    try {
      for (int i = 0; i < count; i++) {
        if (_waveOutGetDevCaps!(i, caps, 84) == 0) {
          final name = _readUtf16Name(caps, 8);
          list.add({'id': i, 'name': name.isNotEmpty ? name : 'Динамик #$i'});
        }
      }
    } finally {
      _free!(caps.cast());
    }
    return list;
  }

  static List<Map<String, dynamic>> listInputDevices() {
    final list = <Map<String, dynamic>>[
      {'id': -1, 'name': 'По умолчанию (Windows)'},
    ];
    if (!Platform.isWindows) return list;
    _ensureLoaded();
    if (_waveInGetNumDevs == null || _waveInGetDevCaps == null || _alloc == null || _free == null) {
      return list;
    }
    final count = _waveInGetNumDevs!();
    final caps = _alloc!(128).cast<Uint8>();
    try {
      for (int i = 0; i < count; i++) {
        if (_waveInGetDevCaps!(i, caps, 80) == 0) {
          final name = _readUtf16Name(caps, 8);
          list.add({'id': i, 'name': name.isNotEmpty ? name : 'Микрофон #$i'});
        }
      }
    } finally {
      _free!(caps.cast());
    }
    return list;
  }

  static void setSelectedDevices({int? outId, int? inId}) {
    if (outId != null && outId != selectedOutDeviceId) {
      selectedOutDeviceId = outId;
      _closeOutput();
    }
    if (inId != null && inId != selectedInDeviceId) {
      selectedInDeviceId = inId;
    }
  }

  static void playTestBeep() {
    if (!Platform.isWindows) return;
    playPcm(_synthTone(523.25, 659.25, 320, amp: 0.30));
  }
}

class _UdpVideoAssembly {
  final int total;
  final List<Uint8List?> chunks;
  int received = 0;
  final int createdMs;
  _UdpVideoAssembly(this.total)
      : chunks = List<Uint8List?>.filled(total, null),
        createdMs = DateTime.now().millisecondsSinceEpoch;
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
  String? replyToMsgId;
  String? replyToText;
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
    this.replyToMsgId,
    this.replyToText,
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
        'rid': replyToMsgId,
        'rtxt': replyToText,
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

class PeerLocationRecord {
  final String nodeId;
  final String nickname;
  final double lat;
  final double lon;
  final double altMeters;
  final double pressureHpa;
  final bool isManualAnchor;
  final int updatedAt;

  PeerLocationRecord({
    required this.nodeId,
    required this.nickname,
    required this.lat,
    required this.lon,
    this.altMeters = 0.0,
    this.pressureHpa = 0.0,
    this.isManualAnchor = false,
    required this.updatedAt,
  });
}

class AppUpdateInfo {
  final String tagName;
  final String version;
  final String notes;
  final String downloadUrl;
  final String assetName;
  final int sizeBytes;

  const AppUpdateInfo({
    required this.tagName,
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.assetName,
    required this.sizeBytes,
  });
}

class MeshEngine {
  static const String currentAppVersion = '3.2.6';

  /// Безопасный парсер адреса узла (убирает udp:/tcp:, поддерживает IPv4, [IPv6]:port и голый IPv6)
  static ({String host, int port, bool isUdp}) parseEndpoint(String raw, {int defaultPort = 42070}) {
    var s = raw.trim();
    bool isUdp = false;
    if (s.startsWith('udp:')) {
      isUdp = true;
      s = s.substring(4).trim();
    } else if (s.startsWith('tcp:')) {
      s = s.substring(4).trim();
    }
    if (s.isEmpty || s.startsWith('BLE') || s == 'Через Mesh') {
      return (host: '', port: 0, isUdp: isUdp);
    }
    if (s.startsWith('[')) {
      final endBracket = s.indexOf(']');
      if (endBracket > 1) {
        final h = s.substring(1, endBracket).trim();
        var p = defaultPort;
        if (endBracket + 2 <= s.length && s[endBracket + 1] == ':') {
          p = int.tryParse(s.substring(endBracket + 2).trim()) ?? defaultPort;
        }
        return (host: h, port: p, isUdp: isUdp);
      }
    }
    final firstColon = s.indexOf(':');
    final lastColon = s.lastIndexOf(':');
    if (firstColon != -1 && firstColon == lastColon) {
      final h = s.substring(0, firstColon).trim();
      final p = int.tryParse(s.substring(firstColon + 1).trim()) ?? defaultPort;
      return (host: h, port: p, isUdp: isUdp);
    }
    // Голый IPv6 (несколько двоеточий) или хост без порта
    return (host: s, port: defaultPort, isUdp: isUdp);
  }

  static bool isPrivateLanIpv4(String ip) {
    if (ip.isEmpty || ip.contains(':')) return false;
    return ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.');
  }
  static const String githubRepo = 'lasaniaden/Mayak-messenger';
  static const String broadcastChannelId = 'BROADCAST';
  static const int discoveryPort = 42069;
  static const int defaultTcpPort = 42070;
  static const int callMediaUdpPort = 42072;
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
  final Map<Socket, int> _tcpLastRxMs = {};
  int _beaconTickCounter = 0;
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
  Directory? _cachedFilesDir;
  int _lastFileUiNotifyMs = 0;
  final Map<String, int> _activeFileStreamGen = {};
  final Map<String, Timer> _downloadWatchdogTimers = {};
  final Set<String> _revokedFileIds = {};
  final Map<String, Map<int, String>> _incomingSdpParts = {};
  bool _isCallInitiator = false;
  late final MayakSoLoudPlayer soloudPlayer = MayakSoLoudPlayer()
    ..onStateChanged = () {
      currentlyPlayingAudioPath = soloudPlayer.currentPath;
      isAudioPlaying = soloudPlayer.isPlaying;
      audioPositionMs = soloudPlayer.positionMs;
      audioDurationMs = soloudPlayer.durationMs;
      onStateChanged();
    }
    ..onLog = (m) => _addLog(m, triggerUi: false);
  late final MayakWebRtcController webrtc = MayakWebRtcController()
    ..onStateChanged = () {
      if (webrtc.isConnected) {
        activeCallTransport = 'WebRTC P2P';
      }
      onStateChanged();
    }
    ..onLog = (m) => _addLog(m, triggerUi: false);
  Timer? _onlineReconnectWatchdog;
  int _onlineReconnectTicks = 0;
  final Map<String, int> _lastDhtAutoLookupMs = {};
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

  // v1.8.0: Полнодуплексный ГЧ/ВЧ (16kHz PCM + UDP 42072 ChaCha20 + 14 FPS Video)
  String? activeCallPeerId;
  String activeCallMode = 'voice'; // 'voice' | 'video'
  bool isCallAccepted = false;
  bool isCallMicMuted = false;
  bool isCallVideoMuted = false;
  bool remoteCallMicMuted = false;
  bool remoteCallVideoMuted = false;
  bool isCallFrontCamera = true;
  bool isCallSpeakerOn = false;
  int _callStartedMs = 0;
  int _lastCallUdpRxMs = 0;
  int _lastBleVideoTxMs = 0;
  String activeCallTransport = 'Wi-Fi UDP';
  String windowsVideoSource = 'camera'; // 'camera' | 'screen'
  int selectedWinCameraIndex = 0;
  List<String> availableWinCameras = [];
  String? incomingCallFromPeerId;
  String incomingCallMode = 'voice';
  String _incomingCallId = '';
  int _incomingCallUdpPort = callMediaUdpPort;
  String _activeCallId = '';
  SecretKey? _activeCallMediaKey;
  RawDatagramSocket? _callUdpSocket;
  int _callUdpListenPort = callMediaUdpPort;
  String? _activeCallPeerIp;
  int _activeCallPeerUdpPort = callMediaUdpPort;
  int _callAudioSeq = 0;
  int _callVideoSeq = 0;
  final Map<int, _UdpVideoAssembly> _udpVideoAssemblies = {};
  int _lastRenderedVideoSeq = -1;
  ServerSocket? _winVideoServer;
  Process? _winVideoProcess;
  bool _isSendingVideoFrame = false;
  Process? _winAudioProc;
  StreamSubscription<String>? _winAudioSub;
  Timer? _udpPunchTimer;
  Uint8List? remoteVideoFrameBytes;
  Uint8List? localVideoFrameBytes;
  int _lastLocalPreviewUiMs = 0;
  String callStatusText = '';
  // v2.0.0: Режим Рации (PTT) — работает из любого экрана по Wi-Fi и Bluetooth
  bool isWalkieTalkieMode = false;
  bool isPttTransmitting = false;
  String pttChannelTarget = 'ALL'; // 'ALL' или nodeId
  bool pttSoundsEnabled = true;
  bool pttAutoReceiveEnabled = true;
  bool pttLatchMode = false; // false = удерживать, true = нажал-говоришь
  String? pttActiveSpeakerName;
  Timer? _pttRxTimeoutTimer;
  // v2.1.0: Security hardening (PTT E2EE, call replay window, DoS cap) + Saved Notes & Disappearing timer
  static const int maxTransitBufferSize = 350;
  final Map<String, SecretKey> _peerPttKeys = {};
  int _lastCallAudioRxSeq = 0;
  final Set<int> _callAudioSeenSeqs = {};
  static const String savedChatKey = 'saved:self';
  int defaultDisappearingSeconds = 0;
  Timer? _disappearingSweeper;
  // v2.3.0: Карта узлов (гео + барометр + анти-спуфинг РЭБ) и межрегиональный P2P
  bool isLocationSharingEnabled = false;
  bool gpsSpoofingDetected = false;
  String gpsSpoofingNote = '';
  PeerLocationRecord? myLocation;
  final Map<String, PeerLocationRecord> peerLocations = {};
  Timer? _locationPollTimer;
  String customExternalEndpoint = '';
  bool isInterRegionalBridgeEnabled = false;
  // v2.5.0: Подавление эха (AES) + авто-STUN/UPnP межрегиональный режим
  int _lastRemoteAudioRxMs = 0;
  bool _remoteVoiceActive = false;
  double _remoteNoiseFloor = 180.0;
  bool isAutoInterRegionalEnabled = false;
  bool isDiscoveringExternalAddr = false;
  String discoveredExternalEndpoint = '';
  String interRegionalStatusText = 'Выключен';
  final Map<String, ({String ip, int port, int lastSeenMs})> _remoteUdpPeers = {};
  late final MayakDhtClient _dhtClient = MayakDhtClient(
    getSocket: () => _callUdpSocket,
    onLog: (m) => _addLog(m, triggerUi: false),
  );
  bool isDhtDiscoveryEnabled = true;
  String myStaticMayakId = '';
  Uint8List _myNospamBytes = Uint8List(4);
  Timer? _dhtRepublishTimer;
  Timer? _sleepWatchdogTimer;
  int _lastWatchdogWallMs = 0;
  final Stopwatch _watchdogMono = Stopwatch();
  int get dhtNodesCount => _dhtClient.knownNodesCount;
  Timer? _stunKeepaliveTimer;
  Timer? _udpPeerPunchTimer;
  final List<String> _stunObservedEndpoints = [];
  Completer<String?>? _stunPendingCompleter;
  // v2.7.0: Dual-Stack IPv6 P2P + Auto UPnP-IGD + Russian STUN
  ServerSocket? _tcpServerV6;
  String globalIpv6Address = '';
  bool upnpPortMapped = false;
  String upnpExternalIp = '';

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

  bool isNodeOnline(String pid) => knownContacts[pid]?.isOnline ?? false;

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
    final u = _remoteUdpPeers[peerId];
    final udpAlive = u != null && (DateTime.now().millisecondsSinceEpoch - u.lastSeenMs) < 15000;
    return _tcpPeers.containsValue(peerId) || _blePeers.containsValue(peerId) || udpAlive;
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

  bool _constantTimeHexEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<bool> tryUnlockAdminConsole(String candidatePhrase) async {
    final clean = _normalizeAdminPhrase(candidatePhrase);
    final digest =
        await _sha256.hash(utf8.encode('MAYAK-ADMIN-AUTH-SALT-V1|$clean'));
    if (!_constantTimeHexEquals(_toHex(digest.bytes), _adminAuthHashHex)) {
      return false;
    }
    final seedDigest =
        await _sha256.hash(utf8.encode('MAYAK-ADMIN-ED25519-SEED-V1|$clean'));
    _unlockedAdminMasterKeyPair =
        await _ed25519.newKeyPairFromSeed(seedDigest.bytes);
    isAdminUnlocked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mayak_adm_seed_v21', _toHex(seedDigest.bytes));
    } catch (_) {}
    _refreshOnlineStatuses();
    unawaited(pingAllKnownNodes());
    onStateChanged();
    return true;
  }

  Future<bool> tryFastAdminUnlockFromCache() async {
    if (isAdminUnlocked) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seedHex = prefs.getString('mayak_adm_seed_v21') ?? '';
      if (seedHex.length != 64) return false;
      final kp = await _ed25519.newKeyPairFromSeed(_fromHex(seedHex));
      final pub = await kp.extractPublicKey();
      if (!_constantTimeHexEquals(_toHex(pub.bytes), _adminMasterPubHex)) {
        return false;
      }
      _unlockedAdminMasterKeyPair = kp;
      isAdminUnlocked = true;
      _refreshOnlineStatuses();
      unawaited(pingAllKnownNodes());
      onStateChanged();
      return true;
    } catch (_) {
      return false;
    }
  }

  List<ChatMessage> getSavedMessages() {
    return chatHistory.putIfAbsent(savedChatKey, () => []);
  }

  Future<void> addSavedNote(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    getSavedMessages().add(ChatMessage(
      msgId: _randomHex(12),
      peerId: savedChatKey,
      senderId: nodeId,
      senderName: nickname,
      text: clean,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMe: true,
      isDelivered: true,
    ));
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> deleteSavedNote(String msgId) async {
    getSavedMessages().removeWhere((m) => m.msgId == msgId);
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> setDefaultDisappearingSeconds(int seconds) async {
    defaultDisappearingSeconds = seconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('mayak_disappear_sec', seconds);
    } catch (_) {}
    onStateChanged();
  }

  void _sweepExpiredMessages() {
    if (defaultDisappearingSeconds <= 0) return;
    final cutoff = DateTime.now().millisecondsSinceEpoch -
        (defaultDisappearingSeconds * 1000);
    bool changed = false;
    for (final entry in chatHistory.entries) {
      if (entry.key == savedChatKey) continue;
      final before = entry.value.length;
      entry.value.removeWhere((m) => m.timestamp < cutoff);
      if (entry.value.length != before) changed = true;
    }
    if (changed) {
      unawaited(_saveContactsAndChats());
      onStateChanged();
    }
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

  List<Map<String, String>> _buildGroupMemberProfiles(List<String> memberIds) {
    final list = <Map<String, String>>[];
    list.add({
      'id': nodeId,
      'nick': nickname,
      'dh': dhPubHex,
      'sg': signPubHex,
    });
    for (final pid in memberIds) {
      if (pid == nodeId) continue;
      final c = knownContacts[pid];
      if (c != null && c.dhPubHex.isNotEmpty && c.signPubHex.isNotEmpty) {
        list.add({
          'id': c.nodeId,
          'nick': c.nickname,
          'dh': c.dhPubHex,
          'sg': c.signPubHex,
        });
      }
    }
    return list;
  }

  void _absorbGroupMemberProfiles(dynamic rawProfiles) {
    if (rawProfiles is! List) return;
    for (final item in rawProfiles) {
      if (item is! Map) continue;
      final pid = (item['id'] ?? '').toString();
      final dh = (item['dh'] ?? '').toString();
      final sg = (item['sg'] ?? '').toString();
      final nick = (item['nick'] ?? '').toString();
      if (pid.isEmpty || pid == nodeId || dh.isEmpty || sg.isEmpty) continue;
      final existing = knownContacts[pid];
      if (existing == null) {
        knownContacts[pid] = ContactProfile(
          nodeId: pid,
          dhPubHex: dh,
          signPubHex: sg,
          nickname: nick.isNotEmpty ? nick : 'Узел $pid',
          lastSeenTimestamp: DateTime.now().millisecondsSinceEpoch,
        );
      } else if (nick.isNotEmpty && existing.nickname.startsWith('Узел ')) {
        existing.nickname = nick;
      }
    }
  }

  Future<void> _relayGroupPayloadToMembers(
    GroupChat group,
    Map<String, dynamic> payloadMap,
    String baseEventId, {
    Set<String> excludeIds = const {},
  }) async {
    final encoded = utf8.encode(jsonEncode(payloadMap));
    for (final pid in group.memberIds) {
      if (pid == nodeId || excludeIds.contains(pid)) continue;
      final c = knownContacts[pid];
      if (c == null) continue;
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: pid,
        contact: c,
        msgId: '${baseEventId}_$pid',
        sealedPayloadBytes: encoded,
        keepInTransitBuffer: true,
        persistInOutbox: true,
      );
    }
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

    final inviteMap = {
      'v': 2,
      'kind': 'GROUP_INVITE',
      'gid': gid,
      'title': cleanTitle,
      'creator': nodeId,
      'members': members,
      'mprof': _buildGroupMemberProfiles(members),
      'hop': 0,
      'ts': group.createdAt,
    };
    await _relayGroupPayloadToMembers(group, inviteMap, 'ginv_$gid');
    await _saveContactsAndChats();
    onStateChanged();
    return group;
  }

  Future<void> sendGroupMessage(
    String groupId,
    String text, {
    String? replyToId,
    String? replyToPreview,
    String? forwardedFrom,
  }) async {
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
      replyToMsgId: replyToId,
      replyToText: replyToPreview,
      forwardedFrom: forwardedFrom,
    );
    getGroupMessages(groupId).add(msg);
    _inspectMessageForTriggers(msg, gKey);

    final payloadMap = <String, dynamic>{
      'v': 2,
      'kind': 'GROUP_MSG',
      'gid': groupId,
      'title': group.title,
      'creator': group.creatorId,
      'members': group.memberIds,
      'mprof': _buildGroupMemberProfiles(group.memberIds),
      'mid': msgId,
      'osid': nodeId,
      'sn': nickname,
      'txt': clean,
      'hop': 0,
      'ts': now,
    };
    if (replyToId != null) payloadMap['rid'] = replyToId;
    if (replyToPreview != null) payloadMap['rtxt'] = replyToPreview;
    if (forwardedFrom != null) payloadMap['fwd'] = forwardedFrom;

    await _relayGroupPayloadToMembers(group, payloadMap, msgId);
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> editGroupMessage(
      String groupId, String msgId, String newText) async {
    final clean = newText.trim();
    final group = groupChats[groupId];
    if (clean.isEmpty || group == null) return;
    final list = getGroupMessages(groupId);
    for (final m in list) {
      if (m.msgId == msgId && m.isMe) {
        m.text = clean;
        m.isEdited = true;
        break;
      }
    }
    final payloadMap = {
      'v': 2,
      'kind': 'GROUP_EDIT',
      'gid': groupId,
      'mid': msgId,
      'osid': nodeId,
      'txt': clean,
      'hop': 0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _relayGroupPayloadToMembers(group, payloadMap, 'gedit_$msgId');
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> deleteGroupMessage(String groupId, String msgId,
      {bool forEveryone = true}) async {
    final group = groupChats[groupId];
    if (group == null) return;
    deletedMessageIds.add(msgId);
    getGroupMessages(groupId).removeWhere((m) => m.msgId == msgId);
    if (forEveryone) {
      final payloadMap = {
        'v': 2,
        'kind': 'GROUP_DELETE',
        'gid': groupId,
        'mid': msgId,
        'osid': nodeId,
        'hop': 0,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      await _relayGroupPayloadToMembers(group, payloadMap, 'gdel_$msgId');
    }
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> toggleGroupReaction(
      String groupId, String msgId, String emoji) async {
    final group = groupChats[groupId];
    if (group == null) return;
    for (final m in getGroupMessages(groupId)) {
      if (m.msgId == msgId) {
        if (m.reactions[nodeId] == emoji) {
          m.reactions.remove(nodeId);
        } else {
          m.reactions[nodeId] = emoji;
        }
        break;
      }
    }
    final payloadMap = {
      'v': 2,
      'kind': 'GROUP_REACTION',
      'gid': groupId,
      'mid': msgId,
      'osid': nodeId,
      'emoji': emoji,
      'hop': 0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _relayGroupPayloadToMembers(
        group, payloadMap, 'grx_${msgId}_${_randomHex(4)}');
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> renameGroupChat(String groupId, String newTitle) async {
    final clean = newTitle.trim();
    final group = groupChats[groupId];
    if (clean.isEmpty || group == null) return;
    group.title = clean;
    final payloadMap = {
      'v': 2,
      'kind': 'GROUP_INVITE',
      'gid': groupId,
      'title': clean,
      'creator': group.creatorId,
      'members': group.memberIds,
      'mprof': _buildGroupMemberProfiles(group.memberIds),
      'hop': 0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _relayGroupPayloadToMembers(
        group, payloadMap, 'gren_${groupId}_${_randomHex(4)}');
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> addMemberToGroupChat(String groupId, String memberId) async {
    final group = groupChats[groupId];
    if (group == null || group.memberIds.contains(memberId)) return;
    group.memberIds.add(memberId);
    final payloadMap = {
      'v': 2,
      'kind': 'GROUP_INVITE',
      'gid': groupId,
      'title': group.title,
      'creator': group.creatorId,
      'members': group.memberIds,
      'mprof': _buildGroupMemberProfiles(group.memberIds),
      'hop': 0,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _relayGroupPayloadToMembers(
        group, payloadMap, 'gadd_${groupId}_${_randomHex(4)}');
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> clearGroupHistory(String groupId) async {
    chatHistory[groupChatKey(groupId)]?.clear();
    unreadGroupCounts[groupId] = 0;
    await _saveContactsAndChats();
    onStateChanged();
  }

  Future<void> leaveOrDeleteGroupChat(String groupId) async {
    final group = groupChats[groupId];
    if (group != null) {
      final payloadMap = {
        'v': 2,
        'kind': 'GROUP_LEAVE',
        'gid': groupId,
        'osid': nodeId,
        'sn': nickname,
        'hop': 0,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      await _relayGroupPayloadToMembers(
          group, payloadMap, 'glv_${groupId}_${_randomHex(4)}');
    }
    groupChats.remove(groupId);
    chatHistory.remove(groupChatKey(groupId));
    unreadGroupCounts.remove(groupId);
    await _saveContactsAndChats();
    onStateChanged();
  }

  /// Универсальное чтение QR-кода из файла картинки (PNG/JPG/WebP) — работает на Android И Windows!
  Future<String?> decodeQrFromImageFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      // Конвертируем в Int32List ARGB для RGBLuminanceSource (zxing2)
      final w = decoded.width;
      final h = decoded.height;
      final pixels = Int32List(w * h);
      int p = 0;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final px = decoded.getPixel(x, y);
          final r = px.r.toInt() & 0xFF;
          final g = px.g.toInt() & 0xFF;
          final b = px.b.toInt() & 0xFF;
          final a = px.a.toInt() & 0xFF;
          // Композитинг на белый фон (если PNG с прозрачностью!)
          final rr = ((r * a + 255 * (255 - a)) ~/ 255) & 0xFF;
          final gg = ((g * a + 255 * (255 - a)) ~/ 255) & 0xFF;
          final bb = ((b * a + 255 * (255 - a)) ~/ 255) & 0xFF;
          pixels[p++] = (0xFF << 24) | (rr << 16) | (gg << 8) | bb;
        }
      }
      final source = zx.RGBLuminanceSource(w, h, pixels);
      final bitmap = zx.BinaryBitmap(zx.HybridBinarizer(source));
      final reader = zx.QRCodeReader();
      final res = reader.decode(bitmap);
      final text = res.text.trim();
      return text.isNotEmpty ? text : null;
    } catch (e) {
      _addLog('[QR] zxing2 не распознал файл: $e', triggerUi: false);
      return null;
    }
  }

  /// Выравнивание длины Padmé (оверхед < 12%, скрывает точный размер сообщений от анализа трафика)
  static int _padmeLength(int l) {
    if (l <= 1) return l;
    final e = (log(l) / ln2).floor();
    final s = (log(e) / ln2).floor() + 1;
    final lastBits = e - s;
    if (lastBits <= 0) return l;
    final bitMask = (1 << lastBits) - 1;
    return (l + bitMask) & ~bitMask;
  }

  static List<int> _applyPadmeJsonPadding(List<int> rawBytes) {
    final targetLen = _padmeLength(rawBytes.length);
    if (targetLen <= rawBytes.length) return rawBytes;
    final out = Uint8List(targetLen);
    out.setRange(0, rawBytes.length, rawBytes);
    // Пробелы в конце JSON полностью валидны для jsonDecode и 100% обратно совместимы
    for (int i = rawBytes.length; i < targetLen; i++) {
      out[i] = 0x20;
    }
    return out;
  }

  /// Проверка автозапуска Windows (реестр HKCU\...\Run, без .bat)
  Future<bool> isWindowsAutostartEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final res = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'MayakMessenger',
      ]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Включение/выключение автозапуска Windows сразу в трей (--minimized)
  Future<bool> setWindowsAutostartEnabled(bool enabled) async {
    if (!Platform.isWindows) return false;
    try {
      if (enabled) {
        final exe = Platform.resolvedExecutable;
        final res = await Process.run('reg', [
          'add',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'MayakMessenger',
          '/t',
          'REG_SZ',
          '/d',
          '"$exe" --minimized',
          '/f',
        ]);
        return res.exitCode == 0;
      } else {
        await Process.run('reg', [
          'delete',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'MayakMessenger',
          '/f',
        ]);
        return true;
      }
    } catch (_) {
      return false;
    }
  }

  static bool _isNewerVersion(String remoteVer, String localVer) {
    List<int> parse(String s) => s
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(p.trim()) ?? 0)
        .toList();
    final r = parse(remoteVer);
    final l = parse(localVer);
    final maxLen = max(r.length, l.length);
    for (int i = 0; i < maxLen; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv > lv) return true;
      if (rv < lv) return false;
    }
    return false;
  }

  /// Проверка обновлений через GitHub Releases API (не блокирует офлайн-работу)
  Future<AppUpdateInfo?> checkForAppUpdate() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('https://api.github.com/repos/$githubRepo/releases/latest');
      final req = await client.getUrl(uri);
      req.headers.set('User-Agent', 'Mayak-P2P/$currentAppVersion');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return null;
      final body = await utf8.decoder.bind(resp).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final tag = (data['tag_name'] ?? '').toString().trim();
      final ver = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (ver.isEmpty || !_isNewerVersion(ver, currentAppVersion)) return null;
      final notes = (data['body'] ?? '').toString().trim();
      final assets = (data['assets'] as List?) ?? const [];
      String? url;
      String? name;
      int size = 0;
      for (final raw in assets) {
        if (raw is! Map) continue;
        final n = (raw['name'] ?? '').toString();
        final u = (raw['browser_download_url'] ?? '').toString();
        final low = n.toLowerCase();
        final match = Platform.isAndroid
            ? low.endsWith('.apk')
            : (Platform.isWindows ? low.endsWith('.zip') && low.contains('windows') : false);
        if (match && u.isNotEmpty) {
          url = u;
          name = n;
          size = (raw['size'] as num?)?.toInt() ?? 0;
          break;
        }
      }
      if (url == null || name == null) return null;
      return AppUpdateInfo(
        tagName: tag,
        version: ver,
        notes: notes.isEmpty ? 'Улучшения стабильности и безопасности сети Маяк.' : notes,
        downloadUrl: url,
        assetName: name,
        sizeBytes: size,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Обновление: на Android открывает прямую загрузку APK в браузере (чисто для Play Protect), на Windows — автообновление ZIP
  Future<String> downloadAndInstallUpdate(
    AppUpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      try {
        final ok = await _nativeChannel.invokeMethod<bool>(
              'openExternalUrl',
              {'url': info.downloadUrl},
            ) ??
            false;
        return ok
            ? 'Открыта загрузка APK в браузере — нажмите «Открыть → Обновить» после скачивания'
            : 'Откройте ссылку вручную: ${info.downloadUrl}';
      } catch (e) {
        return 'Ошибка открытия браузера: $e';
      }
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(Uri.parse(info.downloadUrl));
      req.headers.set('User-Agent', 'Mayak-P2P/$currentAppVersion');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        return 'Ошибка загрузки: HTTP ${resp.statusCode}';
      }
      final total = resp.contentLength > 0 ? resp.contentLength : info.sizeBytes;
      final tmpDir = Directory.systemTemp;
      final sep = Platform.pathSeparator;
      final targetPath = '${tmpDir.path}${sep}mayak_update_${info.version}_${info.assetName}';
      final outFile = File(targetPath);
      final sink = outFile.openWrite();
      int received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress((received / total).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();

      if (Platform.isWindows) {
        final exePath = Platform.resolvedExecutable;
        final appDir = File(exePath).parent.path;
        final exeName = exePath.split(RegExp(r'[\\/]')).last;
        final stageDir = Directory('$appDir${sep}_mayak_upd_stage');
        try {
          if (await stageDir.exists()) {
            await stageDir.delete(recursive: true);
          }
          await stageDir.create(recursive: true);

          _addLog('[UPD] Распаковка архива (${outFile.lengthSync()} Б) чистым Dart...');
          final zipBytes = await outFile.readAsBytes();
          final extractedCount = await _extractZipBytesPureDart(zipBytes, stageDir.path);
          if (extractedCount <= 0) {
            throw Exception('Архив пуст или повреждён');
          }

          // Ищем корень распакованной сборки (где лежит p2p_mesh.exe)
          String srcRoot = stageDir.path;
          if (!await File('$srcRoot$sep$exeName').exists()) {
            await for (final ent in stageDir.list(recursive: true)) {
              if (ent is File &&
                  ent.path.toLowerCase().endsWith('$sep${exeName.toLowerCase()}')) {
                srcRoot = ent.parent.path;
                break;
              }
            }
          }
          final stagedExe = File('$srcRoot$sep$exeName');
          if (!await stagedExe.exists() || await stagedExe.length() < 50000) {
            throw Exception('В архиве не найден корректный $exeName');
          }

          // Атомарная замена файлов на лету (схема TGWSProxy / Telegram Desktop):
          // Windows NTFS разрешает переименовывать запущенный .exe и загруженные .dll в .old без PowerShell!
          final srcRootNorm = srcRoot.endsWith(sep) ? srcRoot : '$srcRoot$sep';
          int replacedCount = 0;
          await for (final ent in Directory(srcRoot).list(recursive: true)) {
            if (ent is! File) continue;
            final rel = ent.path.substring(srcRootNorm.length);
            if (rel.isEmpty || rel.contains('..')) continue;
            final destPath = '$appDir$sep$rel';
            final destFile = File(destPath);
            if (!await destFile.parent.exists()) {
              await destFile.parent.create(recursive: true);
            }
            if (await destFile.exists()) {
              final oldPath = '$destPath.old';
              final oldFile = File(oldPath);
              if (await oldFile.exists()) {
                try {
                  await oldFile.delete();
                } catch (_) {
                  try {
                    await oldFile.rename('$destPath.old_${DateTime.now().millisecondsSinceEpoch}');
                  } catch (_) {}
                }
              }
              await destFile.rename(oldPath);
            }
            await ent.rename(destPath);
            replacedCount++;
          }

          try {
            await stageDir.delete(recursive: true);
          } catch (_) {}
          try {
            await outFile.delete();
          } catch (_) {}

          _addLog('[UPD] Заменено файлов: $replacedCount -> перезапуск на v${info.version}');

          // Закрываем сокеты, запускаем новый p2p_mesh.exe --updated и выходим
          try {
            await _tcpServer?.close();
            await _tcpServerV6?.close();
            _callUdpSocket?.close();
            _winAudioProc?.kill();
            _winVideoProcess?.kill();
          } catch (_) {}

          await Process.start(
            exePath,
            ['--updated'],
            workingDirectory: appDir,
            mode: ProcessStartMode.detached,
          );
          Future.delayed(const Duration(milliseconds: 150), () => exit(0));
          return 'Обновление v${info.version} установлено ($replacedCount файлов) — перезапускаю Маяк...';
        } catch (e) {
          _addLog('[UPD] Ошибка автообновления: $e');
          try {
            if (await stageDir.exists()) await stageDir.delete(recursive: true);
          } catch (_) {}
          return 'Ошибка автообновления: $e';
        }
      }
      return 'Сохранено: ${outFile.path}';
    } catch (e) {
      return 'Ошибка обновления: $e';
    } finally {
      client.close(force: true);
    }
  }

  /// Чистая Dart-распаковка ZIP (без PowerShell, .bat и внешних процессов — 100% чисто для Dr.Web)
  Future<int> _extractZipBytesPureDart(Uint8List bytes, String destDir) async {
    if (bytes.length < 22) return 0;
    final bd = ByteData.sublistView(bytes);
    // Ищем End of Central Directory (0x06054b50) с конца файла
    int eocdOff = -1;
    final minOff = max(0, bytes.length - 65557);
    for (int i = bytes.length - 22; i >= minOff; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4B &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        eocdOff = i;
        break;
      }
    }
    if (eocdOff < 0) return 0;
    final totalEntries = bd.getUint16(eocdOff + 10, Endian.little);
    final cdOffset = bd.getUint32(eocdOff + 16, Endian.little);
    int pos = cdOffset;
    int extracted = 0;
    final sep = Platform.pathSeparator;

    for (int idx = 0; idx < totalEntries; idx++) {
      if (pos + 46 > bytes.length) break;
      final sig = bd.getUint32(pos, Endian.little);
      if (sig != 0x02014B50) break;
      final method = bd.getUint16(pos + 10, Endian.little);
      final compSize = bd.getUint32(pos + 20, Endian.little);
      final nameLen = bd.getUint16(pos + 28, Endian.little);
      final extraLen = bd.getUint16(pos + 30, Endian.little);
      final commentLen = bd.getUint16(pos + 32, Endian.little);
      final localHdrOff = bd.getUint32(pos + 42, Endian.little);
      final rawName = utf8.decode(
        bytes.sublist(pos + 46, pos + 46 + nameLen),
        allowMalformed: true,
      );
      pos += 46 + nameLen + extraLen + commentLen;

      final normName = rawName.replaceAll('\\', '/');
      if (normName.isEmpty || normName.startsWith('/') || normName.contains('..')) {
        continue;
      }
      if (normName.endsWith('/')) {
        await Directory('$destDir$sep${normName.replaceAll('/', sep)}')
            .create(recursive: true);
        continue;
      }
      if (localHdrOff + 30 > bytes.length) continue;
      final lNameLen = bd.getUint16(localHdrOff + 26, Endian.little);
      final lExtraLen = bd.getUint16(localHdrOff + 28, Endian.little);
      final dataStart = localHdrOff + 30 + lNameLen + lExtraLen;
      if (dataStart + compSize > bytes.length) continue;

      final compressed = bytes.sublist(dataStart, dataStart + compSize);
      List<int> content;
      if (method == 0) {
        content = compressed;
      } else if (method == 8) {
        content = ZLibDecoder(raw: true).convert(compressed);
      } else {
        continue;
      }
      final outPath = '$destDir$sep${normName.replaceAll('/', sep)}';
      final outFile = File(outPath);
      if (!await outFile.parent.exists()) {
        await outFile.parent.create(recursive: true);
      }
      await outFile.writeAsBytes(content, flush: true);
      extracted++;
    }
    return extracted;
  }

  Future<void> _cleanupWindowsOldUpdateFiles() async {
    if (!Platform.isWindows) return;
    try {
      final appDir = File(Platform.resolvedExecutable).parent;
      await for (final ent in appDir.list(recursive: true)) {
        if (ent is File &&
            (ent.path.endsWith('.old') || ent.path.contains('.old_'))) {
          try {
            await ent.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  String buildDiagnosticLogReport() {
    final sb = StringBuffer();
    sb.writeln('=== MAYAK DIAGNOSTIC LOG v$currentAppVersion ===');
    sb.writeln('Platform: ${Platform.operatingSystem} | NodeId: $nodeId | Nick: $nickname');
    sb.writeln('TCP peers: ${_tcpPeers.values.toSet().toList()}');
    sb.writeln('BLE peers: ${_blePeers.values.toSet().toList()}');
    sb.writeln('UDP peers: ${_remoteUdpPeers.entries.map((e) => '${e.key}=${e.value.ip}:${e.value.port}(age=${((DateTime.now().millisecondsSinceEpoch - e.value.lastSeenMs) / 1000).toStringAsFixed(1)}s)').toList()}');
    sb.writeln('DHT nodes: ${_dhtClient.knownNodesCount} | ExtUDP: $discoveredExternalEndpoint | IPv6: $globalIpv6Address');
    sb.writeln('Active incoming files: ${_incomingFiles.entries.map((e) => '${e.key}:${e.value.receivedChunkIndices.length}/${e.value.totalChunks}').toList()}');
    sb.writeln('--- RECENT LOGS (last ${debugLogs.length}) ---');
    final startIdx = debugLogs.length > 250 ? debugLogs.length - 250 : 0;
    for (int i = startIdx; i < debugLogs.length; i++) {
      sb.writeln(debugLogs[i]);
    }
    return sb.toString();
  }

  Future<String> saveBytesToDownloads(String fileName, List<int> bytes) async {
    try {
      if (Platform.isAndroid) {
        final savedPath = await _nativeChannel.invokeMethod<String>(
          'saveFileToDownloads',
          {'fileName': fileName, 'bytes': Uint8List.fromList(bytes)},
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
      final outFile = File('${dl.path}$sep$fileName');
      await outFile.writeAsBytes(bytes, flush: true);
      return outFile.path;
    } catch (e) {
      return 'Ошибка сохранения: $e';
    }
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
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final liveUdpPeers = _remoteUdpPeers.entries
        .where((e) => e.value.lastSeenMs > 0 && (nowMs - e.value.lastSeenMs) < 25000)
        .toList();
    if (_tcpPeers.isEmpty && _blePeers.isEmpty && liveUdpPeers.isEmpty) return;

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

    // 1. Отправка на все активные TCP-сокеты с защитой от перегрузки
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

    // 2. Отправка на все живые межрегиональные UDP-туннели!
    for (final entry in liveUdpPeers) {
      final peerId = entry.key;
      final ep = entry.value;
      int udpSent = 0;
      for (final pkt in combined.values) {
        if (pkt.dstNodeId != broadcastChannelId && pkt.dstNodeId != peerId) {
          continue;
        }
        _sendUdpMeshJson(ep.ip, ep.port, jsonEncode(pkt.toJson()));
        udpSent++;
        if (udpSent >= 12) break;
      }
    }
  }

  String? _resolvePeerIp(String peerId) {
    for (final entry in _tcpPeers.entries) {
      if (entry.value == peerId) {
        return entry.key.remoteAddress.address;
      }
    }
    final udpPeer = _remoteUdpPeers[peerId];
    if (udpPeer != null && udpPeer.ip.isNotEmpty) {
      return udpPeer.ip;
    }
    final c = knownContacts[peerId];
    if (c != null && c.lastAddress.isNotEmpty) {
      final ep = parseEndpoint(c.lastAddress, defaultPort: defaultTcpPort);
      if (ep.host.isNotEmpty) return ep.host;
    }
    return null;
  }

  Future<void> _initCallUdpSocket() async {
    if (_callUdpSocket != null) return;
    int preferredUdpPort = callMediaUdpPort;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPort = prefs.getInt('mayak_udp_port_v3');
      if (savedPort != null && savedPort >= 49152 && savedPort <= 65535) {
        preferredUdpPort = savedPort;
      } else {
        preferredUdpPort = 49152 + Random.secure().nextInt(16380);
        await prefs.setInt('mayak_udp_port_v3', preferredUdpPort);
      }
    } catch (_) {}
    for (final port in [preferredUdpPort, 0]) {
      try {
        _callUdpSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          port,
          reuseAddress: true,
          reusePort: false,
        );
        _callUdpListenPort = _callUdpSocket!.port;
        _callUdpSocket!.listen(
          (event) {
            if (event == RawSocketEvent.read) {
              try {
                final dg = _callUdpSocket?.receive();
                if (dg != null) {
                  unawaited(_onCallUdpDatagram(dg));
                }
              } catch (e) {
                // Игнорируем WSAECONNRESET (10054) на Windows при ICMP Port Unreachable
                _addLog('[UDP] Предупреждение чтения (игнор 10054): $e', triggerUi: false);
              }
            }
          },
          onError: (e) {
            _addLog('[UDP] Ошибка сокета (игнор): $e', triggerUi: false);
          },
          onDone: () {
            _callUdpSocket = null;
          },
          cancelOnError: false,
        );
        break;
      } catch (e) {
        _addLog('[UDP] Не удалось открыть порт $port: $e', triggerUi: false);
      }
    }
  }

  Future<SecretKey?> _deriveCallMediaKey(String peerId, String callId) async {
    final contact = knownContacts[peerId];
    if (contact == null || contact.dhPubHex.isEmpty) return null;
    try {
      final peerDhPub = SimplePublicKey(
        _fromHex(contact.dhPubHex),
        type: KeyPairType.x25519,
      );
      final shared = await _x25519.sharedSecretKey(
        keyPair: _dhKeyPair,
        remotePublicKey: peerDhPub,
      );
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final pairIds = [nodeId, peerId]..sort();
      return await hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('mayak-call-salt-v21'),
        info: utf8.encode('mayak-call-key|${pairIds[0]}|${pairIds[1]}|$callId'),
      );
    } catch (_) {
      return null;
    }
  }

  static int _linearToUlaw(int pcm) {
    const int bias = 0x84;
    const int clip = 32635;
    int sign = (pcm >> 8) & 0x80;
    if (sign != 0) pcm = -pcm;
    if (pcm > clip) pcm = clip;
    pcm += bias;
    int exponent = 7;
    for (int expMask = 0x4000;
        (pcm & expMask) == 0 && exponent > 0;
        exponent--, expMask >>= 1) {}
    int mantissa = (pcm >> (exponent + 3)) & 0x0F;
    return (~(sign | (exponent << 4) | mantissa)) & 0xFF;
  }

  static int _ulawToLinear(int uVal) {
    uVal = (~uVal) & 0xFF;
    int t = ((uVal & 0x0F) << 3) + 0x84;
    t <<= (uVal & 0x70) >> 4;
    return ((uVal & 0x80) != 0) ? (0x84 - t) : (t - 0x84);
  }

  static Uint8List _encodePcm16kToUlaw8k(Uint8List pcm16k) {
    final samples16k = pcm16k.length ~/ 2;
    final out = Uint8List(samples16k ~/ 2);
    for (int i = 0; i < out.length; i++) {
      final b = i * 4;
      int s1 = pcm16k[b] | (pcm16k[b + 1] << 8);
      if (s1 >= 32768) s1 -= 65536;
      out[i] = _linearToUlaw(s1);
    }
    return out;
  }

  static Uint8List _decodeUlaw8kToPcm16k(Uint8List ulaw8k) {
    final out = Uint8List(ulaw8k.length * 4);
    int prev = 0;
    for (int i = 0; i < ulaw8k.length; i++) {
      final cur = _ulawToLinear(ulaw8k[i]);
      final mid = (prev + cur) >> 1;
      final b = i * 4;
      out[b] = mid & 0xFF;
      out[b + 1] = (mid >> 8) & 0xFF;
      out[b + 2] = cur & 0xFF;
      out[b + 3] = (cur >> 8) & 0xFF;
      prev = cur;
    }
    return out;
  }

  bool get _shouldUseRelayCallTransport {
    final ip = _activeCallPeerIp ??
        (activeCallPeerId != null ? _resolvePeerIp(activeCallPeerId!) : null);
    if (ip == null || ip.isEmpty) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastCallUdpRxMs > 0 && now - _lastCallUdpRxMs < 3500) return false;
    if (now - _callStartedMs < 2200) return false;
    return true;
  }

  void _sendDirectCallBinToPeer(String peerId, Uint8List encryptedPacket) {
    final line = jsonEncode({'call_bin': base64Encode(encryptedPacket)});
    for (final entry in _tcpPeers.entries) {
      if (entry.value == peerId) {
        _sendTcpLine(entry.key, line);
        return;
      }
    }
    for (final entry in _blePeers.entries) {
      if (entry.value == peerId) {
        unawaited(_sendBleLine(entry.key, line));
        return;
      }
    }
  }

  Future<Uint8List?> _buildEncryptedCallPacket(
      int type, int seq, int chunkIdx, int chunkTotal, Uint8List payload) async {
    final key = _activeCallMediaKey;
    if (key == null) return null;
    try {
      final nonce = Uint8List(12);
      final rng = Random.secure();
      for (int i = 0; i < 12; i++) {
        nonce[i] = rng.nextInt(256);
      }
      final box = await _cipher.encrypt(
        payload,
        secretKey: key,
        nonce: nonce,
      );
      final out = Uint8List(20 + box.cipherText.length + 16);
      out[0] = 0x4D; // 'M'
      out[1] = type;
      out[2] = (seq >> 24) & 0xFF;
      out[3] = (seq >> 16) & 0xFF;
      out[4] = (seq >> 8) & 0xFF;
      out[5] = seq & 0xFF;
      out[6] = chunkIdx & 0xFF;
      out[7] = chunkTotal & 0xFF;
      out.setRange(8, 20, nonce);
      out.setRange(20, 20 + box.cipherText.length, box.cipherText);
      out.setRange(20 + box.cipherText.length, out.length, box.mac.bytes);
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendCallUdpPacket(
      int type, int seq, int chunkIdx, int chunkTotal, Uint8List payload,
      {bool forceRelay = false}) async {
    final pid = activeCallPeerId;
    if (pid == null) return;
    final out = await _buildEncryptedCallPacket(
        type, seq, chunkIdx, chunkTotal, payload);
    if (out == null) return;

    final ip = _activeCallPeerIp ?? _resolvePeerIp(pid);
    final sock = _callUdpSocket;
    if (!forceRelay && sock != null && ip != null && ip.isNotEmpty) {
      try {
        sock.send(out, InternetAddress(ip), _activeCallPeerUdpPort);
      } catch (_) {}
    }
    if (forceRelay || _shouldUseRelayCallTransport) {
      _sendDirectCallBinToPeer(pid, out);
    }
  }

  void _tryParseStunResponse(Uint8List d) {
    if (d.length < 28 || d[0] != 0x01 || d[1] != 0x01) return;
    if (d[4] != 0x21 || d[5] != 0x12 || d[6] != 0xA4 || d[7] != 0x42) return;
    int off = 20;
    while (off + 4 <= d.length) {
      final attrType = (d[off] << 8) | d[off + 1];
      final attrLen = (d[off + 2] << 8) | d[off + 3];
      off += 4;
      if (off + attrLen > d.length) break;
      if ((attrType == 0x0020 || attrType == 0x0001) && attrLen >= 8 && d[off + 1] == 0x01) {
        int port = (d[off + 2] << 8) | d[off + 3];
        int b0 = d[off + 4], b1 = d[off + 5], b2 = d[off + 6], b3 = d[off + 7];
        if (attrType == 0x0020) {
          port ^= 0x2112;
          b0 ^= 0x21;
          b1 ^= 0x12;
          b2 ^= 0xA4;
          b3 ^= 0x42;
        }
        final ep = '$b0.$b1.$b2.$b3:$port';
        if (!_stunObservedEndpoints.contains(ep)) {
          _stunObservedEndpoints.add(ep);
          _addLog('[STUN] <- Ответ: $ep (всего уникальных: ${_stunObservedEndpoints.length})', triggerUi: false);
        }
        if (_stunPendingCompleter != null && !_stunPendingCompleter!.isCompleted) {
          _stunPendingCompleter!.complete(ep);
        }
        return;
      }
      off += (attrLen + 3) & ~3;
    }
  }

  Future<void> _onCallUdpDatagram(Datagram dg) async {
    final d = dg.data;
    if (d.isEmpty) return;
    // 0. Демультиплексирование Mainline DHT (KRPC bencode-словарь начинается с 0x64 'd')
    if (d[0] == 0x64) {
      _dhtClient.handleIncomingDatagram(dg);
      return;
    }
    // 1. Ответ STUN (RFC 5389 Binding Success Response 0x0101)
    if (d.length >= 28 && d[0] == 0x01 && d[1] == 0x01) {
      _tryParseStunResponse(d);
      return;
    }
    if (d.length >= 2 && d[0] == 0x4D) {
      // 2. Межрегиональный UDP Hole Punch / Keepalive (0x4D 0x05 + nodeId)
      if (d[1] == 0x05) {
        try {
          final remoteId = utf8.decode(d.sublist(2), allowMalformed: true).split('|').first.trim();
          if (remoteId.isNotEmpty && remoteId != nodeId) {
            final now = DateTime.now().millisecondsSinceEpoch;
            final prev = _remoteUdpPeers[remoteId];
            final wasAlive = prev != null && prev.lastSeenMs > 0 && (now - prev.lastSeenMs) < 15000;
            final newUdpAddr = 'udp:${dg.address.address}:${dg.port}';
            final addrChanged = prev == null || prev.ip != dg.address.address || prev.port != dg.port;
            _remoteUdpPeers[remoteId] = (
              ip: dg.address.address,
              port: dg.port,
              lastSeenMs: now,
            );
            _ensureUdpPeerPunchLoop();
            final c = knownContacts[remoteId];
            if (c != null) {
              c.isOnline = true;
              c.isDirectPeer = true;
              c.lastSeenTimestamp = now;
              if (c.lastAddress != newUdpAddr) {
                c.lastAddress = newUdpAddr;
              }
            }
            if (!wasAlive || addrChanged) {
              if (!wasAlive) {
                _addLog('[PUNCH] UDP-туннель открыт с $remoteId (${dg.address.address}:${dg.port})');
                _sendUdpHolePunch(dg.address.address, dg.port);
                _sendUdpMeshJson(dg.address.address, dg.port, _buildHelloJson());
                _sendUdpMeshJson(dg.address.address, dg.port, _buildPeerSyncJson());
                _sendUdpMeshJson(dg.address.address, dg.port, _buildChatHistorySyncForPeer(remoteId));
                _flushBufferedPacketsToOnlinePeers();
              }
              unawaited(_saveContactsAndChats());
              onStateChanged();
            }
          }
        } catch (_) {}
        return;
      }
      // 3. Межрегиональный зашифрованный Mesh-пакет поверх пробитого UDP (0x4D 0x06 + JSON)
      if (d[1] == 0x06) {
        try {
          final jsonLine = utf8.decode(d.sublist(2));
          final senderIp = dg.address.address;
          final senderPort = dg.port;
          final nowRx = DateTime.now().millisecondsSinceEpoch;
          for (final ent in _remoteUdpPeers.entries.toList()) {
            if (ent.value.ip == senderIp && ent.value.port == senderPort) {
              _remoteUdpPeers[ent.key] = (ip: senderIp, port: senderPort, lastSeenMs: nowRx);
              final kc = knownContacts[ent.key];
              if (kc != null) kc.lastSeenTimestamp = nowRx;
            }
          }
          await _processIncomingJsonLine(
            jsonLine,
            remoteAddr: '$senderIp:$senderPort',
            onHello: (peerId, peerNick) async {
              final nowMs = DateTime.now().millisecondsSinceEpoch;
              _remoteUdpPeers[peerId] = (
                ip: senderIp,
                port: senderPort,
                lastSeenMs: nowMs,
              );
              _ensureUdpPeerPunchLoop();
              final hc = knownContacts[peerId];
              if (hc != null) {
                hc.lastAddress = 'udp:$senderIp:$senderPort';
                hc.lastSeenTimestamp = nowMs;
                unawaited(_saveContactsAndChats());
              }
              _sendUdpMeshJson(senderIp, senderPort, _buildPeerSyncJson());
              _sendUdpMeshJson(senderIp, senderPort, _buildChatHistorySyncForPeer(peerId));
              _refreshOnlineStatuses();
              _flushBufferedPacketsToOnlinePeers();
              onStateChanged();
            },
            replyDirect: (replyJson) {
              _sendUdpMeshJson(senderIp, senderPort, replyJson);
            },
          );
        } catch (_) {}
        return;
      }
    }
    await _processEncryptedCallMediaBytes(d, dg.address.address, dg.port);
  }

  void _sendUdpHolePunch(String ip, int port) {
    final sock = _callUdpSocket;
    if (sock == null || ip.isEmpty || port <= 0 || ip.contains(':')) return;
    try {
      // Переменный паддинг (0..32 байт) против сигнатурной классификации фиксированных хендшейков
      final padLen = Random.secure().nextInt(33);
      final idBytes = utf8.encode('$nodeId|');
      final out = Uint8List(2 + idBytes.length + padLen);
      out[0] = 0x4D;
      out[1] = 0x05;
      out.setRange(2, 2 + idBytes.length, idBytes);
      if (padLen > 0) {
        final pad = _randomBytes(padLen);
        out.setRange(2 + idBytes.length, out.length, pad);
      }
      sock.send(out, InternetAddress(ip), port);
    } catch (e) {
      _addLog('[PUNCH] Ошибка отправки к $ip:$port: $e', triggerUi: false);
    }
  }

  void _sendUdpMeshJson(String ip, int port, String jsonLine) {
    final sock = _callUdpSocket;
    if (sock == null || ip.isEmpty || port <= 0 || ip.contains(':')) return;
    try {
      final body = utf8.encode(jsonLine);
      if (body.length > 60000) return;
      final out = Uint8List(2 + body.length);
      out[0] = 0x4D;
      out[1] = 0x06;
      out.setRange(2, out.length, body);
      sock.send(out, InternetAddress(ip), port);
    } catch (e) {
      _addLog('[UDP] Ошибка отправки Mesh-пакета к $ip:$port: $e', triggerUi: false);
    }
  }

  void _ensureUdpPeerPunchLoop() {
    if (_udpPeerPunchTimer != null) return;
    _udpPeerPunchTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_remoteUdpPeers.isEmpty) return;
      for (final entry in _remoteUdpPeers.entries.toList()) {
        _sendUdpHolePunch(entry.value.ip, entry.value.port);
      }
    });
  }

  Future<void> _processEncryptedCallMediaBytes(
      Uint8List data, String? fromIp, int fromPort) async {
    if (activeCallPeerId == null || !isCallAccepted) return;
    final key = _activeCallMediaKey;
    if (key == null) return;
    if (data.length < 36 || data[0] != 0x4D) return;
    final type = data[1];
    final seq = (data[2] << 24) | (data[3] << 16) | (data[4] << 8) | data[5];
    final chunkIdx = data[6];
    final chunkTotal = data[7];
    final nonce = data.sublist(8, 20);
    final ctLen = data.length - 36;
    final ct = data.sublist(20, 20 + ctLen);
    final macBytes = data.sublist(20 + ctLen);
    try {
      final plain = await _cipher.decrypt(
        SecretBox(ct, nonce: nonce, mac: Mac(macBytes)),
        secretKey: key,
      );
      if (fromIp != null && fromPort > 0) {
        _activeCallPeerIp = fromIp;
        _activeCallPeerUdpPort = fromPort;
        _lastCallUdpRxMs = DateTime.now().millisecondsSinceEpoch;
        if (activeCallTransport != 'Wi-Fi UDP') {
          activeCallTransport = 'Wi-Fi UDP';
          onStateChanged();
        }
      } else if (activeCallTransport != 'Bluetooth / Mesh') {
        activeCallTransport = 'Bluetooth / Mesh';
        onStateChanged();
      }

      if (type == 0x01 || type == 0x04) {
        if (seq > 0) {
          if (seq + 64 < _lastCallAudioRxSeq || _callAudioSeenSeqs.contains(seq)) {
            return;
          }
          _callAudioSeenSeqs.add(seq);
          if (seq > _lastCallAudioRxSeq) {
            _lastCallAudioRxSeq = seq;
            _callAudioSeenSeqs.removeWhere((k) => k + 64 < _lastCallAudioRxSeq);
          }
        }
        final rawBytes = Uint8List.fromList(plain);
        final pcm =
            (type == 0x04) ? _decodeUlaw8kToPcm16k(rawBytes) : rawBytes;
        // Оценка громкости входящего голоса для подавления эха (AES)
        int sumAbs = 0;
        final step = max(2, (pcm.length ~/ 32) & ~1);
        int cnt = 0;
        for (int i = 0; i + 1 < pcm.length; i += step) {
          int v = pcm[i] | (pcm[i + 1] << 8);
          if (v >= 32768) v -= 65536;
          sumAbs += v.abs();
          cnt++;
        }
        if (cnt > 0) {
          final avgAbs = sumAbs / cnt;
          if (avgAbs < _remoteNoiseFloor * 1.8) {
            _remoteNoiseFloor = (_remoteNoiseFloor * 0.92 + avgAbs * 0.08).clamp(80.0, 900.0);
          }
          if (avgAbs > 450 && avgAbs > _remoteNoiseFloor * 2.5) {
            _lastRemoteAudioRxMs = DateTime.now().millisecondsSinceEpoch;
            _remoteVoiceActive = true;
          }
        }
        // Мягкое усиление речи (+4 дБ с ограничителем, без клиппинга)
        final boosted = Uint8List(pcm.length);
        for (int i = 0; i + 1 < pcm.length; i += 2) {
          int v = pcm[i] | (pcm[i + 1] << 8);
          if (v >= 32768) v -= 65536;
          int s = (v * 16) ~/ 10;
          if (s > 32767) s = 32767;
          if (s < -32768) s = -32768;
          boosted[i] = s & 0xFF;
          boosted[i + 1] = (s >> 8) & 0xFF;
        }
        if (Platform.isAndroid) {
          unawaited(_nativeChannel.invokeMethod('playCallAudioPcm', boosted));
        } else if (Platform.isWindows) {
          WindowsPcmAudioBridge.playPcm(boosted);
        }
      } else if (type == 0x02 && chunkTotal > 0 && chunkIdx < chunkTotal) {
        if (seq <= _lastRenderedVideoSeq) return;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        _udpVideoAssemblies.removeWhere((_, v) => nowMs - v.createdMs > 700);
        final asm = _udpVideoAssemblies.putIfAbsent(
            seq, () => _UdpVideoAssembly(chunkTotal));
        if (asm.chunks[chunkIdx] == null) {
          asm.chunks[chunkIdx] = Uint8List.fromList(plain);
          asm.received++;
        }
        if (asm.received == asm.total) {
          final bb = BytesBuilder(copy: false);
          for (final c in asm.chunks) {
            if (c != null) bb.add(c);
          }
          remoteVideoFrameBytes = bb.takeBytes();
          _lastRenderedVideoSeq = seq;
          _udpVideoAssemblies.removeWhere((k, _) => k <= seq);
          onStateChanged();
        } else if (_udpVideoAssemblies.length > 8) {
          final oldestKey = _udpVideoAssemblies.keys.reduce(min);
          _udpVideoAssemblies.remove(oldestKey);
        }
      }
    } catch (_) {}
  }

  void _onLocalCapturedPcm(Uint8List pcm) {
    if (isPttTransmitting && activeCallPeerId == null) {
      final compressed = _encodePcm16kToUlaw8k(pcm);
      unawaited(_sendEncryptedPttChunk(compressed));
      return;
    }
    if (activeCallPeerId == null || !isCallAccepted || isCallMicMuted) return;
    // Адаптивное подавление эха на ПК (срабатывает ТОЛЬКО на реальную речь собеседника, не на тишину/шум кулера)
    // На Android используется аппаратный AEC VOICE_COMMUNICATION без программного глушения голоса!
    Uint8List outPcm = pcm;
    final nowAes = DateTime.now().millisecondsSinceEpoch;
    final sinceRemoteMs = nowAes - _lastRemoteAudioRxMs;
    if (Platform.isWindows) {
      if (_remoteVoiceActive && sinceRemoteMs < 320) {
        final att = Uint8List(pcm.length);
        for (int i = 0; i + 1 < pcm.length; i += 2) {
          int v = pcm[i] | (pcm[i + 1] << 8);
          if (v >= 32768) v -= 65536;
          final scaled = (v * 12) ~/ 100;
          att[i] = scaled & 0xFF;
          att[i + 1] = (scaled >> 8) & 0xFF;
        }
        outPcm = att;
      } else if (_remoteVoiceActive) {
        _remoteVoiceActive = false;
      }
    } else {
      if (_remoteVoiceActive && sinceRemoteMs >= 320) {
        _remoteVoiceActive = false;
      }
    }
    _callAudioSeq++;
    if (_shouldUseRelayCallTransport) {
      // 4x compression (8kHz u-law = 8 KB/s) for smooth Bluetooth/Nearby calls!
      final compressed = _encodePcm16kToUlaw8k(outPcm);
      unawaited(_sendCallUdpPacket(0x04, _callAudioSeq, 0, 1, compressed,
          forceRelay: true));
    } else {
      unawaited(_sendCallUdpPacket(0x01, _callAudioSeq, 0, 1, outPcm));
    }
  }

  void _onLocalCapturedVideoFrame(Uint8List jpeg) {
    if (activeCallPeerId == null ||
        !isCallAccepted ||
        activeCallMode != 'video' ||
        isCallVideoMuted ||
        jpeg.isEmpty) {
      return;
    }
    localVideoFrameBytes = jpeg;
    final nowUi = DateTime.now().millisecondsSinceEpoch;
    if (nowUi - _lastLocalPreviewUiMs >= 90) {
      _lastLocalPreviewUiMs = nowUi;
      onStateChanged();
    }
    if (_isSendingVideoFrame) return;
    final useRelay = _shouldUseRelayCallTransport;
    if (useRelay) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastBleVideoTxMs < 180) return;
      _lastBleVideoTxMs = now;
    }
    _isSendingVideoFrame = true;
    unawaited(_sendVideoFramePaced(jpeg, useRelay: useRelay));
  }

  Future<void> _sendVideoFramePaced(Uint8List jpeg,
      {bool useRelay = false}) async {
    try {
      _callVideoSeq++;
      final seq = _callVideoSeq;
      if (useRelay) {
        // Send single compact frame over BLE/TCP relay (avoid flooding BLE)
        if (jpeg.length <= 24000) {
          await _sendCallUdpPacket(0x02, seq, 0, 1, jpeg, forceRelay: true);
        }
        return;
      }
      const maxChunk = 1280;
      final total = (jpeg.length + maxChunk - 1) ~/ maxChunk;
      if (total <= 0 || total > 120) return;
      for (int i = 0; i < total; i++) {
        if (activeCallPeerId == null || !isCallAccepted || isCallVideoMuted) {
          break;
        }
        final start = i * maxChunk;
        final end = min(start + maxChunk, jpeg.length);
        final part = Uint8List.sublistView(jpeg, start, end);
        await _sendCallUdpPacket(0x02, seq, i, total, part);
        if ((i % 6) == 5) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }
    } finally {
      _isSendingVideoFrame = false;
    }
  }

  Future<void> toggleCallSpeaker() async {
    isCallSpeakerOn = !isCallSpeakerOn;
    if (Platform.isAndroid) {
      try {
        await _nativeChannel
            .invokeMethod('setCallSpeaker', {'enabled': isCallSpeakerOn});
        await webrtc.setSpeakerphone(isCallSpeakerOn);
      } catch (_) {}
    }
    onStateChanged();
  }

  // ==================== v2.0.0: РЕЖИМ РАЦИИ (PTT) ====================
  Future<void> _playPttBeep(bool isStart) async {
    if (!pttSoundsEnabled) return;
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('playPttSound', {'isStart': isStart});
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.playPttSound(isStart);
    }
  }

  Future<SecretKey?> _getOrDerivePeerPttKey(String peerId) async {
    final cached = _peerPttKeys[peerId];
    if (cached != null) return cached;
    final c = knownContacts[peerId];
    if (c == null || c.dhPubHex.isEmpty) return null;
    try {
      final peerPub = SimplePublicKey(_fromHex(c.dhPubHex), type: KeyPairType.x25519);
      final shared = await _x25519.sharedSecretKey(
        keyPair: _dhKeyPair,
        remotePublicKey: peerPub,
      );
      final pairIds = [nodeId, peerId]..sort();
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final derived = await hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('mayak-ptt-salt-v21'),
        info: utf8.encode('mayak-ptt-key|${pairIds[0]}|${pairIds[1]}'),
      );
      _peerPttKeys[peerId] = derived;
      return derived;
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendEncryptedPttChunk(Uint8List ulawBytes) async {
    final target = pttChannelTarget;
    final rng = Random.secure();
    final sentPeers = <String>{};
    Future<void> sendToPeer(String pid, void Function(String line) emitter) async {
      if (sentPeers.contains(pid)) return;
      if (target != 'ALL') {
        if (target.startsWith('group:')) {
          final gid = target.substring(6);
          final grp = groupChats[gid];
          if (grp == null || !grp.memberIds.contains(pid)) return;
        } else if (pid != target) {
          return;
        }
      }
      final key = await _getOrDerivePeerPttKey(pid);
      if (key == null) return;
      sentPeers.add(pid);
      final nonce = Uint8List(12);
      for (int i = 0; i < 12; i++) {
        nonce[i] = rng.nextInt(256);
      }
      final box = await _cipher.encrypt(ulawBytes, secretKey: key, nonce: nonce);
      final line = jsonEncode({
        'ptt_bin': base64Encode(box.cipherText),
        'n': base64Encode(nonce),
        'm': base64Encode(box.mac.bytes),
        'sn': nickname,
        'sid': nodeId,
        't': target,
      });
      emitter(line);
    }

    for (final entry in _tcpPeers.entries.toList()) {
      await sendToPeer(entry.value, (line) => _sendTcpLine(entry.key, line));
    }
    for (final entry in _blePeers.entries.toList()) {
      await sendToPeer(entry.value, (line) => unawaited(_sendBleLine(entry.key, line)));
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _remoteUdpPeers.entries.toList()) {
      if (entry.value.lastSeenMs > 0 && (nowMs - entry.value.lastSeenMs) < 25000) {
        await sendToPeer(entry.key, (line) => _sendUdpMeshJson(entry.value.ip, entry.value.port, line));
      }
    }
  }

  void _broadcastRawLineToPttTargets(String line) {
    final target = pttChannelTarget;
    for (final entry in _tcpPeers.entries.toList()) {
      if (target == 'ALL' || entry.value == target) {
        _sendTcpLine(entry.key, line);
      }
    }
    for (final entry in _blePeers.entries.toList()) {
      if (target == 'ALL' || entry.value == target) {
        unawaited(_sendBleLine(entry.key, line));
      }
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _remoteUdpPeers.entries.toList()) {
      if (entry.value.lastSeenMs > 0 && (nowMs - entry.value.lastSeenMs) < 25000) {
        if (target == 'ALL' || entry.value.ip.isNotEmpty && entry.key == target) {
          _sendUdpMeshJson(entry.value.ip, entry.value.port, line);
        }
      }
    }
  }

  void toggleWalkieTalkieMode({String? targetPeerId}) {
    if (targetPeerId != null) {
      pttChannelTarget = targetPeerId;
      isWalkieTalkieMode = true;
    } else {
      isWalkieTalkieMode = !isWalkieTalkieMode;
      if (!isWalkieTalkieMode && isPttTransmitting) {
        unawaited(stopPttTransmit());
      }
    }
    onStateChanged();
  }

  void setPttChannelTarget(String target) {
    pttChannelTarget = target;
    onStateChanged();
  }

  void setPttSoundsEnabled(bool v) {
    pttSoundsEnabled = v;
    onStateChanged();
  }

  void setPttAutoReceiveEnabled(bool v) {
    pttAutoReceiveEnabled = v;
    onStateChanged();
  }

  void setPttLatchMode(bool v) {
    pttLatchMode = v;
    if (!v && isPttTransmitting) {
      unawaited(stopPttTransmit());
    }
    onStateChanged();
  }

  Future<void> refreshWindowsCameras() async {
    if (!Platform.isWindows) return;
    try {
      const ps = r'''
$cams = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPClass -eq 'Camera' -or $_.PNPClass -eq 'Image' } | Select-Object -ExpandProperty Name
if ($cams) { $cams -join "`n" }
''';
      final res = await Process.run('powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps]);
      if (res.exitCode == 0) {
        final lines = res.stdout
            .toString()
            .split(RegExp(r'\r?\n'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        availableWinCameras = lines;
        onStateChanged();
      }
    } catch (_) {}
  }

  void setWindowsDeviceSelection({int? outId, int? inId, int? camIdx}) {
    WindowsPcmAudioBridge.setSelectedDevices(outId: outId, inId: inId);
    if (camIdx != null) selectedWinCameraIndex = camIdx;
    onStateChanged();
  }

  Future<void> requestAndroidOverlayCallPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod('requestOverlayCallPermission');
    } catch (_) {}
  }

  Future<bool> requestLocationPermissionForMap() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _nativeChannel
              .invokeMethod<bool>('requestLocationPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  List<Map<String, String>> getPttChannels() {
    final list = <Map<String, String>>[
      {'id': 'ALL', 'label': 'CH-00 • ОБЩИЙ ЭФИР', 'freq': '433.075 MHz'},
    ];
    int idx = 1;
    for (final c in knownContacts.values) {
      final f = (433.075 + idx * 0.025).toStringAsFixed(3);
      list.add({
        'id': c.nodeId,
        'label': 'CH-${idx.toString().padLeft(2, '0')} • ${c.displayTitle}',
        'freq': '$f MHz',
      });
      idx++;
    }
    for (final g in groupChats.values) {
      final f = (433.075 + idx * 0.025).toStringAsFixed(3);
      list.add({
        'id': 'group:${g.groupId}',
        'label': 'GRP • ${g.title}',
        'freq': '$f MHz',
      });
      idx++;
    }
    return list;
  }

  String get currentPttChannelLabel {
    final all = getPttChannels();
    for (final ch in all) {
      if (ch['id'] == pttChannelTarget) return ch['label']!;
    }
    return 'CH-00 • ОБЩИЙ ЭФИР';
  }

  String get currentPttChannelFreq {
    final all = getPttChannels();
    for (final ch in all) {
      if (ch['id'] == pttChannelTarget) return ch['freq']!;
    }
    return '433.075 MHz';
  }

  void cyclePttChannel(int delta) {
    final all = getPttChannels();
    if (all.isEmpty) return;
    int cur = all.indexWhere((c) => c['id'] == pttChannelTarget);
    if (cur < 0) cur = 0;
    final next = (cur + delta) % all.length;
    pttChannelTarget = all[next < 0 ? next + all.length : next]['id']!;
    unawaited(_playPttBeep(true));
    onStateChanged();
  }

  // ==================== v2.3.0: КАРТА УЗЛОВ, БАРОМЕТР И АНТИ-СПУФИНГ (РЭБ) ====================
  static double _haversineMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) *
            cos(lat2 * pi / 180.0) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return 2 * r * atan2(sqrt(a), sqrt(1 - a));
  }

  String formatRelativeHeightToPeer(PeerLocationRecord peer) {
    final me = myLocation;
    if (me != null && me.pressureHpa > 300 && peer.pressureHpa > 300) {
      final deltaM =
          44330.0 * (1.0 - pow(peer.pressureHpa / me.pressureHpa, 0.1903));
      final floors = (deltaM / 3.0).round();
      if (deltaM.abs() < 1.5) return 'На одном уровне (${peer.pressureHpa.toStringAsFixed(1)} hPa)';
      final sign = deltaM > 0 ? '+' : '';
      final flTxt = floors == 0
          ? ''
          : (floors > 0 ? ' • ~$floors эт. выше' : ' • ~${floors.abs()} эт. ниже');
      return '$sign${deltaM.toStringAsFixed(1)} м$flTxt';
    }
    if (peer.altMeters != 0) {
      return 'Высота: ${peer.altMeters.toStringAsFixed(0)} м';
    }
    return 'Высота н/д';
  }

  Future<void> fullShutdownAndExit() async {
    try {
      await _saveContactsAndChats();
    } catch (_) {}
    try {
      if (activeCallPeerId != null) {
        await endActiveCall();
      }
      await _stopCallMediaPipelines();
      await stopAudioPlayback();
    } catch (_) {}
    try {
      _winAudioProc?.kill();
    } catch (_) {}
    try {
      if (Platform.isAndroid) {
        await _nativeChannel.invokeMethod('stopNearby');
        await _nativeChannel.invokeMethod('stopBackgroundService');
      }
    } catch (_) {}
    try {
      for (final s in _tcpPeers.keys.toList()) {
        s.destroy();
      }
      _tcpPeers.clear();
      await _tcpServer?.close();
      await _tcpServerV6?.close();
      _callUdpSocket?.close();
    } catch (_) {}
  }

  Future<void> toggleLocationSharing() async {
    isLocationSharingEnabled = !isLocationSharingEnabled;
    onStateChanged();
    if (isLocationSharingEnabled) {
      unawaited(pollAndBroadcastLocation());
      _locationPollTimer?.cancel();
      _locationPollTimer = Timer.periodic(
        const Duration(seconds: 6),
        (_) => unawaited(pollAndBroadcastLocation()),
      );
    } else {
      _locationPollTimer?.cancel();
      _locationPollTimer = null;
      unawaited(_broadcastLocationStop());
    }
  }

  Future<void> setManualMapAnchor(double lat, double lon) async {
    final hpa = myLocation?.pressureHpa ?? 0.0;
    final alt = myLocation?.altMeters ?? 0.0;
    gpsSpoofingDetected = false;
    gpsSpoofingNote = 'Точка закреплена вручную (обход РЭБ)';
    myLocation = PeerLocationRecord(
      nodeId: nodeId,
      nickname: nickname,
      lat: lat,
      lon: lon,
      altMeters: alt,
      pressureHpa: hpa,
      isManualAnchor: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (isLocationSharingEnabled) {
      await _broadcastMyLocationPacket();
    }
    onStateChanged();
  }

  Future<void> pollAndBroadcastLocation() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (Platform.isAndroid) {
      try {
        final raw = await _nativeChannel
            .invokeMapMethod<String, dynamic>('getGeoAndBarometer');
        if (raw != null) {
          final hpa = (raw['hpa'] as num?)?.toDouble() ?? 0.0;
          if (raw['ok'] == true) {
            final lat = (raw['lat'] as num).toDouble();
            final lon = (raw['lon'] as num).toDouble();
            final alt = (raw['alt'] as num?)?.toDouble() ?? 0.0;

            // Анти-спуфинг фильтр (РЭБ / телепорт в другую страну)
            final prev = myLocation;
            if (prev != null && !prev.isManualAnchor) {
              final dtSec = max(1.0, (now - prev.updatedAt) / 1000.0);
              final distM = _haversineMeters(prev.lat, prev.lon, lat, lon);
              final speedMs = distM / dtSec;
              if (distM > 15000 && speedMs > 150.0) {
                gpsSpoofingDetected = true;
                gpsSpoofingNote =
                    'Заблокирован спуфинг GPS (скачок ${(distM / 1000).toStringAsFixed(0)} км). Используется последняя достоверная точка.';
                myLocation = PeerLocationRecord(
                  nodeId: nodeId,
                  nickname: nickname,
                  lat: prev.lat,
                  lon: prev.lon,
                  altMeters: prev.altMeters,
                  pressureHpa: hpa > 0 ? hpa : prev.pressureHpa,
                  isManualAnchor: prev.isManualAnchor,
                  updatedAt: now,
                );
                if (isLocationSharingEnabled) {
                  await _broadcastMyLocationPacket();
                }
                onStateChanged();
                return;
              }
            }
            if (prev == null || !prev.isManualAnchor) {
              gpsSpoofingDetected = false;
              myLocation = PeerLocationRecord(
                nodeId: nodeId,
                nickname: nickname,
                lat: lat,
                lon: lon,
                altMeters: alt,
                pressureHpa: hpa,
                isManualAnchor: false,
                updatedAt: now,
              );
            } else {
              // Обновляем барометр даже при ручном якоре
              myLocation = PeerLocationRecord(
                nodeId: nodeId,
                nickname: nickname,
                lat: prev.lat,
                lon: prev.lon,
                altMeters: prev.altMeters,
                pressureHpa: hpa > 0 ? hpa : prev.pressureHpa,
                isManualAnchor: true,
                updatedAt: now,
              );
            }
          } else if (myLocation != null && hpa > 0) {
            final prev = myLocation!;
            myLocation = PeerLocationRecord(
              nodeId: nodeId,
              nickname: nickname,
              lat: prev.lat,
              lon: prev.lon,
              altMeters: prev.altMeters,
              pressureHpa: hpa,
              isManualAnchor: prev.isManualAnchor,
              updatedAt: now,
            );
          }
        }
      } catch (_) {}
    }
    if (!Platform.isAndroid && (myLocation == null || !myLocation!.isManualAnchor)) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
        final req = await client.getUrl(Uri.parse('http://ip-api.com/json/?fields=status,lat,lon'));
        final resp = await req.close().timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final txt = await utf8.decoder.bind(resp).join();
          final j = jsonDecode(txt) as Map<String, dynamic>;
          if (j['status'] == 'success' && j['lat'] != null && j['lon'] != null) {
            myLocation = PeerLocationRecord(
              nodeId: nodeId,
              nickname: nickname,
              lat: (j['lat'] as num).toDouble(),
              lon: (j['lon'] as num).toDouble(),
              altMeters: 0.0,
              pressureHpa: 0.0,
              isManualAnchor: false,
              updatedAt: now,
            );
          }
        }
        client.close(force: true);
      } catch (_) {}
    }
    if (isLocationSharingEnabled && myLocation != null) {
      await _broadcastMyLocationPacket();
    }
    onStateChanged();
  }

  Future<void> _broadcastMyLocationPacket() async {
    final loc = myLocation;
    if (loc == null) return;
    final payload = utf8.encode(jsonEncode({
      'v': 2,
      'kind': 'LOC_UPDATE',
      'lat': loc.lat,
      'lon': loc.lon,
      'alt': loc.altMeters,
      'hpa': loc.pressureHpa,
      'man': loc.isManualAnchor,
      'nick': nickname,
      'ts': loc.updatedAt,
    }));
    for (final c in knownContacts.values.toList()) {
      if (!c.isOnline) continue;
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: c.nodeId,
        contact: c,
        msgId: 'loc_${nodeId}_${_randomHex(4)}',
        sealedPayloadBytes: payload,
        persistInOutbox: false,
        keepInTransitBuffer: false,
      );
    }
  }

  Future<void> _broadcastLocationStop() async {
    final payload = utf8.encode(jsonEncode({'v': 2, 'kind': 'LOC_STOP'}));
    for (final c in knownContacts.values.toList()) {
      if (!c.isOnline) continue;
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: c.nodeId,
        contact: c,
        msgId: 'locstop_${_randomHex(6)}',
        sealedPayloadBytes: payload,
        persistInOutbox: false,
        keepInTransitBuffer: false,
      );
    }
  }

  // ==================== v2.3.0: МЕЖРЕГИОНАЛЬНЫЙ РЕЖИМ (BETA) ====================
  Future<void> setCustomExternalEndpoint(String endpoint) async {
    customExternalEndpoint = endpoint.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mayak_ext_endpoint', customExternalEndpoint);
    } catch (_) {}
    onStateChanged();
  }

  Future<void> setInterRegionalBridgeMode(bool enabled) async {
    isInterRegionalBridgeEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mayak_bridge_mode', enabled);
    } catch (_) {}
    _addLog(enabled
        ? 'Межрегиональный Bridge-ретранслятор ВКЛ'
        : 'Межрегиональный Bridge-ретранслятор ВЫКЛ');
    onStateChanged();
  }

  Future<void> toggleAutoInterRegionalMode() async {
    await setAutoInterRegionalEnabled(!isAutoInterRegionalEnabled);
  }

  Future<void> setAutoInterRegionalEnabled(bool enabled) async {
    isAutoInterRegionalEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mayak_auto_interregional_v3', enabled);
    } catch (_) {}
    if (enabled) {
      if (discoveredExternalEndpoint.isEmpty && upnpExternalIp.isEmpty && globalIpv6Address.isEmpty) {
        await discoverExternalEndpointAuto(forceRefresh: true);
      } else {
        _refreshInterRegionalStatusText();
        onStateChanged();
      }
      if (isDhtDiscoveryEnabled) {
        unawaited(publishMyEndpointsToDht());
      }
    } else {
      _stunKeepaliveTimer?.cancel();
      interRegionalStatusText = 'Выключен';
      onStateChanged();
    }
  }

  Future<void> setDhtDiscoveryEnabled(bool enabled) async {
    isDhtDiscoveryEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('mayak_dht_enabled_v3', enabled);
    } catch (_) {}
    if (enabled && isAutoInterRegionalEnabled) {
      unawaited(publishMyEndpointsToDht());
    }
    onStateChanged();
  }

  Future<void> _initStaticIdAndDhtSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedNospamHex = prefs.getString('mayak_nospam_hex_v3');
      if (savedNospamHex != null && savedNospamHex.length == 8) {
        _myNospamBytes = _fromHex(savedNospamHex);
      } else {
        _myNospamBytes = _randomBytes(4);
        await prefs.setString('mayak_nospam_hex_v3', _toHex(_myNospamBytes));
      }
      if (signPubHex.length == 64) {
        myStaticMayakId = MayakStaticId.buildFromPubAndNospam(_fromHex(signPubHex), _myNospamBytes);
      }
      isDhtDiscoveryEnabled = prefs.getBool('mayak_dht_enabled_v3') ?? true;
      isAutoInterRegionalEnabled = prefs.getBool('mayak_auto_interregional_v3') ?? true;
      final cachedNodes = prefs.getStringList('mayak_dht_nodes_v3');
      if (cachedNodes != null && cachedNodes.isNotEmpty) {
        _dhtClient.importCachedNodes(cachedNodes);
      }
    } catch (_) {}
  }

  Future<void> rotateMyNospam() async {
    _myNospamBytes = _randomBytes(4);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mayak_nospam_hex_v3', _toHex(_myNospamBytes));
    } catch (_) {}
    if (signPubHex.length == 64) {
      myStaticMayakId = MayakStaticId.buildFromPubAndNospam(_fromHex(signPubHex), _myNospamBytes);
    }
    _addLog('Сменён nospam — старый ID для новых заявок отключён (старые друзья сохранены)');
    onStateChanged();
  }

  Future<({SimpleKeyPair slotKeyPair, Uint8List slotPub, Uint8List aeadKey, Uint8List salt})?> _derivePairDhtSlot({
    required ContactProfile contact,
    required bool isOutgoingFromMe,
    required int utcDayEpoch,
  }) async {
    if (contact.dhPubHex.length != 64 || contact.signPubHex.length != 64 || signPubHex.length != 64) {
      return null;
    }
    try {
      final peerDh = SimplePublicKey(_fromHex(contact.dhPubHex), type: KeyPairType.x25519);
      final shared = await _x25519.sharedSecretKey(keyPair: _dhKeyPair, remotePublicKey: peerDh);
      final senderSign = isOutgoingFromMe ? signPubHex : contact.signPubHex;
      final receiverSign = isOutgoingFromMe ? contact.signPubHex : signPubHex;
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final seedKey = await hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('mayak-dht-slot-v1'),
        info: utf8.encode('seed|$senderSign|$receiverSign|$utcDayEpoch'),
      );
      final seedBytes = await seedKey.extractBytes();
      final aeadKeyObj = await hkdf.deriveKey(
        secretKey: shared,
        nonce: utf8.encode('mayak-dht-slot-v1'),
        info: utf8.encode('aead|$senderSign|$receiverSign|$utcDayEpoch'),
      );
      final aeadBytes = Uint8List.fromList(await aeadKeyObj.extractBytes());
      final saltKeyObj = await Hkdf(hmac: Hmac.sha256(), outputLength: 8).deriveKey(
        secretKey: shared,
        nonce: utf8.encode('mayak-dht-slot-v1'),
        info: utf8.encode('salt|$senderSign|$receiverSign|$utcDayEpoch'),
      );
      final saltBytes = Uint8List.fromList(await saltKeyObj.extractBytes());
      final slotKp = await _ed25519.newKeyPairFromSeed(seedBytes);
      final slotPub = Uint8List.fromList((await slotKp.extractPublicKey()).bytes);
      return (slotKeyPair: slotKp, slotPub: slotPub, aeadKey: aeadBytes, salt: saltBytes);
    } catch (_) {
      return null;
    }
  }

  /// Публикация своих актуальных координат в приватных суточных слотах Mainline DHT (до 24 контактов)
  Future<int> publishMyEndpointsToDht() async {
    if (!isAutoInterRegionalEnabled || !isDhtDiscoveryEnabled) return 0;
    await _initCallUdpSocket();
    if (discoveredExternalEndpoint.isEmpty && globalIpv6Address.isEmpty) {
      await discoverExternalEndpointAuto();
    }
    if (discoveredExternalEndpoint.isEmpty && globalIpv6Address.isEmpty) return 0;

    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final dayEpoch = nowSec ~/ 86400;
    final epochs = <int>[dayEpoch];
    if ((nowSec % 86400) >= 22 * 3600) {
      epochs.add(dayEpoch + 1);
    }

    final payloadJson = jsonEncode({
      'v': 1,
      'u': discoveredExternalEndpoint,
      'v6': globalIpv6Address,
      'p': listenPort,
      'ts': nowSec,
    });
    final plainBytes = utf8.encode(payloadJson);

    int publishedContacts = 0;
    final targets = knownContacts.values.take(24).toList();
    for (final c in targets) {
      for (final ep in epochs) {
        final slot = await _derivePairDhtSlot(
          contact: c,
          isOutgoingFromMe: true,
          utcDayEpoch: ep,
        );
        if (slot == null) continue;
        final nonce = _randomBytes(12);
        final box = await _cipher.encrypt(
          plainBytes,
          secretKey: SecretKey(slot.aeadKey),
          nonce: nonce,
          aad: utf8.encode('$ep|$nowSec'),
        );
        final blob = Uint8List(12 + box.cipherText.length + 16);
        blob.setRange(0, 12, nonce);
        blob.setRange(12, 12 + box.cipherText.length, box.cipherText);
        blob.setRange(12 + box.cipherText.length, blob.length, box.mac.bytes);
        final stored = await _dhtClient.putMutable(
          slotKeyPair: slot.slotKeyPair,
          valueBytes: blob,
          seq: nowSec,
          salt: slot.salt,
        );
        if (stored > 0) publishedContacts++;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('mayak_dht_nodes_v3', _dhtClient.exportCachedNodes());
    } catch (_) {}
    _addLog('[DHT] Координаты обновлены в приватных слотах ($publishedContacts, узлов DHT: ${_dhtClient.knownNodesCount})', triggerUi: false);
    onStateChanged();
    return publishedContacts;
  }

  /// Автопоиск свежего IP:port друга в его приватном суточном слоте Mainline DHT + автозапуск пробивки!
  Future<bool> resolveContactEndpointFromDht(String peerId) async {
    if (!isAutoInterRegionalEnabled || !isDhtDiscoveryEnabled) return false;
    final contact = knownContacts[peerId];
    if (contact == null || isPeerDirectlyConnected(peerId)) return false;
    await _initCallUdpSocket();

    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final dayEpoch = nowSec ~/ 86400;
    final epochsToTry = <int>[dayEpoch];
    if ((nowSec % 86400) < 2 * 3600) {
      epochsToTry.add(dayEpoch - 1);
    }

    for (final ep in epochsToTry) {
      final slot = await _derivePairDhtSlot(
        contact: contact,
        isOutgoingFromMe: false,
        utcDayEpoch: ep,
      );
      if (slot == null) continue;
      final res = await _dhtClient.getMutable(pubKey32: slot.slotPub, salt: slot.salt);
      if (res == null || res.value.length <= 28) continue;
      try {
        final nonce = res.value.sublist(0, 12);
        final ct = res.value.sublist(12, res.value.length - 16);
        final mac = res.value.sublist(res.value.length - 16);
        final plain = await _cipher.decrypt(
          SecretBox(ct, nonce: nonce, mac: Mac(mac)),
          secretKey: SecretKey(slot.aeadKey),
          aad: utf8.encode('$ep|${res.seq}'),
        );
        final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        final extUdp = (map['u'] ?? '').toString().trim();
        final v6 = (map['v6'] ?? '').toString().trim();
        final tcpPort = (map['p'] as num?)?.toInt() ?? defaultTcpPort;

        bool triggered = false;
        if (extUdp.contains(':')) {
          final parsed = parseEndpoint(extUdp, defaultPort: 0);
          final uIp = parsed.host;
          final uPort = parsed.port;
          if (uIp.isNotEmpty && !uIp.contains(':') && uPort > 0) {
            _remoteUdpPeers[peerId] = (ip: uIp, port: uPort, lastSeenMs: 0);
            _ensureUdpPeerPunchLoop();
            for (int k = 0; k < 4; k++) {
              Future.delayed(Duration(milliseconds: k * 350), () {
                _sendUdpHolePunch(uIp, uPort);
                if (k == 1 || k == 3) {
                  _sendUdpMeshJson(uIp, uPort, _buildHelloJson());
                }
              });
            }
            _addLog('[DHT] Найден свежий адрес ${contact.displayTitle}: $uIp:$uPort -> старт пробивки!');
            triggered = true;
          }
        }
        if (v6.isNotEmpty && v6.contains(':')) {
          unawaited(connectToHost(v6, tcpPort, expectedNodeId: peerId, timeout: const Duration(seconds: 4), forceNewConnection: true));
          triggered = true;
        }
        if (triggered) {
          onStateChanged();
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  static bool _isPrivateOrCgnatIpv4(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? -1;
    final b = int.tryParse(p[1]) ?? -1;
    if (a == 10 || a == 127 || a == 0) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 100 && b >= 64 && b <= 127) return true; // RFC 6598 CGNAT!
    return false;
  }

  void _refreshInterRegionalStatusText() {
    final parts = <String>[];
    if (upnpPortMapped && upnpExternalIp.isNotEmpty) {
      if (_isPrivateOrCgnatIpv4(upnpExternalIp)) {
        parts.add('UPnP за CGNAT ($upnpExternalIp)');
      } else {
        parts.add('UPnP OK ($upnpExternalIp:$listenPort)');
      }
    }
    if (globalIpv6Address.isNotEmpty) {
      parts.add('IPv6 OK');
    }
    if (discoveredExternalEndpoint.isNotEmpty) {
      final isSym = _stunObservedEndpoints.length > 1;
      parts.add(isSym
          ? 'STUN: $discoveredExternalEndpoint (Sym NAT)'
          : 'STUN: $discoveredExternalEndpoint (Cone NAT)');
    }
    interRegionalStatusText = parts.isEmpty
        ? 'Нет внешнего адреса (проверь интернет)'
        : parts.join(' • ');
  }

  Future<void> _detectGlobalIpv6() async {
    globalIpv6Address = '';
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv6,
      );
      final foundSummary = <String>[];
      for (final iface in ifaces) {
        final low = iface.name.toLowerCase();
        if (low.contains('tun') || low.contains('vpn') || low.contains('wg')) continue;
        for (final addr in iface.addresses) {
          final ip = addr.address.split('%').first;
          foundSummary.add('${iface.name}=$ip');
          if ((ip.startsWith('2') || ip.startsWith('3')) && !ip.startsWith('fe80')) {
            globalIpv6Address = ip;
            _addLog('[IPv6] Найден глобальный адрес: $ip (${iface.name})', triggerUi: false);
            return;
          }
        }
      }
      _addLog('[IPv6] Глобальный IPv6 не найден (интерфейсов: ${foundSummary.length})', triggerUi: false);
    } catch (e) {
      _addLog('[IPv6] Ошибка проверки: $e', triggerUi: false);
    }
  }

  /// Компактный клиент NAT-PMP (RFC 6886, порт 5351) для роутеров MikroTik / Apple / ZyXEL
  Future<void> _tryNatPmpPortMapping() async {
    try {
      final lanIp = cachedIps.firstWhere(
        (ip) => ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.'),
        orElse: () => '',
      );
      if (lanIp.isEmpty) return;
      final parts = lanIp.split('.');
      if (parts.length != 4) return;
      final gw = InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.1');
      final sock = await RawDatagramSocket.bind(InternetAddress(lanIp), 0, reusePort: false);
      final extComp = Completer<String?>();
      sock.listen((ev) {
        if (ev == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg == null || dg.data.length < 12) return;
          final d = dg.data;
          // Ответ на запрос внешнего адреса (ver=0, opcode=128, result=0)
          if (d[0] == 0 && d[1] == 128 && d[2] == 0 && d[3] == 0 && !extComp.isCompleted) {
            extComp.complete('${d[8]}.${d[9]}.${d[10]}.${d[11]}');
          }
        }
      }, onError: (_) {});
      // 1. Запрос внешнего IPv4
      sock.send(Uint8List.fromList([0, 0]), gw, 5351);
      final extIp = await extComp.future
          .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
      if (extIp != null && extIp.isNotEmpty) {
        // 2. Проброс TCP (opcode=2) и UDP (opcode=1) на 3600с
        for (final pair in [(2, listenPort), (1, _callUdpListenPort)]) {
          final req = Uint8List(12);
          req[0] = 0;
          req[1] = pair.$1;
          req[4] = (pair.$2 >> 8) & 0xFF;
          req[5] = pair.$2 & 0xFF;
          req[6] = (pair.$2 >> 8) & 0xFF;
          req[7] = pair.$2 & 0xFF;
          req[10] = (3600 >> 8) & 0xFF;
          req[11] = 3600 & 0xFF;
          sock.send(req, gw, 5351);
        }
        upnpExternalIp = extIp;
        upnpPortMapped = true;
        _addLog('[NAT-PMP] Шлюз ${gw.address} открыл порты $listenPort/$_callUdpListenPort на $extIp', triggerUi: false);
      } else {
        _addLog('[NAT-PMP] Шлюз ${gw.address} не ответил на порт 5351', triggerUi: false);
      }
      sock.close();
    } catch (e) {
      _addLog('[NAT-PMP] Ошибка: $e', triggerUi: false);
    }
  }

  /// Автоматический UPnP-IGD: сам просит домашний роутер открыть TCP 42070 и UDP 42072 без ручных настроек!
  Future<void> _tryAutoUpnpPortMapping() async {
    upnpPortMapped = false;
    upnpExternalIp = '';
    try {
      final locCompleter = Completer<String?>();
      const ssdp = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n';
      final ssdpBytes = utf8.encode(ssdp);
      // Пер-интерфейсный SSDP: шлём отдельно с каждого физического LAN IPv4 (обходит VirtualBox/WSL/VPN на Windows!)
      final bindAddrs = <InternetAddress>[
        for (final ip in cachedIps)
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.'))
            InternetAddress(ip),
        InternetAddress.anyIPv4,
      ];
      final openSocks = <RawDatagramSocket>[];
      for (final ba in bindAddrs) {
        try {
          final s = await RawDatagramSocket.bind(ba, 0, reuseAddress: true, reusePort: false);
          openSocks.add(s);
          s.listen((ev) {
            if (ev == RawSocketEvent.read && !locCompleter.isCompleted) {
              final dg = s.receive();
              if (dg == null) return;
              final txt = utf8.decode(dg.data, allowMalformed: true);
              final m = RegExp(r'LOCATION:\s*(http[^\r\n]+)', caseSensitive: false)
                  .firstMatch(txt);
              if (m != null) locCompleter.complete(m.group(1)!.trim());
            }
          }, onError: (_) {});
          s.send(ssdpBytes, InternetAddress('239.255.255.250'), 1900);
        } catch (_) {}
      }
      final locUrl = await locCompleter.future
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      for (final s in openSocks) {
        try { s.close(); } catch (_) {}
      }
      if (locUrl == null) {
        _addLog('[UPnP] Роутер не ответил на SSDP, пробую NAT-PMP (порт 5351)...', triggerUi: false);
        await _tryNatPmpPortMapping();
        return;
      }
      _addLog('[UPnP] Найден шлюз: $locUrl', triggerUi: false);

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final descUri = Uri.parse(locUrl);
      final descReq = await client.getUrl(descUri);
      final descResp = await descReq.close().timeout(const Duration(seconds: 3));
      final xml = await utf8.decoder.bind(descResp).join();

      final srvMatch = RegExp(
        r'<serviceType>(urn:schemas-upnp-org:service:WAN(?:IP|PPP)Connection:\d+)</serviceType>[\s\S]*?<controlURL>([^<]+)</controlURL>',
        caseSensitive: false,
      ).firstMatch(xml);
      if (srvMatch == null) {
        _addLog('[UPnP] Сервис WANIP/WANPPP не найден в XML шлюза', triggerUi: false);
        client.close(force: true);
        return;
      }
      final srvType = srvMatch.group(1)!;
      final ctrlPath = srvMatch.group(2)!;
      final ctrlUri = descUri.resolve(ctrlPath);
      // Выбираем LAN IP строго из подсети /24 роутера (игнорируя VirtualBox 192.168.56.1 и Hotspot 192.168.137.1!)
      final gwParts = descUri.host.split('.');
      final gwPrefix = gwParts.length == 4 ? '${gwParts[0]}.${gwParts[1]}.${gwParts[2]}.' : '';
      String myLanIp = '';
      if (gwPrefix.isNotEmpty) {
        myLanIp = cachedIps.firstWhere((ip) => ip.startsWith(gwPrefix), orElse: () => '');
      }
      if (myLanIp.isEmpty && cachedIps.isNotEmpty) {
        myLanIp = cachedIps.first;
      }
      if (myLanIp.isEmpty) {
        _addLog('[UPnP] Нет локального LAN IP для проброса', triggerUi: false);
        client.close(force: true);
        return;
      }
      _addLog('[UPnP] Проброс портов $listenPort/$_callUdpListenPort на LAN $myLanIp (шлюз ${descUri.host})...', triggerUi: false);

      Future<String> soapCall(String action, String bodyXml) async {
        final env = '<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            '<s:Body><u:$action xmlns:u="$srvType">$bodyXml</u:$action></s:Body>'
            '</s:Envelope>';
        final payloadBytes = utf8.encode(env);
        final req = await client.postUrl(ctrlUri);
        // MiniUPnPd на роутерах рвёт Transfer-Encoding: chunked -> задаём точный Content-Length и Connection: close!
        req.contentLength = payloadBytes.length;
        req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
        req.headers.set('SOAPAction', '"$srvType#$action"');
        req.headers.set('Connection', 'close');
        req.add(payloadBytes);
        final r = await req.close().timeout(const Duration(seconds: 3));
        final respText = await utf8.decoder.bind(r).join();
        if (r.statusCode >= 400) {
          _addLog('[UPnP] $action HTTP ${r.statusCode}', triggerUi: false);
        }
        return respText;
      }

      // 1. Открываем TCP listenPort и UDP _callUdpListenPort (каждый вызов изолирован, чтобы сбой одного не ломал второй)
      try {
        await soapCall(
          'AddPortMapping',
          '<NewRemoteHost></NewRemoteHost>'
          '<NewExternalPort>$listenPort</NewExternalPort>'
          '<NewProtocol>TCP</NewProtocol>'
          '<NewInternalPort>$listenPort</NewInternalPort>'
          '<NewInternalClient>$myLanIp</NewInternalClient>'
          '<NewEnabled>1</NewEnabled>'
          '<NewPortMappingDescription>MayakP2P-TCP</NewPortMappingDescription>'
          '<NewLeaseDuration>3600</NewLeaseDuration>',
        );
      } catch (e) {
        _addLog('[UPnP] Ошибка TCP AddPortMapping: $e', triggerUi: false);
      }
      try {
        await soapCall(
          'AddPortMapping',
          '<NewRemoteHost></NewRemoteHost>'
          '<NewExternalPort>$_callUdpListenPort</NewExternalPort>'
          '<NewProtocol>UDP</NewProtocol>'
          '<NewInternalPort>$_callUdpListenPort</NewInternalPort>'
          '<NewInternalClient>$myLanIp</NewInternalClient>'
          '<NewEnabled>1</NewEnabled>'
          '<NewPortMappingDescription>MayakP2P-UDP</NewPortMappingDescription>'
          '<NewLeaseDuration>3600</NewLeaseDuration>',
        );
      } catch (e) {
        _addLog('[UPnP] Ошибка UDP AddPortMapping: $e', triggerUi: false);
      }
      // 2. Получаем внешний IP роутера
      final extXml = await soapCall('GetExternalIPAddress', '');
      final ipM = RegExp(r'<NewExternalIPAddress>([^<]+)</NewExternalIPAddress>')
          .firstMatch(extXml);
      if (ipM != null) {
        upnpExternalIp = ipM.group(1)!.trim();
        upnpPortMapped = true;
        _addLog('[UPnP] Успешно открыты TCP $listenPort и UDP $_callUdpListenPort на $upnpExternalIp', triggerUi: false);
      } else {
        _addLog('[UPnP] GetExternalIPAddress не вернул IP', triggerUi: false);
      }
      client.close(force: true);
    } catch (e) {
      _addLog('[UPnP] Ошибка: $e', triggerUi: false);
    }
  }

  /// Авто-настройка межрегиональной связи: российские + мировые STUN + UPnP-IGD + IPv6!
  Future<String> discoverExternalEndpointAuto({bool forceRefresh = false}) async {
    if (isDiscoveringExternalAddr) return discoveredExternalEndpoint;
    if (!forceRefresh && discoveredExternalEndpoint.isNotEmpty) {
      return discoveredExternalEndpoint;
    }
    isDiscoveringExternalAddr = true;
    interRegionalStatusText = 'Настройка (UPnP + IPv6 + РФ STUN)...';
    onStateChanged();
    try {
      await _initCallUdpSocket();
      await Future.wait([
        _detectGlobalIpv6(),
        _tryAutoUpnpPortMapping(),
      ]);

      final sock = _callUdpSocket;
      if (sock != null) {
        _stunObservedEndpoints.clear();
        _stunPendingCompleter = Completer<String?>();
        // Пул STUN под РФ и ОАЭ 2026: сначала нестандартные порты (443 / 19302), затем РФ
        final stunServers = [
          ('stun.nextcloud.com', 443),
          ('stun.l.google.com', 19302),
          ('stun1.l.google.com', 19302),
          ('stun.sipnet.ru', 3478),
          ('stun2.l.google.com', 19302),
        ];

        Future<void> sendStunToAll({bool verbose = true}) async {
          final rng = Random.secure();
          for (final srv in stunServers) {
            try {
              final reqBytes = Uint8List(20);
              reqBytes[0] = 0x00;
              reqBytes[1] = 0x01;
              reqBytes[4] = 0x21;
              reqBytes[5] = 0x12;
              reqBytes[6] = 0xA4;
              reqBytes[7] = 0x42;
              for (int i = 0; i < 12; i++) {
                reqBytes[8 + i] = rng.nextInt(256);
              }
              final addrs = await InternetAddress.lookup(srv.$1)
                  .timeout(const Duration(seconds: 2));
              bool sent = false;
              for (final a in addrs) {
                if (a.type == InternetAddressType.IPv4) {
                  sock.send(reqBytes, a, srv.$2);
                  sent = true;
                  if (verbose) {
                    _addLog('[STUN] -> ${srv.$1} (${a.address}:${srv.$2})', triggerUi: false);
                  }
                  break;
                }
              }
              if (!sent && verbose) {
                _addLog('[STUN] Нет IPv4 для ${srv.$1}', triggerUi: false);
              }
            } catch (e) {
              if (verbose) {
                _addLog('[STUN] Сбой ${srv.$1}: $e', triggerUi: false);
              }
            }
          }
        }

        await sendStunToAll(verbose: true);
        var found = await _stunPendingCompleter!.future
            .timeout(const Duration(seconds: 2), onTimeout: () => null);
        // Если на Windows _callUdpSocket (0.0.0.0:42072) не получил ответа (виртуальный адаптер / Firewall), пробуем эфемерный сокет на реальном LAN IP!
        if (found == null && cachedIps.isNotEmpty) {
          final realLan = cachedIps.firstWhere(
            (ip) => ip.startsWith('192.168.') && !ip.startsWith('192.168.56.') && !ip.startsWith('192.168.137.'),
            orElse: () => cachedIps.first,
          );
          if (realLan != '127.0.0.1') {
            try {
              final probeSock = await RawDatagramSocket.bind(InternetAddress(realLan), 0, reusePort: false);
              _addLog('[STUN] Fallback через LAN $realLan:${probeSock.port}...', triggerUi: false);
              probeSock.listen((ev) {
                if (ev == RawSocketEvent.read) {
                  final dg = probeSock.receive();
                  if (dg != null && dg.data.length >= 28 && dg.data[0] == 0x01 && dg.data[1] == 0x01) {
                    _tryParseStunResponse(dg.data);
                  }
                }
              }, onError: (_) {});
              final rng = Random.secure();
              for (final srv in stunServers.take(3)) {
                try {
                  final reqBytes = Uint8List(20);
                  reqBytes[0] = 0x00; reqBytes[1] = 0x01;
                  reqBytes[4] = 0x21; reqBytes[5] = 0x12; reqBytes[6] = 0xA4; reqBytes[7] = 0x42;
                  for (int i = 0; i < 12; i++) reqBytes[8 + i] = rng.nextInt(256);
                  final addrs = await InternetAddress.lookup(srv.$1).timeout(const Duration(seconds: 2));
                  for (final a in addrs) {
                    if (a.type == InternetAddressType.IPv4) {
                      probeSock.send(reqBytes, a, srv.$2);
                      break;
                    }
                  }
                } catch (_) {}
              }
              found = await _stunPendingCompleter!.future
                  .timeout(const Duration(seconds: 2), onTimeout: () => null);
              probeSock.close();
            } catch (e) {
              _addLog('[STUN] Fallback ошибка: $e', triggerUi: false);
            }
          }
        }
        if (found != null) {
          await Future.delayed(const Duration(milliseconds: 500));
        }

        final upnpIsPublic = upnpPortMapped &&
            upnpExternalIp.isNotEmpty &&
            !_isPrivateOrCgnatIpv4(upnpExternalIp);
        if (upnpIsPublic) {
          discoveredExternalEndpoint = '$upnpExternalIp:$_callUdpListenPort';
        } else if (found != null && found.isNotEmpty) {
          discoveredExternalEndpoint = found;
          if (upnpPortMapped && _isPrivateOrCgnatIpv4(upnpExternalIp)) {
            _addLog('[UPnP] Роутер за CGNAT ($upnpExternalIp) -> использую белый STUN $found', triggerUi: false);
          }
        } else if (upnpPortMapped && upnpExternalIp.isNotEmpty) {
          discoveredExternalEndpoint = '$upnpExternalIp:$_callUdpListenPort';
        }

        if (discoveredExternalEndpoint.isNotEmpty) {
          _stunKeepaliveTimer?.cancel();
          _stunKeepaliveTimer = Timer.periodic(const Duration(seconds: 18), (_) {
            if (isAutoInterRegionalEnabled || _remoteUdpPeers.isNotEmpty) {
              unawaited(sendStunToAll(verbose: false));
            }
          });
        }
      }
      _refreshInterRegionalStatusText();
      _addLog('Межрегион статус: $interRegionalStatusText');
    } catch (_) {
      interRegionalStatusText = 'Не удалось определить внешний адрес';
    } finally {
      isDiscoveringExternalAddr = false;
      onStateChanged();
    }
    return discoveredExternalEndpoint;
  }

  String buildInterRegionalInviteLink() {
    final upnpPublic = upnpExternalIp.isNotEmpty && !_isPrivateOrCgnatIpv4(upnpExternalIp);
    final stunIp = discoveredExternalEndpoint.isNotEmpty
        ? parseEndpoint(discoveredExternalEndpoint, defaultPort: 0).host
        : '';
    final ips = <String>[
      if (upnpPublic) upnpExternalIp,
      if (globalIpv6Address.isNotEmpty) globalIpv6Address,
      if (stunIp.isNotEmpty && stunIp != upnpExternalIp) stunIp,
      if (customExternalEndpoint.isNotEmpty) customExternalEndpoint,
      ...cachedIps,
    ];
    final map = {
      'id': nodeId,
      'dh': dhPubHex,
      'sg': signPubHex,
      'nick': nickname,
      'hw': myHwFingerprint,
      'os': myPlatformInfo,
      'p': listenPort,
      'ips': ips,
      if (discoveredExternalEndpoint.isNotEmpty) 'extUdp': discoveredExternalEndpoint,
    };
    return 'mayak://${base64Url.encode(utf8.encode(jsonEncode(map)))}';
  }

  Future<void> startPttTransmit() async {
    if (activeCallPeerId != null || isPttTransmitting) return;
    isPttTransmitting = true;
    onStateChanged();
    unawaited(_playPttBeep(true));
    if (Platform.isAndroid) {
      try {
        await _nativeChannel
            .invokeMethod('setCallSpeaker', {'enabled': true});
        await _nativeChannel.invokeMethod('startCallAudio');
        await _nativeChannel
            .invokeMethod('setCallAudioMuted', {'muted': false});
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.startFullDuplex(_onLocalCapturedPcm);
      WindowsPcmAudioBridge.setMicMuted(false);
    }
  }

  Future<void> stopPttTransmit() async {
    if (!isPttTransmitting) return;
    isPttTransmitting = false;
    final endLine = jsonEncode({
      'ptt_end': nodeId,
      'sn': nickname,
      't': pttChannelTarget,
    });
    _broadcastRawLineToPttTargets(endLine);
    if (activeCallPeerId == null) {
      if (Platform.isAndroid) {
        try {
          await _nativeChannel.invokeMethod('stopCallAudio');
        } catch (_) {}
      } else if (Platform.isWindows) {
        WindowsPcmAudioBridge.stopFullDuplex();
      }
    }
    await _playPttBeep(false);
    onStateChanged();
  }

  Future<void> _onIncomingPttChunk(Map<String, dynamic> map) async {
    if (activeCallPeerId != null || isPttTransmitting) return;
    final target = (map['t'] ?? 'ALL').toString();
    if (target != 'ALL' && target != nodeId) {
      if (target.startsWith('group:')) {
        final gid = target.substring(6);
        final grp = groupChats[gid];
        if (grp == null || !grp.memberIds.contains(nodeId)) return;
      } else {
        return;
      }
    }
    final b64 = (map['ptt_bin'] ?? '').toString();
    if (b64.isEmpty) return;
    final speaker = (map['sn'] ?? 'Узел').toString();
    final isFirst = pttActiveSpeakerName == null;
    pttActiveSpeakerName = speaker;
    if (isFirst) {
      unawaited(_playPttBeep(true));
      if (Platform.isAndroid) {
        try {
          await _nativeChannel
              .invokeMethod('setCallSpeaker', {'enabled': true});
          await _nativeChannel.invokeMethod('startCallAudio');
          await _nativeChannel
              .invokeMethod('setCallAudioMuted', {'muted': true});
        } catch (_) {}
      }
      onStateChanged();
    }
    try {
      Uint8List ulaw;
      final sid = (map['sid'] ?? '').toString();
      final nonceB64 = (map['n'] ?? '').toString();
      final macB64 = (map['m'] ?? '').toString();
      if (nonceB64.isNotEmpty && macB64.isNotEmpty && sid.isNotEmpty) {
        final key = await _getOrDerivePeerPttKey(sid);
        if (key == null) return;
        final plain = await _cipher.decrypt(
          SecretBox(
            base64Decode(b64),
            nonce: base64Decode(nonceB64),
            mac: Mac(base64Decode(macB64)),
          ),
          secretKey: key,
        );
        ulaw = Uint8List.fromList(plain);
      } else {
        return; // Reject unencrypted PTT chunks (v2.1.0 strict E2EE)
      }
      final pcm = _decodeUlaw8kToPcm16k(ulaw);
      if (Platform.isAndroid) {
        unawaited(_nativeChannel.invokeMethod('playCallAudioPcm', pcm));
      } else if (Platform.isWindows) {
        WindowsPcmAudioBridge.playPcm(pcm);
      }
    } catch (_) {}
    _pttRxTimeoutTimer?.cancel();
    _pttRxTimeoutTimer = Timer(const Duration(milliseconds: 1400), () {
      _finishIncomingPtt();
    });
  }

  void _finishIncomingPtt() {
    _pttRxTimeoutTimer?.cancel();
    if (pttActiveSpeakerName == null) return;
    pttActiveSpeakerName = null;
    if (activeCallPeerId == null && !isPttTransmitting) {
      if (Platform.isAndroid) {
        unawaited(_nativeChannel.invokeMethod('stopCallAudio'));
      } else if (Platform.isWindows) {
        WindowsPcmAudioBridge.stopFullDuplex();
      }
      unawaited(_playPttBeep(false));
    }
    onStateChanged();
  }

  Future<void> _startCallTonesOutgoing() async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('startOutgoingRingback');
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.startOutgoingRingback();
    }
  }

  Future<void> _stopCallTonesOutgoing() async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopOutgoingRingback');
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.stopTones();
    }
  }

  Future<void> _startIncomingRingtone({String caller = 'Узел Маяк', String mode = 'voice'}) async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('startIncomingRingtone');
        await _nativeChannel.invokeMethod('showIncomingCallFullScreen', {
          'caller': caller,
          'mode': mode,
        });
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.startIncomingRingtone();
    }
  }

  Future<void> _stopIncomingRingtone() async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopIncomingRingtone');
        await _nativeChannel.invokeMethod('cancelIncomingCallNotification');
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.stopTones();
    }
  }

  Future<void> _playCallEndTone() async {
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('playCallEndTone');
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.playCallEndTone();
    }
  }

  Future<void> _startWindowsVideoStreamer() async {
    await _stopWindowsVideoStreamer();
    if (!Platform.isWindows) return;
    try {
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _winVideoServer = srv;
      final localPort = srv.port;
      srv.listen((client) {
        final buf = <int>[];
        client.listen((chunk) {
          buf.addAll(chunk);
          while (buf.length >= 4) {
            final len =
                (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
            if (len <= 0 || len > 400000) {
              buf.clear();
              break;
            }
            if (buf.length < 4 + len) break;
            final frame = Uint8List.fromList(buf.sublist(4, 4 + len));
            buf.removeRange(0, 4 + len);
            _onLocalCapturedVideoFrame(frame);
          }
        }, onError: (_) {});
      }, onError: (_) {});

      final useCam = windowsVideoSource == 'camera' ? '1' : '0';
      // Без qedit.dll / DirectShow COM (которые вызывали падение и WerFault.exe / Dr.Web 500):
      // используем встроенный WinRT MediaCapture + MediaFrameReader + BitmapEncoder (JPEG)
      // и чистый Graphics.CopyFromScreen для показа экрана.
      final psScript = '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

function Await-WinRT(\$op, [Type]\$resultType) {
  \$m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and \$_.IsGenericMethod
  })[0].MakeGenericMethod(\$resultType)
  \$task = \$m.Invoke(\$null, @(\$op))
  \$task.Wait(5000) | Out-Null
  return \$task.Result
}
function Await-WinRTAction(\$op) {
  \$m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and -not \$_.IsGenericMethod
  })[0]
  \$task = \$m.Invoke(\$null, @(\$op))
  \$task.Wait(5000) | Out-Null
}

\$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { \$_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
\$epScr = New-Object System.Drawing.Imaging.EncoderParameters(1)
\$epScr.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, 58L)

\$tryCam = ($useCam -eq 1)
\$camIndex = $selectedWinCameraIndex
\$mediaCapture = \$null
\$frameReader = \$null
\$camOk = \$false

if (\$tryCam) {
  try {
    [void][Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType=WindowsRuntime]
    [void][Windows.Media.Capture.MediaCaptureInitializationSettings, Windows.Media.Capture, ContentType=WindowsRuntime]
    [void][Windows.Media.Capture.StreamingCaptureMode, Windows.Media.Capture, ContentType=WindowsRuntime]
    [void][Windows.Media.Capture.MediaCaptureMemoryPreference, Windows.Media.Capture, ContentType=WindowsRuntime]
    [void][Windows.Media.Capture.MediaCaptureSharingMode, Windows.Media.Capture, ContentType=WindowsRuntime]
    [void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    [void][Windows.Devices.Enumeration.DeviceClass, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapEncoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
    [void][Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType=WindowsRuntime]

    \$devs = Await-WinRT ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Devices.Enumeration.DeviceClass]::VideoCapture)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    if (\$devs -and \$devs.Count -gt 0) {
      \$idx = if (\$camIndex -ge 0 -and \$camIndex -lt \$devs.Count) { \$camIndex } else { 0 }
      \$dev = \$devs[\$idx]
      [Console]::Error.WriteLine("[CAM] Opening WinRT camera: " + \$dev.Name)
      \$settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
      \$settings.VideoDeviceId = \$dev.Id
      \$settings.StreamingCaptureMode = [Windows.Media.Capture.StreamingCaptureMode]::Video
      \$settings.MemoryPreference = [Windows.Media.Capture.MediaCaptureMemoryPreference]::Cpu
      \$settings.SharingMode = [Windows.Media.Capture.MediaCaptureSharingMode]::ExclusiveControl

      \$mediaCapture = New-Object Windows.Media.Capture.MediaCapture
      Await-WinRTAction (\$mediaCapture.InitializeAsync(\$settings))

      \$colorSource = \$null
      foreach (\$kv in \$mediaCapture.FrameSources) {
        if (\$kv.Value.Info.SourceKind -eq [Windows.Media.Capture.Frames.MediaFrameSourceKind]::Color) {
          \$colorSource = \$kv.Value
          break
        }
      }
      if (\$colorSource -ne \$null) {
        \$frameReader = Await-WinRT (\$mediaCapture.CreateFrameReaderAsync(\$colorSource, [Windows.Media.MediaProperties.MediaEncodingSubtypes]::Bgra8)) ([Windows.Media.Capture.Frames.MediaFrameReader])
        \$st = Await-WinRT (\$frameReader.StartAsync()) ([Windows.Media.Capture.Frames.MediaFrameReaderStartStatus])
        if (\$st -eq [Windows.Media.Capture.Frames.MediaFrameReaderStartStatus]::Success) {
          \$camOk = \$true
          [Console]::Error.WriteLine("[CAM] WinRT MediaFrameReader started OK")
        } else {
          [Console]::Error.WriteLine("[CAM] MediaFrameReader status: " + \$st)
        }
      } else {
        [Console]::Error.WriteLine("[CAM] No Color FrameSource found")
      }
    } else {
      [Console]::Error.WriteLine("[CAM] No video capture devices found")
    }
  } catch {
    [Console]::Error.WriteLine("[CAM] WinRT init error: " + \$_.Exception.Message)
    \$camOk = \$false
  }
}

try {
  \$tcp = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $localPort)
  \$ns = \$tcp.GetStream()
  \$emptyTicks = 0
  while (\$true) {
    \$sw = [System.Diagnostics.Stopwatch]::StartNew()
    \$jpg = \$null
    try {
      if (\$camOk -and \$frameReader -ne \$null) {
        \$frame = \$frameReader.TryAcquireLatestFrame()
        if (\$frame -ne \$null) {
          try {
            \$vmf = \$frame.VideoMediaFrame
            if (\$vmf -ne \$null -and \$vmf.SoftwareBitmap -ne \$null) {
              \$sb = \$vmf.SoftwareBitmap
              \$conv = \$null
              if (\$sb.BitmapPixelFormat -ne [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8 -or \$sb.BitmapAlphaMode -ne [Windows.Graphics.Imaging.BitmapAlphaMode]::Ignore) {
                \$conv = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(\$sb, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Ignore)
                \$sb = \$conv
              }
              \$ras = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
              \$enc = Await-WinRT ([Windows.Graphics.Imaging.BitmapEncoder]::CreateAsync([Windows.Graphics.Imaging.BitmapEncoder]::JpegEncoderId, \$ras)) ([Windows.Graphics.Imaging.BitmapEncoder])
              \$enc.SetSoftwareBitmap(\$sb)
              \$enc.BitmapTransform.ScaledWidth = 480
              \$enc.BitmapTransform.ScaledHeight = [uint32]([Math]::Max(180, [Math]::Min(360, [Math]::Round(\$sb.PixelHeight * (480.0 / [Math]::Max(1, \$sb.PixelWidth))))))
              Await-WinRTAction (\$enc.FlushAsync())
              \$sz = [uint32]\$ras.Size
              if (\$sz -gt 0 -and \$sz -lt 350000) {
                \$ras.Seek(0)
                \$dr = New-Object Windows.Storage.Streams.DataReader(\$ras.GetInputStreamAt(0))
                [void](Await-WinRT (\$dr.LoadAsync(\$sz)) ([uint32]))
                \$bytes = New-Object byte[] \$sz
                \$dr.ReadBytes(\$bytes)
                \$jpg = \$bytes
                \$dr.Dispose()
              }
              \$ras.Dispose()
              if (\$conv -ne \$null) { \$conv.Dispose() }
            }
          } finally {
            \$frame.Dispose()
          }
        }
        if (\$jpg -eq \$null) {
          \$emptyTicks++
          if (\$emptyTicks -gt 40) {
            [Console]::Error.WriteLine("[CAM] No frames from camera -> fallback to screen")
            \$camOk = \$false
          }
        } else {
          \$emptyTicks = 0
        }
      }
      if (-not \$camOk) {
        \$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        \$scr = New-Object System.Drawing.Bitmap(\$b.Width, \$b.Height)
        \$g1 = [System.Drawing.Graphics]::FromImage(\$scr)
        \$g1.CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
        \$dst = New-Object System.Drawing.Bitmap(512, 288)
        \$g2 = [System.Drawing.Graphics]::FromImage(\$dst)
        \$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
        \$g2.DrawImage(\$scr, 0, 0, 512, 288)
        \$ms = New-Object System.IO.MemoryStream
        \$dst.Save(\$ms, \$jpegCodec, \$epScr)
        \$jpg = \$ms.ToArray()
        \$ms.Dispose(); \$g2.Dispose(); \$dst.Dispose(); \$g1.Dispose(); \$scr.Dispose()
      }
    } catch {
      if (\$camOk) {
        [Console]::Error.WriteLine("[CAM] Frame error: " + \$_.Exception.Message)
        \$camOk = \$false
      }
    }
    if (\$jpg -ne \$null -and \$jpg.Length -gt 0) {
      \$n = \$jpg.Length
      \$hdr = [byte[]]@((\$n -shr 24) -band 255, (\$n -shr 16) -band 255, (\$n -shr 8) -band 255, \$n -band 255)
      \$ns.Write(\$hdr, 0, 4)
      \$ns.Write(\$jpg, 0, \$n)
      \$ns.Flush()
    }
    \$sleepMs = 85 - [int]\$sw.ElapsedMilliseconds
    if (\$sleepMs -gt 10) { Start-Sleep -Milliseconds \$sleepMs }
  }
} catch {
} finally {
  try { if (\$frameReader -ne \$null) { Await-WinRTAction (\$frameReader.StopAsync()); \$frameReader.Dispose() } } catch {}
  try { if (\$mediaCapture -ne \$null) { \$mediaCapture.Dispose() } } catch {}
  try { if (\$ns -ne \$null) { \$ns.Dispose() } } catch {}
  try { if (\$tcp -ne \$null) { \$tcp.Dispose() } } catch {}
}
''';

      final scriptFile = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}mayak_win_video.ps1');
      final psBytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(psScript)];
      await scriptFile.writeAsBytes(psBytes, flush: true);

      final proc = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptFile.path,
        ],
        workingDirectory: Directory.systemTemp.path,
      );
      _winVideoProcess = proc;
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.trim().isNotEmpty) {
          _addLog(line.trim(), triggerUi: false);
        }
      });
    } catch (e) {
      _addLog('[CAM] Не удалось запустить видеопоток Windows: $e');
    }
  }

  Future<void> _stopWindowsVideoStreamer() async {
    try {
      _winVideoProcess?.kill();
    } catch (_) {}
    _winVideoProcess = null;
    try {
      await _winVideoServer?.close();
    } catch (_) {}
    _winVideoServer = null;
  }

  Future<void> _sendWebRtcSignal(
      String targetNodeId, String kind, Map<String, dynamic> payload) async {
    final contact = knownContacts[targetNodeId];
    if (contact == null) return;
    if (kind == 'WEBRTC_OFFER' || kind == 'WEBRTC_ANSWER') {
      final rawJson = jsonEncode(payload);
      const chunkLen = 360;
      final sid = _randomHex(6);
      final total = (rawJson.length / chunkLen).ceil().clamp(1, 64);
      for (int i = 0; i < total; i++) {
        final start = i * chunkLen;
        final end = min(start + chunkLen, rawJson.length);
        final partEnv = jsonEncode({
          'v': 2,
          'kind': 'WEBRTC_SDP_PART',
          'sid': sid,
          'sk': kind,
          'idx': i,
          'tot': total,
          'd': rawJson.substring(start, end),
        });
        await _encryptAndQueueSealedDataPacket(
          targetNodeId: targetNodeId,
          contact: contact,
          msgId: '${sid}_sdp_$i',
          sealedPayloadBytes: utf8.encode(partEnv),
          keepInTransitBuffer: false,
          persistInOutbox: false,
          skipPadding: true,
        );
        if (total > 1) {
          await Future.delayed(const Duration(milliseconds: 12));
        }
      }
      return;
    }
    final env = jsonEncode({'v': 2, 'kind': kind, ...payload});
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: targetNodeId,
      contact: contact,
      msgId: _randomHex(10),
      sealedPayloadBytes: utf8.encode(env),
      keepInTransitBuffer: false,
      persistInOutbox: false,
      skipPadding: true,
    );
  }

  Future<void> _startCallMediaPipelines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      defaultDisappearingSeconds = prefs.getInt('mayak_disappear_sec') ?? 0;
      customExternalEndpoint = prefs.getString('mayak_ext_endpoint') ?? '';
      isInterRegionalBridgeEnabled = prefs.getBool('mayak_bridge_mode') ?? false;
    } catch (_) {}
    _disappearingSweeper?.cancel();
    _disappearingSweeper =
        Timer.periodic(const Duration(seconds: 5), (_) => _sweepExpiredMessages());
    await _initCallUdpSocket();
    _udpVideoAssemblies.clear();
    _lastRenderedVideoSeq = -1;
    _callAudioSeq = 0;
    _callVideoSeq = 0;
    _lastCallAudioRxSeq = 0;
    _callAudioSeenSeqs.clear();
    _callStartedMs = DateTime.now().millisecondsSinceEpoch;
    _lastCallUdpRxMs = 0;
    activeCallTransport =
        (_activeCallPeerIp != null && _activeCallPeerIp!.isNotEmpty)
            ? 'Wi-Fi UDP'
            : 'Bluetooth / Mesh';

    // 1. Нативный WebRTC (libwebrtc M144+: C++ CaptureSinkFilter без qedit.dll, Camera2, AEC3/NS/AGC2, WGC)
    final peerId = activeCallPeerId;
    if (peerId != null) {
      activeCallTransport = 'WebRTC P2P';
      if (Platform.isAndroid) {
        try {
          await _nativeChannel.invokeMethod('setCallSpeaker', {'enabled': isCallSpeakerOn});
        } catch (_) {}
      }
      await webrtc.startSession(
        isCaller: _isCallInitiator,
        isVideo: activeCallMode == 'video',
        useScreenOnWindows: windowsVideoSource == 'screen',
        startMicMuted: isCallMicMuted,
        startVideoMuted: isCallVideoMuted,
        sendSignal: (kind, payload) => _sendWebRtcSignal(peerId, kind, payload),
      );
      if (Platform.isAndroid) {
        await webrtc.setSpeakerphone(isCallSpeakerOn);
      }
    }

    // 3. UDP keepalive / NAT punch каждые 1.5с
    _udpPunchTimer?.cancel();
    void sendPunch() {
      unawaited(_sendCallUdpPacket(0x03, 0, 0, 1, Uint8List.fromList([1, 8, 0])));
    }
    sendPunch();
    Future.delayed(const Duration(milliseconds: 250), sendPunch);
    _udpPunchTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (_) => sendPunch());
  }

  Future<void> _stopCallMediaPipelines() async {
    _udpPunchTimer?.cancel();
    _udpPunchTimer = null;
    _udpVideoAssemblies.clear();
    _incomingSdpParts.clear();
    await webrtc.disposeSession();
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopCallAudio');
      } catch (_) {}
      try {
        await _nativeChannel.invokeMethod('stopCallCamera');
      } catch (_) {}
    } else if (Platform.isWindows) {
      WindowsPcmAudioBridge.stopFullDuplex();
      await _stopWindowsVideoStreamer();
    }
  }

  Future<void> _sendCallStateSync() async {
    final pid = activeCallPeerId;
    if (pid == null) return;
    final contact = knownContacts[pid];
    if (contact == null) return;
    final payload = jsonEncode({
      'v': 2,
      'kind': 'CALL_STATE',
      'micMuted': isCallMicMuted,
      'videoMuted': isCallVideoMuted,
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

  Future<void> toggleCallMicMute() async {
    isCallMicMuted = !isCallMicMuted;
    webrtc.setMicMuted(isCallMicMuted);
    unawaited(_sendCallStateSync());
    onStateChanged();
  }

  Future<void> toggleCallVideoMute() async {
    if (activeCallMode != 'video') return;
    isCallVideoMuted = !isCallVideoMuted;
    webrtc.setVideoMuted(isCallVideoMuted);
    unawaited(_sendCallStateSync());
    onStateChanged();
  }

  Future<void> switchCallCameraOrSource() async {
    if (activeCallMode != 'video' || isCallVideoMuted) return;
    if (Platform.isAndroid) {
      isCallFrontCamera = !isCallFrontCamera;
      await webrtc.switchCamera();
    } else if (Platform.isWindows) {
      windowsVideoSource =
          windowsVideoSource == 'camera' ? 'screen' : 'camera';
      if (isCallAccepted) {
        unawaited(webrtc.switchWindowsVideoSource(windowsVideoSource == 'screen'));
      }
    }
    onStateChanged();
  }

  Future<void> startLiveCall(String peerId, String mode) async {
    final contact = knownContacts[peerId];
    if (contact == null) return;
    await _initCallUdpSocket();
    await _stopIncomingRingtone();
    await _stopCallMediaPipelines();

    _isCallInitiator = true;
    activeCallPeerId = peerId;
    activeCallMode = mode;
    isCallAccepted = false;
    isCallMicMuted = false;
    isCallVideoMuted = (mode != 'video');
    remoteCallMicMuted = false;
    remoteCallVideoMuted = (mode != 'video');
    remoteVideoFrameBytes = null;
    localVideoFrameBytes = null;
    _activeCallId = _randomHex(12);
    _activeCallPeerIp = _resolvePeerIp(peerId);
    _activeCallPeerUdpPort = _remoteUdpPeers[peerId]?.port ?? callMediaUdpPort;
    _activeCallMediaKey = await _deriveCallMediaKey(peerId, _activeCallId);

    callStatusText = mode == 'video'
        ? 'Вызов ВЧ (Видеочат)...'
        : 'Вызов ГЧ (Голосовой чат)...';

    await _startCallTonesOutgoing();

    final payload = jsonEncode({
      'v': 2,
      'kind': 'CALL_INVITE',
      'mode': mode,
      'nick': nickname,
      'callId': _activeCallId,
      'udpPort': _callUdpListenPort,
    });
    if (!_tcpPeers.containsValue(peerId) && contact.lastAddress.isNotEmpty) {
      final ep = parseEndpoint(contact.lastAddress, defaultPort: defaultTcpPort);
      if (ep.host.isNotEmpty && ep.port > 0) {
        if (ep.isUdp) {
          _sendUdpHolePunch(ep.host, ep.port);
          _ensureUdpPeerPunchLoop();
        } else {
          unawaited(connectToHost(ep.host, ep.port, expectedNodeId: peerId, forceNewConnection: true));
        }
      }
    }
    final inviteBytes = utf8.encode(payload);
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: peerId,
      contact: contact,
      msgId: _randomHex(12),
      sealedPayloadBytes: inviteBytes,
      persistInOutbox: false,
      keepInTransitBuffer: false,
    );
    // Надёжный повтор вызова через 450мс (на случай сонного TCP-сокета ПК/телефона)
    final savedCallId = _activeCallId;
    Future.delayed(const Duration(milliseconds: 450), () {
      if (activeCallPeerId == peerId && !isCallAccepted && _activeCallId == savedCallId) {
        unawaited(_encryptAndQueueSealedDataPacket(
          targetNodeId: peerId,
          contact: contact,
          msgId: _randomHex(12),
          sealedPayloadBytes: inviteBytes,
          persistInOutbox: false,
          keepInTransitBuffer: false,
        ));
      }
    });
    onStateChanged();
  }

  Future<void> acceptIncomingCall() async {
    final pid = incomingCallFromPeerId;
    if (pid == null) return;
    await _initCallUdpSocket();
    await _stopIncomingRingtone();
    await _stopCallTonesOutgoing();

    _isCallInitiator = false;
    final contact = knownContacts[pid];
    activeCallPeerId = pid;
    activeCallMode = incomingCallMode;
    isCallAccepted = true;
    isCallMicMuted = false;
    isCallVideoMuted = (activeCallMode != 'video');
    remoteCallMicMuted = false;
    remoteCallVideoMuted = (activeCallMode != 'video');
    remoteVideoFrameBytes = null;
    localVideoFrameBytes = null;
    _activeCallId = _incomingCallId.isNotEmpty ? _incomingCallId : _randomHex(12);
    _activeCallPeerIp = _resolvePeerIp(pid);
    _activeCallPeerUdpPort = _incomingCallUdpPort;
    _activeCallMediaKey = await _deriveCallMediaKey(pid, _activeCallId);
    incomingCallFromPeerId = null;

    callStatusText = activeCallMode == 'video'
        ? 'ВЧ активен (HD Видео + Голос)'
        : 'ГЧ активен (Голос)';

    if (contact != null) {
      final payload = jsonEncode({
        'v': 2,
        'kind': 'CALL_ACCEPT',
        'mode': activeCallMode,
        'callId': _activeCallId,
        'udpPort': _callUdpListenPort,
      });
      final acceptBytes = utf8.encode(payload);
      await _encryptAndQueueSealedDataPacket(
        targetNodeId: pid,
        contact: contact,
        msgId: _randomHex(12),
        sealedPayloadBytes: acceptBytes,
        persistInOutbox: false,
        keepInTransitBuffer: false,
      );
      Future.delayed(const Duration(milliseconds: 350), () {
        if (activeCallPeerId == pid && isCallAccepted) {
          unawaited(_encryptAndQueueSealedDataPacket(
            targetNodeId: pid,
            contact: contact,
            msgId: _randomHex(12),
            sealedPayloadBytes: acceptBytes,
            persistInOutbox: false,
            keepInTransitBuffer: false,
          ));
        }
      });
    }
    await _startCallMediaPipelines();
    onStateChanged();
  }

  Future<void> rejectIncomingCall() async {
    final pid = incomingCallFromPeerId;
    incomingCallFromPeerId = null;
    await _stopIncomingRingtone();
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
          keepInTransitBuffer: false,
        );
      }
    }
    onStateChanged();
  }

  Future<void> endActiveCall({bool notifyPeer = true}) async {
    final pid = activeCallPeerId;
    activeCallPeerId = null;
    isCallAccepted = false;
    isCallMicMuted = false;
    isCallVideoMuted = false;
    remoteCallMicMuted = false;
    remoteCallVideoMuted = false;
    remoteVideoFrameBytes = null;
    localVideoFrameBytes = null;
    _activeCallMediaKey = null;
    _activeCallId = '';
    callStatusText = '';

    await _stopCallTonesOutgoing();
    await _stopIncomingRingtone();
    await _stopCallMediaPipelines();
    await _playCallEndTone();

    if (notifyPeer && pid != null) {
      final contact = knownContacts[pid];
      if (contact != null) {
        final payloadBytes = utf8.encode(jsonEncode({'v': 2, 'kind': 'CALL_END'}));
        Future<void> sendEndOnce() async {
          await _encryptAndQueueSealedDataPacket(
            targetNodeId: pid,
            contact: contact,
            msgId: _randomHex(12),
            sealedPayloadBytes: payloadBytes,
            persistInOutbox: false,
            keepInTransitBuffer: false,
          );
        }
        await sendEndOnce();
        Future.delayed(const Duration(milliseconds: 250), () => unawaited(sendEndOnce()));
        Future.delayed(const Duration(milliseconds: 600), () => unawaited(sendEndOnce()));
      }
    }
    onStateChanged();
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

    // Проверяем кэш по fileId (если путь в msg.filePath устарел после обновления)
    try {
      final cacheDir = await _getInternalCacheFilesDir();
      if (await cacheDir.exists()) {
        await for (final ent in cacheDir.list()) {
          if (ent is File && ent.path.contains(msg.msgId) && !ent.path.endsWith('.part')) {
            msg.filePath = ent.path;
            msg.isMediaRevealed = true;
            msg.isDownloading = false;
            msg.transferProgress = 1.0;
            await _saveContactsAndChats();
            onStateChanged();
            return;
          }
        }
      }
    } catch (_) {}

    final oldAsm = _incomingFiles.remove(msg.msgId);
    if (oldAsm != null) {
      try { await oldAsm.openRaf?.close(); } catch (_) {}
    }
    if (msg.text.contains('(удалён отправителем)')) {
      msg.isDownloading = false;
      msg.transferProgress = 0.0;
      onStateChanged();
      return;
    }
    final pullTargetId = msg.senderId == nodeId ? msg.peerId : msg.senderId;
    final contact = knownContacts[pullTargetId];
    if (contact == null) {
      _addLog('Отправитель файла не найден в списке контактов');
      return;
    }
    final udpPeer = _remoteUdpPeers[pullTargetId];
    if (udpPeer != null) {
      _sendUdpHolePunch(udpPeer.ip, udpPeer.port);
      _ensureUdpPeerPunchLoop();
    } else if (contact.lastAddress.startsWith('udp:')) {
      final ep = parseEndpoint(contact.lastAddress, defaultPort: 0);
      if (ep.host.isNotEmpty && !ep.host.contains(':') && ep.port > 0) {
        _remoteUdpPeers[pullTargetId] = (ip: ep.host, port: ep.port, lastSeenMs: DateTime.now().millisecondsSinceEpoch);
        _sendUdpHolePunch(ep.host, ep.port);
        _ensureUdpPeerPunchLoop();
      }
    }
    _addLog('[FILE] Запрос скачивания fid=${msg.msgId} (${msg.fileName ?? "?"}) у ${contact.displayTitle} (direct=${isPeerDirectlyConnected(pullTargetId)}, udp=${_remoteUdpPeers.containsKey(pullTargetId)}, tcp=${_tcpPeers.containsValue(pullTargetId)})');
    msg.isDownloading = true;
    msg.transferProgress = 0.02;
    onStateChanged();

    _downloadWatchdogTimers.remove(msg.msgId)?.cancel();
    _downloadWatchdogTimers[msg.msgId] = Timer(const Duration(seconds: 12), () {
      _downloadWatchdogTimers.remove(msg.msgId);
      if (msg.isDownloading && msg.transferProgress <= 0.03) {
        msg.isDownloading = false;
        msg.transferProgress = 0.0;
        _addLog('Таймаут скачивания «${msg.fileName ?? msg.msgId}» — нет ответа от отправителя');
        onStateChanged();
      }
    });

    final reqId = _randomHex(12);
    final reqPayload = jsonEncode({
      'v': 2,
      'kind': 'FILE_PULL_REQ',
      'fid': msg.msgId,
      'nick': nickname,
    });
    await _encryptAndQueueSealedDataPacket(
      targetNodeId: pullTargetId,
      contact: contact,
      msgId: reqId,
      sealedPayloadBytes: utf8.encode(reqPayload),
      keepInTransitBuffer: false,
      persistInOutbox: false,
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
    _revokedFileIds.add(targetMsgId);
    final streamKey = '${targetMsgId}_$chatId';
    _activeFileStreamGen[streamKey] = (_activeFileStreamGen[streamKey] ?? 0) + 1;
    offeredFileCatalog.remove(targetMsgId);
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
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    debugLogs.insert(0, '[$ts] $msg');
    if (debugLogs.length > 400) {
      debugLogs.removeLast();
    }
    lastStatusLog = msg;
    if (triggerUi) onStateChanged();
  }

  void clearDebugLogs() {
    debugLogs.clear();
    _addLog('[DIAG] Журнал очищен пользователем');
  }

  String buildFullDiagnosticReport() {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final sb = StringBuffer();
    sb.writeln('=== MAYAK DIAGNOSTIC REPORT (v3.1.0) ===');
    sb.writeln('Time: ${now.toIso8601String()}');
    sb.writeln('Platform: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})');
    sb.writeln('NodeId: $nodeId | Nick: $nickname');
    sb.writeln('VPN detected: $vpnDetected | Local IPs: ${cachedIps.join(", ")}');
    sb.writeln('TCP4 Server: ${_tcpServer != null ? "LISTEN :$listenPort" : "OFF"}');
    sb.writeln('TCP6 Server: ${_tcpServerV6 != null ? "LISTEN :$listenPort" : "OFF"}');
    sb.writeln('UDP Call/Mesh Socket: ${_callUdpSocket != null ? "OPEN :$_callUdpListenPort" : "OFF"}');
    sb.writeln('InterRegional Enabled: $isAutoInterRegionalEnabled | DHT Enabled: $isDhtDiscoveryEnabled (nodes: ${_dhtClient.knownNodesCount})');
    sb.writeln('Static Mayak-ID: ${myStaticMayakId.isEmpty ? "-" : myStaticMayakId}');
    sb.writeln('InterRegional Status: $interRegionalStatusText');
    sb.writeln('UPnP Mapped: $upnpPortMapped | UPnP Ext IP: ${upnpExternalIp.isEmpty ? "-" : upnpExternalIp}');
    sb.writeln('Global IPv6: ${globalIpv6Address.isEmpty ? "-" : globalIpv6Address}');
    sb.writeln('STUN Endpoint: ${discoveredExternalEndpoint.isEmpty ? "-" : discoveredExternalEndpoint}');
    sb.writeln('STUN Observed (${_stunObservedEndpoints.length}): ${_stunObservedEndpoints.join(", ")}');
    sb.writeln('Active TCP peers: ${_tcpPeers.length} | BLE peers: ${_blePeers.length} | Remote UDP peers: ${_remoteUdpPeers.length}');
    sb.writeln('Buffered outbox: ${myPersistentOutbox.length} | transit: ${transitBuffer.length}');
    sb.writeln('');
    sb.writeln('--- CONTACTS (${knownContacts.length}) ---');
    for (final c in knownContacts.values) {
      final hasTcp = _tcpPeers.containsValue(c.nodeId);
      final hasBle = _blePeers.containsValue(c.nodeId);
      final udp = _remoteUdpPeers[c.nodeId];
      final ageSec = c.lastSeenTimestamp > 0 ? ((nowMs - c.lastSeenTimestamp) / 1000).toStringAsFixed(1) : 'never';
      final udpInfo = udp == null
          ? 'no'
          : '${udp.ip}:${udp.port} (age=${udp.lastSeenMs > 0 ? ((nowMs - udp.lastSeenMs) / 1000).toStringAsFixed(1) : "never"}s)';
      sb.writeln(
          '• ${c.nodeId} (${c.nickname}): online=${c.isOnline} direct=${c.isDirectPeer} tcp=$hasTcp ble=$hasBle udp=$udpInfo lastAddr=${c.lastAddress} lastSeen=${ageSec}s');
    }
    sb.writeln('');
    sb.writeln('--- RECENT LOGS (newest first, up to 250) ---');
    for (final line in debugLogs.take(250)) {
      sb.writeln(line);
    }
    sb.writeln('=== END REPORT ===');
    return sb.toString();
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
        case 'onCallAudioPcm':
          final pcm = call.arguments as Uint8List?;
          if (pcm != null && pcm.isNotEmpty) {
            _onLocalCapturedPcm(pcm);
          }
          break;
        case 'onCallVideoFrame':
          final jpg = call.arguments as Uint8List?;
          if (jpg != null && jpg.isNotEmpty) {
            _onLocalCapturedVideoFrame(jpg);
          }
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
      _deduplicatePersistedContacts();
    } catch (e) {
      _addLog('Ошибка инициализации хранилища: $e');
    }

    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('acquireMulticastLock');
        await _nativeChannel.invokeMethod('bindProcessToWifiForLan');
        unawaited(_nativeChannel.invokeMethod('requestNotificationPermission').catchError((_) {}));
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
    try {
      _tcpServerV6 = await ServerSocket.bind(
        InternetAddress.anyIPv6,
        listenPort,
        v6Only: true,
        shared: true,
      );
      _tcpServerV6!.listen(_setupTcpSocket, onError: (_) {});
    } catch (_) {}

    await _initCallUdpSocket();
    await refreshNetworkCache(force: true);
    await _startLanAutoDiscovery();
    await _initStaticIdAndDhtSettings();
    if (isAutoInterRegionalEnabled) {
      unawaited(discoverExternalEndpointAuto(forceRefresh: true).then((_) {
        if (isDhtDiscoveryEnabled) {
          unawaited(publishMyEndpointsToDht());
        }
      }));
    }
    _dhtRepublishTimer?.cancel();
    _dhtRepublishTimer = Timer.periodic(const Duration(minutes: 50), (_) {
      if (isAutoInterRegionalEnabled && isDhtDiscoveryEnabled) {
        unawaited(publishMyEndpointsToDht());
      }
    });
    _watchdogMono
      ..reset()
      ..start();
    _lastWatchdogWallMs = DateTime.now().millisecondsSinceEpoch;
    _sleepWatchdogTimer?.cancel();
    _sleepWatchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final wallDelta = nowMs - _lastWatchdogWallMs;
      final monoDelta = _watchdogMono.elapsedMilliseconds;
      _lastWatchdogWallMs = nowMs;
      _watchdogMono
        ..reset()
        ..start();
      if ((wallDelta - monoDelta).abs() > 30000) {
        _addLog('[SYS] Обнаружен выход из сна — обновляю сеть и координаты...', triggerUi: false);
        unawaited(refreshNetworkCache(force: true));
        if (isAutoInterRegionalEnabled) {
          unawaited(discoverExternalEndpointAuto(forceRefresh: true).then((_) {
            if (isDhtDiscoveryEnabled) unawaited(publishMyEndpointsToDht());
          }));
        }
      }
    });
    _onlineReconnectWatchdog?.cancel();
    _onlineReconnectTicks = 0;
    _onlineReconnectWatchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      _onlineReconnectTicks++;
      final changed = _refreshOnlineStatuses();
      if (changed) onStateChanged();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_onlineReconnectTicks == 1 || _onlineReconnectTicks % 2 == 0) {
        for (final c in knownContacts.values.toList()) {
          if (isPeerDirectlyConnected(c.nodeId)) continue;
          if (c.lastAddress.startsWith('udp:')) {
            final ep = parseEndpoint(c.lastAddress, defaultPort: 0);
            final ip = ep.host;
            final port = ep.port;
            if (ip.isNotEmpty && !ip.contains(':') && port > 0) {
              _sendUdpHolePunch(ip, port);
              if (_onlineReconnectTicks == 1 || _onlineReconnectTicks % 4 == 0) {
                _sendUdpMeshJson(ip, port, _buildHelloJson());
              }
            }
          }
          if (isAutoInterRegionalEnabled && isDhtDiscoveryEnabled) {
            final lastLookup = _lastDhtAutoLookupMs[c.nodeId] ?? 0;
            if (_onlineReconnectTicks == 1 || (nowMs - lastLookup) > 45000) {
              _lastDhtAutoLookupMs[c.nodeId] = nowMs;
              unawaited(resolveContactEndpointFromDht(c.nodeId));
            }
          }
        }
      }
    });

    if (Platform.isWindows) unawaited(_cleanupWindowsOldUpdateFiles());
    _addLog('Защищенный узел v$currentAppVersion готов (порт $listenPort)');

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
            if (transitBuffer.length >= maxTransitBufferSize) {
        transitBuffer.remove(transitBuffer.keys.first);
      }
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
    return jsonEncode({
      'peer_sync': const [],
      'dht_pex': _dhtClient.exportActiveNodes(limit: 20),
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
            lower.contains('virtualbox') ||
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

          // VirtualBox Host-Only (192.168.56.*) и Windows Hotspot (192.168.137.*) всегда в конец списка!
          final isVirtualSub = ip.startsWith('192.168.56.') || ip.startsWith('192.168.137.');
          if (ip.startsWith('192.168.') && !isVirtualSub) {
            if (!preferredLan.contains(ip)) preferredLan.add(ip);
          } else {
            if (!fallbackLan.contains(ip)) fallbackLan.add(ip);
          }
        }
      }
    } catch (_) {}

    vpnDetected = detectedVpnInterface;
    if (Platform.isAndroid && (detectedVpnInterface || cachedIps.isNotEmpty)) {
      unawaited(_nativeChannel.invokeMethod('bindProcessToWifiForLan').catchError((_) {}));
    }
    final result = [...preferredLan, ...fallbackLan];
    if (result.isEmpty) result.add('127.0.0.1');
    return result;
  }

  Future<String?> connectWithInviteOrIp(String rawInput) async {
    var input = rawInput.trim();
    if (input.isEmpty) return null;
    if (input.startsWith('mayak://')) {
      input = input.substring(8).trim();
    }

    // Поддержка IPv4, DNS-доменов (DDNS для межрегиональной связи) и IPv6 в скобках
    final hostPortRegex = RegExp(
        r'^(?:\[([0-9a-fA-F:]+)\]|([a-zA-Z0-9.-]+\.[a-zA-Z0-9-]+))(?::(\d+))?$');
    final match = hostPortRegex.firstMatch(input);
    if (match != null && !input.contains('=') && input.length < 120) {
      final host = match.group(1) ?? match.group(2)!;
      final port = int.tryParse(match.group(3) ?? '') ?? defaultTcpPort;
      _addLog('Прямое P2P-подключение к $host:$port...');
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
      markOnline: false,
    );

    final extUdp = (decoded['extUdp'] ?? '').toString().trim();
    if (extUdp.contains(':')) {
      final parsed = parseEndpoint(extUdp, defaultPort: 0);
      final uIp = parsed.host;
      final uPort = parsed.port;
      if (uIp.isNotEmpty && !uIp.contains(':') && uPort > 0) {
        await _initCallUdpSocket();
        _remoteUdpPeers[targetId] = (
          ip: uIp,
          port: uPort,
          lastSeenMs: 0,
        );
        _ensureUdpPeerPunchLoop();
        // Серия UDP Hole Punch + веер соседних портов (пробивает Cone NAT и последовательный Symmetric NAT!)
        for (int k = 0; k < 4; k++) {
          Future.delayed(Duration(milliseconds: k * 350), () {
            _sendUdpHolePunch(uIp, uPort);
            if (k == 1 || k == 3) {
              _sendUdpMeshJson(uIp, uPort, _buildHelloJson());
              for (int delta = -2; delta <= 8; delta++) {
                if (delta != 0 && uPort + delta > 1024 && uPort + delta < 65535) {
                  _sendUdpHolePunch(uIp, uPort + delta);
                }
              }
            }
          });
        }
        // Синхронное UTC-рандеву: дополнительный выровненный залп на ближайшей границе 30с окна UTC (:00 / :30)
        final nowUtcMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        final waitToSlotMs = 30000 - (nowUtcMs % 30000);
        if (waitToSlotMs > 1500 && waitToSlotMs <= 30000) {
          for (final off in [0, 250, 500, 1000, 2000]) {
            Future.delayed(Duration(milliseconds: waitToSlotMs + off), () {
              if (!isPeerDirectlyConnected(targetId)) {
                _sendUdpHolePunch(uIp, uPort);
                if (off == 250 || off == 1000) {
                  _sendUdpMeshJson(uIp, uPort, _buildHelloJson());
                }
              }
            });
          }
          _addLog('[PUNCH] Старт UDP Hole Punch + UTC-рандеву через ${(waitToSlotMs / 1000).toStringAsFixed(1)}с к $uIp:$uPort');
        } else {
          _addLog('[PUNCH] Старт UDP Hole Punch + Hello к $uIp:$uPort (target=$targetId)');
        }
      }
    }
    _addLog('[INVITE] Кандидаты TCP для $targetId: ${candidateIps.join(", ")} (port=$port, extUdp=$extUdp)');
    for (final ip in candidateIps) {
      final isLan = ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.');
      unawaited(connectToHost(
        ip,
        port,
        expectedNodeId: targetId,
        timeout: isLan ? const Duration(seconds: 2) : const Duration(seconds: 4),
        forceNewConnection: true,
      ));
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
      final exePath = Platform.resolvedExecutable;
      final udpPorts = _callUdpListenPort != 42072 ? '42072,$_callUdpListenPort' : '42072';
      final cmdArgs =
          '/c netsh advfirewall firewall delete rule name="Mayak P2P App" >nul 2>&1 & '
          'netsh advfirewall firewall add rule name="Mayak P2P App" dir=in action=allow program="$exePath" enable=yes profile=public,private,domain edge=yes & '
          'netsh advfirewall firewall delete rule name="Mayak P2P TCP 42070" >nul 2>&1 & '
          'netsh advfirewall firewall delete rule name="Mayak P2P UDP 42069" >nul 2>&1 & '
          'netsh advfirewall firewall add rule name="Mayak P2P TCP 42070" dir=in action=allow protocol=TCP localport=42070,42071 profile=public,private,domain edge=yes & '
          'netsh advfirewall firewall add rule name="Mayak P2P UDP 42069" dir=in action=allow protocol=UDP localport=42069 profile=public,private,domain edge=yes & '
          'netsh advfirewall firewall delete rule name="Mayak P2P Call Media UDP 42072" >nul 2>&1 & '
          'netsh advfirewall firewall add rule name="Mayak P2P Call Media UDP 42072" dir=in action=allow protocol=UDP localport=$udpPorts profile=public,private,domain edge=yes';

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

  Future<void> _ensureWinMediaAudioPlayer() async {
    if (!Platform.isWindows || _winAudioProc != null) return;
    try {
      const psAudio = r'''
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
$player = New-Object System.Windows.Media.MediaPlayer
$dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$script:isPlaying = $false
$script:loadedPath = ""

$player.Add_MediaEnded({
    $script:isPlaying = $false
    [Console]::Out.WriteLine('{"ended":true,"playing":false,"pos":0,"dur":0}')
    [Console]::Out.Flush()
})
$player.Add_MediaFailed({
    param($s, $e)
    $script:isPlaying = $false
    $msg = if ($e.ErrorException) { $e.ErrorException.Message } else { "MediaFailed" }
    [Console]::Out.WriteLine('{"ended":true,"playing":false,"pos":0,"dur":0,"err":' + ($msg | ConvertTo-Json) + '}')
    [Console]::Out.Flush()
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    if ($script:isPlaying) {
        $pos = [int]$player.Position.TotalMilliseconds
        $dur = if ($player.NaturalDuration.HasTimeSpan) { [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds } else { 1000 }
        [Console]::Out.WriteLine("{`"ended`":false,`"playing`":true,`"pos`":$pos,`"dur`":$dur}")
        [Console]::Out.Flush()
    }
})
$timer.Start()

$reader = [System.Threading.Tasks.Task]::Run([Action]{
    while ($true) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) {
            $dispatcher.Invoke([Action]{ $dispatcher.InvokeShutdown() })
            break
        }
        $cmdLine = $line
        $dispatcher.Invoke([Action]{
            if ($cmdLine.StartsWith("LOAD64|")) {
                $p = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cmdLine.Substring(7)))
                $player.Stop()
                $player.Open([Uri]::new($p))
                $player.Play()
                $script:loadedPath = $p
                $script:isPlaying = $true
            } elseif ($cmdLine.StartsWith("LOAD|")) {
                $p = $cmdLine.Substring(5)
                $player.Stop()
                $player.Open([Uri]::new($p))
                $player.Play()
                $script:loadedPath = $p
                $script:isPlaying = $true
            } elseif ($cmdLine -eq "PAUSE") {
                $player.Pause()
                $script:isPlaying = $false
            } elseif ($cmdLine -eq "PLAY") {
                $player.Play()
                $script:isPlaying = $true
            } elseif ($cmdLine.StartsWith("SEEK|")) {
                $ms = [double]$cmdLine.Substring(5)
                $player.Position = [TimeSpan]::FromMilliseconds($ms)
            } elseif ($cmdLine -eq "STOP") {
                $player.Stop()
                $player.Close()
                $script:isPlaying = $false
                $script:loadedPath = ""
            } elseif ($cmdLine -eq "QUIT") {
                $player.Stop()
                $player.Close()
                $dispatcher.InvokeShutdown()
            }
        })
    }
})

[System.Windows.Threading.Dispatcher]::Run()
''';
      final tmpPs = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}mayak_wpf_audio.ps1');
      await tmpPs.writeAsString(psAudio, flush: true);
      final proc = await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-STA',
          '-File',
          tmpPs.path,
        ],
        workingDirectory: Directory.systemTemp.path,
      );
      _winAudioProc = proc;
      _winAudioSub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        try {
          final map = jsonDecode(line) as Map<String, dynamic>;
          if (map['err'] != null) {
            _addLog('[AUDIO] Windows MediaPlayer ошибка: ${map['err']}');
          }
          if (map['ended'] == true) {
            currentlyPlayingAudioPath = null;
            isAudioPlaying = false;
            audioPositionMs = 0;
            onStateChanged();
            return;
          }
          if (currentlyPlayingAudioPath != null) {
            audioPositionMs = (map['pos'] as num?)?.toInt() ?? audioPositionMs;
            final d = (map['dur'] as num?)?.toInt() ?? 0;
            if (d > 0) audioDurationMs = d;
            isAudioPlaying = map['playing'] == true;
            onStateChanged();
          }
        } catch (_) {}
      });
      unawaited(proc.exitCode.then((_) {
        if (_winAudioProc == proc) {
          _winAudioProc = null;
        }
      }));
    } catch (_) {}
  }

  Future<void> togglePlayAudioFile(String filePath) async {
    final lower = filePath.toLowerCase();
    final isLegacyM4a = lower.endsWith('.m4a') || lower.endsWith('.aac');
    if (Platform.isWindows || !isLegacyM4a) {
      if (Platform.isAndroid) {
        try { await _nativeChannel.invokeMethod('stopAudioFile'); } catch (_) {}
      }
      await soloudPlayer.togglePlayFile(filePath);
      return;
    }
    if (Platform.isAndroid) {
      await soloudPlayer.stop();
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
    }
  }

  Future<void> seekAudioFile(int newPositionMs) async {
    final targetMs = newPositionMs.clamp(0, audioDurationMs);
    audioPositionMs = targetMs;
    onStateChanged();
    if (soloudPlayer.currentPath != null) {
      await soloudPlayer.seek(targetMs);
      return;
    }
    if (Platform.isAndroid) {
      await _nativeChannel
          .invokeMethod('seekAudioFile', {'positionMs': targetMs});
    }
  }

  Future<void> stopAudioPlayback() async {
    _audioProgressTimer?.cancel();
    await soloudPlayer.stop();
    currentlyPlayingAudioPath = null;
    isAudioPlaying = false;
    audioPositionMs = 0;
    if (Platform.isAndroid) {
      try {
        await _nativeChannel.invokeMethod('stopAudioFile');
      } catch (_) {}
    }
    onStateChanged();
  }

  void _startAudioProgressPolling() {
    _audioProgressTimer?.cancel();
    if (!Platform.isAndroid) return;
    _audioProgressTimer =
        Timer.periodic(const Duration(milliseconds: 300), (_) async {
      if (currentlyPlayingAudioPath == null) {
        _audioProgressTimer?.cancel();
        return;
      }
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
    String persistentPath = filePath;
    if (totalSize <= 25 * 1024 * 1024) {
      try {
        final cacheDir = _cachedFilesDir ??= await _getInternalCacheFilesDir();
        final cachedCopyPath = '${cacheDir.path}/${fileId}_$cleanFileName';
        if (filePath != cachedCopyPath && !await File(cachedCopyPath).exists()) {
          await file.copy(cachedCopyPath);
        }
        if (await File(cachedCopyPath).exists()) {
          persistentPath = cachedCopyPath;
        }
      } catch (_) {}
    }
    offeredFileCatalog[fileId] = persistentPath;

    final myMsg = ChatMessage(
      msgId: fileId,
      peerId: targetNodeId,
      senderId: nodeId,
      senderName: nickname,
      text: '📎 $cleanFileName',
      timestamp: now,
      isMe: true,
      isDelivered: false,
      filePath: persistentPath,
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
    final isUdpOnlyOffer = !_tcpPeers.containsValue(targetNodeId) &&
        !_blePeers.containsValue(targetNodeId);
    if (!isUdpOnlyOffer && resolvedThumbB64 != null && resolvedThumbB64.isNotEmpty) {
      offerMap['tb64'] = resolvedThumbB64;
    }
    _addLog('[FILE] Отправка FILE_OFFER fid=$fileId ($cleanFileName, ${totalSize}B, udpOnly=$isUdpOnlyOffer, hasThumb=${offerMap.containsKey('tb64')})');
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
    if (contact == null) return;
    String? filePath = offeredFileCatalog[fileId];
    if (filePath == null || !await File(filePath).exists()) {
      for (final list in chatHistory.values) {
        for (final m in list) {
          if (m.msgId == fileId && m.filePath != null && m.filePath!.isNotEmpty) {
            if (await File(m.filePath!).exists()) {
              filePath = m.filePath;
              offeredFileCatalog[fileId] = filePath!;
              break;
            }
          }
        }
        if (filePath != null && await File(filePath).exists()) break;
      }
    }
    if (filePath == null || !await File(filePath).exists()) {
      try {
        final cacheDir = await _getInternalCacheFilesDir();
        if (await cacheDir.exists()) {
          await for (final ent in cacheDir.list()) {
            if (ent is File && ent.path.contains(fileId) && !ent.path.endsWith('.part')) {
              filePath = ent.path;
              offeredFileCatalog[fileId] = filePath!;
              break;
            }
          }
        }
      } catch (_) {}
    }
    if (filePath == null || !await File(filePath).exists()) {
      _addLog('[FILE] Отдача fid=$fileId отклонена: файл не найден на диске -> FILE_MISSING');
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
    final resolvedFilePath = filePath;
    final file = File(resolvedFilePath);

    final totalSize = await file.length();
    if (totalSize <= 0) return;
    final cleanFileName = _sanitizeFileName(resolvedFilePath.split(RegExp(r'[\\/]')).last);
    final isUdpOnlyPeer = !_tcpPeers.containsValue(targetNodeId) &&
        !_blePeers.containsValue(targetNodeId) &&
        _remoteUdpPeers.containsKey(targetNodeId);
    // 220B raw -> 296B b64 -> ~410B JSON -> 820B hex + headers = ~1230B (< 1280B safe 4G/IPv6 MTU!)
    final effectiveChunkSize = isUdpOnlyPeer ? 220 : fileChunkSize;
    final totalChunks = (totalSize / effectiveChunkSize).ceil();
    final streamKey = '${fileId}_$targetNodeId';
    final myGen = (_activeFileStreamGen[streamKey] ?? 0) + 1;
    _activeFileStreamGen[streamKey] = myGen;

    final job = pendingFileJobs.putIfAbsent(
      streamKey,
      () => PendingFileJob(
        fileId: fileId,
        targetNodeId: targetNodeId,
        filePath: resolvedFilePath,
        fileName: cleanFileName,
        confirmedChunkIndex: 0,
      ),
    );
    job.isSending = true;

    final raf = await file.open(mode: FileMode.read);
    try {
      final fileEphKeyPair = await _x25519.newKeyPair();
      final fileEphPub = await fileEphKeyPair.extractPublicKey();
      final fileEphPubHex = _toHex(fileEphPub.bytes);

      _addLog('[FILE] Начинаю отдачу fid=$fileId ($cleanFileName, ${totalSize}B, chunks=$totalChunks, chunkSize=$effectiveChunkSize, udpOnly=$isUdpOnlyPeer)');
      for (int idx = 0; idx < totalChunks; idx++) {
        if (_activeFileStreamGen[streamKey] != myGen ||
            (!isPeerDirectlyConnected(targetNodeId) && !_remoteUdpPeers.containsKey(targetNodeId))) {
          _addLog('[FILE] Отдача fid=$fileId прервана на чанке $idx/$totalChunks');
          break;
        }
        await raf.setPosition(idx * effectiveChunkSize);
        final chunkLen = min(effectiveChunkSize, totalSize - idx * effectiveChunkSize);
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
          'cs': effectiveChunkSize,
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
          skipPadding: isUdpOnlyPeer,
        );

        if (winWaiter != null) {
          await winWaiter.future.timeout(const Duration(milliseconds: 1500),
              onTimeout: () {});
          _fileWindowAckWaiters.remove('${fileId}_$idx');
        } else {
          await Future.delayed(Duration(milliseconds: isUdpOnlyPeer ? 10 : 3));
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
        .replaceAll(RegExp(r'[\x00/\\:*?"<>|]'), '_')
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

  void _deduplicatePersistedContacts() {
    final seenBySign = <String, String>{};
    final seenByHw = <String, String>{};
    final toRemove = <String>[];
    final entries = knownContacts.entries.toList()
      ..sort((a, b) {
        final ca = chatHistory[a.key]?.length ?? 0;
        final cb = chatHistory[b.key]?.length ?? 0;
        if (ca != cb) return cb.compareTo(ca); // Сохраняем контакт с историей!
        return b.value.lastSeenTimestamp.compareTo(a.value.lastSeenTimestamp);
      });
    for (final e in entries) {
      final id = e.key;
      final c = e.value;
      String? canonical;
      if (c.signPubHex.isNotEmpty && seenBySign.containsKey(c.signPubHex)) {
        canonical = seenBySign[c.signPubHex];
      } else if (c.hwFingerprint.isNotEmpty &&
          seenByHw.containsKey(c.hwFingerprint)) {
        canonical = seenByHw[c.hwFingerprint];
      }
      if (canonical != null && canonical != id) {
        final oldHist = chatHistory.remove(id);
        if (oldHist != null && oldHist.isNotEmpty) {
          final dst = getMessagesFor(canonical);
          final ids = dst.map((m) => m.msgId).toSet();
          for (final m in oldHist) {
            if (!ids.contains(m.msgId)) dst.add(m);
          }
          dst.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
        toRemove.add(id);
      } else {
        if (c.signPubHex.isNotEmpty) seenBySign[c.signPubHex] = id;
        if (c.hwFingerprint.isNotEmpty) seenByHw[c.hwFingerprint] = id;
      }
    }
    for (final id in toRemove) {
      knownContacts.remove(id);
    }
    if (toRemove.isNotEmpty) {
      unawaited(_saveContactsAndChats());
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
    bool markOnline = true,
  }) {
    if (nodeId.isEmpty || nodeId == this.nodeId) return;
    if (dhPubHex.length != 64 || signPubHex.length != 64) return;
    if (!allowEvenIfDeleted && deletedContactIds.contains(nodeId)) {
      return;
    }

    final cleanNick = (nick ?? '').trim();
    final cleanHw = (hwFingerprint ?? '').trim();
    final cleanOs = (platformInfo ?? '').trim();
    final parsedNewAddr = parseEndpoint(address ?? '', defaultPort: 0);
    final cleanIp = (!parsedNewAddr.isUdp && isPrivateLanIpv4(parsedNewAddr.host))
        ? parsedNewAddr.host
        : '';

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
      final samePubKey =
          (signPubHex.isNotEmpty && oldContact.signPubHex == signPubHex) ||
              (dhPubHex.isNotEmpty && oldContact.dhPubHex == dhPubHex);
      final sameHw = cleanHw.isNotEmpty &&
          oldContact.hwFingerprint.isNotEmpty &&
          oldContact.hwFingerprint == cleanHw;
      final parsedOldAddr = parseEndpoint(oldContact.lastAddress, defaultPort: 0);
      final oldIp = (!parsedOldAddr.isUdp && isPrivateLanIpv4(parsedOldAddr.host))
          ? parsedOldAddr.host
          : '';
      final sameLanIp = cleanIp.isNotEmpty && oldIp.isNotEmpty && oldIp == cleanIp;
      final sameOfflineByNick = !oldContact.isOnline &&
          cleanNick.isNotEmpty &&
          !cleanNick.startsWith('Android-') &&
          !cleanNick.startsWith('PC-') &&
          !cleanNick.startsWith('Узел ') &&
          oldContact.nickname == cleanNick;

      if (samePubKey || sameHw || sameLanIp || sameOfflineByNick) {
        duplicateIds.add(oldId);
      }
    });

    for (final oldId in duplicateIds) {
      final oldHistory = chatHistory.remove(oldId);
      if (oldHistory != null && oldHistory.isNotEmpty) {
        final currentHistory = getMessagesFor(nodeId);
        final existingMsgIds = currentHistory.map((m) => m.msgId).toSet();
        for (final m in oldHistory) {
          if (!existingMsgIds.contains(m.msgId)) {
            currentHistory.add(m);
            existingMsgIds.add(m.msgId);
          }
        }
        currentHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
      // Перенаправляем живые сокеты со старого ID на актуальный
      for (final entry in _tcpPeers.entries.toList()) {
        if (entry.value == oldId) _tcpPeers[entry.key] = nodeId;
      }
      for (final entry in _blePeers.entries.toList()) {
        if (entry.value == oldId) _blePeers[entry.key] = nodeId;
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
      if (markOnline) {
        existing.packetsSeenCount++;
        existing.lastSeenTimestamp = now;
        existing.isOnline = true;
      }
      existing.isDirectPeer = isPeerConnected;
    } else {
      knownContacts[nodeId] = ContactProfile(
        nodeId: nodeId,
        dhPubHex: dhPubHex,
        signPubHex: signPubHex,
        nickname: cleanNick.isNotEmpty ? cleanNick : 'Узел $nodeId',
        hwFingerprint: cleanHw,
        platformInfo: cleanOs,
        isOnline: markOnline ? true : isPeerConnected,
        isDirectPeer: isPeerConnected,
        lastAddress: address ?? '',
        packetsSeenCount: markOnline ? 1 : 0,
        lastSeenTimestamp: markOnline ? now : 0,
      );
    }
  }

  String? _selectLocalSourceIpFor(String targetHost) {
    if (cachedIps.isEmpty) return null;
    final tParts = targetHost.split('.');
    if (tParts.length == 4) {
      final tPrefix = '${tParts[0]}.${tParts[1]}.${tParts[2]}.';
      for (final ip in cachedIps) {
        if (ip.startsWith(tPrefix) && !ip.startsWith('198.18.') && !ip.startsWith('198.19.')) {
          return ip;
        }
      }
    }
    for (final ip in cachedIps) {
      if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
        return ip;
      }
    }
    return null;
  }

  Future<void> connectToHost(
    String host,
    int port, {
    String? expectedNodeId,
    Duration timeout = const Duration(seconds: 2),
    bool forceNewConnection = false,
  }) async {
    if (port <= 0 || host.isEmpty || host == '127.0.0.1' || host == 'udp' || host == 'tcp' || host.startsWith('BLE') || host == 'Через Mesh') return;
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
      final isIpv6 = host.contains(':');
      final isLan = !isIpv6 && (host.startsWith('192.168.') || host.startsWith('10.') || host.startsWith('172.'));
      final srcIp = isLan ? _selectLocalSourceIpFor(host) : null;
      if (forceNewConnection) {
        _addLog('[TCP] Подключение к $host:$port (${isIpv6 ? "IPv6" : (isLan ? "LAN" : "WAN")})...', triggerUi: false);
      }
      Socket socket;
      if (srcIp != null) {
        try {
          socket = await Socket.connect(
            host,
            port,
            sourceAddress: InternetAddress(srcIp),
            timeout: timeout,
          );
        } catch (_) {
          socket = await Socket.connect(host, port, timeout: timeout);
        }
      } else {
        socket = await Socket.connect(host, port, timeout: timeout);
      }
      if (forceNewConnection) {
        _addLog('[TCP] Сокет открыт: $host:$port', triggerUi: false);
      }
      _setupTcpSocket(socket);
    } catch (e) {
      if (forceNewConnection) {
        _addLog('[TCP] Не удалось $host:$port: $e', triggerUi: false);
      }
    } finally {
      _connectingHosts.remove(key);
    }
  }

  void _setupTcpSocket(Socket socket) {
    String remoteAddr = '';
    try {
      remoteAddr = '${socket.remoteAddress.address}:${socket.remotePort}';
    } catch (_) {}

    _tcpLastRxMs[socket] = DateTime.now().millisecondsSinceEpoch;
    _sendTcpLine(socket, _buildHelloJson());
    _sendTcpLine(socket, _buildPeerSyncJson());

    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _tcpLastRxMs[socket] = DateTime.now().millisecondsSinceEpoch;
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

      if (map.containsKey('ptt_bin')) {
        unawaited(_onIncomingPttChunk(map));
        return;
      }
      if (map.containsKey('ptt_end')) {
        _finishIncomingPtt();
        return;
      }
      if (map.containsKey('call_bin')) {
        final b64 = (map['call_bin'] ?? '').toString();
        if (b64.isNotEmpty) {
          unawaited(_processEncryptedCallMediaBytes(base64Decode(b64), null, 0));
        }
        return;
      }
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
          if (remoteAddr.isNotEmpty && !remoteAddr.startsWith('BLE')) 'obs_addr': remoteAddr,
        }));
        return;
      }
      if (map.containsKey('ping_resp')) {
        final obs = (map['obs_addr'] ?? '').toString().trim();
        if (obs.isNotEmpty &&
            !obs.startsWith('192.168.') &&
            !obs.startsWith('10.') &&
            !obs.startsWith('172.') &&
            !obs.startsWith('127.')) {
          if (discoveredExternalEndpoint.isEmpty) {
            discoveredExternalEndpoint = obs;
            _refreshInterRegionalStatusText();
            _addLog('[REFLECT] Внешний адрес определён через пира Маяк (без STUN): $obs', triggerUi: false);
          }
        }
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
        bool changedAny = false;
        // v3.2.5: контакты собеседников больше не копируются автоматически (приватность адресной книги).
        // Зато импортируем живые DHT-узлы (DHT PEX), чтобы помочь устройствам за блокировкой порта 6881.
        if (map['dht_pex'] is List) {
          final pexList = map['dht_pex'] as List;
          if (pexList.isNotEmpty) {
            _dhtClient.importExternalNodes(pexList);
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
    bool skipPadding = false,
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

    final paddedBytes = skipPadding ? sealedPayloadBytes : _applyPadmeJsonPadding(sealedPayloadBytes);
    final secretBox = await _cipher.encrypt(
      paddedBytes,
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
        if (transitBuffer.length >= maxTransitBufferSize) {
        transitBuffer.remove(transitBuffer.keys.first);
      }
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
        if (transitBuffer.length >= maxTransitBufferSize) {
        transitBuffer.remove(transitBuffer.keys.first);
      }
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
        if (transitBuffer.length >= maxTransitBufferSize) {
        transitBuffer.remove(transitBuffer.keys.first);
      }
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
          final lowerFn = fn.toLowerCase();
          if ((lowerFn.startsWith('voice_') || lowerFn.endsWith('.m4a') || lowerFn.endsWith('.wav')) &&
              fs > 0 &&
              fs <= 2 * 1024 * 1024) {
            unawaited(requestDownloadOrRevealMedia(offerMsg));
          }
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
        final alreadyInCall = (activeCallPeerId != null && activeCallPeerId != senderId) ||
            (incomingCallFromPeerId != null && incomingCallFromPeerId != senderId);
        if (alreadyInCall) {
          final busyPayload = jsonEncode({'v': 2, 'kind': 'CALL_BUSY'});
          unawaited(_encryptAndQueueSealedDataPacket(
            targetNodeId: senderId,
            contact: contact,
            msgId: _randomHex(12),
            sealedPayloadBytes: utf8.encode(busyPayload),
            persistInOutbox: false,
            keepInTransitBuffer: false,
          ));
          unawaited(_triggerIncomingNotification(
            senderId,
            contact.displayTitle,
            '📞 Пропущенный вызов (вы в другом звонке)',
          ));
        } else {
          incomingCallFromPeerId = senderId;
          incomingCallMode = mode;
          _incomingCallId = (envelope['callId'] ?? '').toString();
          _incomingCallUdpPort = _remoteUdpPeers[senderId]?.port ??
              (envelope['udpPort'] as num?)?.toInt() ??
              callMediaUdpPort;
          unawaited(_startIncomingRingtone(caller: contact.displayTitle, mode: mode));
          unawaited(_triggerIncomingNotification(
            senderId,
            contact.displayTitle,
            mode == 'video'
                ? '📹 Входящий видеочат (ВЧ)'
                : '📞 Входящий голосовой чат (ГЧ)',
          ));
        }
      } else if (kind == 'CALL_ACCEPT') {
        if (activeCallPeerId == senderId && !isCallAccepted) {
          isCallAccepted = true;
          _activeCallPeerIp = _resolvePeerIp(senderId);
          _activeCallPeerUdpPort = _remoteUdpPeers[senderId]?.port ??
              (envelope['udpPort'] as num?)?.toInt() ??
              callMediaUdpPort;
          final remoteCallId = (envelope['callId'] ?? '').toString();
          if (remoteCallId.isNotEmpty && remoteCallId != _activeCallId) {
            _activeCallId = remoteCallId;
            _activeCallMediaKey =
                await _deriveCallMediaKey(senderId, _activeCallId);
          }
          callStatusText = activeCallMode == 'video'
              ? 'ВЧ активен (HD Видео + Голос)'
              : 'ГЧ активен (Голос)';
          await _stopCallTonesOutgoing();
          onStateChanged();
          unawaited(_startCallMediaPipelines());
        }
      } else if (kind == 'CALL_STATE') {
        if (activeCallPeerId == senderId) {
          remoteCallMicMuted = envelope['micMuted'] == true;
          remoteCallVideoMuted = envelope['videoMuted'] == true;
          if (remoteCallVideoMuted) {
            remoteVideoFrameBytes = null;
          }
        }
      } else if (kind == 'CALL_REJECT' || kind == 'CALL_BUSY') {
        if (activeCallPeerId == senderId) {
          activeCallPeerId = null;
          isCallAccepted = false;
          remoteVideoFrameBytes = null;
          localVideoFrameBytes = null;
          _activeCallMediaKey = null;
          callStatusText = kind == 'CALL_BUSY'
              ? 'Абонент занят в другом звонке'
              : 'Вызов отклонён';
          unawaited(_stopCallTonesOutgoing());
          unawaited(_stopCallMediaPipelines());
          unawaited(_playCallEndTone());
        }
      } else if (kind == 'CALL_END') {
        if (activeCallPeerId == senderId || incomingCallFromPeerId == senderId) {
          activeCallPeerId = null;
          incomingCallFromPeerId = null;
          isCallAccepted = false;
          isCallMicMuted = false;
          isCallVideoMuted = false;
          remoteCallMicMuted = false;
          remoteCallVideoMuted = false;
          remoteVideoFrameBytes = null;
    localVideoFrameBytes = null;
          _activeCallMediaKey = null;
          callStatusText = '';
          unawaited(_stopCallTonesOutgoing());
          unawaited(_stopIncomingRingtone());
          unawaited(_stopCallMediaPipelines());
          unawaited(_playCallEndTone());
        }
      } else if (kind == 'WEBRTC_SDP_PART') {
        final sid = (envelope['sid'] ?? '').toString();
        final sk = (envelope['sk'] ?? '').toString();
        final idx = (envelope['idx'] as num?)?.toInt() ?? 0;
        final tot = (envelope['tot'] as num?)?.toInt() ?? 1;
        final partData = (envelope['d'] ?? '').toString();
        if (sid.isNotEmpty && sk.isNotEmpty && tot > 0 && tot <= 64) {
          final bucket = _incomingSdpParts.putIfAbsent(sid, () => {});
          bucket[idx] = partData;
          if (bucket.length >= tot) {
            _incomingSdpParts.remove(sid);
            final sb = StringBuffer();
            for (int i = 0; i < tot; i++) {
              sb.write(bucket[i] ?? '');
            }
            try {
              final decoded = jsonDecode(sb.toString()) as Map<String, dynamic>;
              unawaited(webrtc.handleSignal(sk, decoded));
            } catch (e) {
              _addLog('[RTC] Ошибка сборки SDP $sk: $e', triggerUi: false);
            }
          }
        }
      } else if (kind == 'WEBRTC_ICE') {
        unawaited(webrtc.handleSignal('WEBRTC_ICE', envelope));
      } else if (kind == 'FILE_REVOKED') {
        final fid = (envelope['fid'] ?? '').toString();
        if (fid.isNotEmpty) {
          _revokedFileIds.add(fid);
          deletedMessageIds.add(fid);
          _downloadWatchdogTimers.remove(fid)?.cancel();
          final asm = _incomingFiles.remove(fid);
          if (asm != null) {
            try { await asm.openRaf?.close(); } catch (_) {}
            try { await File(asm.partFilePath).delete(); } catch (_) {}
          }
          getMessagesFor(senderId).removeWhere((m) => m.msgId == fid);
          unawaited(_saveContactsAndChats());
          onStateChanged();
          _addLog('[FILE] Файл $fid отозван отправителем — загрузка отменена');
        }
      } else if (kind == 'FILE_MISSING') {
        final fid = (envelope['fid'] ?? '').toString();
        _downloadWatchdogTimers.remove(fid)?.cancel();
        for (final list in chatHistory.values) {
          for (final msg in list) {
            if (msg.msgId == fid) {
              msg.isDownloading = false;
              msg.transferProgress = 0.0;
              if (!msg.text.contains('(удалён отправителем)')) {
                msg.text = '${msg.text} (удалён отправителем)';
              }
              break;
            }
          }
        }
        unawaited(_saveContactsAndChats());
        onStateChanged();
        _addLog('Файл $fid больше не доступен на устройстве отправителя.');
      } else if (kind == 'GROUP_INVITE') {
        final gid = (envelope['gid'] ?? '').toString();
        final gtitle = (envelope['title'] ?? 'Mesh-комната').toString();
        final gcreator = (envelope['creator'] ?? senderId).toString();
        final hop = (envelope['hop'] as num?)?.toInt() ?? 0;
        _absorbGroupMemberProfiles(envelope['mprof']);
        final gmembers = (envelope['members'] is List)
            ? (envelope['members'] as List).map((e) => e.toString()).toSet().toList()
            : <String>[nodeId, senderId];
        if (!gmembers.contains(nodeId)) gmembers.add(nodeId);
        if (gid.isNotEmpty) {
          final existing = groupChats[gid];
          final mergedMembers = <String>{
            ...?existing?.memberIds,
            ...gmembers,
          }.toList();
          final grp = GroupChat(
            groupId: gid,
            title: gtitle,
            creatorId: gcreator,
            memberIds: mergedMembers,
            createdAt: (envelope['ts'] as num?)?.toInt() ??
                existing?.createdAt ??
                DateTime.now().millisecondsSinceEpoch,
          );
          groupChats[gid] = grp;
          await _saveContactsAndChats();
          if (hop < 4) {
            final relayMap = Map<String, dynamic>.from(envelope);
            relayMap['hop'] = hop + 1;
            relayMap['members'] = mergedMembers;
            relayMap['mprof'] = _buildGroupMemberProfiles(mergedMembers);
            unawaited(_relayGroupPayloadToMembers(
              grp,
              relayMap,
              'ginv_${gid}_${(envelope['ts'] ?? 0)}',
              excludeIds: {senderId},
            ));
          }
        }
      } else if (kind == 'GROUP_MSG') {
        final gid = (envelope['gid'] ?? '').toString();
        final gtitle = (envelope['title'] ?? 'Mesh-комната').toString();
        final gcreator = (envelope['creator'] ?? senderId).toString();
        final mid = (envelope['mid'] ?? pkt.msgId).toString();
        final origSenderId = (envelope['osid'] ?? senderId).toString();
        final hop = (envelope['hop'] as num?)?.toInt() ?? 0;
        _absorbGroupMemberProfiles(envelope['mprof']);
        final gmembers = (envelope['members'] is List)
            ? (envelope['members'] as List).map((e) => e.toString()).toSet().toList()
            : <String>[nodeId, senderId, origSenderId];
        if (!gmembers.contains(nodeId)) gmembers.add(nodeId);
        if (gid.isNotEmpty && !deletedMessageIds.contains(mid)) {
          final grp = groupChats.putIfAbsent(
            gid,
            () => GroupChat(
              groupId: gid,
              title: gtitle,
              creatorId: gcreator,
              memberIds: gmembers,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          for (final mId in gmembers) {
            if (!grp.memberIds.contains(mId)) grp.memberIds.add(mId);
          }
          final gList = getGroupMessages(gid);
          final isNew = !gList.any((m) => m.msgId == mid);
          if (isNew && origSenderId != nodeId) {
            final txt = (envelope['txt'] ?? '').toString();
            final sn = (envelope['sn'] ??
                    knownContacts[origSenderId]?.displayTitle ??
                    contact.displayTitle)
                .toString();
            final gMsg = ChatMessage(
              msgId: mid,
              peerId: groupChatKey(gid),
              senderId: origSenderId,
              senderName: sn,
              text: txt,
              timestamp: (envelope['ts'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch,
              isMe: false,
              isDelivered: true,
              replyToMsgId: envelope['rid'] as String?,
              replyToText: envelope['rtxt'] as String?,
              forwardedFrom: envelope['fwd'] as String?,
            );
            gList.add(gMsg);
            unreadGroupCounts[gid] = (unreadGroupCounts[gid] ?? 0) + 1;
            _inspectMessageForTriggers(gMsg, groupChatKey(gid));
            unawaited(_triggerIncomingNotification(
                groupChatKey(gid), '$gtitle • $sn', txt));
            await _saveContactsAndChats();
          }
          // Multi-hop Mesh Relay: forward to all other group members so A <-> B <-> C works!
          if (isNew && hop < 5) {
            final relayMap = Map<String, dynamic>.from(envelope);
            relayMap['hop'] = hop + 1;
            relayMap['osid'] = origSenderId;
            relayMap['members'] = grp.memberIds;
            relayMap['mprof'] = _buildGroupMemberProfiles(grp.memberIds);
            unawaited(_relayGroupPayloadToMembers(
              grp,
              relayMap,
              mid,
              excludeIds: {senderId, origSenderId},
            ));
          }
        }
      } else if (kind == 'GROUP_EDIT') {
        final gid = (envelope['gid'] ?? '').toString();
        final mid = (envelope['mid'] ?? '').toString();
        final origSenderId = (envelope['osid'] ?? senderId).toString();
        final newTxt = (envelope['txt'] ?? '').toString();
        final hop = (envelope['hop'] as num?)?.toInt() ?? 0;
        final grp = groupChats[gid];
        if (grp != null && mid.isNotEmpty) {
          bool changed = false;
          for (final m in getGroupMessages(gid)) {
            if (m.msgId == mid && m.senderId == origSenderId && m.text != newTxt) {
              m.text = newTxt;
              m.isEdited = true;
              changed = true;
              break;
            }
          }
          if (changed) {
            await _saveContactsAndChats();
            if (hop < 5) {
              final relayMap = Map<String, dynamic>.from(envelope);
              relayMap['hop'] = hop + 1;
              unawaited(_relayGroupPayloadToMembers(
                grp,
                relayMap,
                'gedit_$mid',
                excludeIds: {senderId, origSenderId},
              ));
            }
          }
        }
      } else if (kind == 'GROUP_DELETE') {
        final gid = (envelope['gid'] ?? '').toString();
        final mid = (envelope['mid'] ?? '').toString();
        final origSenderId = (envelope['osid'] ?? senderId).toString();
        final hop = (envelope['hop'] as num?)?.toInt() ?? 0;
        final grp = groupChats[gid];
        if (grp != null && mid.isNotEmpty && !deletedMessageIds.contains(mid)) {
          deletedMessageIds.add(mid);
          getGroupMessages(gid).removeWhere((m) => m.msgId == mid);
          await _saveContactsAndChats();
          if (hop < 5) {
            final relayMap = Map<String, dynamic>.from(envelope);
            relayMap['hop'] = hop + 1;
            unawaited(_relayGroupPayloadToMembers(
              grp,
              relayMap,
              'gdel_$mid',
              excludeIds: {senderId, origSenderId},
            ));
          }
        }
      } else if (kind == 'GROUP_REACTION') {
        final gid = (envelope['gid'] ?? '').toString();
        final mid = (envelope['mid'] ?? '').toString();
        final origSenderId = (envelope['osid'] ?? senderId).toString();
        final emoji = (envelope['emoji'] ?? '').toString();
        final hop = (envelope['hop'] as num?)?.toInt() ?? 0;
        final grp = groupChats[gid];
        if (grp != null && mid.isNotEmpty && emoji.isNotEmpty) {
          for (final m in getGroupMessages(gid)) {
            if (m.msgId == mid) {
              if (m.reactions[origSenderId] == emoji) {
                m.reactions.remove(origSenderId);
              } else {
                m.reactions[origSenderId] = emoji;
              }
              break;
            }
          }
          await _saveContactsAndChats();
          if (hop < 4) {
            final relayMap = Map<String, dynamic>.from(envelope);
            relayMap['hop'] = hop + 1;
            unawaited(_relayGroupPayloadToMembers(
              grp,
              relayMap,
              'grx_${mid}_${(envelope['ts'] ?? 0)}',
              excludeIds: {senderId, origSenderId},
            ));
          }
        }
      } else if (kind == 'LOC_UPDATE') {
        final lat = (envelope['lat'] as num?)?.toDouble();
        final lon = (envelope['lon'] as num?)?.toDouble();
        if (lat != null && lon != null) {
          peerLocations[senderId] = PeerLocationRecord(
            nodeId: senderId,
            nickname: (envelope['nick'] ?? contact.displayTitle).toString(),
            lat: lat,
            lon: lon,
            altMeters: (envelope['alt'] as num?)?.toDouble() ?? 0.0,
            pressureHpa: (envelope['hpa'] as num?)?.toDouble() ?? 0.0,
            isManualAnchor: envelope['man'] == true,
            updatedAt: (envelope['ts'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          );
        }
      } else if (kind == 'LOC_STOP') {
        peerLocations.remove(senderId);
      } else if (kind == 'GROUP_LEAVE') {
        final gid = (envelope['gid'] ?? '').toString();
        final origSenderId = (envelope['osid'] ?? senderId).toString();
        final hop = (envelope['hop'] as num?)?.toInt() ?? 0;
        final grp = groupChats[gid];
        if (grp != null && grp.memberIds.remove(origSenderId)) {
          await _saveContactsAndChats();
          if (hop < 4) {
            final relayMap = Map<String, dynamic>.from(envelope);
            relayMap['hop'] = hop + 1;
            unawaited(_relayGroupPayloadToMembers(
              grp,
              relayMap,
              'glv_${gid}_$origSenderId',
              excludeIds: {senderId, origSenderId},
            ));
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
        final existingMsgs = getMessagesFor(senderId);
        if (!deletedMessageIds.contains(pkt.msgId) &&
            !existingMsgs.any((m) => m.msgId == pkt.msgId)) {
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
      if (transitBuffer.length >= maxTransitBufferSize) {
        transitBuffer.remove(transitBuffer.keys.first);
      }
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

    if (tot <= 0 || tot > 500000 || totalSize > 1050 * 1024 * 1024) return;
    if (deletedMessageIds.contains(fileId) || _revokedFileIds.contains(fileId)) {
      final stale = _incomingFiles.remove(fileId);
      if (stale != null) {
        try { await stale.openRaf?.close(); } catch (_) {}
        try { await File(stale.partFilePath).delete(); } catch (_) {}
      }
      return;
    }

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

    _downloadWatchdogTimers.remove(fileId)?.cancel();
    final dir = _cachedFilesDir ??= await _getInternalCacheFilesDir();
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
        final rxChunkSize = (env['cs'] as num?)?.toInt() ?? fileChunkSize;
        await raf.setPosition(idx * rxChunkSize);
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
      _incomingFiles.remove(fileId);
      try { await assembly.openRaf?.close(); } catch (_) {}
      try { await File(partPath).delete(); } catch (_) {}
      return;
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
      _lastFileUiNotifyMs = now;
      onStateChanged();
      return;
    }
    if (assembly.receivedChunkIndices.length <= 1 ||
        now - _lastFileUiNotifyMs >= 400) {
      _lastFileUiNotifyMs = now;
      onStateChanged();
    }
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

    for (final entry in _remoteUdpPeers.entries.toList()) {
      if (sentPeerIds.contains(entry.key)) continue;
      if (pkt.dstNodeId == broadcastChannelId || pkt.dstNodeId == entry.key) {
        sentPeerIds.add(entry.key);
        _sendUdpMeshJson(entry.value.ip, entry.value.port, serialized);
      }
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
        _beaconTickCounter++;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        // Watchdog полуоткрытых TCP-сокетов: если пир вышел из сети без FIN/RST, режем сокет через 16с
        for (final entry in _tcpPeers.entries.toList()) {
          final sock = entry.key;
          final lastRx = _tcpLastRxMs[sock] ?? nowMs;
          final tcpTimeoutMs = (_incomingFiles.isNotEmpty || pendingFileJobs.isNotEmpty) ? 60000 : 35000;
          if (nowMs - lastRx > tcpTimeoutMs) {
            _addLog('[ONLINE] TCP таймаут ${tcpTimeoutMs ~/ 1000}с без ответа: ${entry.value} -> OFFLINE', triggerUi: false);
            _cleanupSocket(sock);
          } else if (_beaconTickCounter % 2 == 0) {
            _sendTcpLine(sock, jsonEncode({'ping_req': _randomHex(6), 'from': nodeId}));
          }
        }
        await refreshNetworkCache();
        final changed = _refreshOnlineStatuses();
        if (changed) onStateChanged();
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
              !c.lastAddress.startsWith('udp:') &&
              c.lastAddress.contains(':')) {
            final ep = parseEndpoint(c.lastAddress, defaultPort: defaultTcpPort);
            if (!ep.isUdp && ep.host.isNotEmpty && ep.port > 0) {
              unawaited(connectToHost(
                ep.host,
                ep.port,
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

  bool _refreshOnlineStatuses() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final activeUdpIds = <String>{};
    for (final entry in _remoteUdpPeers.entries) {
      if (entry.value.lastSeenMs > 0 && (now - entry.value.lastSeenMs) < 15000) {
        activeUdpIds.add(entry.key);
      }
    }
    final activeIds = {..._tcpPeers.values, ..._blePeers.values, ...activeUdpIds};
    bool anyChanged = false;
    for (final c in knownContacts.values) {
      final wasOnline = c.isOnline;
      final recentlySeen =
          c.lastSeenTimestamp > 0 && (now - c.lastSeenTimestamp) < 14000;
      c.isDirectPeer = activeIds.contains(c.nodeId);
      c.isOnline = c.isDirectPeer || recentlySeen;
      if (wasOnline != c.isOnline) {
        anyChanged = true;
        _addLog('[ONLINE] ${c.nickname} (${c.nodeId}): ${c.isOnline ? "В СЕТИ" : "НЕ В СЕТИ"}', triggerUi: false);
      }
    }
    return anyChanged;
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
    final removedPeer = _tcpPeers.remove(s);
    _tcpLastRxMs.remove(s);
    try {
      s.destroy();
    } catch (_) {}
    if (removedPeer != null) {
      _addLog('[ONLINE] TCP-соединение закрыто: $removedPeer', triggerUi: false);
    }
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
