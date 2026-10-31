import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String? _selectedContactId;
  String _myInvite = '';

  @override
  void initState() {
    super.initState();
    _engine = MeshEngine(
      onMessageReceived: (senderId, text) {
        if (!mounted) return;
        setState(() {
          _messages.add('[$senderId]: $text');
          _selectedContactId ??= senderId;
        });
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
    final code = await _engine.getInviteCode();
    if (!mounted) return;
    setState(() {
      _myInvite = code;
    });
  }

  void _showQrModal() {
    if (_myInvite.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Мой узел: ${_engine.nodeId}'),
        content: SizedBox(
          width: 240,
          height: 240,
          child: Center(
            child: QrImageView(
              data: _myInvite,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
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

  @override
  Widget build(BuildContext context) {
    final contacts = _engine.knownContacts.keys.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('ID: ${_engine.nodeId.isEmpty ? "..." : _engine.nodeId}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Показать QR-код',
            onPressed: _showQrModal,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Text(
                'Пиры: ${_engine.connectedPeersCount} (BLE: ${_engine.blePeersCount}) | Буфер: ${_engine.transitBuffer.length}',
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _myInvite.isEmpty ? 'Генерация ключа...' : _myInvite,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
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
                              hintText: 'Вставь код соседа или получателя...',
                              isDense: true,
                            ),
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
              DropdownButton<String>(
                value: contacts.contains(_selectedContactId) ? _selectedContactId : contacts.first,
                isExpanded: true,
                hint: const Text('Выбери получателя'),
                items: contacts
                    .map((id) => DropdownMenuItem(value: id, child: Text('Контакт: $id')))
                    .toList(),
                onChanged: (v) => setState(() => _selectedContactId = v),
              ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
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
                    decoration: const InputDecoration(
                      hintText: 'Сообщение (Wi-Fi / Bluetooth Mesh)...',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final target = _selectedContactId ?? (contacts.isNotEmpty ? contacts.first : null);
                    final text = _msgCtrl.text.trim();
                    if (target == null || text.isEmpty) return;
                    _msgCtrl.clear();
                    await _engine.sendMessage(target, text);
                    setState(() {
                      _messages.add('[Я -> $target]: $text');
                    });
                  },
                  child: const Text('Отправить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
