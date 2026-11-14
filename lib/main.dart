import 'dart:async';
import 'dart:convert';
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
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF6366F1),
          surface: Color(0xFF111827),
          onSurface: Color(0xFFF1F5F9),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111827),
          elevation: 0,
          scrolledUnderElevation: 0,
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
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _chatScrollCtrl = ScrollController();

  String? _activeChatId;
  String _searchQuery = '';

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

  List<Color> _avatarGradientFor(String seed) {
    final hash = seed.codeUnits.fold<int>(0, (p, c) => p + c * 31);
    const palettes = [
      [Color(0xFF6366F1), Color(0xFF0EA5E9)],
      [Color(0xFFEC4899), Color(0xFF8B5CF6)],
      [Color(0xFF10B981), Color(0xFF059669)],
      [Color(0xFFF59E0B), Color(0xFFEF4444)],
      [Color(0xFF3B82F6), Color(0xFF2DD4BF)],
    ];
    return palettes[hash.abs() % palettes.length];
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
          _chatScrollCtrl.position.maxScrollExtent + 140,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendTextMessage(String text) async {
    final target = _activeChatId;
    if (target == null || text.isEmpty) return;
    if (_engine.isSelfBanned) {
      _showBanAppealDialog();
      return;
    }
    final ok = await _engine.sendMessage(target, text);
    if (!mounted) return;
    if (!ok && _engine.isSelfBanned) {
      _showBanAppealDialog();
      return;
    }
    setState(() {});
    _scrollToBottom();
  }

  Future<void> _pickAndSendAttachment(String mode) async {
    if (_engine.isSelfBanned) {
      _showBanAppealDialog();
      return;
    }
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
    final thumbPath = picked['thumbPath'] as String?;
    if (path == null || name == null) return;

    await _engine.sendFileMessage(
      target,
      filePath: path,
      fileName: name,
      thumbPathArg: thumbPath,
    );
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
  }

  Future<void> _toggleVoiceNoteRecording() async {
    if (_engine.isSelfBanned) {
      _showBanAppealDialog();
      return;
    }
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
        if (path != null && name == null) return;
        if (path != null && name != null) {
          await _engine.sendFileMessage(target, filePath: path, fileName: name);
          if (mounted) setState(() {});
          _scrollToBottom();
        }
      }
    }
  }

  /// Диалог отправки записки администратору, если пользователя забанили
  void _showBanAppealDialog() {
    final noteCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161F30),
        title: const Row(
          children: [
            Icon(Icons.gavel, color: Colors.redAccent),
            SizedBox(width: 8),
            Expanded(child: Text('Ваш узел ограничен')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Администратор сети ограничил отправку сообщений с вашего устройства. Если бан выдан по ошибке или вам нужен разбан, напишите короткую записку администратору:',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Напишите причину для разбана...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              final txt = noteCtrl.text.trim();
              if (txt.isEmpty) return;
              Navigator.pop(ctx);
              await _engine.sendBanAppealNote(txt);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text('Записка отправлена в консоль администратора сети'),
                ),
              );
            },
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Отправить записку'),
          ),
        ],
      ),
    );
  }

  void _showReactionPicker(ChatMessage msg) {
    final target = _activeChatId;
    if (target == null || _engine.isSelfBanned) return;
    const emojis = ['👍', '❤️', '🔥', '😂', '😮', '👏', '💯', '🤝'];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F30),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Быстрая реакция на сообщение',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 14),
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
                          color: Colors.white.withOpacity(0.06),
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

  /// СКРЫТАЯ ROOT-КОНСОЛЬ АДМИНА v2 (3 вкладки: Узлы и Локатор, Триггеры -5:+5, Апелляции на разбан)
  void _showHiddenAdminConsoleModal() {
    _engine.pingAllKnownNodes();
    final triggerInputCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D131F),
      builder: (ctx) => DefaultTabController(
        length: 3,
        child: StatefulBuilder(
          builder: (ctx, setModalState) {
            final allNodes = _engine.knownContacts.values.toList()
              ..sort((a, b) => (b.isOnline ? 1 : 0) - (a.isOnline ? 1 : 0));

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.90,
              maxChildSize: 0.96,
              builder: (_, scrollCtrl) => Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.admin_panel_settings,
                              color: Colors.redAccent, size: 24),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'ROOT-КОНСОЛЬ АДМИНИСТРАТОРА',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.redAccent,
                                ),
                              ),
                              Text(
                                'Мой ID: ${_engine.nodeId} (🟢 В СЕТИ) • IP: ${_engine.cachedIps.join(", ")}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.greenAccent,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            await _engine.pingAllKnownNodes();
                            if (ctx.mounted) setModalState(() {});
                          },
                          icon: const Icon(Icons.sync, size: 16),
                          label: const Text('Обновить'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF161F30),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TabBar(
                        indicatorColor: Colors.redAccent,
                        labelColor: Colors.white,
                        unselectedLabelColor: Colors.white54,
                        tabs: [
                          Tab(text: '📡 Узлы (${allNodes.length + 1})'),
                          Tab(
                              text:
                                  '🎯 Триггеры (${_engine.triggerHits.length})'),
                          Tab(
                              text:
                                  '📨 Апелляции (${_engine.banAppeals.length})'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // ВКЛАДКА 1: ВСЕ УЗЛЫ И ЛОКАТОР СЕТИ
                          ListView(
                            controller: scrollCtrl,
                            children: [
                              // Карточка собственного узла администратора (всегда ОНЛАЙН)
                              Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF14242B),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                      color:
                                          Colors.greenAccent.withOpacity(0.4)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.verified_user,
                                        color: Colors.greenAccent),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        '${_engine.nickname} [ЭТОТ УЗЕЛ: ${_engine.nodeId}]\n'
                                        '📍 IP: ${_engine.cachedIps.join(", ")}:${_engine.listenPort} • HW: ${_engine.myHwFingerprint}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace'),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade800,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'АДМИН • ОНЛАЙН',
                                        style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (allNodes.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Center(
                                    child: Text(
                                      'Других узлов в локальном реестре пока не обнаружено.',
                                      style: TextStyle(color: Colors.white54),
                                    ),
                                  ),
                                ),
                              ...allNodes.map((c) {
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
                                      ? const Color(0xFF2B1419)
                                      : const Color(0xFF162030),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
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
                                                      : Icons
                                                          .portable_wifi_off),
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
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3),
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
                                                    fontWeight:
                                                        FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          '📍 Точка / Маршрут: ${c.lastAddress.isNotEmpty ? c.lastAddress : "Неизвестно"}\n'
                                          '🔑 HW-отпечаток: ${c.hwFingerprint.isNotEmpty ? c.hwFingerprint : "не передан"}\n'
                                          '⚡ Пинг: ${c.lastPingMs >= 0 ? "${c.lastPingMs} мс" : "активен"} • Пакетов: ${c.packetsSeenCount} • Сигнал: $lastStr',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            color: Colors.white70,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: () async {
                                                await _engine
                                                    .pingPeer(c.nodeId);
                                                if (ctx.mounted) {
                                                  setModalState(() {});
                                                }
                                              },
                                              icon: const Icon(
                                                  Icons.network_ping,
                                                  size: 15),
                                              label: const Text('Пинг'),
                                            ),
                                            const SizedBox(width: 8),
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
                              }),
                            ],
                          ),

                          // ВКЛАДКА 2: ТРИГГЕРЫ В ЧАТАХ (КОНТЕКСТ -5 : +5 СООБЩЕНИЙ)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: triggerInputCtrl,
                                      decoration: const InputDecoration(
                                        hintText:
                                            'Добавить слово-триггер (например: спам)...',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton(
                                    onPressed: () async {
                                      final w = triggerInputCtrl.text.trim();
                                      if (w.isEmpty) return;
                                      triggerInputCtrl.clear();
                                      await _engine.addAdminTriggerWord(w);
                                      if (ctx.mounted) setModalState(() {});
                                    },
                                    child: const Text('+ Добавить'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: _engine.adminTriggerWords
                                    .map(
                                      (w) => Chip(
                                        label: Text(w,
                                            style:
                                                const TextStyle(fontSize: 12)),
                                        backgroundColor:
                                            const Color(0xFF1E293B),
                                        onDeleted: () async {
                                          await _engine
                                              .removeAdminTriggerWord(w);
                                          if (ctx.mounted) setModalState(() {});
                                        },
                                      ),
                                    )
                                    .toList(),
                              ),
                              const Divider(height: 16),
                              Expanded(
                                child: _engine.triggerHits.isEmpty
                                    ? const Center(
                                        child: Text(
                                          'Срабатываний триггеров пока нет.\nПри появлении слова-триггера в чате здесь отобразится контекст (-5 до и +5 после).',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: Colors.white54,
                                              fontSize: 12.5),
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: _engine.triggerHits.length,
                                        itemBuilder: (_, idx) {
                                          final hit = _engine.triggerHits[idx];
                                          final isBanned = _engine.isNodeBanned(
                                              hit.offenderNodeId);
                                          return Card(
                                            color: const Color(0xFF1A2234),
                                            margin: const EdgeInsets.only(
                                                bottom: 10),
                                            child: Padding(
                                              padding: const EdgeInsets.all(12),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      const Icon(
                                                          Icons
                                                              .warning_amber_rounded,
                                                          color:
                                                              Colors.amberAccent,
                                                          size: 20),
                                                      const SizedBox(width: 6),
                                                      Expanded(
                                                        child: Text(
                                                          'Триггер «${hit.triggerWord}» • ${hit.chatTitle}',
                                                          style:
                                                              const TextStyle(
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color: Colors
                                                                .amberAccent,
                                                          ),
                                                        ),
                                                      ),
                                                      if (hit.offenderNodeId !=
                                                          _engine.nodeId)
                                                        FilledButton.tonal(
                                                          style: FilledButton
                                                              .styleFrom(
                                                            backgroundColor: isBanned
                                                                ? Colors.teal
                                                                : Colors
                                                                    .redAccent,
                                                          ),
                                                          onPressed: () async {
                                                            await _engine
                                                                .executeAdminBanOrUnban(
                                                              targetNodeId: hit
                                                                  .offenderNodeId,
                                                              ban: !isBanned,
                                                            );
                                                            if (ctx.mounted) {
                                                              setModalState(
                                                                  () {});
                                                            }
                                                          },
                                                          child: Text(
                                                            isBanned
                                                                ? 'Разбанить'
                                                                : 'Бан автора',
                                                            style:
                                                                const TextStyle(
                                                                    fontSize:
                                                                        11),
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Container(
                                                    width: double.infinity,
                                                    padding:
                                                        const EdgeInsets.all(8),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black38,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                    ),
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        if (hit.beforeLines
                                                            .isNotEmpty) ...[
                                                          const Text(
                                                            '--- До триггера (-5) ---',
                                                            style: TextStyle(
                                                                fontSize: 10,
                                                                color: Colors
                                                                    .white38),
                                                          ),
                                                          ...hit.beforeLines
                                                              .map((l) => Text(
                                                                    l,
                                                                    style: const TextStyle(
                                                                        fontSize:
                                                                            11.5,
                                                                        color: Colors
                                                                            .white70),
                                                                  )),
                                                        ],
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  vertical: 4),
                                                          child: Text(
                                                            '🚨 ${hit.triggerLine}',
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 12.5,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              color: Colors
                                                                  .redAccent,
                                                            ),
                                                          ),
                                                        ),
                                                        if (hit.afterLines
                                                            .isNotEmpty) ...[
                                                          const Text(
                                                            '--- После триггера (+5) ---',
                                                            style: TextStyle(
                                                                fontSize: 10,
                                                                color: Colors
                                                                    .white38),
                                                          ),
                                                          ...hit.afterLines.map(
                                                              (l) => Text(
                                                                    l,
                                                                    style: const TextStyle(
                                                                        fontSize:
                                                                            11.5,
                                                                        color: Colors
                                                                            .white70),
                                                                  )),
                                                        ],
                                                      ],
                                                    ),
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

                          // ВКЛАДКА 3: АПЕЛЛЯЦИИ НА РАЗБАН
                          _engine.banAppeals.isEmpty
                              ? const Center(
                                  child: Text(
                                    'Записок на разбан от заблокированных пользователей пока нет.',
                                    style: TextStyle(color: Colors.white54),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _engine.banAppeals.length,
                                  itemBuilder: (_, idx) {
                                    final a = _engine.banAppeals[idx];
                                    return Card(
                                      color: const Color(0xFF1B2436),
                                      margin: const EdgeInsets.only(bottom: 10),
                                      child: ListTile(
                                        leading: const Icon(Icons.mail_lock,
                                            color: Colors.amberAccent),
                                        title: Text(
                                            '${a.nickname} [ID: ${a.nodeId}]'),
                                        subtitle: Text(
                                          'Записка: «${a.appealText}»\nHW: ${a.hwFingerprint}',
                                          style: const TextStyle(
                                              color: Colors.white70),
                                        ),
                                        trailing: FilledButton.icon(
                                          style: FilledButton.styleFrom(
                                              backgroundColor: Colors.teal),
                                          onPressed: () async {
                                            await _engine
                                                .executeAdminBanOrUnban(
                                              targetNodeId: a.nodeId,
                                              ban: false,
                                            );
                                            if (ctx.mounted) {
                                              setModalState(() {});
                                            }
                                          },
                                          icon: const Icon(Icons.lock_open,
                                              size: 16),
                                          label: const Text('Разбанить'),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
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
            Icon(Icons.speed, color: Color(0xFF38BDF8)),
            SizedBox(width: 8),
            Expanded(child: Text('Бенчмарк Маяк v1.4')),
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
                    fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
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
                    fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
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
                tooltip: 'Сохранить на устройство (в Загрузки/Mayak)',
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

  void _openInAppVideoPlayer(
      String videoPath, String title, String? thumbPath) {
    _engine.stopAudioPlayback();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InAppVideoPlayerScreen(
          engine: _engine,
          videoPath: videoPath,
          title: title,
          initialThumbPath: thumbPath,
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
            Icon(Icons.verified_user, color: Color(0xFF38BDF8)),
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
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFF38BDF8).withOpacity(0.4)),
              ),
              child: Text(
                safetyCode,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  color: Color(0xFF38BDF8),
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
          'Вы можете очистить только переписку или полностью удалить контакт.',
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
        title: const Text('Подключить узел по IP или коду'),
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
      backgroundColor: const Color(0xFF111827),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (_, scrollCtrl) => Padding(
          padding: const EdgeInsets.all(18),
          child: ListView(
            controller: scrollCtrl,
            children: [
              const Text(
                'Настройки и Память «Маяк v1.4.0»',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
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
                    label: const Text('Бенчмарк и Пинг'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _engine.scanLocalSubnet();
                    },
                    icon: const Icon(Icons.radar, size: 18),
                    label: const Text('Сканировать Wi-Fi сеть'),
                  ),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF312E81),
                    ),
                    onPressed: () async {
                      final report =
                          await _engine.clearAllDownloadedMediaFromDevice();
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(report)),
                      );
                    },
                    icon: const Icon(Icons.cleaning_services, size: 18),
                    label: const Text(
                        'Стереть скачанные данные (картинки и файлы)'),
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
              const Divider(height: 28),
              const Text(
                'Что нового в патче v1.4.0:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
              ),
              const SizedBox(height: 8),
              const Text(
                '• Новый современный интерфейс Cyber-Ocean (графит-индиго, градиентные карточки и поиск по чатам).\n'
                '• Защита медиа в стиле Telegram: входящие фото и видео сначала скрыты под матовым блюром с кнопкой показа, а рядом есть отдельная кнопка сохранения на устройство.\n'
                '• Кнопка «Стереть скачанные данные (картинки и файлы)» в настройках для мгновенной очистки памяти.\n'
                '• Полноценный встроенный видеоплеер на Windows ПК и Android с генерацией превью-кадра до и после просмотра видео.\n'
                '• Надежное файловое хранилище чатов и профилей на Android + автоматическая доотправка файлов из оффлайн-очереди буфера при подключении.',
                style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
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
                'Очередь буфера (СМС + файлы): ${_engine.totalBufferedCount}\n'
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
      backgroundColor: const Color(0xFF111827),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(14),
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
                borderRadius: BorderRadius.circular(16),
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF38BDF8)),
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

  Widget _buildStatusPill(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatsListPane({required bool isWideScreen}) {
    final contacts = _engine.knownContacts.values
        .where((c) => !_engine.isNodeBanned(c.nodeId, c.hwFingerprint))
        .where((c) =>
            _searchQuery.isEmpty ||
            c.displayTitle.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            c.nodeId.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        final lastA = _engine.getLastMessageFor(a.nodeId)?.timestamp ?? 0;
        final lastB = _engine.getLastMessageFor(b.nodeId)?.timestamp ?? 0;
        return lastB.compareTo(lastA);
      });

    final lastBroadcast =
        _engine.getLastMessageFor(MeshEngine.broadcastChannelId);

    return Container(
      color: const Color(0xFF0E1420),
      child: Column(
        children: [
          if (_engine.isSelfBanned)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              color: const Color(0xFF45121B),
              child: Row(
                children: [
                  const Icon(Icons.block, color: Colors.redAccent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Ваш узел заблокирован администратором сети.',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    onPressed: _showBanAppealDialog,
                    child: const Text(
                      'Записка на разбан',
                      style: TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: const BoxDecoration(
              color: Color(0xFF131B2B),
              border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _buildStatusPill(
                      Icons.sensors,
                      'Онлайн: ${_engine.connectedPeersCount}',
                      const Color(0xFF34D399),
                    ),
                    _buildStatusPill(
                      Icons.lan_outlined,
                      '${_engine.cachedIps.first}:${_engine.listenPort}',
                      const Color(0xFF38BDF8),
                    ),
                    _buildStatusPill(
                      Icons.inventory_2_outlined,
                      'Буфер: ${_engine.totalBufferedCount}',
                      _engine.totalBufferedCount > 0
                          ? Colors.amberAccent
                          : Colors.white70,
                    ),
                    if (Platform.isAndroid)
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () async {
                          await _engine.toggleAndroidBleMesh();
                          if (mounted) setState(() {});
                        },
                        child: _buildStatusPill(
                          _engine.bleMeshActive
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth,
                          _engine.bleMeshActive ? 'BLE Активен' : 'Вкл BLE',
                          _engine.bleMeshActive
                              ? const Color(0xFF60A5FA)
                              : Colors.white54,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _searchQuery = v.trim()),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Поиск по узлам и чатам...',
                    prefixIcon: const Icon(Icons.search,
                        size: 18, color: Colors.white54),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF0B0F19),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF1E293B)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF1E293B)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              children: [
                // КАРТОЧКА ОБЩЕГО ЭФИРА
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: _activeChatId == MeshEngine.broadcastChannelId &&
                            isWideScreen
                        ? const Color(0xFF1E293B)
                        : const Color(0xFF141C2B),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _activeChatId == MeshEngine.broadcastChannelId &&
                              isWideScreen
                          ? const Color(0xFF38BDF8).withOpacity(0.5)
                          : Colors.transparent,
                    ),
                  ),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFF59E0B), Color(0xFFEA580C)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.podcasts, color: Colors.white),
                    ),
                    title: const Text(
                      'Общий эфир (Всем рядом)',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
                    ),
                    subtitle: Text(
                      lastBroadcast != null
                          ? '${lastBroadcast.senderName}: ${lastBroadcast.text}'
                          : 'Открытый радиоканал для всех узлов поблизости',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12.5, color: Colors.white60),
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
                              color: const Color(0xFFF59E0B),
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
                ),

                if (contacts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF141C2B),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.radar,
                              size: 42, color: Color(0xFF38BDF8)),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Устройства рядом появятся автоматически\nпри включенном Wi-Fi, Точке доступа или BLE.',
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
                              label: const Text('По IP / Коду'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _engine.scanLocalSubnet(),
                              icon: const Icon(Icons.radar, size: 18),
                              label: const Text('Поиск в сети'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                ...contacts.map((c) {
                  final lastMsg = _engine.getLastMessageFor(c.nodeId);
                  final isSelected = _activeChatId == c.nodeId && isWideScreen;
                  final grad = _avatarGradientFor(c.nodeId);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF1E293B)
                          : const Color(0xFF141C2B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF38BDF8).withOpacity(0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      leading: Stack(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: grad),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: Text(
                                c.displayTitle.isNotEmpty
                                    ? c.displayTitle[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 13,
                              height: 13,
                              decoration: BoxDecoration(
                                color: c.isOnline
                                    ? const Color(0xFF34D399)
                                    : const Color(0xFFF59E0B),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: const Color(0xFF141C2B), width: 2.2),
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
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14.5),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            c.nodeId,
                            style: const TextStyle(
                              fontSize: 10.5,
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
                                ? '🟢 В сети (${c.lastAddress})'
                                : '🟠 Ожидание соединения / Mesh'),
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
                                color: const Color(0xFF38BDF8),
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
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// ИСПРАВЛЕНИЕ ПУНКТОВ 1 и 4: Медиа-карточки в стиле Telegram (сначала блюр с кнопкой показа/загрузки, превью-кадр видео и отдельная кнопка «На устройство»)
  Widget _buildMessageContent(ChatMessage m) {
    final hasFile = m.fileName != null && m.fileName!.isNotEmpty;
    if (!hasFile) {
      return Text(
        m.text,
        style: const TextStyle(fontSize: 15, color: Colors.white, height: 1.35),
      );
    }

    final fileReady = m.filePath != null && File(m.filePath!).existsSync();
    final thumbReady = m.thumbPath != null && File(m.thumbPath!).existsSync();
    final isThisAudioActive =
        fileReady && _engine.currentlyPlayingAudioPath == m.filePath;

    final isVisualMedia = m.isImageFile || m.isVideoFile;
    final previewSourcePath = m.isImageFile
        ? (fileReady ? m.filePath : (thumbReady ? m.thumbPath : null))
        : (thumbReady ? m.thumbPath : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isVisualMedia)
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              constraints: const BoxConstraints(
                maxWidth: 290,
                maxHeight: 240,
                minHeight: 150,
                minWidth: 240,
              ),
              color: const Color(0xFF0F172A),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (previewSourcePath != null)
                    Positioned.fill(
                      child: Image.file(
                        File(previewSourcePath),
                        fit: BoxFit.cover,
                      ),
                    )
                  else
                    Positioned.fill(
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Icon(
                          m.isVideoFile ? Icons.movie_creation : Icons.image,
                          size: 54,
                          color: Colors.white24,
                        ),
                      ),
                    ),

                  // ЭФФЕКТ БЛЮРА В СТИЛЕ TELEGRAM (пока пользователь не нажал кнопку показа/скачивания)
                  if (!m.isMediaRevealed || !fileReady)
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          color: Colors.black.withOpacity(0.35),
                          alignment: Alignment.center,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(30),
                            onTap: () async {
                              if (fileReady) {
                                await _engine.revealMediaMessage(m);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'Файл еще передается по сети или был очищен из кэша'),
                                  ),
                                );
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.65),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                    color: Colors.white24, width: 1.2),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    m.transferProgress < 1.0
                                        ? Icons.downloading
                                        : Icons.visibility,
                                    color: const Color(0xFF38BDF8),
                                    size: 22,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    m.transferProgress < 1.0
                                        ? 'Загрузка ${(m.transferProgress * 100).toInt()}% (${m.fileSizeFormatted})'
                                        : (fileReady
                                            ? 'Показать ${m.isVideoFile ? "видео" : "фото"} • ${m.fileSizeFormatted}'
                                            : 'Очищено из кэша'),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    // Когда блюр снят: клик открывает фото в зуме или видео во встроенном плеере!
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (m.isImageFile) {
                              _openFullScreenImage(m.filePath!, m.fileName!);
                            } else if (m.isVideoFile) {
                              _openInAppVideoPlayer(
                                  m.filePath!, m.fileName!, m.thumbPath);
                            }
                          },
                          child: m.isVideoFile
                              ? Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.6),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: const Color(0xFF38BDF8),
                                          width: 2),
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 38,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.22),
            borderRadius: BorderRadius.circular(12),
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
                        color: const Color(0xFF38BDF8),
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
                        color: Color(0xFF38BDF8),
                        size: 32,
                      ),
                      tooltip: 'Смотреть видео во встроенном плеере',
                      onPressed: () async {
                        if (!m.isMediaRevealed) {
                          await _engine.revealMediaMessage(m);
                        }
                        if (mounted) {
                          _openInAppVideoPlayer(
                              m.filePath!, m.fileName!, m.thumbPath);
                        }
                      },
                    )
                  else
                    Icon(
                      m.isImageFile
                          ? Icons.photo_camera_back
                          : (m.isVideoFile
                              ? Icons.videocam
                              : (m.isAudioFile
                                  ? Icons.audiotrack
                                  : Icons.insert_drive_file)),
                      color: const Color(0xFF38BDF8),
                      size: 24,
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
                              ? (m.transferProgress <= 0.0
                                  ? '${m.fileSizeFormatted} • ⏳ В очереди буфера'
                                  : '${m.fileSizeFormatted} • Передача ${(m.transferProgress * 100).toInt()}%')
                              : m.fileSizeFormatted,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  if (fileReady) ...[
                    const SizedBox(width: 6),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 32),
                        backgroundColor: Colors.white.withOpacity(0.1),
                      ),
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
                      icon: const Icon(Icons.download_rounded,
                          size: 16, color: Color(0xFF38BDF8)),
                      label: const Text(
                        'На устройство',
                        style: TextStyle(fontSize: 11, color: Colors.white),
                      ),
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
                          activeColor: const Color(0xFF38BDF8),
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
        if (m.transferProgress > 0.0 && m.transferProgress < 1.0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              value: m.transferProgress,
              backgroundColor: Colors.white12,
              color: const Color(0xFF38BDF8),
            ),
          ),
      ],
    );
  }

  Widget _buildConversationPane({required bool showBackButton}) {
    final chatId = _activeChatId;
    if (chatId == null) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(28),
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF131B2B),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 52, color: Color(0xFF38BDF8)),
              SizedBox(height: 12),
              Text(
                'Выберите диалог слева или подключите друга',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              SizedBox(height: 6),
              Text(
                'Все сообщения, голосовые, фото и видео до 1 ГБ\nзащищены сквозным шифрованием E2EE v2.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final isBroadcast = chatId == MeshEngine.broadcastChannelId;
    final contact = isBroadcast ? null : _engine.knownContacts[chatId];
    final title = isBroadcast
        ? 'Общий эфир (Всем рядом)'
        : (contact?.displayTitle ?? 'Узел $chatId');
    final subtitle = isBroadcast
        ? 'Видят все устройства поблизости (Онлайн: ${_engine.connectedPeersCount})'
        : (contact?.isOnline == true
            ? '🟢 Прямая связь (${contact?.lastAddress ?? "P2P"}) • До 1 ГБ'
            : '🟠 Оффлайн-буфер (автоматическая отправка при подключении)');

    final messages = _engine.getMessagesFor(chatId);
    final grad = _avatarGradientFor(chatId);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: const BoxDecoration(
            color: Color(0xFF131B2B),
            border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
          ),
          child: Row(
            children: [
              if (showBackButton)
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  tooltip: 'Назад к чатам',
                  onPressed: _closeChatToHome,
                ),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isBroadcast
                        ? [const Color(0xFFF59E0B), const Color(0xFFEA580C)]
                        : grad,
                  ),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Center(
                  child: isBroadcast
                      ? const Icon(Icons.podcasts,
                          color: Colors.white, size: 20)
                      : Text(
                          title.isNotEmpty ? title[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16),
                        ),
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
                          const TextStyle(fontSize: 11.5, color: Colors.white60),
                    ),
                  ],
                ),
              ),
              if (!isBroadcast && contact != null) ...[
                IconButton(
                  icon: const Icon(Icons.verified_user_outlined,
                      color: Color(0xFF38BDF8), size: 20),
                  tooltip: 'Код безопасности E2EE',
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
                          : 'Защищенный E2EE v2 диалог с «$title».\nОтправляйте текст, смайлики 😊, голосовые 🎤, музыку 🎵, фото и видео до 1 ГБ 🎬.\nФайлы, прикрепленные оффлайн, автоматически уйдут при появлении собеседника!',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollCtrl,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[i];
                    final align = m.isMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start;

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
                            constraints: const BoxConstraints(maxWidth: 350),
                            margin: const EdgeInsets.symmetric(vertical: 5),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 13, vertical: 9),
                            decoration: BoxDecoration(
                              gradient: m.isMe
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFF4F46E5),
                                        Color(0xFF0284C7),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    )
                                  : null,
                              color: m.isMe ? null : const Color(0xFF182234),
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(18),
                                topRight: const Radius.circular(18),
                                bottomLeft:
                                    Radius.circular(m.isMe ? 18 : 4),
                                bottomRight:
                                    Radius.circular(m.isMe ? 4 : 18),
                              ),
                              border: m.isMe
                                  ? null
                                  : Border.all(
                                      color: const Color(0xFF28354A)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!m.isMe && isBroadcast)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      m.senderName,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF38BDF8),
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
                                                      horizontal: 8,
                                                      vertical: 3),
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
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(
                                      m.timeFormatted,
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.white70),
                                    ),
                                    if (m.isMe) ...[
                                      const SizedBox(width: 5),
                                      Icon(
                                        m.isDelivered
                                            ? Icons.done_all
                                            : Icons.schedule,
                                        size: 14,
                                        color: m.isDelivered
                                            ? const Color(0xFF7DD3FC)
                                            : Colors.white60,
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
        if (_engine.isSelfBanned)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF3B1219),
            child: Row(
              children: [
                const Icon(Icons.lock_person, color: Colors.redAccent),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Отправка сообщений заблокирована администратором сети.',
                    style: TextStyle(fontSize: 12.5, color: Colors.white),
                  ),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent),
                  onPressed: _showBanAppealDialog,
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('Написать записку на разбан'),
                ),
              ],
            ),
          )
        else
          ChatInputBar(
            hintText: isBroadcast
                ? 'Сообщение в Общий эфир...'
                : 'Написать для $title...',
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
        final isWideScreen = constraints.maxWidth >= 720;

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
                borderRadius: BorderRadius.circular(12),
                onTap: _showEditProfileDialog,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6366F1), Color(0xFF38BDF8)],
                          ),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Center(
                          child: Text(
                            _engine.nickname.isNotEmpty
                                ? _engine.nickname[0].toUpperCase()
                                : 'М',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    _engine.nickname.isEmpty
                                        ? 'Маяк P2P'
                                        : _engine.nickname,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.edit_outlined,
                                    size: 14, color: Colors.white54),
                              ],
                            ),
                            Text(
                              'ID: ${_engine.nodeId}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Color(0xFF38BDF8),
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.speed, color: Color(0xFF38BDF8)),
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
                  icon: const Icon(Icons.tune, color: Color(0xFF38BDF8)),
                  tooltip: 'Настройки, Очистка кэша и Выход',
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
                        width: 350,
                        child: _buildChatsListPane(isWideScreen: true),
                      ),
                      const VerticalDivider(
                          width: 1, color: Color(0xFF1E293B)),
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

/// ПОЛНОЦЕННЫЙ ВСТРОЕННЫЙ ВИДЕОПЛЕЕР (На Android через Texture, на Windows ПК через встроенный .NET WPF Frame+Audio Streamer без внешних окон + показ превью-кадра после окончания видео!)
class InAppVideoPlayerScreen extends StatefulWidget {
  final MeshEngine engine;
  final String videoPath;
  final String title;
  final String? initialThumbPath;

  const InAppVideoPlayerScreen({
    super.key,
    required this.engine,
    required this.videoPath,
    required this.title,
    this.initialThumbPath,
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
  bool _isCompleted = false;
  bool _loading = true;
  String? _thumbPath;

  Timer? _androidPollTimer;
  Process? _winVideoProc;
  Uint8List? _winCurrentFrameBytes;

  @override
  void initState() {
    super.initState();
    _thumbPath = widget.initialThumbPath;
    _initVideo();
  }

  Future<void> _initVideo() async {
    if (_thumbPath == null || !File(_thumbPath!).existsSync()) {
      _thumbPath = await widget.engine.extractVideoThumbnail(widget.videoPath);
    }

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
        _androidPollTimer =
            Timer.periodic(const Duration(milliseconds: 250), (_) async {
          final st = await widget.engine.nativeChannel
              .invokeMapMethod<String, dynamic>(
            'controlInAppVideo',
            {'action': 'status', 'positionMs': 0},
          );
          if (!mounted || st == null) return;
          final playing = (st['isPlaying'] as bool?) ?? false;
          final completed = (st['isCompleted'] as bool?) ?? false;
          final pos = (st['positionMs'] as int?) ?? 0;
          final dur = max((st['durationMs'] as int?) ?? 1, 1);
          setState(() {
            _isPlaying = playing;
            _isCompleted = completed || (!playing && pos >= dur - 250);
            _positionMs = pos;
            _durationMs = dur;
          });
        });
      } else {
        setState(() => _loading = false);
      }
    } else if (Platform.isWindows) {
      await _startWindowsInAppVideoStreamer();
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _startWindowsInAppVideoStreamer() async {
    try {
      const psScript = r'''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$vPath = $env:MAYAK_VIDEO_PATH
$mp = New-Object System.Windows.Media.MediaPlayer
$mp.Volume = 1.0
$mp.ScrubbingEnabled = $true
$mp.Open([Uri]::new($vPath))
$t0 = [DateTime]::Now
while (-not $mp.NaturalDuration.HasTimeSpan -and (([DateTime]::Now - $t0).TotalMilliseconds -lt 4000)) {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
  Start-Sleep -Milliseconds 30
}
$w = $mp.NaturalVideoWidth; if ($w -le 0) { $w = 640 }
$h = $mp.NaturalVideoHeight; if ($h -le 0) { $h = 360 }
if ($w -gt 640) { $h = [int]($h * (640.0 / $w)); $w = 640 }
$durMs = 1000
if ($mp.NaturalDuration.HasTimeSpan) {
  $durMs = [int][Math]::Max(1, $mp.NaturalDuration.TimeSpan.TotalMilliseconds)
}
[Console]::Out.WriteLine("META|$w|$h|$durMs")
$mp.Play()
$isPlaying = $true
$isCompleted = $false

$inTask = [System.Console]::In.ReadLineAsync()

while ($true) {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
  if ($inTask.IsCompleted) {
    $cmdLine = $inTask.Result
    if ($null -eq $cmdLine -or $cmdLine -eq "QUIT") { break }
    if ($cmdLine -eq "PAUSE") { $mp.Pause(); $isPlaying = $false }
    elseif ($cmdLine -eq "PLAY") {
      if ($isCompleted) { $mp.Position = [TimeSpan]::Zero; $isCompleted = $false }
      $mp.Play(); $isPlaying = $true
    }
    elseif ($cmdLine.StartsWith("SEEK|")) {
      $ms = [int]($cmdLine.Substring(5))
      $mp.Position = [TimeSpan]::FromMilliseconds($ms)
      $isCompleted = $false
      if ($isPlaying) { $mp.Play() }
    }
    $inTask = [System.Console]::In.ReadLineAsync()
  }

  $posMs = [int]$mp.Position.TotalMilliseconds
  if ($durMs -gt 200 -and $posMs -ge ($durMs - 120)) {
    $isPlaying = $false
    $isCompleted = $true
    $mp.Pause()
  }

  $dv = New-Object System.Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  $dc.DrawVideo($mp, (New-Object System.Windows.Rect(0, 0, $w, $h)))
  $dc.Close()
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($dv)
  $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
  $enc.QualityLevel = 72
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $msStream = New-Object System.IO.MemoryStream
  $enc.Save($msStream)
  $b64 = [Convert]::ToBase64String($msStream.ToArray())
  $msStream.Dispose()

  $pFlag = if ($isPlaying) { "1" } else { "0" }
  $cFlag = if ($isCompleted) { "1" } else { "0" }
  [Console]::Out.WriteLine("FRAME|$posMs|$durMs|$pFlag|$cFlag|$b64")
  Start-Sleep -Milliseconds 55
}
$mp.Close()
''';

      final proc = await Process.start(
        'powershell',
        ['-NoProfile', '-STA', '-Command', psScript],
        environment: {
          'MAYAK_VIDEO_PATH': widget.videoPath.replaceAll('/', '\\'),
        },
      );
      _winVideoProc = proc;

      utf8.decoder
          .bind(proc.stdout)
          .transform(const LineSplitter())
          .listen((line) {
        if (!mounted) return;
        if (line.startsWith('META|')) {
          final p = line.split('|');
          if (p.length >= 4) {
            setState(() {
              _videoWidth = int.tryParse(p[1]) ?? 640;
              _videoHeight = int.tryParse(p[2]) ?? 360;
              _durationMs = max(int.tryParse(p[3]) ?? 1, 1);
              _loading = false;
            });
          }
        } else if (line.startsWith('FRAME|')) {
          final p = line.split('|');
          if (p.length >= 6) {
            final pos = int.tryParse(p[1]) ?? 0;
            final dur = max(int.tryParse(p[2]) ?? 1, 1);
            final playing = p[3] == '1';
            final completed = p[4] == '1';
            final frameBytes = base64Decode(p[5]);
            setState(() {
              _positionMs = pos;
              _durationMs = dur;
              _isPlaying = playing;
              _isCompleted = completed;
              if (frameBytes.isNotEmpty) {
                _winCurrentFrameBytes = frameBytes;
              }
              _loading = false;
            });
          }
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
        _isCompleted = (st['isCompleted'] as bool?) ?? false;
        _positionMs = (st['positionMs'] as int?) ?? 0;
      });
    } else if (Platform.isWindows && _winVideoProc != null) {
      if (action == 'seek') {
        _isCompleted = false;
        _winVideoProc!.stdin.writeln('SEEK|$posMs');
      } else if (action == 'play') {
        _isCompleted = false;
        _winVideoProc!.stdin.writeln('PLAY');
      } else if (action == 'pause') {
        _winVideoProc!.stdin.writeln('PAUSE');
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _androidPollTimer?.cancel();
    if (Platform.isAndroid) {
      widget.engine.nativeChannel.invokeMethod('disposeInAppVideo');
    } else if (_winVideoProc != null) {
      try {
        _winVideoProc!.stdin.writeln('QUIT');
      } catch (_) {}
      try {
        _winVideoProc!.kill();
      } catch (_) {}
    }
    super.dispose();
  }

  Widget _buildVideoSurfaceOrPreview(double aspect) {
    final hasThumb = _thumbPath != null && File(_thumbPath!).existsSync();

    // Показ превью-кадра после окончания видео (на ПК и на Android!)
    if (_isCompleted) {
      return Stack(
        alignment: Alignment.center,
        children: [
          if (hasThumb)
            AspectRatio(
              aspectRatio: aspect,
              child: Image.file(File(_thumbPath!), fit: BoxFit.contain),
            )
          else if (_winCurrentFrameBytes != null)
            AspectRatio(
              aspectRatio: aspect,
              child: Image.memory(_winCurrentFrameBytes!,
                  gaplessPlayback: true, fit: BoxFit.contain),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.72),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
            ),
            child: InkWell(
              onTap: () => _sendControl('play'),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.replay_circle_filled,
                      color: Color(0xFF38BDF8), size: 32),
                  SizedBox(width: 10),
                  Text(
                    'Видео завершено • Повторить просмотр',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (Platform.isAndroid && _textureId != null) {
      return AspectRatio(
        aspectRatio: aspect,
        child: Texture(textureId: _textureId!),
      );
    }

    if (Platform.isWindows && _winCurrentFrameBytes != null) {
      return AspectRatio(
        aspectRatio: aspect,
        child: Image.memory(
          _winCurrentFrameBytes!,
          gaplessPlayback: true,
          fit: BoxFit.contain,
        ),
      );
    }

    if (hasThumb) {
      return AspectRatio(
        aspectRatio: aspect,
        child: Image.file(File(_thumbPath!), fit: BoxFit.contain),
      );
    }

    return const CircularProgressIndicator();
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
            tooltip: 'Сохранить на устройство (в Загрузки/Mayak)',
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
                  : _buildVideoSurfaceOrPreview(aspect),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF111827),
            child: Column(
              children: [
                Slider(
                  value: _positionMs
                      .toDouble()
                      .clamp(0.0, max(_durationMs.toDouble(), 1.0)),
                  min: 0.0,
                  max: max(_durationMs.toDouble(), 1.0),
                  activeColor: const Color(0xFF38BDF8),
                  onChanged: (val) => _sendControl('seek', val.round()),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      MeshEngine.formatDurationMs(_positionMs),
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
                          backgroundColor: const Color(0xFF38BDF8),
                          child: IconButton(
                            icon: Icon(
                              _isPlaying && !_isCompleted
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.black,
                              size: 28,
                            ),
                            onPressed: () => _sendControl(
                                (_isPlaying && !_isCompleted)
                                    ? 'pause'
                                    : 'play'),
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
                      MeshEngine.formatDurationMs(_durationMs),
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
      backgroundColor: const Color(0xFF141C2B),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF0284C7),
                child: Icon(Icons.perm_media, color: Colors.white),
              ),
              title: const Text('Фото или Видео (до 1 ГБ)'),
              subtitle: const Text(
                  'С автогенерацией превью-кадра и защитным блюром'),
              onTap: () {
                Navigator.pop(ctx);
                widget.onPickMedia();
              },
            ),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF6366F1),
                child: Icon(Icons.music_note, color: Colors.white),
              ),
              title: const Text('Музыка или Аудиофайл'),
              subtitle: const Text(
                  'Проигрывание и перемотка прямо внутри чата'),
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
                  'Потоковая передача и оффлайн-очередь буфера'),
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
            color: const Color(0xFF111827),
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF131B2B),
            border: Border(top: BorderSide(color: Color(0xFF1E293B))),
          ),
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
                  icon: const Icon(Icons.add_circle_outline,
                      color: Color(0xFF38BDF8)),
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
                    fillColor: const Color(0xFF0B0F19),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(color: Color(0xFF1E293B)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: const BorderSide(color: Color(0xFF1E293B)),
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
                      : const Color(0xFF1E293B),
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
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF0284C7)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.send_rounded,
                      color: Colors.white, size: 19),
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
                border: Border.all(color: const Color(0xFF38BDF8), width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
