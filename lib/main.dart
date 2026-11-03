import 'dart:async';
import 'dart:io';
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
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _chatScrollCtrl = ScrollController();
  final FocusNode _msgFocus = FocusNode();

  String? _activeChatId; // null на списке чатов (для телефона), либо ID контакта / 'BROADCAST'
  String _myInvite = '';
  List<String> _myIps = [];

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
        _refreshInviteAndIps();
      },
    );
    _initNode();
  }

  Future<void> _initNode() async {
    await _engine.init();
    await _refreshInviteAndIps();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          await _engine.requestAndroidNotifications();
        }
      });
    }
  }

  Future<void> _refreshInviteAndIps() async {
    final code = await _engine.getInviteCode();
    final ips = await _engine.getLocalIPv4Addresses();
    if (!mounted) return;
    setState(() {
      _myInvite = code;
      _myIps = ips;
    });
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
          _chatScrollCtrl.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendCurrentMessage() async {
    final target = _activeChatId;
    final text = _msgCtrl.text.trim();
    if (target == null || text.isEmpty) return;

    _msgCtrl.clear();
    _msgFocus.requestFocus();

    await _engine.sendMessage(target, text);
    if (!mounted) return;
    setState(() {});
    _scrollToBottom();
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
        initialChildSize: 0.82,
        maxChildSize: 0.95,
        builder: (_, scrollCtrl) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: scrollCtrl,
            children: [
              const Text(
                'Мастер автонастройки и Помощь «Маяк»',
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
                      _engine.scanLocalSubnet();
                    },
                    icon: const Icon(Icons.radar, size: 18),
                    label: const Text('Автопоиск устройств в сети'),
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
                  if (Platform.isAndroid)
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await _engine.requestAndroidNotifications();
                        await _engine.toggleAndroidBleMesh();
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.bluetooth_connected, size: 18),
                      label: const Text('Включить BLE + Уведомления'),
                    ),
                ],
              ),
              const Divider(height: 24),
              const Text(
                '1. Почему к одному другу подключилось, а ко второму нет?',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 4),
              const Text(
                '• Если подключаетесь по Bluetooth (BLE): убедитесь, что у всех включен не только Bluetooth, но и значок «Геолокация (GPS)» в верхней шторке телефона (без него Android блокирует сканирование Bluetooth-устройств рядом).\n'
                '• В v0.7.0 исправлена ошибка одновременного подключения к нескольким друзьям и добавлена авто-синхронизация контактов: если ты подключился к Другу 1, а он подключен к Другу 2, то Друг 2 автоматически появится у тебя в списке чатов!',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              const Text(
                '2. Дальность связи без интернета:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 4),
              const Text(
                '• Bluetooth LE напрямую: 15–25 м в здании (через стены), до 50–80 м на улице.\n'
                '• Wi-Fi Direct / Точка доступа смартфона: 40–120 м.\n'
                '• Через цепочку телефонов (Mesh «через три улицы»): каждый телефон увеличивает радиус еще на 50–100 м (до 500–700 м в реальном времени или без ограничений через прохожих-курьеров).',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              const Text(
                '3. Как оставить «Общественную сеть» на Windows (не светить ПК в Частной сети):',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 4),
              const Text(
                '• Оставь в настройках Windows профиль «Общедоступная сеть» и нажми кнопку «Открыть доступ в Общественной сети (Firewall)» выше (или запусти allow_public_network_firewall.bat от Администратора).',
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
                'ID узла: ${_engine.nodeId}\n'
                'Физические IP (без VPN): ${_myIps.join(", ")}\n'
                'TCP-порт: ${_engine.listenPort}\n'
                'VPN обнаружен: ${_engine.vpnDetected ? "Да (включен обход)" : "Нет"}\n'
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

  void _showMyQrModal() {
    if (_myInvite.isEmpty) return;
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
                  data: _myInvite,
                  size: 210,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              'Прямой IP: ${_myIps.join(", ")}:${_engine.listenPort}',
              style: const TextStyle(fontSize: 12, color: Colors.tealAccent),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _myInvite));
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
    try {
      final id = await _engine.connectWithInviteOrIp(raw);
      if (!mounted) return;
      _inviteCtrl.clear();
      if (id != null) {
        _openChat(id);
      }
      final label = id != null
          ? (_engine.knownContacts[id]?.displayTitle ?? id)
          : raw.trim();
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

  /// Левая панель / Главный экран со списком всех чатов (как в Telegram)
  Widget _buildChatsListPane({required bool isWideScreen}) {
    final contacts = _engine.knownContacts.values.toList()
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
        // Информационная плашка состояния сети
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: const Color(0xFF161F27),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.router, size: 15, color: Colors.tealAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'IP: ${_myIps.join(", ")}:${_engine.listenPort} • Онлайн: ${_engine.connectedPeersCount} • Буфер: ${_engine.transitBuffer.length}',
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
                    '⚠️ Включи значок Геолокации (GPS) в верхней шторке телефона, иначе Android не видит Bluetooth рядом!',
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
              // 1. Закрепленный канал "Общий эфир (Всем рядом)"
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
                        'Пока нет найденных друзей.\n\n'
                        '• Если вы в одной Wi-Fi сети или Точке доступа — устройства появятся здесь автоматически.\n'
                        '• Для Bluetooth-связи без Wi-Fi нажмите «Вкл BLE» на обоих телефонах (и включите GPS в шторке).\n'
                        '• Или добавьте друга вручную по IP / QR-коду кнопкой ниже.',
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

              // 2. Список индивидуальных чатов с каждым пользователем
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
                                ? 'В сети (${c.lastAddress}) — нажмите, чтобы написать'
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

  /// Правая панель / Экран открытого диалога с конкретным другом
  Widget _buildConversationPane({required bool showBackButton}) {
    final chatId = _activeChatId;
    if (chatId == null) {
      return const Center(
        child: Text(
          'Выберите чат слева или подключите устройство,\nчтобы начать защищенную переписку.',
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
            ? '🟢 В сети напрямую (${contact?.lastAddress ?? "P2P"}) • E2EE ChaCha20'
            : '🟠 Нет прямой связи — доставка через буфер Mesh («3 улицы»)');

    final messages = _engine.getMessagesFor(chatId);

    return Column(
      children: [
        // Шапка открытого диалога
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
            ],
          ),
        ),

        // Пузыри сообщений этого диалога
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      isBroadcast
                          ? 'Здесь отображаются открытые сообщения для всех участников вокруг вас.'
                          : 'Личный зашифрованный чат с «$title».\nСообщения шифруются сквозным ключом X25519 + ChaCha20-Poly1305.',
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

                    return Column(
                      crossAxisAlignment: align,
                      children: [
                        Container(
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
                              SelectableText(
                                m.text,
                                style: const TextStyle(
                                    fontSize: 14.5, color: Colors.white),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    m.timeFormatted,
                                    style: const TextStyle(
                                        fontSize: 10.5, color: Colors.white60),
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
                      ],
                    );
                  },
                ),
        ),

        // Нижняя панель ввода сообщения
        Container(
          padding: const EdgeInsets.all(8),
          color: const Color(0xFF18222C),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  focusNode: _msgFocus,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendCurrentMessage(),
                  decoration: InputDecoration(
                    hintText: isBroadcast
                        ? 'Сообщение всем вокруг...'
                        : 'Написать $title...',
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
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 22,
                backgroundColor: Colors.tealAccent.shade700,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.black, size: 20),
                  onPressed: _sendCurrentMessage,
                ),
              ),
            ],
          ),
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
                  tooltip: 'Автонастройка и Туториал',
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
