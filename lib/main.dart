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
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.tealAccent,
          brightness: Brightness.dark,
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
  final List<String> _messages = [];
  final TextEditingController _inviteCtrl = TextEditingController();
  final TextEditingController _msgCtrl = TextEditingController();
  final FocusNode _msgFocus = FocusNode();

  String? _selectedContactId;
  String _myInvite = '';
  List<String> _myIps = [];

  @override
  void initState() {
    super.initState();
    _engine = MeshEngine(
      onMessageReceived: (senderId, senderName, text) {
        if (!mounted) return;
        setState(() {
          _messages.add('$senderName: $text');
          _selectedContactId ??= senderId;
        });
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

  Future<void> _sendCurrentMessage() async {
    final contacts = _engine.knownContacts.keys.toList();
    final target =
        _selectedContactId ?? (contacts.isNotEmpty ? contacts.first : null);
    final text = _msgCtrl.text.trim();
    if (target == null || text.isEmpty) return;

    final targetName = _engine.knownContacts[target]?.nickname ?? target;
    _msgCtrl.clear();
    _msgFocus.requestFocus();

    await _engine.sendMessage(target, text);
    if (!mounted) return;
    setState(() {
      _messages.add('Я -> $targetName: $text');
    });
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
                'Локальные IP: ${_myIps.join(", ")}\n'
                'TCP-порт: ${_engine.listenPort}\n'
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
      setState(() {
        if (id != null) _selectedContactId = id;
        _inviteCtrl.clear();
      });
      final label = id != null
          ? (_engine.knownContacts[id]?.nickname ?? id)
          : raw.trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Запрос подключения отправлен: $label')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Неверный формат кода или IP (пример: 192.168.1.5)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _engine.knownContacts.values.toList();
    if (_selectedContactId == null && contacts.isNotEmpty) {
      _selectedContactId = contacts.first.nodeId;
    }

    return Scaffold(
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
            icon: const Icon(Icons.terminal),
            tooltip: 'Журнал сети',
            onPressed: _showLogsModal,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'IP: ${_myIps.join(", ")}:${_engine.listenPort} | Онлайн: ${_engine.connectedPeersCount} | Буфер: ${_engine.transitBuffer.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (Platform.isAndroid)
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              await _engine.toggleAndroidBleMesh();
                              if (mounted) setState(() {});
                            },
                            icon: Icon(
                              _engine.bleMeshActive
                                  ? Icons.bluetooth_connected
                                  : Icons.bluetooth,
                              size: 16,
                              color: _engine.bleMeshActive
                                  ? Colors.lightBlueAccent
                                  : Colors.white70,
                            ),
                            label: Text(
                              _engine.bleMeshActive ? 'BLE Вкл' : 'Вкл BLE',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _engine.lastStatusLog,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inviteCtrl,
                            decoration: const InputDecoration(
                              hintText:
                                  'Вставь IP (напр. 192.168.1.5) или код узла...',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (val) => _handleConnectInput(val),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () =>
                              _handleConnectInput(_inviteCtrl.text),
                          child: const Text('Подключить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (contacts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: DropdownButtonFormField<String>(
                  value: contacts.any((c) => c.nodeId == _selectedContactId)
                      ? _selectedContactId
                      : contacts.first.nodeId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Кому пишем',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: contacts
                      .map(
                        (c) => DropdownMenuItem(
                          value: c.nodeId,
                          child: Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 10,
                                color: c.isOnline
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  c.lastAddress.isNotEmpty
                                      ? '${c.displayTitle} [${c.lastAddress}]'
                                      : c.displayTitle,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedContactId = v),
                ),
              ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _messages.isEmpty
                    ? const Center(
                        child: Text(
                          'Сообщений пока нет.\n'
                          '• В одной Wi-Fi сети или Точке доступа узлы находятся автоматически (или нажми иконку радара сверху).\n'
                          '• Также можно ввести IP второго устройства (например 192.168.1.5) или отсканировать QR-код.\n'
                          '• Для связи без Wi-Fi по Bluetooth нажми «Вкл BLE».',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: SelectableText(_messages[i]),
                        ),
                      ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgCtrl,
                    focusNode: _msgFocus,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendCurrentMessage(),
                    decoration: const InputDecoration(
                      hintText: 'Сообщение (Enter — отправить)...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _sendCurrentMessage,
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('Отправить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _alreadyScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Наведи камеру на QR-код')),
      body: MobileScanner(
        controller: _controller,
        errorBuilder: (context, error, child) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Не удалось открыть камеру: ${error.errorCode}\nИспользуйте подключение по IP или коду.',
                textAlign: TextAlign.center,
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
              _controller.stop();
              Navigator.pop(context, raw.trim());
              break;
            }
          }
        },
      ),
    );
  }
}
