import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Нативный автономный аудиоплеер на C++ SoLoud + miniaudio + Xiph (без PowerShell и без системных кодеков).
/// Все файлы читаются в оперативную память (`loadMem`) с немедленным закрытием файлового дескриптора —
/// 100% совместимо с кириллическими путями Windows и никогда не блокирует папку приложения.
class MayakSoLoudPlayer {
  bool _initialized = false;
  AudioSource? _currentSource;
  SoundHandle? _currentHandle;
  String? currentPath;
  bool isPlaying = false;
  int positionMs = 0;
  int durationMs = 1000;
  Timer? _pollTimer;

  void Function()? onStateChanged;
  void Function(String msg)? onLog;

  Future<bool> _ensureInit() async {
    if (_initialized && SoLoud.instance.isInitialized) return true;
    try {
      await SoLoud.instance.init();
      _initialized = true;
      return true;
    } catch (e) {
      onLog?.call('[AUDIO] Ошибка инициализации SoLoud: $e');
      return false;
    }
  }

  Future<bool> togglePlayFile(String filePath) async {
    final ok = await _ensureInit();
    if (!ok) return false;

    if (currentPath == filePath && _currentHandle != null) {
      try {
        if (SoLoud.instance.getIsValidVoiceHandle(_currentHandle!)) {
          SoLoud.instance.pauseSwitch(_currentHandle!);
          isPlaying = !SoLoud.instance.getPause(_currentHandle!);
          onStateChanged?.call();
          return true;
        }
      } catch (_) {}
    }

    await stop();
    try {
      final f = File(filePath);
      if (!await f.exists()) {
        onLog?.call('[AUDIO] Файл не найден: $filePath');
        return false;
      }
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        onLog?.call('[AUDIO] Пустой аудиофайл: $filePath');
        return false;
      }
      final ext = filePath.contains('.') ? filePath.split('.').last.toLowerCase() : 'wav';
      final safeKey = 'mayak_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final src = await SoLoud.instance.loadMem(safeKey, bytes);
      final dur = SoLoud.instance.getLength(src);
      final handle = await SoLoud.instance.play(src);

      _currentSource = src;
      _currentHandle = handle;
      currentPath = filePath;
      durationMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1000;
      positionMs = 0;
      isPlaying = true;
      onLog?.call('[AUDIO] SoLoud воспроизведение: ${f.path.split(RegExp(r"[\\/]")).last} (${durationMs}мс)');

      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final h = _currentHandle;
        if (h == null) return;
        try {
          if (!SoLoud.instance.getIsValidVoiceHandle(h)) {
            unawaited(stop());
            return;
          }
          final paused = SoLoud.instance.getPause(h);
          final pos = SoLoud.instance.getPosition(h).inMilliseconds;
          isPlaying = !paused;
          positionMs = pos.clamp(0, durationMs);
          onStateChanged?.call();
        } catch (_) {
          unawaited(stop());
        }
      });
      onStateChanged?.call();
      return true;
    } catch (e) {
      onLog?.call('[AUDIO] SoLoud не смог открыть файл ($filePath): $e');
      await stop();
      return false;
    }
  }

  Future<void> seek(int targetMs) async {
    final h = _currentHandle;
    if (h == null) return;
    try {
      final clamped = targetMs.clamp(0, durationMs);
      SoLoud.instance.seek(h, Duration(milliseconds: clamped));
      positionMs = clamped;
      onStateChanged?.call();
    } catch (_) {}
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final h = _currentHandle;
    final src = _currentSource;
    _currentHandle = null;
    _currentSource = null;
    currentPath = null;
    isPlaying = false;
    positionMs = 0;
    try {
      if (h != null && SoLoud.instance.isInitialized) {
        if (SoLoud.instance.getIsValidVoiceHandle(h)) {
          await SoLoud.instance.stop(h);
        }
      }
    } catch (_) {}
    try {
      if (src != null && SoLoud.instance.isInitialized) {
        await SoLoud.instance.disposeSource(src);
      }
    } catch (_) {}
    onStateChanged?.call();
  }
}

/// Нативный P2P WebRTC-движок звонков (libwebrtc M144+: C++ CaptureSinkFilter без qedit.dll,
/// Camera2 на Android, WebRTC AEC3/NS/AGC2/NetEQ, WGC показ экрана на Windows).
/// Весь сигналинг (Offer/Answer/ICE) идёт через зашифрованный бессерверный P2P-канал Маяка.
class MayakWebRtcController {
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  bool _renderersReady = false;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCRtpSender? _videoSender;

  bool isActive = false;
  bool isConnected = false;
  bool hasLocalVideo = false;
  bool hasRemoteVideo = false;
  bool isScreenSharing = false;
  bool _remoteDescSet = false;
  final List<RTCIceCandidate> _pendingRemoteIce = [];

  Future<void> Function(String kind, Map<String, dynamic> payload)? _sendSignal;
  void Function()? onStateChanged;
  void Function(String msg)? onLog;

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> startSession({
    required bool isCaller,
    required bool isVideo,
    required bool useScreenOnWindows,
    required bool startMicMuted,
    required bool startVideoMuted,
    required Future<void> Function(String kind, Map<String, dynamic> payload) sendSignal,
  }) async {
    await disposeSession();
    _sendSignal = sendSignal;
    isActive = true;
    isConnected = false;
    isScreenSharing = Platform.isWindows && isVideo && useScreenOnWindows;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();

    try {
      await _ensureRenderers();

      final config = <String, dynamic>{
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun.cloudflare.com:3478'},
        ],
        'sdpSemantics': 'unified-plan',
      };

      final pc = await createPeerConnection(config);
      _pc = pc;

      pc.onIceCandidate = (RTCIceCandidate cand) {
        if (cand.candidate == null || cand.candidate!.isEmpty) return;
        unawaited(_sendSignal?.call('WEBRTC_ICE', {
          'candidate': cand.candidate,
          'sdpMid': cand.sdpMid,
          'sdpMLineIndex': cand.sdpMLineIndex,
        }));
      };

      pc.onIceConnectionState = (RTCIceConnectionState st) {
        onLog?.call('[RTC] ICE state: $st');
        final connectedNow = st == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            st == RTCIceConnectionState.RTCIceConnectionStateCompleted;
        if (connectedNow != isConnected) {
          isConnected = connectedNow;
          onStateChanged?.call();
        }
      };

      pc.onTrack = (RTCTrackEvent event) {
        onLog?.call('[RTC] Получен удалённый трек: ${event.track.kind}');
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
          remoteRenderer.srcObject = _remoteStream;
        }
        if (event.track.kind == 'video') {
          hasRemoteVideo = true;
        }
        onStateChanged?.call();
      };

      // Захват локального аудио (WebRTC AEC3 + NS + AGC2) и видео (нативная камера / экран WGC)
      MediaStream? stream;
      try {
        if (isVideo && Platform.isWindows && useScreenOnWindows) {
          final audioStream = await navigator.mediaDevices.getUserMedia({
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            },
            'video': false,
          });
          try {
            final screenStream = await navigator.mediaDevices.getDisplayMedia({
              'video': true,
              'audio': false,
            });
            for (final vt in screenStream.getVideoTracks()) {
              await audioStream.addTrack(vt);
            }
          } catch (e) {
            onLog?.call('[RTC] Показ экрана недоступен: $e');
          }
          stream = audioStream;
        } else {
          stream = await navigator.mediaDevices.getUserMedia({
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            },
            'video': isVideo
                ? {
                    'facingMode': 'user',
                    'width': {'ideal': 640},
                    'height': {'ideal': 480},
                    'frameRate': {'ideal': 24},
                  }
                : false,
          });
        }
      } catch (e) {
        onLog?.call('[RTC] Камера/видео недоступны ($e) -> стартую только с микрофоном');
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            },
            'video': false,
          });
        } catch (e2) {
          onLog?.call('[RTC] Ошибка захвата микрофона: $e2');
        }
      }

      if (stream != null) {
        _localStream = stream;
        for (final at in stream.getAudioTracks()) {
          at.enabled = !startMicMuted;
          await pc.addTrack(at, stream);
        }
        for (final vt in stream.getVideoTracks()) {
          vt.enabled = !startVideoMuted;
          _videoSender = await pc.addTrack(vt, stream);
          hasLocalVideo = !startVideoMuted;
        }
        if (stream.getVideoTracks().isNotEmpty) {
          localRenderer.srcObject = stream;
        }
      }

      onStateChanged?.call();

      if (isCaller) {
        final offer = await pc.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': isVideo,
        });
        await pc.setLocalDescription(offer);
        onLog?.call('[RTC] Отправка WEBRTC_OFFER (${offer.sdp?.length ?? 0} байт)');
        await _sendSignal?.call('WEBRTC_OFFER', {
          'sdp': offer.sdp ?? '',
          'type': offer.type ?? 'offer',
        });
      }
    } catch (e) {
      onLog?.call('[RTC] Ошибка запуска WebRTC-сессии: $e');
    }
  }

  Future<void> handleSignal(String kind, Map<String, dynamic> env) async {
    final pc = _pc;
    if (pc == null || !isActive) return;
    try {
      if (kind == 'WEBRTC_OFFER') {
        final sdp = (env['sdp'] ?? '').toString();
        if (sdp.isEmpty) return;
        onLog?.call('[RTC] Получен WEBRTC_OFFER (${sdp.length} байт)');
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        _remoteDescSet = true;
        await _flushPendingIce(pc);
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        onLog?.call('[RTC] Отправка WEBRTC_ANSWER (${answer.sdp?.length ?? 0} байт)');
        await _sendSignal?.call('WEBRTC_ANSWER', {
          'sdp': answer.sdp ?? '',
          'type': answer.type ?? 'answer',
        });
      } else if (kind == 'WEBRTC_ANSWER') {
        final sdp = (env['sdp'] ?? '').toString();
        if (sdp.isEmpty) return;
        onLog?.call('[RTC] Получен WEBRTC_ANSWER (${sdp.length} байт)');
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        _remoteDescSet = true;
        await _flushPendingIce(pc);
      } else if (kind == 'WEBRTC_ICE') {
        final cStr = (env['candidate'] ?? '').toString();
        if (cStr.isEmpty) return;
        final cand = RTCIceCandidate(
          cStr,
          env['sdpMid']?.toString(),
          (env['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_remoteDescSet) {
          await pc.addCandidate(cand);
        } else {
          _pendingRemoteIce.add(cand);
        }
      }
    } catch (e) {
      onLog?.call('[RTC] Ошибка обработки $kind: $e');
    }
  }

  Future<void> _flushPendingIce(RTCPeerConnection pc) async {
    if (_pendingRemoteIce.isEmpty) return;
    final copy = List<RTCIceCandidate>.from(_pendingRemoteIce);
    _pendingRemoteIce.clear();
    for (final c in copy) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
  }

  void setMicMuted(bool muted) {
    final s = _localStream;
    if (s == null) return;
    for (final t in s.getAudioTracks()) {
      t.enabled = !muted;
    }
  }

  void setVideoMuted(bool muted) {
    final s = _localStream;
    if (s == null) return;
    for (final t in s.getVideoTracks()) {
      t.enabled = !muted;
    }
    hasLocalVideo = !muted && s.getVideoTracks().isNotEmpty;
    onStateChanged?.call();
  }

  Future<void> switchCamera() async {
    final s = _localStream;
    if (s == null) return;
    final vts = s.getVideoTracks();
    if (vts.isEmpty) return;
    try {
      await Helper.switchCamera(vts.first);
    } catch (e) {
      onLog?.call('[RTC] Ошибка переключения камеры: $e');
    }
  }

  Future<void> setSpeakerphone(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } catch (_) {}
  }

  Future<void> switchWindowsVideoSource(bool useScreen) async {
    if (!Platform.isWindows || _pc == null || !isActive) return;
    isScreenSharing = useScreen;
    try {
      final newStream = useScreen
          ? await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false})
          : await navigator.mediaDevices.getUserMedia({
              'audio': false,
              'video': {'width': {'ideal': 640}, 'height': {'ideal': 480}, 'frameRate': {'ideal': 24}},
            });
      final newTracks = newStream.getVideoTracks();
      if (newTracks.isEmpty) return;
      final newTrack = newTracks.first;
      if (_videoSender != null) {
        await _videoSender!.replaceTrack(newTrack);
      } else {
        _videoSender = await _pc!.addTrack(newTrack, _localStream ?? newStream);
      }
      if (_localStream != null) {
        for (final old in _localStream!.getVideoTracks().toList()) {
          await _localStream!.removeTrack(old);
          await old.stop();
        }
        await _localStream!.addTrack(newTrack);
        localRenderer.srcObject = _localStream;
      } else {
        localRenderer.srcObject = newStream;
      }
      hasLocalVideo = true;
      onLog?.call('[RTC] Источник видео Windows переключён на: ${useScreen ? "Экран" : "Камера"}');
      onStateChanged?.call();
    } catch (e) {
      onLog?.call('[RTC] Не удалось переключить источник видео: $e');
    }
  }

  Future<void> disposeSession() async {
    isActive = false;
    isConnected = false;
    hasLocalVideo = false;
    hasRemoteVideo = false;
    _remoteDescSet = false;
    _pendingRemoteIce.clear();
    _videoSender = null;
    _sendSignal = null;

    try {
      if (_localStream != null) {
        for (final t in _localStream!.getTracks()) {
          try {
            await t.stop();
          } catch (_) {}
        }
        await _localStream!.dispose();
      }
    } catch (_) {}
    _localStream = null;

    try {
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;

    if (_renderersReady) {
      try {
        localRenderer.srcObject = null;
        remoteRenderer.srcObject = null;
      } catch (_) {}
    }

    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (_) {}
    _pc = null;
    onStateChanged?.call();
  }
}
