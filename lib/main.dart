import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'mesh_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MeshMessengerApp());
}

class MeshMessengerApp extends StatelessWidget {
  const MeshMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P Mesh Intercom',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
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
        title: const Text('Мой профиль'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ID узла: ${_engine.nodeId}\nЛокальные IP: ${_myIps.join(", ")}:${_engine.listenPort}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Твое имя / Никнейм',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) async {
                await _engine.updateNickname(nameCtrl.text);
                if (ctx.mounted) Navigator.pop(ctx);
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
              await _engine.updateNickname(nameCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
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
            SizedBox(
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
            const SizedBox(height: 8),
            Text(
              'IP: ${_myIps.join(", ")} : ${_engine.listenPort}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openQrScanner() async {
    final scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (scannedCode != null && scannedCode.trim().isNotEmpty) {
      try {
        final id = await _engine.connectWithInviteCode(scannedCode);
        if (!mounted) return;
        setState(() {
          _selectedContactId = id;
        });
        final name = _engine.knownContacts[id]?.nickname ?? id;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Подключен контакт: $name')),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Неверный формат QR-кода')),
        );
      }
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
                  _engine.nickname.isEmpty ? '...' : _engine.nickname,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.edit, size: 16, color: Colors.white54),
            ],
          ),
        ),
        actions: [
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                'Онлайн: ${_engine.connectedPeersCount} | Буфер: ${_engine.transitBuffer.length}',
                style: const TextStyle(fontSize: 12, color: Colors.greenAccent),
              ),
            ),
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
                    Text(
                      'Мои IP в сети: ${_myIps.join(", ")} (Порт: ${_engine.listenPort})',
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _myInvite.isEmpty ? 'Генерация...' : _myInvite,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: 'Скопировать мой код',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _myInvite));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Код скопирован')),
                            );
                          },
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inviteCtrl,
                            decoration: const InputDecoration(
                              hintText: 'Вставь код или сканируй QR кнопкой сверху...',
                              isDense: true,
                            ),
                            onSubmitted: (_) async {
                              if (_inviteCtrl.text.trim().isEmpty) return;
                              final id = await _engine.connectWithInviteCode(_inviteCtrl.text);
                              setState(() {
                                _selectedContactId = id;
                                _inviteCtrl.clear();
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            if (_inviteCtrl.text.trim().isEmpty) return;
                            final id = await _engine.connectWithInviteCode(_inviteCtrl.text);
                            setState(() {
                              _selectedContactId = id;
                              _inviteCtrl.clear();
                            });
                          },
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
                                color: c.isOnline ? Colors.greenAccent : Colors.orangeAccent,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  c.displayTitle,
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
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _messages.isEmpty
                    ? const Center(
                        child: Text(
                          'Сообщений пока нет.\nОтсканируй QR-код второго устройства или подожди автопоиска в одной Wi-Fi / Bluetooth сети.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(_messages[i]),
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
  bool _alreadyScanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Наведи камеру на QR-код')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_alreadyScanned) return;
          for (final barcode in capture.barcodes) {
            final raw = barcode.rawValue;
            if (raw != null && raw.trim().isNotEmpty) {
              _alreadyScanned = true;
              Navigator.pop(context, raw.trim());
              break;
            }
          }
        },
      ),
    );
  }
}
