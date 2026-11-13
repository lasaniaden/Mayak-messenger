import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'mesh_engine.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      return true;
    };
    runApp(const MeshMessengerApp());
  }, (error, stack) {});
}

class MeshMessengerApp extends StatelessWidget {
  const MeshMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Маяк P2P Mesh',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F1419),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D2B8),
          brightness: Brightness.dark,
          surface: const Color(0xFF182028),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final MeshEngine _engine;
  final TextEditingController _inviteCtrl = TextEditingController();
  final ScrollController _chatScrollCtrl = ScrollController();

  String? _activeChatId;

  @override
  void initState() {
    super.initState();
    _engine = MeshEngine(
      onMessageReceived: (msg) {
        if (!mounted) return;
        setState(() {});
        _scrollToBottom();
      },
      onStateChanged: () {
        if (!mounted) return;
        setState(() {});
      },
    );
    _initNode();
  }

  Future<void> _initNode() async {
    await _engine.init();
    if (!mounted) return;
    setState(() {});
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          await _engine.requestAndroidNotifications();
        }
      });
    }
  }

  void _openChat(String chatId) {
    setState(() {
      _activeChatId = chatId;
      _engine.markChatAsRead(chatId);
    });
    _scrollToBottom();
  }

  void _closeChatToHome() {
    setState(() {
      _activeChatId = null;
      _engine.markChatAsRead(null);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollCtrl.hasClients) {
        _chatScrollCtrl.animateTo(
          _chatScrollCtrl.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendTextMessage(String text) async {
    final target = _activeChatId;
    if (target == null || text.isEmpty) return;
    await _engine.sendMessage(target, text);
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
  }

  Future<void> _pickAndSendAttachment(String mode) async {
    final target = _activeChatId;
    if (target == null || target == MeshEngine.broadcastChannelId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Пересылка зашифрованных медиа и файлов доступна в личных чатах'),
        ),
      );
      return;
    }
    final picked = await _engine.pickFileForChat(mode: mode);
    if (picked == null) return;
    final path = picked['path'] as String?;
    final name = picked['name'] as String?;
    if (path == null || name == null) return;

    await _engine.sendFileMessage(target, filePath: path, fileName: name);
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
  }

  Future<void> _toggleVoiceNoteRecording() async {
    final target = _activeChatId;
    if (target == null || target == MeshEngine.broadcastChannelId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Голосовые сообщения отправляются в личных чатах'),
        ),
      );
      return;
    }

    if (!_engine.isRecordingVoice) {
      final ok = await _engine.startVoiceRecording();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Проверьте доступ к микрофону для записи голоса')),
        );
      }
    } else {
      final recInfo = await _engine.stopVoiceRecording();
      if (recInfo != null) {
        final path = recInfo['path'] as String?;
        final name = recInfo['name'] as String?;
        if (path != null && name != null) {
          await _engine.sendFileMessage(target, filePath: path, fileName: name);
          if (mounted) setState(() {});
          _scrollToBottom();
        }
      }
    }
  }

  void _showReactionPicker(ChatMessage msg) {
    final target = _activeChatId;
    if (target == null) return;
    const emojis = ['👍', '❤️', '🔥', '😂', '😮', '👏', '💯', '🤝'];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A2530),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Поставить реакцию на сообщение',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: emojis
                  .map(
                    (e) => InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        Navigator.pop(ctx);
                        _engine.sendReaction(target, msg.msgId, e);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Text(
                          e,
                          style: const TextStyle(fontSize: 26),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// СКРЫТАЯ КОНСОЛЬ АДМИНА (открывается только по секретному мастер-ключу, без единого упоминания в UI!)
  void _showHiddenAdminConsoleModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111820),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final allNodes = _engine.knownContacts.values.toList();
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.88,
            maxChildSize: 0.96,
            builder: (_, scrollCtrl) => Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.admin_panel_settings,
                          color: Colors.redAccent, size: 26),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'ROOT-КОНСОЛЬ АДМИНИСТРАТОРА СЕТИ',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          for (final c in allNodes) {
                            if (c.isOnline) {
                              await _engine.pingPeer(c.nodeId);
                            }
                          }
                          if (ctx.mounted) setModalState(() {});
                        },
                        icon: const Icon(Icons.network_ping, size: 16),
                        label: const Text('Опросить сеть'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Мой узел: ${_engine.nodeId} • HW: ${_engine.myHwFingerprint} • IP: ${_engine.cachedIps.join(", ")}\n'
                    'Всего известных узлов: ${allNodes.length} • В глобальном бане: ${_engine.bannedNodeIds.length}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        color: Colors.white70,
                        fontFamily: 'monospace'),
                  ),
                  const Divider(height: 20),
                  Expanded(
                    child: allNodes.isEmpty
                        ? const Center(
                            child: Text(
                              'Пока нет обнаруженных узлов в сети.',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollCtrl,
                            itemCount: allNodes.length,
                            itemBuilder: (_, i) {
                              final c = allNodes[i];
                              final banned = _engine.isNodeBanned(
                                  c.nodeId, c.hwFingerprint);
                              final lastDt = c.lastSeenTimestamp > 0
                                  ? DateTime.fromMillisecondsSinceEpoch(
                                      c.lastSeenTimestamp)
                                  : null;
                              final lastStr = lastDt != null
                                  ? '${lastDt.hour.toString().padLeft(2, '0')}:${lastDt.minute.toString().padLeft(2, '0')}:${lastDt.second.toString().padLeft(2, '0')}'
                                  : 'неизвестно';

                              return Card(
                                color: banned
                                    ? const Color(0xFF2D161A)
                                    : const Color(0xFF1A242F),
                                margin: const EdgeInsets.only(bottom: 10),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            banned
                                                ? Icons.block
                                                : (c.isOnline
                                                    ? Icons.sensors
                                                    : Icons.portable_wifi_off),
                                            color: banned
                                                ? Colors.redAccent
                                                : (c.isOnline
                                                    ? Colors.greenAccent
                                                    : Colors.orangeAccent),
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              '${c.displayTitle} [ID: ${c.nodeId}]',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: banned
                                                  ? Colors.redAccent
                                                  : (c.isOnline
                                                      ? Colors.green.shade800
                                                      : Colors.blueGrey),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              banned
                                                  ? 'ЗАБАНЕН'
                                                  : (c.isOnline
                                                      ? 'ОНЛАЙН'
                                                      : 'ОФФЛАЙН'),
                                              style: const TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '📍 Сетевая точка / Маршрут: ${c.lastAddress.isNotEmpty ? c.lastAddress : "Неизвестно"}\n'
                                        '🔑 HW-отпечаток железа: ${c.hwFingerprint.isNotEmpty ? c.hwFingerprint : "не передан"}\n'
                                        '⚡ Пинг (RTT): ${c.lastPingMs >= 0 ? "${c.lastPingMs} мс" : "—"} • Пакетов: ${c.packetsSeenCount} • Активность: $lastStr',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.white70,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          if (!banned)
                                            FilledButton.icon(
                                              style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.redAccent,
                                              ),
                                              onPressed: () async {
                                                await _engine
                                                    .executeAdminBanOrUnban(
                                                  targetNodeId: c.nodeId,
                                                  ban: true,
                                                );
                                                if (ctx.mounted) {
                                                  setModalState(() {});
                                                }
                                              },
                                              icon: const Icon(Icons.gavel,
                                                  size: 16),
                                              label: const Text(
                                                  'Забанить в сети'),
                                            )
                                          else
                                            FilledButton.icon(
                                              style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.teal.shade700,
                                              ),
                                              onPressed: () async {
                                                await _engine
                                                    .executeAdminBanOrUnban(
                                                  targetNodeId: c.nodeId,
                                                  ban: false,
                                                );
                                                if (ctx.mounted) {
                                                  setModalState(() {});
                                                }
                                              },
                                              icon: const Icon(
                                                  Icons.lock_open,
                                                  size: 16),
                                              label: const Text('Разбанить'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showBenchmarkModal() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(
              child:
                  Text('Тестирование крипто-ядра и замер пинга до друзей...'),
            ),
          ],
        ),
      ),
    );

    final report = await _engine.runBenchmarkAndPing();
    if (!mounted) return;
    Navigator.pop(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.speed, color: Colors.tealAccent),
            SizedBox(width: 8),
            Expanded(child: Text('Бенчмарк Маяк v1.3')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Производительность криптографии на устройстве:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 6),
              Text(
                '• Потоковое шифрование ChaCha20-Poly1305: ${report.chachaMbPerSec.toStringAsFixed(1)} МБ/сек\n'
                '• Рукопожатия X25519 + HKDF: ${report.x25519HandshakesPerSec} опер/сек\n'
                '• Цифровые подписи Ed25519: ${report.ed25519SignsPerSec} пакет/сек',
                style: const TextStyle(fontSize: 13),
              ),
              const Divider(height: 20),
              const Text(
                'Живой сетевой пинг (RTT) до подключенных узлов:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 6),
              if (report.peerPingsMs.isEmpty)
                const Text(
                  'Нет активных прямых подключений для замера пинга.',
                  style: TextStyle(fontSize: 12.5, color: Colors.white60),
                )
              else
                ...report.peerPingsMs.entries.map(
                  (e) => Text(
                    '• ${e.key}: ${e.value >= 0 ? "${e.value} мс" : "Таймаут"}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отлично'),
          ),
        ],
      ),
    );
  }

  void _openFullScreenImage(String imagePath, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.black54,
            elevation: 0,
            title: Text(title, style: const TextStyle(fontSize: 15)),
            actions: [
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: 'Сохранить в Загрузки',
                onPressed: () async {
                  final msg = await _engine.saveReceivedFileToDownloads(
                      imagePath, title);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg)),
                  );
                },
              ),
            ],
          ),
          body: SizedBox.expand(
            child: InteractiveViewer(
              clipBehavior: Clip.none,
              panEnabled: true,
              scaleEnabled: true,
              minScale: 0.5,
              maxScale: 6.0,
              child: Center(
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openInAppVideoPlayer(String videoPath, String title) {
    _engine.stopAudioPlayback();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InAppVideoPlayerScreen(
          engine: _engine,
          videoPath: videoPath,
          title: title,
        ),
      ),
    );
  }

  Future<void> _showSafetyNumberDialog(ContactProfile contact) async {
    final safetyCode = await _engine.computeSafetyNumber(contact.nodeId);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.verified_user, color: Colors.tealAccent),
            SizedBox(width: 8),
            Expanded(child: Text('Код безопасности E2EE v2')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Сверьте этот код с устройством «${contact.displayTitle}»:',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.tealAccent.withOpacity(0.4)),
              ),
              child: Text(
                safetyCode,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  color: Colors.tealAccent,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteContact(ContactProfile contact) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Управление чатом «${contact.displayTitle}»'),
        content: const Text(
          'Вы можете очистить только переписку или полностью удалить контакт (он больше не появится автоматически после перезапуска).',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          OutlinedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _engine.clearChatHistoryOnly(contact.nodeId);
            },
            child: const Text('Очистить СМС'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              await _engine.deleteContact(contact.nodeId);
            },
            child: const Text('Удалить навсегда'),
          ),
        ],
      ),
    );
  }

  void _showAddContactModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить устройство по IP или коду'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Введи локальный IP второго устройства (например 192.168.1.5 или 192.168.43.1) либо вставь скопированный код-приглашение:',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inviteCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '192.168.1.5 или код узла...',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (val) async {
                Navigator.pop(ctx);
                await _handleConnectInput(val);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _handleConnectInput(_inviteCtrl.text);
            },
            child: const Text('Подключить'),
          ),
        ],
      ),
    );
  }

  void _showTutorialAndAutoSetupModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.84,
        maxChildSize: 0.95,
        builder: (_, scrollCtrl) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: scrollCtrl,
            children: [
              const Text(
                'Управление узлом «Маяк v1.3.0»',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showBenchmarkModal();
                    },
                    icon: const Icon(Icons.speed, size: 18),
                    label: const Text('Запустить Бенчмарк и Пинг'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _engine.scanLocalSubnet();
                    },
                    icon: const Icon(Icons.radar, size: 18),
                    label: const Text('Полный поиск устройств в сети'),
                  ),
                  if (Platform.isAndroid)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await _engine.requestIgnoreBatteryOptimizations();
                      },
                      icon: const Icon(Icons.battery_charging_full, size: 18),
                      label:
                          const Text('Разрешить работу в фоне (POCO/Xiaomi)'),
                    ),
                  if (Platform.isWindows)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        final res =
                            await _engine.configureWindowsPublicFirewall();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(res == 'OK'
                                ? 'Порты 42069/42070 открыты для Общественной сети!'
                                : 'Запустите allow_public_network_firewall.bat от имени Администратора'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.security, size: 18),
                      label: const Text(
                          'Открыть доступ в Общественной сети (Firewall)'),
                    ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    onPressed: () => _engine.stopAllAndExitApp(),
                    icon: const Icon(Icons.power_settings_new, size: 18),
                    label: const Text('Полностью выключить Маяк и выйти'),
                  ),
                ],
              ),
              const Divider(height: 24),
              const Text(
                'Статус и возможности v1.3.0:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 6),
              const Text(
                '• Бесшовное обновление APK поверх старых версий (постоянный сертификат подписи + авто-бэкап переписки).\n'
                '• Потоковая передача больших файлов и видео до 1 ГБ напрямую на диск без переполнения памяти.\n'
                '• Встроенный аудиоплеер с перемоткой (Seek Bar) и запись голосовых сообщений 🎤 на Android и Windows ПК.\n'
                '• Встроенный видеоплеер внутри приложения и полноэкранный зум фотографий.',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditProfileDialog() {
    final nameCtrl = TextEditingController(text: _engine.nickname);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Мой профиль и сеть'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Постоянный ID узла: ${_engine.nodeId}\n'
                'Аппаратный отпечаток: ${_engine.myHwFingerprint}\n'
                'Физические IP: ${_engine.cachedIps.join(", ")}\n'
                'TCP-порт: ${_engine.listenPort}\n'
                'Файлов в очереди докачки: ${_engine.pendingFileJobs.length}\n'
                'Статус: ${_engine.lastStatusLog}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Твое имя / Позывной',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) async {
                  await _engine.updateNickname(nameCtrl.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              await _engine.updateNickname(nameCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showLogsModal() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Журнал работы узла Маяк',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: _engine.debugLogs.join('\n')),
                    );
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Журнал скопирован')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Скопировать'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _engine.debugLogs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _engine.debugLogs[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMyQrModal() async {
    await _engine.refreshNetworkCache(force: true);
    if (!mounted || _engine.cachedInviteCode.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${_engine.nickname} (${_engine.nodeId})'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              width: 230,
              height: 230,
              child: Center(
                child: QrImageView(
                  data: _engine.cachedInviteCode,
                  size: 210,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              'Прямой IP: ${_engine.cachedIps.join(", ")}:${_engine.listenPort}',
              style: const TextStyle(fontSize: 12, color: Colors.tealAccent),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _engine.cachedInviteCode));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Код скопирован')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Копировать код'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openQrScanner() async {
    if (Platform.isAndroid) {
      final camGranted = await _engine.requestCameraPermission();
      if (!camGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Для сканирования QR разрешите доступ к камере')),
        );
        return;
      }
    }

    if (!mounted) return;
    final scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (scannedCode != null && scannedCode.trim().isNotEmpty) {
      await _handleConnectInput(scannedCode);
    }
  }

  Future<void> _handleConnectInput(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;

    // Тихая криптографическая проверка секретной фразы Админа (фраза нигде в коде не хранится!)
    final isAdmin = await _engine.tryUnlockAdminConsole(trimmed);
    if (isAdmin) {
      _inviteCtrl.clear();
      if (!mounted) return;
      _showHiddenAdminConsoleModal();
      return;
    }

    try {
      final id = await _engine.connectWithInviteOrIp(trimmed);
      if (!mounted) return;
      _inviteCtrl.clear();
      if (id != null) {
        _openChat(id);
      }
      final label = id != null
          ? (_engine.knownContacts[id]?.displayTitle ?? id)
          : trimmed;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Подключение к узлу: $label')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Неверный формат кода или IP (пример: 192.168.1.5)')),
      );
    }
  }

  Widget _buildChatsListPane({required bool isWideScreen}) {
    final contacts = _engine.knownContacts.values
        .where((c) => !_engine.isNodeBanned(c.nodeId, c.hwFingerprint))
        .toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        final lastA = _engine.getLastMessageFor(a.nodeId)?.timestamp ?? 0;
        final lastB = _engine.getLastMessageFor(b.nodeId)?.timestamp ?? 0;
        return lastB.compareTo(lastA);
      });

    final lastBroadcast =
        _engine.getLastMessageFor(MeshEngine.broadcastChannelId);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: const Color(0xFF161F27),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield, size: 15, color: Colors.tealAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'IP: ${_engine.cachedIps.join(", ")}:${_engine.listenPort} • Онлайн: ${_engine.connectedPeersCount} • Буфер: ${_engine.transitBuffer.length}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Colors.tealAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (Platform.isAndroid)
                    SizedBox(
                      height: 28,
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: () async {
                          await _engine.toggleAndroidBleMesh();
                          if (mounted) setState(() {});
                        },
                        icon: Icon(
                          _engine.bleMeshActive
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth,
                          size: 14,
                          color: _engine.bleMeshActive
                              ? Colors.lightBlueAccent
                              : Colors.white70,
                        ),
                        label: Text(
                          _engine.bleMeshActive ? 'BLE Вкл' : 'Вкл BLE',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                ],
              ),
              if (_engine.vpnDetected)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '⚡ Активен VPN: включен прямой обход через локальный Wi-Fi IP',
                    style: TextStyle(fontSize: 11, color: Colors.amberAccent),
                  ),
                ),
              if (Platform.isAndroid &&
                  _engine.bleMeshActive &&
                  _engine.gpsDisabledOnAndroid)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '⚠️ Включи значок Геолокации (GPS) в верхней шторке телефона для поиска по Bluetooth!',
                    style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
                  ),
                ),
              const SizedBox(height: 3),
              Text(
                _engine.lastStatusLog,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                selected: _activeChatId == MeshEngine.broadcastChannelId &&
                    isWideScreen,
                selectedTileColor: Colors.teal.withOpacity(0.15),
                leading: CircleAvatar(
                  backgroundColor: Colors.amber.shade700,
                  child: const Icon(Icons.campaign, color: Colors.black),
                ),
                title: const Text(
                  'Общий эфир (Всем рядом)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  lastBroadcast != null
                      ? '${lastBroadcast.senderName}: ${lastBroadcast.text}'
                      : 'Широковещательный канал для всех устройств поблизости',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Colors.white70),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (lastBroadcast != null)
                      Text(
                        lastBroadcast.timeFormatted,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54),
                      ),
                    if (_engine.unreadBroadcastCount > 0)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amberAccent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_engine.unreadBroadcastCount}',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                onTap: () => _openChat(MeshEngine.broadcastChannelId),
              ),
              const Divider(height: 1),

              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Icon(Icons.people_outline,
                          size: 48, color: Colors.white24),
                      const SizedBox(height: 12),
                      const Text(
                        'Пока нет активных чатов.\n\n'
                        '• В одной Wi-Fi сети или Точке доступа устройства находятся автоматически.\n'
                        '• Для Bluetooth-связи без Wi-Fi нажмите «Вкл BLE» на обоих телефонах.\n'
                        '• Или добавьте друга по IP / QR-коду кнопкой ниже.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: _showAddContactModal,
                            icon: const Icon(Icons.person_add, size: 18),
                            label: const Text('Подключить по IP / Коду'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _engine.scanLocalSubnet(),
                            icon: const Icon(Icons.radar, size: 18),
                            label: const Text('Сканировать сеть'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              ...contacts.map((c) {
                final lastMsg = _engine.getLastMessageFor(c.nodeId);
                final isSelected = _activeChatId == c.nodeId && isWideScreen;
                return Column(
                  children: [
                    ListTile(
                      selected: isSelected,
                      selectedTileColor: Colors.teal.withOpacity(0.15),
                      leading: Stack(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.teal.shade700,
                            child: Text(
                              c.displayTitle.isNotEmpty
                                  ? c.displayTitle[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: c.isOnline
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFF0F1419), width: 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            c.nodeId,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        lastMsg != null
                            ? '${lastMsg.isMe ? "Вы: " : ""}${lastMsg.text}'
                            : (c.isOnline
                                ? 'В сети (${c.lastAddress}) • Защищено E2EE v2'
                                : 'Оффлайн / Доставка через Mesh-курьеров'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: c.unreadCount > 0
                              ? Colors.white
                              : Colors.white60,
                          fontWeight: c.unreadCount > 0
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (lastMsg != null)
                            Text(
                              lastMsg.timeFormatted,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54),
                            ),
                          if (c.unreadCount > 0)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.tealAccent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${c.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      onTap: () => _openChat(c.nodeId),
                      onLongPress: () => _confirmDeleteContact(c),
                    ),
                    const Divider(height: 1, indent: 70),
                  ],
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageContent(ChatMessage m) {
    final hasFile = m.fileName != null && m.fileName!.isNotEmpty;
    if (!hasFile) {
      return Text(
        m.text,
        style: const TextStyle(fontSize: 15, color: Colors.white),
      );
    }

    final fileReady = m.filePath != null && File(m.filePath!).existsSync();
    final isThisAudioActive =
        fileReady && _engine.currentlyPlayingAudioPath == m.filePath;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.isImageFile && fileReady)
          GestureDetector(
            onTap: () => _openFullScreenImage(m.filePath!, m.fileName!),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 280,
                  maxHeight: 240,
                ),
                child: Image.file(
                  File(m.filePath!),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.isAudioFile && fileReady)
                    IconButton(
                      icon: Icon(
                        (isThisAudioActive && _engine.isAudioPlaying)
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: Colors.tealAccent,
                        size: 34,
                      ),
                      tooltip: (isThisAudioActive && _engine.isAudioPlaying)
                          ? 'Пауза'
                          : 'Прослушать в программе',
                      onPressed: () => _engine.togglePlayAudioFile(m.filePath!),
                    )
                  else if (m.isVideoFile && fileReady)
                    IconButton(
                      icon: const Icon(
                        Icons.smart_display,
                        color: Colors.amberAccent,
                        size: 34,
                      ),
                      tooltip: 'Смотреть видео в программе',
                      onPressed: () =>
                          _openInAppVideoPlayer(m.filePath!, m.fileName!),
                    )
                  else
                    Icon(
                      m.isImageFile
                          ? Icons.image
                          : (m.isVideoFile
                              ? Icons.videocam
                              : (m.isAudioFile
                                  ? Icons.audiotrack
                                  : Icons.insert_drive_file)),
                      color: Colors.tealAccent,
                      size: 26,
                    ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.fileName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          m.transferProgress < 1.0
                              ? '${m.fileSizeFormatted} • Передача ${(m.transferProgress * 100).toInt()}%'
                              : m.fileSizeFormatted,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  if (fileReady) ...[
                    IconButton(
                      icon: const Icon(Icons.download,
                          size: 20, color: Colors.tealAccent),
                      tooltip: 'Сохранить в Загрузки/Mayak',
                      onPressed: () async {
                        final res = await _engine.saveReceivedFileToDownloads(
                          m.filePath!,
                          m.fileName!,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(res)),
                        );
                      },
                    ),
                  ],
                ],
              ),
              if (m.isAudioFile && isThisAudioActive)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                        ),
                        child: Slider(
                          value: _engine.audioPositionMs
                              .toDouble()
                              .clamp(0.0, _engine.audioDurationMs.toDouble()),
                          min: 0.0,
                          max: max(_engine.audioDurationMs.toDouble(), 1.0),
                          activeColor: Colors.tealAccent,
                          inactiveColor: Colors.white24,
                          onChanged: (val) {
                            _engine.seekAudioFile(val.round());
                          },
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            MeshEngine.formatDurationMs(
                                _engine.audioPositionMs),
                            style: const TextStyle(
                                fontSize: 10.5, color: Colors.white70),
                          ),
                          Text(
                            MeshEngine.formatDurationMs(
                                _engine.audioDurationMs),
                            style: const TextStyle(
                                fontSize: 10.5, color: Colors.white70),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (m.transferProgress < 1.0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              value: m.transferProgress,
              backgroundColor: Colors.white12,
              color: Colors.tealAccent,
            ),
          ),
      ],
    );
  }

  Widget _buildConversationPane({required bool showBackButton}) {
    final chatId = _activeChatId;
    if (chatId == null) {
      return const Center(
        child: Text(
          'Выберите чат слева или подключите устройство,\nчтобы начать переписку и обмен файлами до 1 ГБ.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 14),
        ),
      );
    }

    final isBroadcast = chatId == MeshEngine.broadcastChannelId;
    final contact = isBroadcast ? null : _engine.knownContacts[chatId];
    final title = isBroadcast
        ? '📢 Общий эфир (Всем рядом)'
        : (contact?.displayTitle ?? 'Узел $chatId');
    final subtitle = isBroadcast
        ? 'Видят все устройства поблизости (Онлайн: ${_engine.connectedPeersCount})'
        : (contact?.isOnline == true
            ? '🟢 Прямая связь (${contact?.lastAddress ?? "P2P"}) • Файлы до 1 ГБ'
            : '🟠 Через буфер Mesh («3 улицы») • Авто-докачка активна');

    final messages = _engine.getMessagesFor(chatId);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF18222C),
            border: Border(bottom: BorderSide(color: Colors.white12)),
          ),
          child: Row(
            children: [
              if (showBackButton)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Назад к списку чатов',
                  onPressed: _closeChatToHome,
                ),
              CircleAvatar(
                radius: 18,
                backgroundColor:
                    isBroadcast ? Colors.amber.shade700 : Colors.teal.shade700,
                child: isBroadcast
                    ? const Icon(Icons.campaign, color: Colors.black, size: 20)
                    : Text(
                        title.isNotEmpty ? title[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 11.5, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (!isBroadcast && contact != null) ...[
                IconButton(
                  icon: const Icon(Icons.verified_user_outlined,
                      color: Colors.tealAccent, size: 20),
                  tooltip: 'Проверить Код безопасности E2EE',
                  onPressed: () => _showSafetyNumberDialog(contact),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.white54, size: 20),
                  tooltip: 'Очистить или удалить чат',
                  onPressed: () => _confirmDeleteContact(contact),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      isBroadcast
                          ? 'Здесь отображаются открытые сообщения и реакции для всех вокруг.'
                          : 'Защищенный E2EE v2 диалог с «$title».\nОтправляйте текст, смайлики 😊, голосовые 🎤, музыку 🎵, фото и видео до 1 ГБ 🎬.\nНажмите на любое сообщение, чтобы поставить реакцию 👍❤️🔥.',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollCtrl,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[i];
                    final align = m.isMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start;
                    final bubbleColor = m.isMe
                        ? const Color(0xFF005C4B)
                        : const Color(0xFF1F2C34);

                    final reactionCounts = <String, int>{};
                    for (final emoji in m.reactions.values) {
                      reactionCounts[emoji] = (reactionCounts[emoji] ?? 0) + 1;
                    }

                    return Column(
                      crossAxisAlignment: align,
                      children: [
                        GestureDetector(
                          onTap: () => _showReactionPicker(m),
                          onLongPress: () => _showReactionPicker(m),
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 340),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: bubbleColor,
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(14),
                                topRight: const Radius.circular(14),
                                bottomLeft:
                                    Radius.circular(m.isMe ? 14 : 3),
                                bottomRight:
                                    Radius.circular(m.isMe ? 3 : 14),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!m.isMe && isBroadcast)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      m.senderName,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.tealAccent,
                                      ),
                                    ),
                                  ),
                                _buildMessageContent(m),
                                if (reactionCounts.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: reactionCounts.entries
                                          .map(
                                            (e) => Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 7,
                                                      vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.black38,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Text(
                                                e.value > 1
                                                    ? '${e.key} ${e.value}'
                                                    : e.key,
                                                style: const TextStyle(
                                                    fontSize: 13),
                                              ),
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  ),
                                const SizedBox(height: 3),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(
                                      m.timeFormatted,
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.white60),
                                    ),
                                    if (m.isMe) ...[
                                      const SizedBox(width: 5),
                                      Icon(
                                        m.isDelivered
                                            ? Icons.done_all
                                            : Icons.schedule,
                                        size: 14,
                                        color: m.isDelivered
                                            ? Colors.lightBlueAccent
                                            : Colors.white54,
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        ChatInputBar(
          hintText: isBroadcast
              ? 'Сообщение всем вокруг...'
              : 'Сообщение для $title...',
          allowAttachments: !isBroadcast,
          isRecordingVoice: _engine.isRecordingVoice,
          onSend: _sendTextMessage,
          onPickMedia: () => _pickAndSendAttachment('media'),
          onPickAudio: () => _pickAndSendAttachment('audio'),
          onPickFile: () => _pickAndSendAttachment('all'),
          onToggleVoiceRecord: _toggleVoiceNoteRecording,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideScreen = constraints.maxWidth >= 700;

        return PopScope(
          canPop: isWideScreen || _activeChatId == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _activeChatId != null && !isWideScreen) {
              _closeChatToHome();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: InkWell(
                onTap: _showEditProfileDialog,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 15,
                      backgroundColor: Colors.tealAccent.shade700,
                      child: Text(
                        _engine.nickname.isNotEmpty
                            ? _engine.nickname[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _engine.nickname.isEmpty ? 'Маяк' : _engine.nickname,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, size: 15, color: Colors.white54),
                  ],
                ),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.speed, color: Colors.tealAccent),
                  tooltip: 'Бенчмарк и Пинг',
                  onPressed: _showBenchmarkModal,
                ),
                IconButton(
                  icon: const Icon(Icons.person_add_alt_1),
                  tooltip: 'Добавить по IP или коду',
                  onPressed: _showAddContactModal,
                ),
                IconButton(
                  icon: _engine.isScanningSubnet
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar),
                  tooltip: 'Поиск узлов в Wi-Fi / Точке доступа',
                  onPressed: () => _engine.scanLocalSubnet(),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code),
                  tooltip: 'Мой QR-код',
                  onPressed: _showMyQrModal,
                ),
                if (Platform.isAndroid || Platform.isIOS)
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Сканировать QR камерой',
                    onPressed: _openQrScanner,
                  ),
                IconButton(
                  icon:
                      const Icon(Icons.help_outline, color: Colors.amberAccent),
                  tooltip: 'Автонастройка и Выход',
                  onPressed: _showTutorialAndAutoSetupModal,
                ),
                IconButton(
                  icon: const Icon(Icons.terminal),
                  tooltip: 'Журнал сети',
                  onPressed: _showLogsModal,
                ),
              ],
            ),
            body: isWideScreen
                ? Row(
                    children: [
                      SizedBox(
                        width: 340,
                        child: _buildChatsListPane(isWideScreen: true),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _buildConversationPane(showBackButton: false),
                      ),
                    ],
                  )
                : (_activeChatId == null
                    ? _buildChatsListPane(isWideScreen: false)
                    : _buildConversationPane(showBackButton: true)),
          ),
        );
      },
    );
  }
}

class InAppVideoPlayerScreen extends StatefulWidget {
  final MeshEngine engine;
  final String videoPath;
  final String title;

  const InAppVideoPlayerScreen({
    super.key,
    required this.engine,
    required this.videoPath,
    required this.title,
  });

  @override
  State<InAppVideoPlayerScreen> createState() => _InAppVideoPlayerScreenState();
}

class _InAppVideoPlayerScreenState extends State<InAppVideoPlayerScreen> {
  int? _textureId;
  int _videoWidth = 1280;
  int _videoHeight = 720;
  int _positionMs = 0;
  int _durationMs = 1;
  bool _isPlaying = true;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    if (Platform.isAndroid) {
      final res = await widget.engine.nativeChannel
          .invokeMapMethod<String, dynamic>(
        'initInAppVideo',
        {'path': widget.videoPath},
      );
      if (!mounted) return;
      if (res != null) {
        setState(() {
          _textureId = res['textureId'] as int?;
          _videoWidth = (res['width'] as int?) ?? 1280;
          _videoHeight = (res['height'] as int?) ?? 720;
          _durationMs = max((res['durationMs'] as int?) ?? 1, 1);
          _loading = false;
        });
        _timer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
          final st = await widget.engine.nativeChannel
              .invokeMapMethod<String, dynamic>(
            'controlInAppVideo',
            {'action': 'status', 'positionMs': 0},
          );
          if (!mounted || st == null) return;
          setState(() {
            _isPlaying = (st['isPlaying'] as bool?) ?? false;
            _positionMs = (st['positionMs'] as int?) ?? 0;
            _durationMs = max((st['durationMs'] as int?) ?? 1, 1);
          });
        });
      } else {
        setState(() => _loading = false);
      }
    } else {
      await widget.engine.togglePlayAudioFile(widget.videoPath);
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _sendControl(String action, [int posMs = 0]) async {
    if (Platform.isAndroid) {
      final st = await widget.engine.nativeChannel
          .invokeMapMethod<String, dynamic>(
        'controlInAppVideo',
        {'action': action, 'positionMs': posMs},
      );
      if (!mounted || st == null) return;
      setState(() {
        _isPlaying = (st['isPlaying'] as bool?) ?? false;
        _positionMs = (st['positionMs'] as int?) ?? 0;
      });
    } else if (Platform.isWindows) {
      if (action == 'seek') {
        await widget.engine.seekAudioFile(posMs);
      } else {
        await widget.engine.togglePlayAudioFile(widget.videoPath);
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (Platform.isAndroid) {
      widget.engine.nativeChannel.invokeMethod('disposeInAppVideo');
    } else {
      widget.engine.stopAudioPlayback();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _videoHeight > 0 ? (_videoWidth / _videoHeight) : (16 / 9);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Сохранить в Загрузки/Mayak',
            onPressed: () async {
              final msg = await widget.engine.saveReceivedFileToDownloads(
                widget.videoPath,
                widget.title,
              );
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(msg)),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : (_textureId != null
                      ? AspectRatio(
                          aspectRatio: aspect,
                          child: Texture(textureId: _textureId!),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.movie,
                                size: 72, color: Colors.tealAccent),
                            const SizedBox(height: 12),
                            Text(widget.title),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () => widget.engine
                                  .openFileExternal(widget.videoPath),
                              icon: const Icon(Icons.fullscreen),
                              label:
                                  const Text('Развернуть окно видео DirectX'),
                            ),
                          ],
                        )),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF141C24),
            child: Column(
              children: [
                Slider(
                  value: (Platform.isAndroid
                          ? _positionMs
                          : widget.engine.audioPositionMs)
                      .toDouble()
                      .clamp(
                          0.0,
                          max(
                              (Platform.isAndroid
                                      ? _durationMs
                                      : widget.engine.audioDurationMs)
                                  .toDouble(),
                              1.0)),
                  min: 0.0,
                  max: max(
                      (Platform.isAndroid
                              ? _durationMs
                              : widget.engine.audioDurationMs)
                          .toDouble(),
                      1.0),
                  activeColor: Colors.tealAccent,
                  onChanged: (val) => _sendControl('seek', val.round()),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      MeshEngine.formatDurationMs(Platform.isAndroid
                          ? _positionMs
                          : widget.engine.audioPositionMs),
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.replay_10, size: 28),
                          onPressed: () =>
                              _sendControl('seek', max(0, _positionMs - 10000)),
                        ),
                        const SizedBox(width: 8),
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: Colors.tealAccent.shade700,
                          child: IconButton(
                            icon: Icon(
                              _isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.black,
                              size: 28,
                            ),
                            onPressed: () =>
                                _sendControl(_isPlaying ? 'pause' : 'play'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.forward_10, size: 28),
                          onPressed: () => _sendControl(
                              'seek', min(_durationMs, _positionMs + 10000)),
                        ),
                      ],
                    ),
                    Text(
                      MeshEngine.formatDurationMs(Platform.isAndroid
                          ? _durationMs
                          : widget.engine.audioDurationMs),
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ChatInputBar extends StatefulWidget {
  final String hintText;
  final bool allowAttachments;
  final bool isRecordingVoice;
  final Future<void> Function(String text) onSend;
  final VoidCallback onPickMedia;
  final VoidCallback onPickAudio;
  final VoidCallback onPickFile;
  final VoidCallback onToggleVoiceRecord;

  const ChatInputBar({
    super.key,
    required this.hintText,
    required this.allowAttachments,
    required this.isRecordingVoice,
    required this.onSend,
    required this.onPickMedia,
    required this.onPickAudio,
    required this.onPickFile,
    required this.onToggleVoiceRecord,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _showEmojiPanel = false;

  static const List<String> _builtInEmojis = [
    '😀', '😂', '🤣', '😊', '😍', '😎', '🤝', '👍',
    '👎', '❤️', '🔥', '💯', '🎉', '👏', '🙏', '💪',
    '🤔', '😮', '😢', '😡', '🥳', '🤩', '🫡', '🤫',
    '✅', '❌', '⚡', '📡', '🛡️', '🔒', '📍', '🚀',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    _focus.requestFocus();
    widget.onSend(text);
  }

  void _insertEmoji(String emoji) {
    final text = _ctrl.text;
    final sel = _ctrl.selection;
    if (sel.isValid && sel.start >= 0) {
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      _ctrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      );
    } else {
      _ctrl.text = text + emoji;
      _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A2530),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.teal,
                child: Icon(Icons.perm_media, color: Colors.white),
              ),
              title: const Text('Фото или Видео (до 1 ГБ)'),
              subtitle: const Text(
                  'Отправить фотографию или большой видеоролик из галереи'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onPickMedia();
              },
            ),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.deepPurple,
                child: Icon(Icons.music_note, color: Colors.white),
              ),
              title: const Text('Музыка или Аудиофайл'),
              subtitle: const Text(
                  'Отправить трек с проигрыванием и перемоткой в чате'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onPickAudio();
              },
            ),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.blueGrey,
                child: Icon(Icons.insert_drive_file, color: Colors.white),
              ),
              title: const Text('Любой файл / Архив (до 1 ГБ)'),
              subtitle: const Text(
                  'Потоковая передача больших файлов напрямую с диска'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onPickFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showEmojiPanel)
          Container(
            height: 150,
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF141C24),
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: _builtInEmojis.length,
              itemBuilder: (_, i) {
                final e = _builtInEmojis[i];
                return InkWell(
                  onTap: () => _insertEmoji(e),
                  borderRadius: BorderRadius.circular(8),
                  child: Center(
                    child: Text(
                      e,
                      style: const TextStyle(fontSize: 22),
                    ),
                  ),
                );
              },
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          color: const Color(0xFF18222C),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  _showEmojiPanel
                      ? Icons.keyboard
                      : Icons.emoji_emotions_outlined,
                  color: Colors.amberAccent,
                ),
                tooltip: 'Смайлики',
                onPressed: () {
                  setState(() => _showEmojiPanel = !_showEmojiPanel);
                },
              ),
              if (widget.allowAttachments)
                IconButton(
                  icon: const Icon(Icons.attach_file, color: Colors.tealAccent),
                  tooltip: 'Прикрепить Фото, Видео, Музыку или Файл (до 1 ГБ)',
                  onPressed: _showAttachmentMenu,
                ),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: widget.isRecordingVoice
                        ? '🔴 Идет запись голоса (нажми стоп)...'
                        : widget.hintText,
                    filled: true,
                    fillColor: const Color(0xFF23303C),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              if (widget.allowAttachments) ...[
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 20,
                  backgroundColor: widget.isRecordingVoice
                      ? Colors.redAccent
                      : const Color(0xFF263542),
                  child: IconButton(
                    icon: Icon(
                      widget.isRecordingVoice ? Icons.stop : Icons.mic,
                      color: Colors.white,
                      size: 19,
                    ),
                    tooltip: widget.isRecordingVoice
                        ? 'Остановить и отправить голосовое'
                        : 'Записать голосовое сообщение',
                    onPressed: widget.onToggleVoiceRecord,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              CircleAvatar(
                radius: 21,
                backgroundColor: Colors.tealAccent.shade700,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.black, size: 19),
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  late final MobileScannerController _controller;
  bool _alreadyScanned = false;
  bool _cameraStarted = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      formats: const [BarcodeFormat.qrCode],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      try {
        await _controller.start();
        if (mounted) {
          setState(() => _cameraStarted = true);
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Наведи камеру на QR-код'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            tooltip: 'Переключить камеру',
            onPressed: () => _controller.switchCamera(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Перезапустить камеру',
            onPressed: () async {
              try {
                await _controller.stop();
                await Future.delayed(const Duration(milliseconds: 200));
                await _controller.start();
              } catch (_) {}
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            errorBuilder: (context, error, child) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Не удалось запустить превью камеры (${error.errorCode}).\nНажмите «Перезапустить» или подключитесь по IP.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => _controller.start(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Перезапустить камеру'),
                      ),
                    ],
                  ),
                ),
              );
            },
            onDetect: (capture) {
              if (_alreadyScanned) return;
              for (final barcode in capture.barcodes) {
                final raw = barcode.rawValue;
                if (raw != null && raw.trim().isNotEmpty) {
                  _alreadyScanned = true;
                  HapticFeedback.mediumImpact();
                  Navigator.pop(context, raw.trim());
                  break;
                }
              }
            },
          ),
          if (!_cameraStarted)
            const Center(
              child: CircularProgressIndicator(),
            ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.tealAccent, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
