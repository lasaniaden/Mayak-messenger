import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'mesh_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MayakMeshApp());
}

class MayakTheme {
  // Gemini Monochrome Minimalism (pure OLED black, crisp white hairlines)
  static const Color bgDeep = Color(0xFF000000);
  static const Color bgSurface = Color(0xFF0C0C0C);
  static const Color bgElevated = Color(0xFF171717);
  static const Color accentCyan = Color(0xFFFFFFFF);
  static const Color accentIndigo = Color(0xFFA3A3A3);
  static const Color accentEmerald = Color(0xFF4ADE80);
  static const Color accentAmber = Color(0xFFFBBF24);
  static const Color accentRed = Color(0xFFEF4444);

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF262626), Color(0xFF121212)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient myBubbleGradient = LinearGradient(
    colors: [Color(0xFF232323), Color(0xFF181818)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

final GlobalKey<NavigatorState> mayakNavigatorKey = GlobalKey<NavigatorState>();
MeshEngine? mayakGlobalEngine;

class MayakMeshApp extends StatelessWidget {
  const MayakMeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: mayakNavigatorKey,
      title: 'Маяк P2P v2.2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: MayakTheme.bgDeep,
        colorScheme: const ColorScheme.dark(
          primary: MayakTheme.accentCyan,
          secondary: MayakTheme.accentIndigo,
          surface: MayakTheme.bgSurface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: MayakTheme.bgSurface,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardColor: MayakTheme.bgSurface,
        dividerColor: const Color(0x22FFFFFF),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color(0xFF121212),
            side: const BorderSide(color: Color(0x38FFFFFF), width: 1),
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            foregroundColor: Colors.black,
            backgroundColor: Colors.white,
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0x40FFFFFF), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0E0E0E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0x30FFFFFF)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0x28FFFFFF)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.white70),
          ),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          },
        ),
        useMaterial3: true,
      ),
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            const _MayakGlobalFloatingOverlay(),
          ],
        );
      },
      home: const ChatsHomeScreen(),
    );
  }
}

class ChatsHomeScreen extends StatefulWidget {
  const ChatsHomeScreen({super.key});

  @override
  State<ChatsHomeScreen> createState() => _ChatsHomeScreenState();
}

class _ChatsHomeScreenState extends State<ChatsHomeScreen>
    with WidgetsBindingObserver {
  late final MeshEngine engine;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _drawerSection = 'all'; // 'all' | 'direct' | 'groups'

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    engine = MeshEngine(
      onMessageReceived: (msg) {
        if (!mounted) return;
        setState(() {});
      },
      onStateChanged: () {
        if (mounted) setState(() {});
        MeshEngineListenerExt.notifyExtra();
        if (engine.incomingCallFromPeerId != null &&
            !IncomingCallScreen.isShowing) {
          IncomingCallScreen.isShowing = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final nav = mayakNavigatorKey.currentState;
            if (nav == null || engine.incomingCallFromPeerId == null) {
              IncomingCallScreen.isShowing = false;
              return;
            }
            nav
                .push(
                  MaterialPageRoute(
                    fullscreenDialog: true,
                    builder: (_) => IncomingCallScreen(engine: engine),
                  ),
                )
                .whenComplete(() {
              IncomingCallScreen.isShowing = false;
            });
          });
        }
      },
    );
    mayakGlobalEngine = engine;
    engine.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      engine.refreshNetworkCache(force: true);
    }
  }

  List<Color> _avatarColorsFor(String id) {
    final shades = [
      const [Color(0xFF1C1C1C), Color(0xFF121212)],
      const [Color(0xFF242424), Color(0xFF161616)],
      const [Color(0xFF2A2A2A), Color(0xFF1A1A1A)],
      const [Color(0xFF1F1F1F), Color(0xFF101010)],
    ];
    final hash = id.codeUnits.fold<int>(0, (a, b) => a + b);
    return shades[hash % shades.length];
  }

  void _openChatRoom(String peerId, String title, bool isBroadcast) async {
    engine.markChatAsRead(peerId);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatConversationScreen(
          engine: engine,
          peerId: peerId,
          initialTitle: title,
          isBroadcast: isBroadcast,
        ),
      ),
    );
    engine.markChatAsRead(null);
  }

  void _openFullAdminDashboard() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminDashboardScreen(engine: engine),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showBanAppealDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.mark_email_unread_rounded, color: MayakTheme.accentAmber),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Записка на разбан',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ваш узел заблокирован администратором сети. Вы не можете писать в чаты, но можете отправить объяснительную записку на разбан:',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 3,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Напишите причину для снятия блокировки...',
                filled: true,
                fillColor: MayakTheme.bgDeep,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
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
            style: FilledButton.styleFrom(
              backgroundColor: MayakTheme.accentAmber,
              foregroundColor: Colors.black,
            ),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Отправить админу'),
            onPressed: () async {
              final text = ctrl.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx);
              await engine.sendBanAppealNote(text);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Записка отправлена администратору сети! Ожидайте решения.'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }


  void _showImportBackupDialog() {
    final jsonCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Text('Импорт резервной копии'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Вставьте содержимое файла .mayakbak или путь к файлу на устройстве:',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: jsonCtrl,
              maxLines: 5,
              minLines: 3,
              decoration: InputDecoration(
                hintText: '{"mayak_backup_v":1,...} или /storage/.../.mayakbak',
                filled: true,
                fillColor: MayakTheme.bgDeep,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
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
              var raw = jsonCtrl.text.trim();
              if (raw.isEmpty) return;
              try {
                if (!raw.startsWith('{') && await File(raw).exists()) {
                  raw = await File(raw).readAsString();
                }
                final msg = await engine.importBackupFromJson(raw);
                if (ctx.mounted) Navigator.pop(ctx);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFF065F46),
                    content: Text(msg),
                  ),
                );
                setState(() {});
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFF7F1D1D),
                    content: Text('Ошибка импорта: $e'),
                  ),
                );
              }
            },
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
  }

  void _showCreateGroupDialog() {
    final titleCtrl = TextEditingController();
    final selected = <String>{};
    final allContacts = engine.knownContacts.values
        .where((c) => !engine.deletedContactIds.contains(c.nodeId))
        .toList();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: MayakTheme.bgSurface,
          title: const Text('Создать групповую комнату'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Название группы (например: Штаб)',
                    filled: true,
                    fillColor: MayakTheme.bgDeep,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 10),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Участники:',
                      style: TextStyle(fontSize: 12, color: Colors.white70)),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 180,
                  child: allContacts.isEmpty
                      ? const Center(
                          child: Text('Сначала добавьте хотя бы один узел',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.white54)),
                        )
                      : ListView.builder(
                          itemCount: allContacts.length,
                          itemBuilder: (_, idx) {
                            final c = allContacts[idx];
                            final checked = selected.contains(c.nodeId);
                            return CheckboxListTile(
                              dense: true,
                              value: checked,
                              title: Text(c.displayTitle,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(c.nodeId,
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white54)),
                              onChanged: (v) {
                                setDlgState(() {
                                  if (v == true) {
                                    selected.add(c.nodeId);
                                  } else {
                                    selected.remove(c.nodeId);
                                  }
                                });
                              },
                            );
                          },
                        ),
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
              style: FilledButton.styleFrom(
                backgroundColor: MayakTheme.accentCyan,
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                if (selected.isEmpty) return;
                final grp = await engine.createGroupChat(
                    titleCtrl.text, selected.toList());
                if (ctx.mounted) Navigator.pop(ctx);
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        GroupConversationScreen(engine: engine, group: grp),
                  ),
                );
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditNicknameDialog() {
    final ctrl = TextEditingController(text: engine.nickname);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Ваш позывной (Никнейм)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: 'Введите имя или позывной',
                filled: true,
                fillColor: MayakTheme.bgDeep,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Это имя видят все участники локальной сети рядом с вами.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MayakTheme.accentCyan,
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              final input = ctrl.text.trim();
              final unlocked = await engine.tryUnlockAdminConsole(input);
              if (unlocked) {
                if (ctx.mounted) Navigator.pop(ctx);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: Color(0xFF065F46),
                    content: Text(
                        '🛡️ ROOT-Панель Администратора разблокирована!'),
                  ),
                );
                _openFullAdminDashboard();
                return;
              }
              engine.updateNickname(input);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }


  void _showAdminSecretKeyDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.shield_rounded, color: MayakTheme.accentAmber),
            SizedBox(width: 8),
            Text('Ключ Администратора', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(
            hintText: 'Введите секретную команду',
            filled: true,
            fillColor: MayakTheme.bgDeep,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MayakTheme.accentAmber,
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              final unlocked =
                  await engine.tryUnlockAdminConsole(ctrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              if (!mounted) return;
              if (unlocked) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: Color(0xFF065F46),
                    content:
                        Text('🛡️ ROOT-Панель Администратора разблокирована!'),
                  ),
                );
                _openFullAdminDashboard();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: Color(0xFF7F1D1D),
                    content: Text('Неверный ключ администратора'),
                  ),
                );
              }
            },
            child: const Text('Войти'),
          ),
        ],
      ),
    );
  }

  void _showAddContactSheet() {
    engine.refreshNetworkCache(force: true);
    final codeCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.qr_code_2_rounded,
                      color: MayakTheme.accentCyan, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Подключение: ${engine.nickname}',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Ваши локальные IP: ${engine.cachedIps.join(", ")} (Порт: ${engine.listenPort})',
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 12),
              if (engine.cachedInviteCode.isNotEmpty)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: MayakTheme.accentCyan.withOpacity(0.25),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: engine.cachedInviteCode,
                      version: QrVersions.auto,
                      size: 190,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Скопировать инвайт'),
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: engine.cachedInviteCode));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Код приглашения скопирован')),
                        );
                      },
                    ),
                  ),
                  if (Platform.isAndroid) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: MayakTheme.accentIndigo,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.qr_code_scanner, size: 18),
                        label: const Text('Сканировать QR'),
                        onPressed: () async {
                          final camOk = await engine.requestCameraPermission();
                          if (!camOk) return;
                          if (!ctx.mounted) return;
                          final scanned = await Navigator.of(ctx).push<String>(
                            MaterialPageRoute(
                              builder: (_) => const QrScannerPage(),
                            ),
                          );
                          if (scanned != null && scanned.isNotEmpty) {
                            final peerId =
                                await engine.connectWithInviteOrIp(scanned);
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (peerId != null && mounted) {
                              final c = engine.knownContacts[peerId];
                              if (c != null) {
                                _openChatRoom(c.nodeId, c.displayTitle, false);
                              }
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: codeCtrl,
                decoration: InputDecoration(
                  hintText:
                      'Вставьте инвайт-код ИЛИ IP (напр. 192.168.1.45)',
                  filled: true,
                  fillColor: MayakTheme.bgDeep,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        codeCtrl.text = data!.text!.trim();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: MayakTheme.accentCyan,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.link),
                label: const Text(
                  'Подключиться и открыть чат',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: () async {
                  final raw = codeCtrl.text.trim();
                  if (raw.isEmpty) return;
                  try {
                    final peerId = await engine.connectWithInviteOrIp(raw);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (peerId != null && mounted) {
                      final c = engine.knownContacts[peerId];
                      if (c != null) {
                        _openChatRoom(c.nodeId, c.displayTitle, false);
                      }
                    }
                  } catch (_) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Неверный формат кода или IP')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBenchmarkDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        content: Row(
          children: [
            CircularProgressIndicator(color: MayakTheme.accentCyan),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                  'Замер скорости шифрования ChaCha20-Poly1305 и пинга...'),
            ),
          ],
        ),
      ),
    );

    final report = await engine.runBenchmarkAndPing();
    if (!mounted) return;
    Navigator.of(context).pop();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Row(
          children: [
            Icon(Icons.speed, color: MayakTheme.accentCyan),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Тест скорости и готовности к звонкам',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '• Поток ChaCha20-Poly1305: ${report.chachaMbPerSec.toStringAsFixed(1)} МБ/сек\n'
                '• Обмены X25519 + HKDF: ${report.x25519HandshakesPerSec} опер/сек\n'
                '• Подписи Ed25519: ${report.ed25519SignsPerSec} опер/сек',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const Divider(height: 20),
              Row(
                children: [
                  Icon(
                    report.readyForVoicePtt
                        ? Icons.check_circle
                        : Icons.warning,
                    color: report.readyForVoicePtt
                        ? MayakTheme.accentEmerald
                        : Colors.orange,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Голосовая рация (Push-To-Talk / Opus): Готово',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    report.readyForVideoCalls
                        ? Icons.check_circle
                        : Icons.info_outline,
                    color: report.readyForVideoCalls
                        ? MayakTheme.accentEmerald
                        : Colors.amber,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      report.readyForVideoCalls
                          ? 'Видеозвонки по Wi-Fi (E2EE потоковое): Готово'
                          : 'Видеозвонки: только при прямом Wi-Fi',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (report.peerPingsMs.isNotEmpty) ...[
                const Divider(height: 20),
                const Text(
                  'Задержка (RTT Ping) до активных узлов:',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: MayakTheme.accentCyan),
                ),
                const SizedBox(height: 6),
                ...report.peerPingsMs.entries.map(
                  (e) => Text(
                    '• ${e.key}: ${e.value >= 0 ? "${e.value} мс" : "таймаут"}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _uniformMonoAction({
    required IconData icon,
    required String label,
    String? trailingText,
    VoidCallback? onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color(0xFF121212),
            side: const BorderSide(color: Color(0x2EFFFFFF), width: 1),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed: onPressed,
          child: Row(
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              if (trailingText != null)
                Text(
                  trailingText,
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showNetworkDiagnosticsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        side: BorderSide(color: Color(0x30FFFFFF), width: 1),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.terminal_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Диагностика узла • ${engine.nodeId}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white60, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF070707),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0x22FFFFFF)),
                    ),
                    child: Text(
                      'Позывной: ${engine.nickname} • HW: ${engine.myHwFingerprint}\n'
                      'IP: ${engine.cachedIps.isEmpty ? "нет" : engine.cachedIps.join(", ")}:${engine.listenPort}\n'
                      'В сети: ${engine.connectedPeersCount} • Буфер: ${engine.totalBufferedCount} • VPN: ${engine.vpnDetected ? "обнаружен (активен обход LAN)" : "нет"}',
                      style:
                          const TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _uniformMonoAction(
                    icon: Icons.wifi_find_rounded,
                    label: engine.isScanningSubnet
                        ? 'Сканирование Wi-Fi...'
                        : 'Сканировать Wi-Fi подсеть',
                    onPressed: engine.isScanningSubnet
                        ? null
                        : () async {
                            setSheetState(() {});
                            await engine.scanLocalSubnet();
                            if (ctx.mounted) setSheetState(() {});
                          },
                  ),
                  if (Platform.isAndroid)
                    _uniformMonoAction(
                      icon: engine.bleMeshActive
                          ? Icons.bluetooth_connected_rounded
                          : Icons.bluetooth_rounded,
                      label: engine.bleMeshActive
                          ? 'Bluetooth Mesh: Включён'
                          : 'Включить Bluetooth Mesh (BLE + RFCOMM)',
                      trailingText:
                          engine.bleMeshActive ? '${engine.blePeersCount} узл.' : 'ВЫКЛ',
                      onPressed: () async {
                        await engine.toggleAndroidBleMesh();
                        if (ctx.mounted) setSheetState(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                  if (Platform.isAndroid)
                    _uniformMonoAction(
                      icon: Icons.battery_saver_rounded,
                      label: 'Разрешить работу в фоне (без ограничений АКБ)',
                      onPressed: () async {
                        await engine.requestIgnoreBatteryOptimizations();
                      },
                    ),
                  if (Platform.isWindows)
                    _uniformMonoAction(
                      icon: Icons.security_rounded,
                      label: 'Открыть порты Windows (42069 / 42070 / 42072)',
                      onPressed: () async {
                        final res =
                            await engine.configureWindowsPublicFirewall();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(res == 'OK'
                                ? 'Порты 42069/42070/42072 открыты в Брандмауэре Windows!'
                                : 'Не удалось применить правила автоматически (требуются права Администратора)'),
                          ),
                        );
                      },
                    ),
                  _uniformMonoAction(
                    icon: Icons.speed_rounded,
                    label: 'Тест скорости и пинг узлов',
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showBenchmarkDialog();
                    },
                  ),
                  _uniformMonoAction(
                    icon: Icons.upload_file_rounded,
                    label: 'Экспорт резервной копии (.mayakbak)',
                    onPressed: () async {
                      final path = await engine.exportBackupJsonToDownloads();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Копия сохранена: $path')),
                      );
                    },
                  ),
                  _uniformMonoAction(
                    icon: Icons.restore_rounded,
                    label: 'Импорт резервной копии (.mayakbak)',
                    onPressed: () {
                      if (ctx.mounted) Navigator.pop(ctx);
                      _showImportBackupDialog();
                    },
                  ),
                  _uniformMonoAction(
                    icon: Icons.layers_clear_rounded,
                    label: 'Очистить буфер отправки',
                    trailingText: '${engine.totalBufferedCount} пак.',
                    onPressed: () async {
                      final cnt = await engine.clearOutboxAndTransitBuffer();
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Буфер очищен: удалено $cnt пак.')),
                      );
                    },
                  ),
                  _uniformMonoAction(
                    icon: Icons.cleaning_services_rounded,
                    label: 'Очистить кэш скачанных медиафайлов',
                    onPressed: () async {
                      final msg =
                          await engine.clearAllDownloadedMediaFromDevice();
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(msg)),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Журнал событий (последние записи):',
                    style: TextStyle(fontSize: 11.5, color: Colors.white54),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 150,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0x22FFFFFF)),
                    ),
                    child: ListView.builder(
                      itemCount: engine.debugLogs.length,
                      itemBuilder: (_, i) => Text(
                        engine.debugLogs[i],
                        style: const TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _confirmContactAction(ContactProfile c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person, color: MayakTheme.accentCyan),
              title: Text(c.displayTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('ID узла: ${c.nodeId} • ${c.lastAddress}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined,
                  color: Colors.amber),
              title: const Text('Очистить историю переписки'),
              onTap: () async {
                Navigator.pop(ctx);
                await engine.clearChatHistoryOnly(c.nodeId);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_forever, color: Colors.redAccent),
              title: const Text(
                'Удалить контакт и чат навсегда',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await engine.deleteContact(c.nodeId);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openDedicatedSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MayakSettingsScreen(
          engine: engine,
          onEditNickname: _showEditNicknameDialog,
          onShowQrAdd: _showAddContactSheet,
          onOpenDiagnostics: _showNetworkDiagnosticsSheet,
          onOpenAdminUnlock: _showAdminSecretKeyDialog,
          onOpenAdminDashboard: _openFullAdminDashboard,
        ),
      ),
    );
  }

  Widget _buildGeminiDrawer() {
    return Drawer(
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
        side: BorderSide(color: Color(0x26FFFFFF), width: 1),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 16, 14),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Navigator.pop(context);
                  _showEditNicknameDialog();
                },
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white38, width: 1),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Image.asset('assets/mayak_icon.png',
                            fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            engine.nickname.isEmpty ? 'Маяк' : engine.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'ID: ${engine.nodeId} • В сети: ${engine.connectedPeersCount}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            const SizedBox(height: 8),
            _drawerTile(
              icon: Icons.chat_bubble_outline_rounded,
              label: 'Все чаты',
              selected: _drawerSection == 'all',
              onTap: () {
                setState(() => _drawerSection = 'all');
                Navigator.pop(context);
              },
            ),
            _drawerTile(
              icon: Icons.person_outline_rounded,
              label: 'Личные чаты',
              selected: _drawerSection == 'direct',
              onTap: () {
                setState(() => _drawerSection = 'direct');
                Navigator.pop(context);
              },
            ),
            _drawerTile(
              icon: Icons.groups_outlined,
              label: 'Общие чаты',
              selected: _drawerSection == 'groups',
              onTap: () {
                setState(() => _drawerSection = 'groups');
                Navigator.pop(context);
              },
            ),
            _drawerTile(
              icon: Icons.bookmark_border_rounded,
              label: 'Избранное',
              selected: false,
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SavedMessagesScreen(engine: engine),
                  ),
                );
              },
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(height: 1, color: Color(0x22FFFFFF)),
            ),
            _drawerTile(
              icon: Icons.add_circle_outline_rounded,
              label: 'Добавить чат / узел',
              selected: false,
              onTap: () {
                Navigator.pop(context);
                _showAddOrCreateMenu();
              },
            ),
            _drawerTile(
              icon: Icons.radio_rounded,
              label: engine.isWalkieTalkieMode
                  ? 'Рация (PTT): Вкл'
                  : 'Режим Рации (PTT)',
              selected: engine.isWalkieTalkieMode,
              onTap: () {
                engine.toggleWalkieTalkieMode();
                Navigator.pop(context);
              },
            ),
            const Spacer(),
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              child: _drawerTile(
                icon: Icons.settings_outlined,
                label: 'Настройки',
                selected: false,
                onTap: () {
                  Navigator.pop(context);
                  _openDedicatedSettings();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerTile({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? const Color(0x1FFFFFFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: selected
                  ? Border.all(color: Colors.white30, width: 1)
                  : null,
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: selected ? Colors.white : Colors.white70),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                      color: selected ? Colors.white : Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddOrCreateMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0x26FFFFFF)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Добавить чат или узел',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.qr_code_2_rounded, color: Colors.white),
                title: const Text('Подключить по QR-коду или IP'),
                subtitle: const Text('Прямое P2P-соединение в локальной сети',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddContactSheet();
                },
              ),
              ListTile(
                leading: const Icon(Icons.group_add_outlined, color: Colors.white),
                title: const Text('Создать групповой чат'),
                subtitle: const Text('Multi-Hop E2EE комната для 3+ участников',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showCreateGroupDialog();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allContacts = engine.knownContacts.values.toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        final lastA = engine.getLastMessageFor(a.nodeId)?.timestamp ?? 0;
        final lastB = engine.getLastMessageFor(b.nodeId)?.timestamp ?? 0;
        return lastB.compareTo(lastA);
      });

    final contacts = _searchQuery.isEmpty
        ? allContacts
        : allContacts
            .where((c) =>
                c.displayTitle.toLowerCase().contains(_searchQuery) ||
                c.nodeId.toLowerCase().contains(_searchQuery))
            .toList();

    final lastBroadcast =
        engine.getLastMessageFor(MeshEngine.broadcastChannelId);

    return Scaffold(
      drawer: _buildGeminiDrawer(),
      appBar: AppBar(
        toolbarHeight: 64,
        shape: const Border(
          bottom: BorderSide(color: Color(0x22FFFFFF), width: 1),
        ),
        title: GestureDetector(
          onTap: _showEditNicknameDialog,
          onLongPress: _showAdminSecretKeyDialog,
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white30, width: 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.asset('assets/mayak_icon.png', fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            engine.nickname.isEmpty ? 'Маяк' : engine.nickname,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 17,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Icon(Icons.edit, size: 14, color: Colors.white54),
                      ],
                    ),
                    Text(
                      engine.isSelfBanned
                          ? '🚫 УЗЕЛ ЗАБЛОКИРОВАН АДМИНОМ'
                          : (engine.connectedPeersCount > 0
                              ? 'В сети: ${engine.connectedPeersCount} узел(ов) • ID: ${engine.nodeId}'
                              : 'Автономный поиск • ID: ${engine.nodeId}'),
                      style: TextStyle(
                        fontSize: 11,
                        color: engine.isSelfBanned
                            ? MayakTheme.accentRed
                            : (engine.connectedPeersCount > 0
                                ? MayakTheme.accentEmerald
                                : Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (engine.isAdminUnlocked)
            IconButton(
              tooltip: 'Панель Управления Сетью (ROOT)',
              onPressed: _openFullAdminDashboard,
              icon: Badge(
                isLabelVisible: engine.banAppeals.isNotEmpty ||
                    engine.triggerHits.isNotEmpty,
                label: Text(
                    '${engine.banAppeals.length + engine.triggerHits.length}'),
                child: const Icon(Icons.admin_panel_settings_rounded,
                    color: MayakTheme.accentAmber),
              ),
            ),
          IconButton(
            tooltip: 'Режим Рации (PTT)',
            onPressed: () => engine.toggleWalkieTalkieMode(),
            icon: Icon(
              Icons.radio_rounded,
              color: engine.isWalkieTalkieMode
                  ? MayakTheme.accentEmerald
                  : Colors.white70,
            ),
          ),
          IconButton(
            tooltip: 'Настройки',
            onPressed: _openDedicatedSettings,
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
          ),
        ],
      ),
      body: Column(
        children: [
          if (engine.isSelfBanned)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFF450A0A),
                border: Border(
                  bottom: BorderSide(color: MayakTheme.accentRed, width: 1),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.block,
                      color: Colors.redAccent, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Ваш узел заблокирован администратором. Отправка сообщений в чаты отключена.',
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: MayakTheme.accentAmber,
                      foregroundColor: Colors.black,
                    ),
                    icon: const Icon(Icons.edit_note, size: 16),
                    label: const Text(
                      'Записка на разбан',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _showBanAppealDialog,
                  ),
                ],
              ),
            ),
              if (engine.incomingCallFromPeerId != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF065F46), Color(0xFF0E7490)],
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        engine.incomingCallMode == 'video'
                            ? Icons.videocam_rounded
                            : Icons.call_rounded,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${engine.incomingCallMode == 'video' ? 'Входящий ВЧ' : 'Входящий ГЧ'} от ${engine.knownContacts[engine.incomingCallFromPeerId]?.displayTitle ?? engine.incomingCallFromPeerId}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () => engine.rejectIncomingCall(),
                        child: const Text('Сброс',
                            style: TextStyle(color: Colors.redAccent)),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () async {
                          await engine.acceptIncomingCall();
                          if (!mounted) return;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CallSessionScreen(engine: engine),
                            ),
                          );
                        },
                        child: const Text('Принять'),
                      ),
                    ],
                  ),
                ),
          if (engine.vpnDetected)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: const Color(0xFF422006),
              child: const Row(
                children: [
                  Icon(Icons.shield_outlined,
                      size: 16, color: MayakTheme.accentAmber),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Активен VPN: Маяк автоматически обходит туннель для локальной сети.',
                      style: TextStyle(fontSize: 11, color: Color(0xFFFDE68A)),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            decoration: const BoxDecoration(
              color: MayakTheme.bgSurface,
              border: Border(
                bottom: BorderSide(color: Colors.white10),
              ),
            ),
            child: Column(
              children: [
                TextField(
                  controller: _searchCtrl,
                  onChanged: (v) =>
                      setState(() => _searchQuery = v.trim().toLowerCase()),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Поиск по позывному или ID узла...',
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
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: MayakTheme.bgDeep,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildStatusPill(
                      icon: Icons.lan_rounded,
                      text: 'IP: ${engine.cachedIps.first}',
                      color: MayakTheme.accentCyan,
                    ),
                    const SizedBox(width: 6),
                    _buildStatusPill(
                      icon: Icons.people_alt_rounded,
                      text: 'Онлайн: ${engine.connectedPeersCount}',
                      color: engine.connectedPeersCount > 0
                          ? MayakTheme.accentEmerald
                          : Colors.white38,
                    ),
                    const SizedBox(width: 6),
                    _buildStatusPill(
                      icon: Icons.outbox_rounded,
                      text: 'Буфер: ${engine.totalBufferedCount}',
                      color: engine.totalBufferedCount > 0
                          ? MayakTheme.accentAmber
                          : Colors.white38,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // Карточка Общего эфира
                if (_drawerSection != 'direct')
                Container(
                  margin: EdgeInsets.zero,
                  decoration: const BoxDecoration(
                    color: MayakTheme.bgDeep,
                    border: Border(
                      bottom: BorderSide(color: Color(0x1FFFFFFF), width: 1),
                    ),
                  ),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    onTap: () => _openChatRoom(
                      MeshEngine.broadcastChannelId,
                      'Общий эфир (Все рядом)',
                      true,
                    ),
                    leading: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFD97706), Color(0xFFF59E0B)],
                        ),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.campaign_rounded,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                    title: const Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Общий эфир (Все рядом)',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                        Text(
                          'КАНАЛ',
                          style: TextStyle(
                            fontSize: 10,
                            color: MayakTheme.accentAmber,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        lastBroadcast != null
                            ? '${lastBroadcast.senderName}: ${lastBroadcast.text}'
                            : 'Открытый широковещательный канал для всех узлов рядом',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    trailing: engine.unreadBroadcastCount > 0
                        ? CircleAvatar(
                            radius: 12,
                            backgroundColor: MayakTheme.accentAmber,
                            child: Text(
                              '${engine.unreadBroadcastCount}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : const Icon(Icons.chevron_right,
                            color: Colors.white38),
                  ),
                ),
                if (_drawerSection != 'direct')
                ...engine.groupChats.values.map((grp) {
                  final gMsgs = engine.getGroupMessages(grp.groupId);
                  final lastG = gMsgs.isNotEmpty ? gMsgs.last : null;
                  final unreadG = engine.unreadGroupCounts[grp.groupId] ?? 0;
                  return Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: MayakTheme.bgSurface,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: MayakTheme.accentIndigo.withOpacity(0.45),
                      ),
                    ),
                    child: ListTile(
                      onTap: () {
                        engine.markGroupRead(grp.groupId);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => GroupConversationScreen(
                                engine: engine, group: grp),
                          ),
                        );
                      },
                      leading: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF4F46E5), Color(0xFF06B6D4)],
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.groups_rounded,
                            color: Colors.white),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              grp.title,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                          ),
                          Text(
                            '${grp.memberIds.length} уч.',
                            style: const TextStyle(
                                fontSize: 10, color: MayakTheme.accentCyan),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        lastG != null
                            ? '${lastG.senderName}: ${lastG.text}'
                            : 'Групповая E2EE-комната',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                      trailing: unreadG > 0
                          ? CircleAvatar(
                              radius: 12,
                              backgroundColor: MayakTheme.accentCyan,
                              child: Text(
                                '$unreadG',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            )
                          : const Icon(Icons.chevron_right,
                              color: Colors.white38),
                    ),
                  );
                }),
                if (contacts.isEmpty && engine.groupChats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: MayakTheme.bgSurface,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Icon(Icons.radar_rounded,
                              size: 40, color: MayakTheme.accentCyan),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Ожидание других узлов Маяк...',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Устройства в одной Wi-Fi сети или точке доступа находятся автоматически.\nЕсли сети изолированы — нажмите на иконку QR-кода сверху.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                if (_drawerSection != 'groups')
                ...contacts.map((c) {
                  final lastMsg = engine.getLastMessageFor(c.nodeId);
                  final isBanned = engine.isNodeBanned(c.nodeId);
                  final colors = _avatarColorsFor(c.nodeId);
                  return Container(
                    margin: EdgeInsets.zero,
                    decoration: const BoxDecoration(
                      color: MayakTheme.bgDeep,
                      border: Border(
                        bottom: BorderSide(color: Color(0x1FFFFFFF), width: 1),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      onTap: () => _openChatRoom(c.nodeId, c.displayTitle, false),
                      onLongPress: () => _confirmContactAction(c),
                      leading: Stack(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: isBanned
                                    ? [
                                        const Color(0xFF7F1D1D),
                                        const Color(0xFF991B1B)
                                      ]
                                    : colors,
                              ),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              c.displayTitle.characters.first.toUpperCase(),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontSize: 19,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: isBanned
                                    ? MayakTheme.accentRed
                                    : (c.isOnline
                                        ? MayakTheme.accentEmerald
                                        : Colors.grey),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: MayakTheme.bgSurface,
                                  width: 2.2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              isBanned
                                  ? '🚫 ${c.displayTitle} (БАН)'
                                  : c.displayTitle,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: isBanned
                                    ? Colors.redAccent
                                    : Colors.white,
                              ),
                            ),
                          ),
                          if (lastMsg != null)
                            Text(
                              lastMsg.timeFormatted,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54),
                            ),
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          lastMsg != null
                              ? (lastMsg.isMe
                                  ? 'Вы: ${lastMsg.text}'
                                  : lastMsg.text)
                              : (c.isOnline
                                  ? 'Онлайн (${c.lastAddress}) • E2EE'
                                  : 'Оффлайн • Доставка через буфер'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.unreadCount > 0
                                ? MayakTheme.accentCyan
                                : Colors.white60,
                            fontWeight: c.unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (c.unreadCount > 0)
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: MayakTheme.accentCyan,
                              child: Text(
                                '${c.unreadCount}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          IconButton(
                            tooltip: 'Действия с чатом',
                            icon: const Icon(Icons.more_vert,
                                size: 18, color: Colors.white38),
                            onPressed: () => _confirmContactAction(c),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'fab_group',
            backgroundColor: MayakTheme.bgElevated,
            foregroundColor: Colors.white,
            onPressed: _showCreateGroupDialog,
            icon: const Icon(Icons.group_add_rounded),
            label: const Text('Группа',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          FloatingActionButton.extended(
            heroTag: 'fab_peer',
            backgroundColor: MayakTheme.accentCyan,
            foregroundColor: Colors.black,
            onPressed: _showAddContactSheet,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text(
              'Новый узел',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: MayakTheme.bgDeep,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ПОЛНОЭКРАННАЯ ПАНЕЛЬ АДМИНИСТРАТОРА СЕТИ «ЩИТ МАЯКА» (Исправление пунктов 6, 7 и 8)
class AdminDashboardScreen extends StatefulWidget {
  final MeshEngine engine;
  const AdminDashboardScreen({super.key, required this.engine});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  MeshEngine get engine => widget.engine;

  void _onAdminEngineUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    engine.addListenerState(_onAdminEngineUpdate);
  }

  @override
  void dispose() {
    engine.removeListenerState(_onAdminEngineUpdate);
    super.dispose();
  }

  void _showAddTriggerDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Text('Добавить триггерное слово'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Например: бомба, взрыв, террор, клад...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MayakTheme.accentAmber,
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              final w = ctrl.text.trim();
              if (w.isNotEmpty) {
                await engine.addAdminTriggerWord(w);
              }
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) setState(() {});
            },
            child: const Text('Добавить и синхронизировать'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nodes = engine.knownContacts.values.toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return b.lastSeenTimestamp.compareTo(a.lastSeenTimestamp);
      });

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: MayakTheme.bgDeep,
        appBar: AppBar(
          backgroundColor: MayakTheme.bgSurface,
          title: const Row(
            children: [
              Icon(Icons.shield_rounded, color: MayakTheme.accentAmber),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Панель Администратора Сети',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Мониторинг узлов, триггеров (-5 : +5) и блокировок',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Опросить все узлы',
              icon: const Icon(Icons.sync, color: MayakTheme.accentCyan),
              onPressed: () async {
                await engine.pingAllKnownNodes();
                if (mounted) setState(() {});
              },
            ),
          ],
          bottom: TabBar(
            indicatorColor: MayakTheme.accentAmber,
            labelColor: MayakTheme.accentAmber,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(text: '📡 Узлы (${nodes.length + 1})'),
              Tab(text: '🎯 Триггеры (${engine.triggerHits.length})'),
              Tab(text: '📨 Апелляции (${engine.banAppeals.length})'),
            ],
          ),
        ),
        body: Column(
          children: [
            // Верхняя информационная панель показателей (KPI)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: const BoxDecoration(
                color: MayakTheme.bgSurface,
                border: Border(bottom: BorderSide(color: Colors.white12)),
              ),
              child: Row(
                children: [
                  _buildKpiBox(
                    label: 'Онлайн',
                    value: '${engine.connectedPeersCount + 1}',
                    color: MayakTheme.accentEmerald,
                  ),
                  const SizedBox(width: 8),
                  _buildKpiBox(
                    label: 'Всего в базе',
                    value: '${nodes.length + 1}',
                    color: MayakTheme.accentCyan,
                  ),
                  const SizedBox(width: 8),
                  _buildKpiBox(
                    label: 'В бане',
                    value: '${engine.bannedNodeIds.length}',
                    color: MayakTheme.accentRed,
                  ),
                  const SizedBox(width: 8),
                  _buildKpiBox(
                    label: 'Инцидентов',
                    value: '${engine.triggerHits.length}',
                    color: MayakTheme.accentAmber,
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // ВКЛАДКА 1: ВСЕ УЗЛЫ СЕТИ И ПОДРОБНЫЕ ДАННЫЕ
                  ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      _buildAdminNodeCard(
                        title: '${engine.nickname} (ВЫ — АДМИНИСТРАТОР)',
                        nodeId: engine.nodeId,
                        hw: engine.myHwFingerprint,
                        osInfo: engine.myPlatformInfo,
                        ipAddr:
                            '${engine.cachedIps.join(", ")}:${engine.listenPort}',
                        dhKey: engine.dhPubHex,
                        signKey: engine.signPubHex,
                        isOnline: true,
                        pingMs: 0,
                        isBanned: engine.isSelfBanned,
                        isSelf: true,
                      ),
                      ...nodes.map(
                        (c) => _buildAdminNodeCard(
                          title: c.displayTitle,
                          nodeId: c.nodeId,
                          hw: c.hwFingerprint,
                          osInfo: c.platformInfo,
                          ipAddr: c.lastAddress,
                          dhKey: c.dhPubHex,
                          signKey: c.signPubHex,
                          isOnline: c.isOnline,
                          pingMs: c.lastPingMs,
                          isBanned: engine.isNodeBanned(c.nodeId),
                          isSelf: false,
                        ),
                      ),
                    ],
                  ),

                  // ВКЛАДКА 2: ТРИГГЕРЫ (-5 : +5 СООБЩЕНИЙ) + ПОЛНОЕ ДОСЬЕ УЗЛА + ОЧИСТКА
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        color: MayakTheme.bgSurface,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Слова-триггеры (синхронизируются на все узлы даже оффлайн):',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white70),
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  icon: const Icon(Icons.add, size: 16),
                                  label: const Text('+ Слово',
                                      style: TextStyle(fontSize: 12)),
                                  onPressed: _showAddTriggerDialog,
                                ),
                                if (engine.triggerHits.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: MayakTheme.accentRed,
                                      side: const BorderSide(
                                          color: MayakTheme.accentRed),
                                    ),
                                    icon: const Icon(Icons.delete_sweep_rounded,
                                        size: 16),
                                    label: const Text('Очистить журнал',
                                        style: TextStyle(fontSize: 12)),
                                    onPressed: () async {
                                      await engine.clearAllTriggerHits();
                                      if (mounted) setState(() {});
                                    },
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: engine.adminTriggerWords
                                  .map(
                                    (w) => InputChip(
                                      label: Text(w,
                                          style: const TextStyle(fontSize: 12)),
                                      backgroundColor: MayakTheme.bgElevated,
                                      deleteIconColor: Colors.redAccent,
                                      onDeleted: () async {
                                        await engine.removeAdminTriggerWord(w);
                                        if (mounted) setState(() {});
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: engine.triggerHits.isEmpty
                            ? const Center(
                                child: Text(
                                  'Срабатываний триггеров в чатах пока не зафиксировано.\nПри срабатывании здесь появится полное досье узла и контекст -5 : +5 сообщений.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 13),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(14),
                                itemCount: engine.triggerHits.length,
                                itemBuilder: (_, i) {
                                  final hit = engine.triggerHits[i];
                                  final isOffenderBanned =
                                      engine.isNodeBanned(hit.offenderNodeId);
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: MayakTheme.bgSurface,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: MayakTheme.accentRed
                                            .withOpacity(0.55),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 4),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF7F1D1D),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                'ТРИГГЕР: «${hit.triggerWord}»',
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                '${hit.chatTitle} • ${hit.formattedDateTime}',
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: MayakTheme.accentAmber,
                                                ),
                                              ),
                                            ),
                                            IconButton(
                                              tooltip:
                                                  'Удалить эту запись из журнала',
                                              icon: const Icon(Icons.close,
                                                  size: 18,
                                                  color: Colors.white54),
                                              onPressed: () async {
                                                await engine
                                                    .deleteSingleTriggerHit(
                                                        hit.hitId);
                                                if (mounted) setState(() {});
                                              },
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        // ПОЛНОЕ ТЕХНИЧЕСКОЕ ДОСЬЕ УЗЛА-НАРУШИТЕЛЯ (Исправление пункта 7)
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: MayakTheme.bgDeep,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                                color: Colors.white12),
                                          ),
                                          child: SelectableText(
                                            '👤 Позывной: ${hit.offenderName}\n'
                                            '🔑 Крипто-ID узла: ${hit.offenderNodeId}\n'
                                            '🧬 HW-отпечаток устройства: ${hit.offenderHwFingerprint.isNotEmpty ? hit.offenderHwFingerprint : "Н/Д"}\n'
                                            '🌐 Сетевой адрес (IP:Порт): ${hit.offenderIpAddress.isNotEmpty ? hit.offenderIpAddress : "Mesh-маршрут"}\n'
                                            '💻 ОС / Устройство: ${hit.offenderPlatformInfo.isNotEmpty ? hit.offenderPlatformInfo : "Не указано"}\n'
                                            '🔐 Ключ X25519: ${hit.offenderDhPubHex.isNotEmpty ? hit.offenderDhPubHex : "Н/Д"}\n'
                                            '✍️ Ключ Ed25519: ${hit.offenderSignPubHex.isNotEmpty ? hit.offenderSignPubHex : "Н/Д"}',
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 11,
                                              color: Colors.white70,
                                              height: 1.4,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        const Text(
                                          'Контекст переписки (-5 сообщений до и +5 после):',
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: MayakTheme.accentCyan),
                                        ),
                                        const SizedBox(height: 6),
                                        ...hit.beforeLines.map(
                                          (l) => Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 1.5),
                                            child: Text(
                                              l,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white54),
                                            ),
                                          ),
                                        ),
                                        Container(
                                          width: double.infinity,
                                          margin: const EdgeInsets.symmetric(
                                              vertical: 5),
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF450A0A),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                                color: Colors.redAccent),
                                          ),
                                          child: SelectableText(
                                            hit.triggerLine,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        ...hit.afterLines.map(
                                          (l) => Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 1.5),
                                            child: Text(
                                              l,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white70),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton.icon(
                                              icon: const Icon(Icons.copy_all,
                                                  size: 16),
                                              label: const Text(
                                                  'Скопировать полное досье',
                                                  style:
                                                      TextStyle(fontSize: 12)),
                                              onPressed: () {
                                                Clipboard.setData(ClipboardData(
                                                    text: hit
                                                        .buildFullSecurityDossierText()));
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                        'Полное техническое досье инцидента скопировано в буфер обмена!'),
                                                  ),
                                                );
                                              },
                                            ),
                                            if (hit.offenderNodeId !=
                                                engine.nodeId)
                                              FilledButton.tonalIcon(
                                                style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      isOffenderBanned
                                                          ? const Color(
                                                              0xFF065F46)
                                                          : const Color(
                                                              0xFF7F1D1D),
                                                  foregroundColor: Colors.white,
                                                ),
                                                icon: Icon(
                                                  isOffenderBanned
                                                      ? Icons.lock_open
                                                      : Icons.gavel_rounded,
                                                  size: 15,
                                                ),
                                                label: Text(
                                                  isOffenderBanned
                                                      ? 'Разбанить ${hit.offenderName}'
                                                      : 'Забанить ${hit.offenderName}',
                                                  style: const TextStyle(
                                                      fontSize: 12),
                                                ),
                                                onPressed: () async {
                                                  await engine
                                                      .executeAdminBanOrUnban(
                                                    targetNodeId:
                                                        hit.offenderNodeId,
                                                    ban: !isOffenderBanned,
                                                  );
                                                  if (mounted) setState(() {});
                                                },
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),

                  // ВКЛАДКА 3: АПЕЛЛЯЦИИ (ЗАПИСКИ НА РАЗБАН)
                  engine.banAppeals.isEmpty
                      ? const Center(
                          child: Text(
                            'Новых записок на разбан от заблокированных узлов нет.',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(14),
                          itemCount: engine.banAppeals.length,
                          itemBuilder: (_, i) {
                            final ap = engine.banAppeals[i];
                            final stillBanned = engine.isNodeBanned(ap.nodeId);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: MayakTheme.bgSurface,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color:
                                      MayakTheme.accentAmber.withOpacity(0.4),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.mail_lock_rounded,
                                          color: MayakTheme.accentAmber,
                                          size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${ap.nickname} (ID: ${ap.nodeId} • HW: ${ap.hwFingerprint})',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: MayakTheme.bgDeep,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      ap.appealText,
                                      style: const TextStyle(
                                          fontSize: 13, color: Colors.white),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: stillBanned
                                            ? MayakTheme.accentEmerald
                                            : Colors.grey,
                                        foregroundColor: Colors.black,
                                      ),
                                      icon: const Icon(Icons.lock_open,
                                          size: 16),
                                      label: Text(stillBanned
                                          ? 'Принять апелляцию и РАЗБАНИТЬ'
                                          : 'Уже разбанен'),
                                      onPressed: stillBanned
                                          ? () async {
                                              await engine
                                                  .executeAdminBanOrUnban(
                                                targetNodeId: ap.nodeId,
                                                ban: false,
                                              );
                                              if (mounted) setState(() {});
                                            }
                                          : null,
                                    ),
                                  ),
                                ],
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
  }

  Widget _buildKpiBox({
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: MayakTheme.bgDeep,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminNodeCard({
    required String title,
    required String nodeId,
    required String hw,
    required String osInfo,
    required String ipAddr,
    required String dhKey,
    required String signKey,
    required bool isOnline,
    required int pingMs,
    required bool isBanned,
    required bool isSelf,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MayakTheme.bgSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isBanned
              ? MayakTheme.accentRed.withOpacity(0.6)
              : (isOnline
                  ? MayakTheme.accentEmerald.withOpacity(0.4)
                  : Colors.white12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isBanned
                      ? MayakTheme.accentRed
                      : (isOnline ? MayakTheme.accentEmerald : Colors.grey),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isBanned
                      ? const Color(0xFF7F1D1D)
                      : (isOnline
                          ? const Color(0xFF065F46)
                          : Colors.white10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isBanned ? 'ЗАБАНЕН' : (isOnline ? 'ОНЛАЙН' : 'ОФФЛАЙН'),
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            'ID узла: $nodeId • HW-ID: ${hw.isNotEmpty ? hw : "Н/Д"}\n'
            'ОС / Устройство: ${osInfo.isNotEmpty ? osInfo : "Не определено"}\n'
            'Адрес: ${ipAddr.isNotEmpty ? ipAddr : "Mesh"} ${pingMs >= 0 ? "• Ping: $pingMs мс" : ""}\n'
            'X25519: $dhKey\n'
            'Ed25519: $signKey',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Colors.white70,
              height: 1.35,
            ),
          ),
          if (!isSelf) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: isBanned
                        ? const Color(0xFF065F46)
                        : const Color(0xFF7F1D1D),
                    foregroundColor: Colors.white,
                  ),
                  icon: Icon(
                    isBanned ? Icons.lock_open : Icons.gavel_rounded,
                    size: 16,
                  ),
                  label: Text(
                    isBanned ? 'РАЗБАНИТЬ УЗЕЛ' : 'ЗАБАНИТЬ В СЕТИ',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    await engine.executeAdminBanOrUnban(
                      targetNodeId: nodeId,
                      ban: !isBanned,
                    );
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class ChatConversationScreen extends StatefulWidget {
  final MeshEngine engine;
  final String peerId;
  final String initialTitle;
  final bool isBroadcast;

  const ChatConversationScreen({
    super.key,
    required this.engine,
    required this.peerId,
    required this.initialTitle,
    required this.isBroadcast,
  });

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final TextEditingController _msgCtrl = TextEditingController();
  bool _isSearching = false;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  final ScrollController _scrollCtrl = ScrollController();

  MeshEngine get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    engine.addListenerState(_onEngineUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    engine.removeListenerState(_onEngineUpdate);
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onEngineUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent + 140,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _msgCtrl.clear();
    await engine.sendMessage(widget.peerId, text);
    _scrollToBottom();
  }

  void _pickAndSendFile({String mode = 'all'}) async {
    final picked = await engine.pickFileForChat(mode: mode);
    if (picked == null) return;
    final path = (picked['path'] as String?) ?? '';
    final name = (picked['name'] as String?) ?? 'file.bin';
    final thumbB64 = (picked['thumbB64'] as String?) ?? '';
    if (path.isEmpty) return;
    await engine.sendFileMessage(
      widget.peerId,
      filePath: path,
      fileName: name,
      thumbB64Arg: thumbB64.isNotEmpty ? thumbB64 : null,
    );
    _scrollToBottom();
  }

  void _toggleVoiceRecording() async {
    if (!engine.isRecordingVoice) {
      final started = await engine.startVoiceRecording();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Не удалось запустить микрофон для записи')),
        );
      }
    } else {
      final voiceInfo = await engine.stopVoiceRecording();
      if (voiceInfo != null) {
        final path = (voiceInfo['path'] as String?) ?? '';
        final name = (voiceInfo['name'] as String?) ?? 'Голосовое.m4a';
        if (path.isNotEmpty) {
          await engine.sendFileMessage(
            widget.peerId,
            filePath: path,
            fileName: name,
          );
          _scrollToBottom();
        }
      }
    }
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 9: Меню действий с сообщением (Реакции, Редактировать, Переслать, Удалить у всех, Копировать)
  void _showMessageActionsSheet(ChatMessage m) {
    const emojis = ['👍', '❤️', '🔥', '😂', '😮', '👏', '💯', '🤝'];
    final canEdit = m.isMe && (m.fileName == null || m.fileName!.isEmpty);
    final canDelete = m.isMe || engine.isAdminUnlocked;

    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Ряд быстрых реакций
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: emojis
                      .map(
                        (e) => InkWell(
                          borderRadius: BorderRadius.circular(30),
                          onTap: () {
                            Navigator.pop(ctx);
                            engine.sendReaction(widget.peerId, m.msgId, e);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(e, style: const TextStyle(fontSize: 26)),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const Divider(height: 16),
              if (canEdit)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.edit_rounded,
                      color: MayakTheme.accentCyan),
                  title: const Text('Редактировать сообщение'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showEditMessageDialog(m);
                  },
                ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.forward_rounded,
                    color: MayakTheme.accentIndigo),
                title: const Text('Переслать в другой чат'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showForwardMessagePicker(m);
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.copy_rounded, color: Colors.white70),
                title: const Text('Скопировать текст'),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: m.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Текст скопирован')),
                  );
                },
              ),
              if (canDelete)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.delete_outline_rounded,
                      color: MayakTheme.accentRed),
                  title: const Text(
                    'Удалить сообщение у всех',
                    style: TextStyle(color: MayakTheme.accentRed),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await engine.deleteMessageForEveryone(
                        widget.peerId, m.msgId);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditMessageDialog(ChatMessage m) {
    final editCtrl = TextEditingController(text: m.text);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Text('Редактировать сообщение',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: editCtrl,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: InputDecoration(
            filled: true,
            fillColor: MayakTheme.bgDeep,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MayakTheme.accentCyan,
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              final updated = editCtrl.text.trim();
              if (updated.isNotEmpty) {
                await engine.editMessage(widget.peerId, m.msgId, updated);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showForwardMessagePicker(ChatMessage m) {
    final contacts = engine.knownContacts.values.toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Куда переслать сообщение?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: MayakTheme.accentAmber,
                  child: Icon(Icons.campaign_rounded, color: Colors.black),
                ),
                title: const Text('Общий эфир (Все рядом)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await engine.forwardMessageToChat(
                      m, MeshEngine.broadcastChannelId);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Сообщение переслано в Общий эфир')),
                  );
                },
              ),
              ...contacts.map(
                (c) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: MayakTheme.accentIndigo,
                    child: Text(c.displayTitle.characters.first.toUpperCase()),
                  ),
                  title: Text(c.displayTitle),
                  subtitle: Text('ID: ${c.nodeId}'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await engine.forwardMessageToChat(m, c.nodeId);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(
                              'Сообщение переслано контакту ${c.displayTitle}')),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSafetyNumberDialog() async {
    final code = await engine.computeSafetyNumber(widget.peerId);
    if (!mounted) return;
    final c = engine.knownContacts[widget.peerId];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Row(
          children: [
            Icon(Icons.verified_user, color: MayakTheme.accentCyan),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Код безопасности E2EE',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Сверьте эти 4 группы цифр с собеседником. Если они совпадают — соединение на 100% защищено от перехвата (MITM):',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: MayakTheme.bgDeep,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: MayakTheme.accentCyan.withOpacity(0.4)),
              ),
              child: Text(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: MayakTheme.accentCyan,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            if (c != null) ...[
              const SizedBox(height: 12),
              Text(
                'Ключ узла X25519:\n${c.dhPubHex.substring(0, 32)}...',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.white38,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  void _openInAppImageViewer(String imagePath, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InAppImageViewerScreen(
          engine: engine,
          imagePath: imagePath,
          title: title,
        ),
      ),
    );
  }

  void _openInAppVideoPlayer(
      String videoPath, String title, String? thumbB64) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InAppVideoPlayerScreen(
          engine: engine,
          videoPath: videoPath,
          title: title,
          thumbB64: thumbB64,
        ),
      ),
    );
  }

  /// ИСПРАВЛЕНИЕ ПУНКТА 2: Отображение фото и видео с эффектом блюра как в Telegram и скачиванием по нажатию кнопки (без автосохранения превьюшек в Загрузки!)
  Widget _buildInlineMediaPreview(ChatMessage m) {
    final hasFileOnDisk =
        m.filePath != null && File(m.filePath!).existsSync();
    final hasThumbB64 = m.thumbB64 != null && m.thumbB64!.isNotEmpty;

    Uint8List? thumbBytes;
    if (hasThumbB64) {
      try {
        thumbBytes = base64Decode(m.thumbB64!);
      } catch (_) {}
    }

    // 1. Встроенный аудиоплеер для голосовых и музыки (если еще не скачан — сначала кнопка Скачать!)
    if (m.isAudioFile) {
      if (!hasFileOnDisk) {
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: MayakTheme.accentCyan,
                  foregroundColor: Colors.black,
                ),
                icon: m.isDownloading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black),
                      )
                    : const Icon(Icons.download_rounded),
                onPressed: m.isDownloading
                    ? null
                    : () => engine.requestDownloadOrRevealMedia(m),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.fileName ?? 'Аудиозапись',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    Text(
                      m.isDownloading
                          ? 'Скачивание ${(m.transferProgress * 100).toInt()}%...'
                          : 'Нажмите, чтобы скачать (${m.fileSizeFormatted})',
                      style: const TextStyle(
                          fontSize: 11, color: MayakTheme.accentCyan),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      final isThisPlaying =
          engine.currentlyPlayingAudioPath == m.filePath &&
              engine.isAudioPlaying;
      final isThisLoaded = engine.currentlyPlayingAudioPath == m.filePath;
      final curMs = isThisLoaded ? engine.audioPositionMs : 0;
      final totMs = isThisLoaded ? max(engine.audioDurationMs, 1) : 1;
      final progress =
          isThisLoaded ? (curMs / totMs).clamp(0.0, 1.0) : 0.0;

      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                isThisPlaying ? MayakTheme.accentCyan : Colors.white12,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: isThisPlaying
                        ? Colors.amber
                        : MayakTheme.accentCyan,
                    foregroundColor: Colors.black,
                  ),
                  icon: Icon(
                      isThisPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () => engine.togglePlayAudioFile(m.filePath!),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.fileName ?? 'Аудиосообщение',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12),
                        ),
                        child: Slider(
                          value: progress,
                          activeColor: MayakTheme.accentCyan,
                          inactiveColor: Colors.white24,
                          onChanged: isThisLoaded
                              ? (val) {
                                  final target = (val * totMs).round();
                                  engine.seekAudioFile(target);
                                }
                              : null,
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isThisLoaded
                                ? '${MeshEngine.formatDurationMs(curMs)} / ${MeshEngine.formatDurationMs(totMs)}'
                                : m.fileSizeFormatted,
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white70),
                          ),
                          InkWell(
                            onTap: () async {
                              final msg =
                                  await engine.saveReceivedFileToDownloads(
                                m.filePath!,
                                m.fileName ?? 'audio.m4a',
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(msg)),
                              );
                            },
                            child: const Text(
                              '💾 В Загрузки',
                              style: TextStyle(
                                fontSize: 10,
                                color: MayakTheme.accentCyan,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // 2. ФОТО ИЛИ ВИДЕО: Реализация с блюром как в Telegram (пока не нажата кнопка Скачать или после очистки кэша — висит блюр с кнопкой Скачать!)
    if (m.isImageFile || m.isVideoFile) {
      final bool showBlurredState = !m.isMediaRevealed || !hasFileOnDisk;

      Widget backgroundWidget;
      if (!showBlurredState && m.isImageFile && hasFileOnDisk) {
        backgroundWidget = Image.file(
          File(m.filePath!),
          width: 245,
          height: 185,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallbackMediaBox(m),
        );
      } else if (thumbBytes != null) {
        backgroundWidget = Image.memory(
          thumbBytes,
          width: 245,
          height: 185,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildFallbackMediaBox(m),
        );
      } else if (m.isImageFile && hasFileOnDisk) {
        backgroundWidget = Image.file(
          File(m.filePath!),
          width: 245,
          height: 185,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildFallbackMediaBox(m),
        );
      } else {
        backgroundWidget = _buildFallbackMediaBox(m);
      }

      return GestureDetector(
        onTap: () {
          if (showBlurredState) {
            engine.requestDownloadOrRevealMedia(m);
          } else if (m.isImageFile && hasFileOnDisk) {
            _openInAppImageViewer(m.filePath!, m.fileName ?? 'Фото');
          } else if (m.isVideoFile && hasFileOnDisk) {
            _openInAppVideoPlayer(
                m.filePath!, m.fileName ?? 'Видео', m.thumbB64);
          }
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          width: 245,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: Colors.black38,
            border: Border.all(color: Colors.white12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 245,
                height: 185,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    backgroundWidget,
                    if (showBlurredState)
                      ClipRect(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(
                              sigmaX: 16.0, sigmaY: 16.0),
                          child: Container(
                            color: Colors.black.withOpacity(0.38),
                            alignment: Alignment.center,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.68),
                                borderRadius: BorderRadius.circular(26),
                                border: Border.all(
                                    color: MayakTheme.accentCyan,
                                    width: 1.3),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (m.isDownloading)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: MayakTheme.accentCyan,
                                      ),
                                    )
                                  else
                                    Icon(
                                      hasFileOnDisk
                                          ? Icons.visibility_rounded
                                          : Icons.download_rounded,
                                      color: MayakTheme.accentCyan,
                                      size: 20,
                                    ),
                                  const SizedBox(width: 8),
                                  Text(
                                    m.isDownloading
                                        ? 'Загрузка ${(m.transferProgress * 100).toInt()}%'
                                        : (hasFileOnDisk
                                            ? (m.isVideoFile
                                                ? 'Показать видео'
                                                : 'Показать фото')
                                            : 'Скачать (${m.fileSizeFormatted})'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (m.isVideoFile)
                      Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: MayakTheme.accentCyan, width: 2),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            size: 38,
                            color: MayakTheme.accentCyan,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (hasFileOnDisk && !showBlurredState)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  color: Colors.black45,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        m.fileSizeFormatted,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white70),
                      ),
                      InkWell(
                        onTap: () async {
                          final msg =
                              await engine.saveReceivedFileToDownloads(
                            m.filePath!,
                            m.fileName ?? 'media_file',
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(msg)),
                          );
                        },
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.save_alt_rounded,
                                size: 14, color: MayakTheme.accentCyan),
                            SizedBox(width: 4),
                            Text(
                              'В Загрузки',
                              style: TextStyle(
                                fontSize: 11,
                                color: MayakTheme.accentCyan,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildFallbackMediaBox(ChatMessage m) {
    return Container(
      width: 245,
      height: 185,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        m.isVideoFile ? Icons.movie_creation_outlined : Icons.image_outlined,
        size: 54,
        color: Colors.white24,
      ),
    );
  }

  Widget _buildFileBubble(ChatMessage m) {
    final isMedia = m.isImageFile || m.isVideoFile || m.isAudioFile;
    final hasFileOnDisk =
        m.filePath != null && File(m.filePath!).existsSync();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isMedia) _buildInlineMediaPreview(m),
        if (!isMedia)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasFileOnDisk
                          ? Icons.insert_drive_file_rounded
                          : Icons.cloud_download_rounded,
                      color: MayakTheme.accentCyan,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.fileName ?? 'Файл',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            m.isDownloading
                                ? 'Скачивание ${(m.transferProgress * 100).toInt()}% (${m.fileSizeFormatted})'
                                : (hasFileOnDisk
                                    ? 'Скачан в кэш (${m.fileSizeFormatted})'
                                    : 'Доступен для скачивания (${m.fileSizeFormatted})'),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (m.isDownloading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: m.transferProgress,
                    backgroundColor: Colors.white12,
                    color: MayakTheme.accentCyan,
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (!hasFileOnDisk && !m.isDownloading)
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          backgroundColor: MayakTheme.accentCyan,
                          foregroundColor: Colors.black,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('Скачать файл',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () =>
                            engine.requestDownloadOrRevealMedia(m),
                      ),
                    if (hasFileOnDisk) ...[
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.open_in_new, size: 15),
                        label: const Text('Открыть',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () =>
                            engine.openFileExternal(m.filePath!),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.download, size: 15),
                        label: const Text('В Загрузки',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () async {
                          final msg =
                              await engine.saveReceivedFileToDownloads(
                            m.filePath!,
                            m.fileName ?? 'mayak_file',
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(msg)),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final contact = engine.knownContacts[widget.peerId];
    final title =
        widget.isBroadcast ? widget.initialTitle : (contact?.displayTitle ?? widget.initialTitle);
    final isOnline =
        widget.isBroadcast ? engine.connectedPeersCount > 0 : (contact?.isOnline ?? false);
    final allMessages = engine.getMessagesFor(widget.peerId);
    final messages = _searchQuery.isEmpty
        ? allMessages
        : allMessages
            .where((m) =>
                m.text.toLowerCase().contains(_searchQuery) ||
                (m.fileName ?? '').toLowerCase().contains(_searchQuery))
            .toList();
    final selfBanned = engine.isSelfBanned;

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF111827), Color(0xFF1E1B4B)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: widget.isBroadcast
                    ? const LinearGradient(
                        colors: [Color(0xFFD97706), Color(0xFFF59E0B)])
                    : MayakTheme.primaryGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: widget.isBroadcast
                  ? const Icon(Icons.campaign_rounded,
                      color: Colors.black, size: 22)
                  : Text(
                      title.characters.first.toUpperCase(),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
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
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    widget.isBroadcast
                        ? 'Подключено узлов рядом: ${engine.connectedPeersCount}'
                        : (isOnline
                            ? 'В сети (${contact?.lastAddress ?? "прямой канал"}) • E2EE'
                            : 'Оффлайн (доставка через буфер при появлении в сети)'),
                    style: TextStyle(
                      fontSize: 11,
                      color: isOnline
                          ? MayakTheme.accentEmerald
                          : Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Поиск по сообщениям',
            icon: Icon(
              _isSearching ? Icons.search_off_rounded : Icons.search_rounded,
              color: Colors.white70,
            ),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchCtrl.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
          if (!widget.isBroadcast)
            IconButton(
              tooltip: 'Голосовой чат (ГЧ)',
              icon: const Icon(Icons.call_rounded, color: MayakTheme.accentEmerald),
              onPressed: () async {
                await engine.startLiveCall(widget.peerId, 'voice');
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CallSessionScreen(engine: engine),
                  ),
                );
              },
            ),
          if (!widget.isBroadcast)
            IconButton(
              tooltip: 'Видеочат (ВЧ)',
              icon: const Icon(Icons.videocam_rounded, color: MayakTheme.accentCyan),
              onPressed: () async {
                await engine.startLiveCall(widget.peerId, 'video');
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CallSessionScreen(engine: engine),
                  ),
                );
              },
            ),
          if (!widget.isBroadcast)
            IconButton(
              tooltip: 'Проверить код безопасности E2EE',
              icon: const Icon(Icons.verified_user_outlined,
                  color: MayakTheme.accentCyan),
              onPressed: _showSafetyNumberDialog,
            ),
          PopupMenuButton<String>(
            onSelected: (val) async {
              if (val == 'clear') {
                await engine.clearChatHistoryOnly(widget.peerId);
              } else if (val == 'delete' && !widget.isBroadcast) {
                await engine.deleteContact(widget.peerId);
                if (mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.cleaning_services_outlined,
                        size: 18, color: Colors.amber),
                    SizedBox(width: 8),
                    Text('Очистить историю сообщений'),
                  ],
                ),
              ),
              if (!widget.isBroadcast)
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_forever,
                          size: 18, color: Colors.redAccent),
                      SizedBox(width: 8),
                      Text(
                        'Удалить контакт и чат',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isSearching)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              color: MayakTheme.bgSurface,
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                onChanged: (v) =>
                    setState(() => _searchQuery = v.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: 'Поиск по сообщениям и файлам...',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  isDense: true,
                  filled: true,
                  fillColor: MayakTheme.bgDeep,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        widget.isBroadcast
                            ? 'Напишите сообщение в Общий эфир — его получат все устройства поблизости.'
                            : 'Сквозное шифрование (X25519 + ChaCha20-Poly1305) активно.\nМожно отправлять текст, фото, видео, голосовые и файлы до 1 ГБ!\nНажмите на сообщение для реакций, редактирования, пересылки или удаления.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    itemCount: messages.length,
                    itemBuilder: (_, i) {
                      final m = messages[i];
                      final hasReaction = m.reactions.isNotEmpty;
                      return Align(
                        alignment: m.isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: GestureDetector(
                          onTap: () => _showMessageActionsSheet(m),
                          onLongPress: () => _showMessageActionsSheet(m),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.80,
                            ),
                            decoration: BoxDecoration(
                              gradient:
                                  m.isMe ? MayakTheme.myBubbleGradient : null,
                              color: m.isMe ? null : MayakTheme.bgSurface,
                              borderRadius: BorderRadius.only(
                                topLeft: const Radius.circular(18),
                                topRight: const Radius.circular(18),
                                bottomLeft:
                                    Radius.circular(m.isMe ? 18 : 4),
                                bottomRight:
                                    Radius.circular(m.isMe ? 4 : 18),
                              ),
                              border: Border.all(
                                color: m.isMe
                                    ? MayakTheme.accentCyan.withOpacity(0.25)
                                    : Colors.white10,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: m.isMe
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (!m.isMe && widget.isBroadcast)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      m.senderName,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: MayakTheme.accentAmber,
                                      ),
                                    ),
                                  ),
                                if (m.forwardedFrom != null &&
                                    m.forwardedFrom!.isNotEmpty)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 5),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(8),
                                      border: const Border(
                                        left: BorderSide(
                                          color: MayakTheme.accentCyan,
                                          width: 2.5,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      '↪ Переслано от: ${m.forwardedFrom}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontStyle: FontStyle.italic,
                                        color: MayakTheme.accentCyan,
                                      ),
                                    ),
                                  ),
                                if (m.fileName != null &&
                                    m.fileName!.isNotEmpty)
                                  _buildFileBubble(m)
                                else
                                  Text(
                                    m.text,
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      m.isEdited
                                          ? '${m.timeFormatted} (изм.)'
                                          : m.timeFormatted,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white60,
                                      ),
                                    ),
                                    if (m.isMe) ...[
                                      const SizedBox(width: 4),
                                      Icon(
                                        m.isDelivered
                                            ? Icons.done_all
                                            : Icons.schedule,
                                        size: 14,
                                        color: m.isDelivered
                                            ? MayakTheme.accentCyan
                                            : Colors.amberAccent,
                                      ),
                                    ],
                                  ],
                                ),
                                if (hasReaction) ...[
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 4,
                                    children: m.reactions.values
                                        .toSet()
                                        .map((emoji) {
                                      final count = m.reactions.values
                                          .where((v) => v == emoji)
                                          .length;
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.black38,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          count > 1
                                              ? '$emoji $count'
                                              : emoji,
                                          style: const TextStyle(
                                              fontSize: 12),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: selfBanned
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    color: const Color(0xFF450A0A),
                    child: const Text(
                      '🚫 Ваш узел заблокирован администратором сети. Отправка сообщений в чаты недоступна.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    decoration: const BoxDecoration(
                      color: MayakTheme.bgSurface,
                      border: Border(
                        top: BorderSide(color: Colors.white10),
                      ),
                    ),
                    child: Row(
                      children: [
                        if (!widget.isBroadcast) ...[
                          PopupMenuButton<String>(
                            tooltip: 'Прикрепить медиа или файл',
                            icon: const Icon(Icons.attach_file,
                                color: MayakTheme.accentCyan),
                            onSelected: (mode) =>
                                _pickAndSendFile(mode: mode),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'media',
                                child: Row(
                                  children: [
                                    Icon(Icons.perm_media,
                                        color: MayakTheme.accentCyan,
                                        size: 18),
                                    SizedBox(width: 8),
                                    Text('Фото или Видео'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'audio',
                                child: Row(
                                  children: [
                                    Icon(Icons.audiotrack,
                                        color: Colors.amber, size: 18),
                                    SizedBox(width: 8),
                                    Text('Аудио / Музыка'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'all',
                                child: Row(
                                  children: [
                                    Icon(Icons.folder_open,
                                        color: Colors.lightBlueAccent,
                                        size: 18),
                                    SizedBox(width: 8),
                                    Text('Любой файл / Документ'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            tooltip: engine.isRecordingVoice
                                ? 'Нажмите, чтобы остановить и отправить голосовое'
                                : 'Записать голосовое сообщение',
                            onPressed: _toggleVoiceRecording,
                            icon: Icon(
                              engine.isRecordingVoice
                                  ? Icons.stop_circle
                                  : Icons.mic,
                              color: engine.isRecordingVoice
                                  ? Colors.redAccent
                                  : Colors.amberAccent,
                            ),
                          ),
                        ],
                        Expanded(
                          child: TextField(
                            controller: _msgCtrl,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: engine.isRecordingVoice
                                  ? '🔴 Идет запись голоса... Нажмите Стоп'
                                  : (widget.isBroadcast
                                      ? 'Сообщение в общий эфир...'
                                      : 'Зашифрованное сообщение...'),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 11),
                              filled: true,
                              fillColor: MayakTheme.bgDeep,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(22),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: MayakTheme.accentCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _send,
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class InAppImageViewerScreen extends StatelessWidget {
  final MeshEngine engine;
  final String imagePath;
  final String title;

  const InAppImageViewerScreen({
    super.key,
    required this.engine,
    required this.imagePath,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = imagePath.split(RegExp(r'[\\/]')).last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: Text(title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: 'Сохранить в Загрузки',
            icon: const Icon(Icons.download, color: MayakTheme.accentCyan),
            onPressed: () async {
              final res = await engine.saveReceivedFileToDownloads(
                  imagePath, fileName);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(res)),
              );
            },
          ),
          IconButton(
            tooltip: 'Открыть во внешнем приложении',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => engine.openFileExternal(imagePath),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => InteractiveViewer(
          minScale: 0.5,
          maxScale: 6.0,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Image.file(
              File(imagePath),
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}

/// ИСПРАВЛЕНИЕ ПУНКТА 1: Встроенный видеоплеер для Windows ПК и Android (рабочий рендер кадров через скрытое окно WPF MediaElement + локальный TCP-сокет без блокировки stdin!)
class InAppVideoPlayerScreen extends StatefulWidget {
  final MeshEngine engine;
  final String videoPath;
  final String title;
  final String? thumbB64;

  const InAppVideoPlayerScreen({
    super.key,
    required this.engine,
    required this.videoPath,
    required this.title,
    this.thumbB64,
  });

  @override
  State<InAppVideoPlayerScreen> createState() =>
      _InAppVideoPlayerScreenState();
}

class _InAppVideoPlayerScreenState extends State<InAppVideoPlayerScreen> {
  int? _textureId;
  int _videoWidth = 640;
  int _videoHeight = 360;
  int _positionMs = 0;
  int _durationMs = 1;
  bool _isPlaying = true;
  bool _isCompleted = false;
  bool _loading = true;
  Timer? _pollTimer;

  // Переменные для встроенного рендера видео на Windows ПК (через локальный неблокирующий TCP-канал к WPF MediaElement)
  ServerSocket? _winCmdServer;
  Socket? _winClientSocket;
  Process? _winVideoProc;
  Uint8List? _currentWinFrameBytes;
  Uint8List? _fallbackThumbBytes;

  @override
  void initState() {
    super.initState();
    if (widget.thumbB64 != null && widget.thumbB64!.isNotEmpty) {
      try {
        _fallbackThumbBytes = base64Decode(widget.thumbB64!);
      } catch (_) {}
    }
    _initVideo();
  }

  Future<void> _initVideo() async {
    if (Platform.isAndroid) {
      final info = await widget.engine.nativeChannel
          .invokeMapMethod<String, dynamic>(
        'initInAppVideo',
        {'path': widget.videoPath},
      );
      if (!mounted) return;
      if (info != null) {
        setState(() {
          _textureId = (info['textureId'] as num?)?.toInt();
          _videoWidth = max((info['width'] as num?)?.toInt() ?? 640, 1);
          _videoHeight = max((info['height'] as num?)?.toInt() ?? 360, 1);
          _durationMs = max((info['durationMs'] as num?)?.toInt() ?? 1, 1);
          _isPlaying = true;
          _isCompleted = false;
          _loading = false;
        });
        _pollTimer =
            Timer.periodic(const Duration(milliseconds: 250), (_) async {
          final st = await widget.engine.nativeChannel
              .invokeMapMethod<String, dynamic>(
            'controlInAppVideo',
            {'action': 'status', 'positionMs': 0},
          );
          if (!mounted || st == null) return;
          setState(() {
            _isPlaying = (st['isPlaying'] as bool?) ?? false;
            _isCompleted = (st['isCompleted'] as bool?) ?? false;
            _positionMs = (st['positionMs'] as num?)?.toInt() ?? _positionMs;
            _durationMs = max(
                (st['durationMs'] as num?)?.toInt() ?? _durationMs, 1);
          });
        });
      } else {
        setState(() => _loading = false);
      }
    } else if (Platform.isWindows) {
      await _startWindowsInAppVideoStreamer();
    }
  }

  Future<void> _startWindowsInAppVideoStreamer() async {
    try {
      _winCmdServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final localPort = _winCmdServer!.port;

      _winCmdServer!.listen((client) {
        _winClientSocket = client;
        utf8.decoder
            .bind(client)
            .transform(const LineSplitter())
            .listen((line) {
          if (!mounted) return;
          if (line.startsWith('META|')) {
            final p = line.split('|');
            if (p.length >= 4) {
              setState(() {
                _videoWidth = max(int.tryParse(p[1]) ?? 640, 160);
                _videoHeight = max(int.tryParse(p[2]) ?? 360, 90);
                _durationMs = max(int.tryParse(p[3]) ?? 1, 1);
                _loading = false;
              });
            }
          } else if (line.startsWith('FRAME|')) {
            final p = line.split('|');
            if (p.length >= 6) {
              final pos = int.tryParse(p[1]) ?? _positionMs;
              final dur = max(int.tryParse(p[2]) ?? _durationMs, 1);
              final playing = p[3] == '1';
              final completed = p[4] == '1';
              final b64 = p[5];
              Uint8List? decoded;
              if (b64.isNotEmpty) {
                try {
                  decoded = base64Decode(b64);
                } catch (_) {}
              }
              setState(() {
                _positionMs = pos.clamp(0, dur);
                _durationMs = dur;
                _isPlaying = playing;
                _isCompleted = completed;
                if (decoded != null && decoded.isNotEmpty) {
                  _currentWinFrameBytes = decoded;
                }
                _loading = false;
              });
            }
          }
        });
      });

      const psScript = r'''
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$vPath = $env:MAYAK_VIDEO_PATH
$port = [int]$env:MAYAK_PLAYER_PORT

$tcp = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $port)
$stream = $tcp.GetStream()
$writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::UTF8)
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

$me = New-Object System.Windows.Controls.MediaElement
$me.LoadedBehavior = [System.Windows.Controls.MediaState]::Manual
$me.UnloadedBehavior = [System.Windows.Controls.MediaState]::Manual
$me.ScrubbingEnabled = $true
$me.Stretch = [System.Windows.Media.Stretch]::Fill
$me.Volume = 1.0
$me.Width = 560
$me.Height = 315

$win = New-Object System.Windows.Window
$win.Width = 560
$win.Height = 315
$win.Left = -10000
$win.Top = -10000
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.ShowInTaskbar = $false
$win.AllowsTransparency = $true
$win.Opacity = 0.01
$win.Content = $me
$win.Show()

$me.Source = [Uri]::new($vPath)
$me.Play()

$t0 = [DateTime]::Now
while (-not $me.NaturalDuration.HasTimeSpan -and (([DateTime]::Now - $t0).TotalMilliseconds -lt 4000)) {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
  Start-Sleep -Milliseconds 30
}

$vw = $me.NaturalVideoWidth
$vh = $me.NaturalVideoHeight
if ($vw -le 0) { $vw = 640; $vh = 360 }
$scale = [Math]::Min(1.0, 560.0 / $vw)
$w = [Math]::Max(160, [int]($vw * $scale))
$h = [Math]::Max(90, [int]($vh * $scale))
$me.Width = $w
$me.Height = $h
$win.Width = $w
$win.Height = $h

$durMs = 1
if ($me.NaturalDuration.HasTimeSpan) {
  $durMs = [Math]::Max(1, [int]$me.NaturalDuration.TimeSpan.TotalMilliseconds)
}
$writer.WriteLine("META|$w|$h|$durMs")

$isPlaying = $true
$isCompleted = $false
$forceRenderFrame = $true

while ($tcp.Connected) {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

  while ($stream.DataAvailable) {
    $cmdLine = $reader.ReadLine()
    if ($null -eq $cmdLine) { break }
    $cmd = $cmdLine.Trim()
    if ($cmd -eq "QUIT") { break }
    elseif ($cmd -eq "PAUSE") {
      $me.Pause()
      $isPlaying = $false
      $forceRenderFrame = $true
    }
    elseif ($cmd -eq "PLAY") {
      if ($isCompleted) {
        $me.Position = [TimeSpan]::Zero
        $isCompleted = $false
      }
      $me.Play()
      $isPlaying = $true
      $forceRenderFrame = $true
    }
    elseif ($cmd.StartsWith("SEEK|")) {
      $ms = [int]($cmd.Split("|")[1])
      $me.Position = [TimeSpan]::FromMilliseconds($ms)
      $isCompleted = $false
      for ($k = 0; $k -lt 4; $k++) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 15
      }
      $forceRenderFrame = $true
    }
  }

  if ($me.NaturalDuration.HasTimeSpan) {
    $durMs = [Math]::Max(1, [int]$me.NaturalDuration.TimeSpan.TotalMilliseconds)
  }
  $posMs = [int]$me.Position.TotalMilliseconds
  if ($durMs -gt 200 -and $posMs -ge ($durMs - 80)) {
    if ($isPlaying) {
      $me.Pause()
      $isPlaying = $false
      $isCompleted = $true
      $forceRenderFrame = $true
    }
  }

  if ($isPlaying -or $forceRenderFrame) {
    $forceRenderFrame = $false
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($me)
    $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
    $enc.QualityLevel = 72
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $msStream = New-Object System.IO.MemoryStream
    $enc.Save($msStream)
    $b64 = [Convert]::ToBase64String($msStream.ToArray())
    $msStream.Dispose()
    $pFlag = if ($isPlaying) { "1" } else { "0" }
    $cFlag = if ($isCompleted) { "1" } else { "0" }
    try {
      $writer.WriteLine("FRAME|$posMs|$durMs|$pFlag|$cFlag|$b64")
    } catch { break }
  }

  Start-Sleep -Milliseconds 50
}

$me.Close()
$win.Close()
$tcp.Close()
''';

      _winVideoProc = await Process.start(
        'powershell',
        ['-NoProfile', '-STA', '-Command', psScript],
        environment: {
          'MAYAK_VIDEO_PATH': widget.videoPath.replaceAll('/', '\\'),
          'MAYAK_PLAYER_PORT': '$localPort',
        },
      );
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _sendWinCmd(String cmd) {
    try {
      _winClientSocket?.writeln(cmd);
    } catch (_) {}
  }

  Future<void> _togglePlayPause() async {
    if (Platform.isAndroid) {
      final act = (_isCompleted || !_isPlaying) ? 'play' : 'pause';
      final st = await widget.engine.nativeChannel
          .invokeMapMethod<String, dynamic>(
        'controlInAppVideo',
        {'action': act, 'positionMs': 0},
      );
      if (st != null && mounted) {
        setState(() {
          _isPlaying = (st['isPlaying'] as bool?) ?? false;
          _isCompleted = (st['isCompleted'] as bool?) ?? false;
        });
      }
    } else if (Platform.isWindows) {
      if (_isCompleted || !_isPlaying) {
        _sendWinCmd('PLAY');
        setState(() {
          _isPlaying = true;
          _isCompleted = false;
        });
      } else {
        _sendWinCmd('PAUSE');
        setState(() => _isPlaying = false);
      }
    }
  }

  Future<void> _seekTo(int targetMs) async {
    final clamped = targetMs.clamp(0, _durationMs);
    setState(() {
      _positionMs = clamped;
      _isCompleted = false;
    });
    if (Platform.isAndroid) {
      await widget.engine.nativeChannel.invokeMapMethod<String, dynamic>(
        'controlInAppVideo',
        {'action': 'seek', 'positionMs': clamped},
      );
    } else if (Platform.isWindows) {
      _sendWinCmd('SEEK|$clamped');
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    if (Platform.isAndroid) {
      widget.engine.nativeChannel.invokeMethod('disposeInAppVideo');
    } else if (Platform.isWindows) {
      _sendWinCmd('QUIT');
      try {
        _winClientSocket?.destroy();
      } catch (_) {}
      try {
        _winCmdServer?.close();
      } catch (_) {}
      _winVideoProc?.kill();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.videoPath.split(RegExp(r'[\\/]')).last;
    final progress = (_positionMs / max(_durationMs, 1)).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: 'Сохранить видео в Загрузки',
            icon: const Icon(Icons.download, color: MayakTheme.accentCyan),
            onPressed: () async {
              final res = await widget.engine.saveReceivedFileToDownloads(
                  widget.videoPath, fileName);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(res)),
              );
            },
          ),
          IconButton(
            tooltip: 'Открыть в системном плеере',
            icon: const Icon(Icons.open_in_new),
            onPressed: () =>
                widget.engine.openFileExternal(widget.videoPath),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator(
                      color: MayakTheme.accentCyan)
                  : GestureDetector(
                      onTap: _togglePlayPause,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (Platform.isAndroid && _textureId != null)
                            AspectRatio(
                              aspectRatio: _videoWidth / _videoHeight,
                              child: Texture(textureId: _textureId!),
                            )
                          else if (Platform.isWindows &&
                              _currentWinFrameBytes != null)
                            AspectRatio(
                              aspectRatio: _videoWidth / _videoHeight,
                              child: Image.memory(
                                _currentWinFrameBytes!,
                                gaplessPlayback: true,
                                fit: BoxFit.contain,
                              ),
                            )
                          else if (_fallbackThumbBytes != null)
                            Image.memory(
                              _fallbackThumbBytes!,
                              fit: BoxFit.contain,
                            ),
                          // После завершения видео показываем кадр-превью и кнопку Повторить
                          if (_isCompleted && _fallbackThumbBytes != null)
                            Positioned.fill(
                              child: Image.memory(
                                _fallbackThumbBytes!,
                                fit: BoxFit.contain,
                              ),
                            ),
                          if (!_isPlaying || _isCompleted)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.70),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                    color: MayakTheme.accentCyan, width: 2),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _isCompleted
                                        ? Icons.replay_rounded
                                        : Icons.play_arrow_rounded,
                                    color: MayakTheme.accentCyan,
                                    size: 32,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _isCompleted
                                        ? 'Повторить просмотр'
                                        : 'Продолжить',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            color: MayakTheme.bgSurface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: progress,
                  activeColor: MayakTheme.accentCyan,
                  inactiveColor: Colors.white24,
                  onChanged: (v) {
                    _seekTo((v * _durationMs).round());
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      MeshEngine.formatDurationMs(_positionMs),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70),
                    ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: '-10 сек',
                          icon: const Icon(Icons.replay_10),
                          onPressed: () => _seekTo(_positionMs - 10000),
                        ),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: MayakTheme.accentCyan,
                            foregroundColor: Colors.black,
                          ),
                          icon: Icon(
                            _isCompleted
                                ? Icons.replay
                                : (_isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow),
                          ),
                          onPressed: _togglePlayPause,
                        ),
                        IconButton(
                          tooltip: '+10 сек',
                          icon: const Icon(Icons.forward_10),
                          onPressed: () => _seekTo(_positionMs + 10000),
                        ),
                      ],
                    ),
                    Text(
                      MeshEngine.formatDurationMs(_durationMs),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70),
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

extension MeshEngineListenerExt on MeshEngine {
  static final Set<void Function()> _extraListeners = {};

  void addListenerState(void Function() cb) {
    _extraListeners.add(cb);
  }

  void removeListenerState(void Function() cb) {
    _extraListeners.remove(cb);
  }

  static void addStaticListener(VoidCallback cb) => _extraListeners.add(cb);
  static void removeStaticListener(VoidCallback cb) => _extraListeners.remove(cb);

  static void notifyExtra() {
    for (final cb in _extraListeners.toList()) {
      cb();
    }
  }
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool _alreadyPopped = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Наведите камеру на QR узла')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_alreadyPopped) return;
          for (final barcode in capture.barcodes) {
            final raw = barcode.rawValue;
            if (raw != null && raw.isNotEmpty) {
              _alreadyPopped = true;
              Navigator.of(context).pop(raw);
              break;
            }
          }
        },
      ),
    );
  }
}


class GroupConversationScreen extends StatefulWidget {
  final MeshEngine engine;
  final GroupChat group;

  const GroupConversationScreen({
    super.key,
    required this.engine,
    required this.group,
  });

  @override
  State<GroupConversationScreen> createState() =>
      _GroupConversationScreenState();
}

class _GroupConversationScreenState extends State<GroupConversationScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  ChatMessage? _replyingTo;
  ChatMessage? _editingMsg;

  MeshEngine get engine => widget.engine;
  GroupChat? get _group => engine.groupChats[widget.group.groupId];

  void _onUpdate() {
    if (!mounted) return;
    if (_group == null) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    engine.addListenerState(_onUpdate);
    engine.markGroupRead(widget.group.groupId);
  }

  @override
  void dispose() {
    engine.removeListenerState(_onUpdate);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _fmtTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _sendOrSave() async {
    final txt = _ctrl.text.trim();
    if (txt.isEmpty) return;
    _ctrl.clear();
    if (_editingMsg != null) {
      final mid = _editingMsg!.msgId;
      setState(() => _editingMsg = null);
      await engine.editGroupMessage(widget.group.groupId, mid, txt);
    } else {
      final rId = _replyingTo?.msgId;
      final rTxt = _replyingTo != null
          ? '${_replyingTo!.senderName}: ${_replyingTo!.text}'
          : null;
      setState(() => _replyingTo = null);
      await engine.sendGroupMessage(
        widget.group.groupId,
        txt,
        replyToId: rId,
        replyToPreview: rTxt,
      );
    }
  }

  void _showForwardDialog(ChatMessage m) {
    final contacts = engine.knownContacts.values.toList();
    final groups = engine.groupChats.values
        .where((g) => g.groupId != widget.group.groupId)
        .toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(14),
          children: [
            const Text('Переслать сообщение',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            for (final c in contacts)
              ListTile(
                leading: const Icon(Icons.person_rounded,
                    color: MayakTheme.accentCyan),
                title: Text(c.displayTitle),
                onTap: () async {
                  Navigator.pop(ctx);
                  await engine.sendMessage(
                    c.nodeId,
                    m.text,
                    forwardedFrom: m.senderName,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('Переслано пользователю ${c.displayTitle}')),
                    );
                  }
                },
              ),
            for (final g in groups)
              ListTile(
                leading: const Icon(Icons.groups_rounded,
                    color: MayakTheme.accentEmerald),
                title: Text('Группа: ${g.title}'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await engine.sendGroupMessage(
                    g.groupId,
                    m.text,
                    forwardedFrom: m.senderName,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Переслано в «${g.title}»')),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showMessageMenu(ChatMessage m) {
    final grp = _group ?? widget.group;
    final canDeleteForAll = m.isMe || grp.creatorId == engine.nodeId;
    const quickEmojis = ['👍', '❤️', '🔥', '😂', '😮', '👌'];

    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final em in quickEmojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        Navigator.pop(ctx);
                        engine.toggleGroupReaction(
                            widget.group.groupId, m.msgId, em);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(em, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.reply_rounded,
                  color: MayakTheme.accentCyan),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _editingMsg = null;
                  _replyingTo = m;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: Colors.white70),
              title: const Text('Копировать текст'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: m.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Скопировано')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward_rounded,
                  color: MayakTheme.accentEmerald),
              title: const Text('Переслать'),
              onTap: () {
                Navigator.pop(ctx);
                _showForwardDialog(m);
              },
            ),
            if (m.isMe)
              ListTile(
                leading: const Icon(Icons.edit_rounded,
                    color: MayakTheme.accentAmber),
                title: const Text('Редактировать'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _replyingTo = null;
                    _editingMsg = m;
                    _ctrl.text = m.text;
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: MayakTheme.accentRed),
              title: Text(canDeleteForAll
                  ? 'Удалить для всех'
                  : 'Удалить у себя'),
              onTap: () {
                Navigator.pop(ctx);
                engine.deleteGroupMessage(
                  widget.group.groupId,
                  m.msgId,
                  forEveryone: canDeleteForAll,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showGroupInfoSheet() {
    final grp = _group ?? widget.group;
    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.groups_rounded,
                      color: MayakTheme.accentCyan, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(grp.title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_rounded,
                        color: MayakTheme.accentAmber),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showRenameDialog(grp);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Участники (${grp.memberIds.length}) — Multi-Hop Mesh:',
                  style: const TextStyle(
                      fontSize: 12, color: MayakTheme.accentCyan)),
              const SizedBox(height: 6),
              for (final pid in grp.memberIds)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.circle,
                    size: 10,
                    color: (pid == engine.nodeId || engine.isNodeOnline(pid))
                        ? MayakTheme.accentEmerald
                        : Colors.white38,
                  ),
                  title: Text(pid == engine.nodeId
                      ? '${engine.nickname} (Вы)'
                      : (engine.knownContacts[pid]?.displayTitle ?? 'Узел $pid')),
                  trailing: pid == grp.creatorId
                      ? const Text('Создатель',
                          style: TextStyle(
                              fontSize: 11, color: MayakTheme.accentAmber))
                      : null,
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showAddMemberDialog(grp);
                    },
                    icon: const Icon(Icons.person_add_rounded, size: 18),
                    label: const Text('Добавить'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await engine.clearGroupHistory(grp.groupId);
                    },
                    icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                    label: const Text('Очистить чат'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: MayakTheme.accentRed),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await engine.leaveOrDeleteGroupChat(grp.groupId);
                      if (mounted && Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    },
                    icon: const Icon(Icons.exit_to_app_rounded, size: 18),
                    label: const Text('Покинуть'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRenameDialog(GroupChat grp) {
    final tCtrl = TextEditingController(text: grp.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Text('Переименовать группу'),
        content: TextField(controller: tCtrl),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await engine.renameGroupChat(grp.groupId, tCtrl.text);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showAddMemberDialog(GroupChat grp) {
    final candidates = engine.knownContacts.values
        .where((c) => !grp.memberIds.contains(c.nodeId))
        .toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MayakTheme.bgSurface,
        title: const Text('Добавить участника'),
        content: candidates.isEmpty
            ? const Text('Все известные узлы уже в группе')
            : SizedBox(
                width: 300,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in candidates)
                      ListTile(
                        title: Text(c.displayTitle),
                        subtitle: Text(c.nodeId,
                            style: const TextStyle(fontSize: 11)),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await engine.addMemberToGroupChat(
                              grp.groupId, c.nodeId);
                        },
                      ),
                  ],
                ),
              ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grp = _group ?? widget.group;
    final msgs = engine.getGroupMessages(grp.groupId);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _showGroupInfoSheet,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(grp.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              Text('Участников: ${grp.memberIds.length} • Multi-Hop E2EE Mesh',
                  style: const TextStyle(
                      fontSize: 11, color: MayakTheme.accentCyan)),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: 'Управление группой',
            onPressed: _showGroupInfoSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: msgs.isEmpty
                ? const Center(
                    child: Text(
                      'Напишите первое сообщение в групповую комнату',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length,
                    itemBuilder: (_, idx) {
                      final m = msgs[idx];
                      return Align(
                        alignment: m.isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: GestureDetector(
                          onLongPress: () => _showMessageMenu(m),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            constraints: const BoxConstraints(maxWidth: 310),
                            decoration: BoxDecoration(
                              color: m.isMe
                                  ? const Color(0xFF1E3A8A)
                                  : MayakTheme.bgSurface,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!m.isMe)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text(
                                      m.senderName,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: MayakTheme.accentCyan,
                                      ),
                                    ),
                                  ),
                                if (m.forwardedFrom != null &&
                                    m.forwardedFrom!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      'Переслано от ${m.forwardedFrom}',
                                      style: const TextStyle(
                                          fontSize: 10,
                                          fontStyle: FontStyle.italic,
                                          color: Colors.white70),
                                    ),
                                  ),
                                if (m.replyToText != null &&
                                    m.replyToText!.isNotEmpty)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(8),
                                      border: const Border(
                                        left: BorderSide(
                                            color: MayakTheme.accentCyan,
                                            width: 2.5),
                                      ),
                                    ),
                                    child: Text(
                                      m.replyToText!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.white70),
                                    ),
                                  ),
                                Text(m.text,
                                    style:
                                        const TextStyle(color: Colors.white)),
                                const SizedBox(height: 3),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (m.isEdited)
                                      const Text('ред. • ',
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white54)),
                                    Text(
                                      _fmtTime(m.timestamp),
                                      style: const TextStyle(
                                          fontSize: 10, color: Colors.white54),
                                    ),
                                  ],
                                ),
                                if (m.reactions.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Wrap(
                                      spacing: 4,
                                      children: [
                                        for (final em
                                            in m.reactions.values.toSet())
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.black38,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              '$em ${m.reactions.values.where((v) => v == em).length}',
                                              style:
                                                  const TextStyle(fontSize: 11),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_replyingTo != null || _editingMsg != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: MayakTheme.bgElevated,
              child: Row(
                children: [
                  Icon(
                    _editingMsg != null
                        ? Icons.edit_rounded
                        : Icons.reply_rounded,
                    size: 16,
                    color: MayakTheme.accentCyan,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _editingMsg != null
                          ? 'Редактирование: ${_editingMsg!.text}'
                          : 'Ответ ${_replyingTo!.senderName}: ${_replyingTo!.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() {
                      _replyingTo = null;
                      _editingMsg = null;
                      _ctrl.clear();
                    }),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            color: MayakTheme.bgSurface,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: InputDecoration(
                      hintText: _editingMsg != null
                          ? 'Изменить сообщение...'
                          : 'Сообщение в группу...',
                      filled: true,
                      fillColor: MayakTheme.bgDeep,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _sendOrSave(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: MayakTheme.accentCyan,
                    foregroundColor: Colors.black,
                  ),
                  icon: Icon(_editingMsg != null
                      ? Icons.check_rounded
                      : Icons.send_rounded),
                  onPressed: _sendOrSave,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class IncomingCallScreen extends StatefulWidget {
  static bool isShowing = false;
  final MeshEngine engine;
  const IncomingCallScreen({super.key, required this.engine});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  MeshEngine get engine => widget.engine;
  bool _hasClosed = false;
  late final AnimationController _pulseCtrl;

  void _onUpdate() {
    if (!mounted || _hasClosed) return;
    if (engine.incomingCallFromPeerId == null &&
        engine.activeCallPeerId == null) {
      _hasClosed = true;
      engine.removeListenerState(_onUpdate);
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    engine.addListenerState(_onUpdate);
  }

  @override
  void dispose() {
    engine.removeListenerState(_onUpdate);
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerId = engine.incomingCallFromPeerId ?? '';
    final peerName = engine.knownContacts[peerId]?.displayTitle ?? peerId;
    final isVideo = engine.incomingCallMode == 'video';

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: MayakTheme.bgDeep,
        body: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0A1024), Color(0xFF0F2940), Color(0xFF070B14)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 36),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: MayakTheme.accentCyan.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                        color: MayakTheme.accentCyan.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                        color: MayakTheme.accentCyan,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isVideo
                            ? 'Входящий видеочат (ВЧ) • E2EE'
                            : 'Входящий голосовой чат (ГЧ) • E2EE',
                        style: const TextStyle(
                          color: MayakTheme.accentCyan,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                ScaleTransition(
                  scale: Tween<double>(begin: 0.94, end: 1.08).animate(
                    CurvedAnimation(
                        parent: _pulseCtrl, curve: Curves.easeInOut),
                  ),
                  child: Container(
                    width: 132,
                    height: 132,
                    decoration: BoxDecoration(
                      gradient: MayakTheme.primaryGradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: MayakTheme.accentCyan.withOpacity(0.35),
                          blurRadius: 34,
                          spreadRadius: 6,
                        ),
                      ],
                    ),
                    child: Icon(
                      isVideo
                          ? Icons.videocam_rounded
                          : Icons.phone_in_talk_rounded,
                      size: 62,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    peerName.isNotEmpty ? peerName : 'Узел Маяк',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Звонит по защищённому P2P-каналу...',
                  style: TextStyle(fontSize: 14, color: Colors.white70),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(36, 0, 36, 48),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.large(
                            heroTag: 'inc_reject',
                            backgroundColor: MayakTheme.accentRed,
                            onPressed: () async {
                              if (_hasClosed) return;
                              _hasClosed = true;
                              engine.removeListenerState(_onUpdate);
                              await engine.rejectIncomingCall();
                              if (mounted && Navigator.of(context).canPop()) {
                                Navigator.of(context).pop();
                              }
                            },
                            child: const Icon(Icons.call_end_rounded,
                                color: Colors.white, size: 34),
                          ),
                          const SizedBox(height: 10),
                          const Text('Сбросить',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.large(
                            heroTag: 'inc_accept',
                            backgroundColor: MayakTheme.accentEmerald,
                            onPressed: () async {
                              if (_hasClosed) return;
                              _hasClosed = true;
                              engine.removeListenerState(_onUpdate);
                              await engine.acceptIncomingCall();
                              if (!mounted) return;
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      CallSessionScreen(engine: engine),
                                ),
                              );
                            },
                            child: Icon(
                              isVideo
                                  ? Icons.videocam_rounded
                                  : Icons.call_rounded,
                              color: Colors.white,
                              size: 34,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text('Принять',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CallSessionScreen extends StatefulWidget {
  static bool isFullScreenOpen = false;
  final MeshEngine engine;
  const CallSessionScreen({super.key, required this.engine});

  @override
  State<CallSessionScreen> createState() => _CallSessionScreenState();
}

class _CallSessionScreenState extends State<CallSessionScreen> {
  MeshEngine get engine => widget.engine;
  Timer? _secTimer;
  int _seconds = 0;
  bool _hasPopped = false;

  void _safeClose() {
    if (_hasPopped) return;
    _hasPopped = true;
    CallSessionScreen.isFullScreenOpen = false;
    engine.removeListenerState(_onUpdate);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _minimizeToChat() {
    if (_hasPopped) return;
    _hasPopped = true;
    CallSessionScreen.isFullScreenOpen = false;
    engine.removeListenerState(_onUpdate);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    MeshEngineListenerExt.notifyExtra();
  }

  void _onUpdate() {
    if (!mounted || _hasPopped) return;
    if (engine.activeCallPeerId == null) {
      _safeClose();
      return;
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    CallSessionScreen.isFullScreenOpen = true;
    engine.addListenerState(_onUpdate);
    _secTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && engine.isCallAccepted) {
        setState(() => _seconds++);
      }
    });
  }

  @override
  void dispose() {
    CallSessionScreen.isFullScreenOpen = false;
    engine.removeListenerState(_onUpdate);
    _secTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerId = engine.activeCallPeerId ?? '';
    final peerName = engine.knownContacts[peerId]?.displayTitle ?? peerId;
    final isVideo = engine.activeCallMode == 'video';
    final mm = (_seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (_seconds % 60).toString().padLeft(2, '0');
    final hasRemoteVideo = isVideo &&
        !engine.remoteCallVideoMuted &&
        engine.remoteVideoFrameBytes != null;
    final hasLocalPreview = isVideo &&
        !engine.isCallVideoMuted &&
        engine.localVideoFrameBytes != null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _minimizeToChat();
      },
      child: Scaffold(
        backgroundColor: MayakTheme.bgDeep,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (hasRemoteVideo)
              Image.memory(
                engine.remoteVideoFrameBytes!,
                gaplessPlayback: true,
                fit: BoxFit.contain,
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 118,
                      height: 118,
                      decoration: BoxDecoration(
                        gradient: MayakTheme.primaryGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: MayakTheme.accentCyan.withOpacity(0.32),
                            blurRadius: 28,
                          ),
                        ],
                      ),
                      child: Icon(
                        isVideo
                            ? (engine.remoteCallVideoMuted
                                ? Icons.videocam_off_rounded
                                : Icons.videocam_rounded)
                            : Icons.graphic_eq_rounded,
                        size: 54,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      peerName.isNotEmpty ? peerName : 'Собеседник',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      engine.isCallAccepted
                          ? '${engine.callStatusText} • $mm:$ss'
                          : engine.callStatusText,
                      style: const TextStyle(
                        fontSize: 14,
                        color: MayakTheme.accentCyan,
                      ),
                    ),
                  ],
                ),
              ),
            // Своя фронтальная камера (PiP self-view в правом верхнем углу)
            if (hasLocalPreview)
              Positioned(
                top: 86,
                right: 14,
                child: SafeArea(
                  child: Container(
                    width: 108,
                    height: 148,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.65), width: 1.8),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 14,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Transform(
                        alignment: Alignment.center,
                        transform: (Platform.isAndroid &&
                                engine.isCallFrontCamera)
                            ? Matrix4.rotationY(pi)
                            : Matrix4.identity(),
                        child: Image.memory(
                          engine.localVideoFrameBytes!,
                          gaplessPlayback: true,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Верхняя плашка статуса + кнопка «В чат» (свернуть звонок)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Material(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: _minimizeToChat,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.keyboard_arrow_down_rounded,
                                    color: Colors.white, size: 20),
                                SizedBox(width: 4),
                                Text('В чат',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.lock_rounded,
                                  size: 14, color: MayakTheme.accentEmerald),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  engine.isCallAccepted
                                      ? '$peerName • $mm:$ss • ${engine.activeCallTransport}'
                                      : '$peerName • Гудки...',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (engine.remoteCallMicMuted) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: MayakTheme.accentRed.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(Icons.mic_off_rounded,
                              size: 14, color: Colors.white),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            // Нижняя панель управления звонком
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.85),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton(
                            heroTag: 'call_mute',
                            backgroundColor: engine.isCallMicMuted
                                ? MayakTheme.accentAmber
                                : MayakTheme.bgElevated,
                            onPressed: () => engine.toggleCallMicMute(),
                            child: Icon(
                              engine.isCallMicMuted
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            engine.isCallMicMuted ? 'Выкл' : 'Микро',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                      if (Platform.isAndroid)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FloatingActionButton(
                              heroTag: 'call_speaker',
                              backgroundColor: engine.isCallSpeakerOn
                                  ? MayakTheme.accentCyan
                                  : MayakTheme.bgElevated,
                              onPressed: () => engine.toggleCallSpeaker(),
                              child: Icon(
                                engine.isCallSpeakerOn
                                    ? Icons.volume_up_rounded
                                    : Icons.hearing_rounded,
                                color: engine.isCallSpeakerOn
                                    ? Colors.black
                                    : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              engine.isCallSpeakerOn ? 'Громкая' : 'Ухо',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      if (isVideo)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FloatingActionButton(
                              heroTag: 'call_vid',
                              backgroundColor: engine.isCallVideoMuted
                                  ? MayakTheme.accentAmber
                                  : MayakTheme.bgElevated,
                              onPressed: () => engine.toggleCallVideoMute(),
                              child: Icon(
                                engine.isCallVideoMuted
                                    ? Icons.videocam_off_rounded
                                    : Icons.videocam_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              engine.isCallVideoMuted ? 'Выкл' : 'Камера',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      if (isVideo)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FloatingActionButton(
                              heroTag: 'call_switch',
                              backgroundColor: MayakTheme.bgElevated,
                              onPressed: () =>
                                  engine.switchCallCameraOrSource(),
                              child: Icon(
                                Platform.isWindows
                                    ? (engine.windowsVideoSource == 'camera'
                                        ? Icons.screen_share_rounded
                                        : Icons.videocam_rounded)
                                    : Icons.cameraswitch_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              Platform.isWindows
                                  ? (engine.windowsVideoSource == 'camera'
                                      ? 'Экран'
                                      : 'Вебка')
                                  : 'Смена',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.large(
                            heroTag: 'call_end',
                            backgroundColor: MayakTheme.accentRed,
                            onPressed: () async {
                              await engine.endActiveCall();
                              _safeClose();
                            },
                            child: const Icon(Icons.call_end_rounded,
                                color: Colors.white, size: 32),
                          ),
                          const SizedBox(height: 6),
                          const Text('Сброс',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MayakGlobalFloatingOverlay extends StatefulWidget {
  const _MayakGlobalFloatingOverlay();

  @override
  State<_MayakGlobalFloatingOverlay> createState() =>
      _MayakGlobalFloatingOverlayState();
}

class _MayakGlobalFloatingOverlayState
    extends State<_MayakGlobalFloatingOverlay> {
  double _pipTop = 92;
  double _pipRight = 12;

  void _onEngineTick() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    MeshEngineListenerExt.addStaticListener(_onEngineTick);
  }

  @override
  void dispose() {
    MeshEngineListenerExt.removeStaticListener(_onEngineTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = mayakGlobalEngine;
    if (engine == null) return const SizedBox.shrink();

    final showMiniCall =
        engine.activeCallPeerId != null && !CallSessionScreen.isFullScreenOpen;
    final showPttBar = (engine.isWalkieTalkieMode ||
            engine.pttActiveSpeakerName != null) &&
        engine.activeCallPeerId == null;

    if (!showMiniCall && !showPttBar) return const SizedBox.shrink();

    return Stack(
      children: [
        // 1. Плавающее мини-окно активного звонка (можно сидеть в чате и вернуться по нажатию!)
        if (showMiniCall)
          Positioned(
            top: _pipTop,
            right: _pipRight,
            child: GestureDetector(
              onPanUpdate: (d) {
                setState(() {
                  _pipTop = (_pipTop + d.delta.dy).clamp(48.0, 520.0);
                  _pipRight = (_pipRight - d.delta.dx).clamp(8.0, 260.0);
                });
              },
              onTap: () {
                final nav = mayakNavigatorKey.currentState;
                if (nav != null && !CallSessionScreen.isFullScreenOpen) {
                  nav.push(
                    MaterialPageRoute(
                      builder: (_) => CallSessionScreen(engine: engine),
                    ),
                  );
                }
              },
              child: Material(
                color: Colors.transparent,
                elevation: 10,
                borderRadius: BorderRadius.circular(18),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: engine.activeCallMode == 'video' &&
                          engine.remoteVideoFrameBytes != null
                      ? 124
                      : 215,
                  padding: engine.activeCallMode == 'video' &&
                          engine.remoteVideoFrameBytes != null
                      ? const EdgeInsets.all(4)
                      : const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: MayakTheme.bgSurface.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: MayakTheme.accentEmerald, width: 1.6),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 14),
                    ],
                  ),
                  child: engine.activeCallMode == 'video' &&
                          engine.remoteVideoFrameBytes != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: SizedBox(
                                width: 116,
                                height: 146,
                                child: Image.memory(
                                  engine.remoteVideoFrameBytes!,
                                  gaplessPlayback: true,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                InkWell(
                                  onTap: () => engine.toggleCallMicMute(),
                                  child: Icon(
                                    engine.isCallMicMuted
                                        ? Icons.mic_off_rounded
                                        : Icons.mic_rounded,
                                    size: 18,
                                    color: engine.isCallMicMuted
                                        ? MayakTheme.accentAmber
                                        : Colors.white,
                                  ),
                                ),
                                InkWell(
                                  onTap: () => engine.endActiveCall(),
                                  child: const Icon(Icons.call_end_rounded,
                                      size: 18, color: MayakTheme.accentRed),
                                ),
                              ],
                            ),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: const BoxDecoration(
                                color: MayakTheme.accentEmerald,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.phone_in_talk_rounded,
                                  color: Colors.white, size: 18),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    engine.knownContacts[
                                                engine.activeCallPeerId]
                                            ?.displayTitle ??
                                        'Звонок',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ),
                                  const Text('Нажми, чтобы вернуть',
                                      style: TextStyle(
                                          color: MayakTheme.accentEmerald,
                                          fontSize: 10)),
                                ],
                              ),
                            ),
                            InkWell(
                              onTap: () => engine.endActiveCall(),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.call_end_rounded,
                                    color: MayakTheme.accentRed, size: 20),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        // 2. Глобальная панель Рации (PTT) — работает поверх любого экрана!
        if (showPttBar)
          Positioned(
            left: 12,
            right: 12,
            bottom: 74,
            child: SafeArea(
              child: Material(
                color: Colors.transparent,
                elevation: 12,
                borderRadius: BorderRadius.circular(20),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: engine.isPttTransmitting
                        ? const Color(0xFF3A1216)
                        : (engine.pttActiveSpeakerName != null
                            ? const Color(0xFF103324)
                            : MayakTheme.bgSurface.withOpacity(0.96)),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: engine.isPttTransmitting
                          ? MayakTheme.accentRed
                          : (engine.pttActiveSpeakerName != null
                              ? MayakTheme.accentEmerald
                              : MayakTheme.accentCyan.withOpacity(0.6)),
                      width: 1.5,
                    ),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 16),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        engine.isPttTransmitting
                            ? Icons.podcasts_rounded
                            : Icons.radio_rounded,
                        color: engine.isPttTransmitting
                            ? MayakTheme.accentRed
                            : (engine.pttActiveSpeakerName != null
                                ? MayakTheme.accentEmerald
                                : MayakTheme.accentCyan),
                        size: 26,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              engine.isPttTransmitting
                                  ? 'В ЭФИРЕ (передача)...'
                                  : (engine.pttActiveSpeakerName != null
                                      ? 'Говорит: ${engine.pttActiveSpeakerName}'
                                      : 'Рация (PTT) • Общий эфир'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              engine.isPttTransmitting
                                  ? 'Отпусти кнопку для Roger Beep'
                                  : 'Удерживай кнопку, чтобы говорить',
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Listener(
                        onPointerDown: (_) => engine.startPttTransmit(),
                        onPointerUp: (_) => engine.stopPttTransmit(),
                        onPointerCancel: (_) => engine.stopPttTransmit(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: engine.isPttTransmitting
                                ? MayakTheme.accentRed
                                : MayakTheme.accentCyan,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                engine.isPttTransmitting
                                    ? Icons.mic_rounded
                                    : Icons.mic_none_rounded,
                                color: engine.isPttTransmitting
                                    ? Colors.white
                                    : Colors.black,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                engine.isPttTransmitting ? 'ГОВОРЮ' : 'PTT',
                                style: TextStyle(
                                  color: engine.isPttTransmitting
                                      ? Colors.white
                                      : Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white54, size: 20),
                        onPressed: () => engine.toggleWalkieTalkieMode(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}


// =============================================================================
// v2.1.0: СИСТЕМАТИЗИРОВАННЫЕ НАСТРОЙКИ, ПОДКЛЮЧЕНИЯ С ТУТОРИАЛАМИ И «О ПРИЛОЖЕНИИ»
// =============================================================================

class MayakSettingsScreen extends StatefulWidget {
  final MeshEngine engine;
  final VoidCallback onEditNickname;
  final VoidCallback onShowQrAdd;
  final VoidCallback onOpenDiagnostics;
  final VoidCallback onOpenAdminUnlock;
  final VoidCallback onOpenAdminDashboard;

  const MayakSettingsScreen({
    super.key,
    required this.engine,
    required this.onEditNickname,
    required this.onShowQrAdd,
    required this.onOpenDiagnostics,
    required this.onOpenAdminUnlock,
    required this.onOpenAdminDashboard,
  });

  @override
  State<MayakSettingsScreen> createState() => _MayakSettingsScreenState();
}

class _MayakSettingsScreenState extends State<MayakSettingsScreen> {
  MeshEngine get engine => widget.engine;

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    engine.addListenerState(_onUpdate);
  }

  @override
  void dispose() {
    engine.removeListenerState(_onUpdate);
    super.dispose();
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w600,
          color: Colors.white54,
        ),
      ),
    );
  }

  Widget _settingsCard(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: MayakTheme.bgSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x22FFFFFF), width: 1),
      ),
      child: Column(children: children),
    );
  }

  String _disappearingLabel(int sec) {
    if (sec <= 0) return 'Выключено';
    if (sec == 30) return '30 секунд';
    if (sec == 300) return '5 минут';
    if (sec == 3600) return '1 час';
    return '$sec сек';
  }

  void _pickDisappearingTimer() {
    showModalBottomSheet(
      context: context,
      backgroundColor: MayakTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0x26FFFFFF)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Автоудаление сообщений',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            for (final opt in [0, 30, 300, 3600])
              ListTile(
                title: Text(_disappearingLabel(opt)),
                trailing: engine.defaultDisappearingSeconds == opt
                    ? const Icon(Icons.check_rounded, color: Colors.white)
                    : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  await engine.setDefaultDisappearingSeconds(opt);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки',
            style: TextStyle(fontWeight: FontWeight.w600)),
        shape: const Border(
          bottom: BorderSide(color: Color(0x22FFFFFF), width: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _sectionHeader('Профиль и ключи'),
          _settingsCard([
            ListTile(
              leading: const Icon(Icons.badge_outlined, color: Colors.white),
              title: Text(engine.nickname.isEmpty ? 'Узел Маяк' : engine.nickname),
              subtitle: Text('ID узла: ${engine.nodeId} • Нажми, чтобы изменить',
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: widget.onEditNickname,
            ),
            const Divider(height: 1, color: Color(0x1AFFFFFF)),
            ListTile(
              leading: const Icon(Icons.timer_outlined, color: Colors.white),
              title: const Text('Исчезающие сообщения'),
              subtitle: Text(
                  _disappearingLabel(engine.defaultDisappearingSeconds),
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: _pickDisappearingTimer,
            ),
            const Divider(height: 1, color: Color(0x1AFFFFFF)),
            ListTile(
              leading: const Icon(Icons.backup_outlined, color: Colors.white),
              title: const Text('Резервная копия (.mayakbak)'),
              subtitle: const Text('Экспорт ключей и истории чатов',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: () async {
                final path = await engine.exportBackupJsonToDownloads();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Бэкап сохранён: $path')),
                );
              },
            ),
          ]),
          _sectionHeader('Сеть и подключения'),
          _settingsCard([
            ListTile(
              leading: const Icon(Icons.hub_outlined, color: Colors.white),
              title: const Text('Подключения и туториалы'),
              subtitle: Text(
                'Wi-Fi • Bluetooth (${engine.bleMeshActive ? 'Вкл' : 'Выкл'}) • QR/IP • Буфер (${engine.totalBufferedCount})',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConnectionsSettingsScreen(
                      engine: engine,
                      onShowQrAdd: widget.onShowQrAdd,
                    ),
                  ),
                );
              },
            ),
            const Divider(height: 1, color: Color(0x1AFFFFFF)),
            ListTile(
              leading: const Icon(Icons.terminal_outlined, color: Colors.white),
              title: const Text('Диагностика и журнал событий'),
              subtitle: const Text('Логи BLE/Wi-Fi, пинг узлов, очистка кэша',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: widget.onOpenDiagnostics,
            ),
          ]),
          _sectionHeader('Система'),
          _settingsCard([
            if (engine.isAdminUnlocked) ...[
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined,
                    color: MayakTheme.accentAmber),
                title: const Text('Панель управления сетью'),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: Colors.white38),
                onTap: widget.onOpenAdminDashboard,
              ),
              const Divider(height: 1, color: Color(0x1AFFFFFF)),
            ],
            ListTile(
              leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
              title: const Text('О приложении'),
              subtitle: const Text('Маяк v2.1.0 • Шифрование и справка',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: Colors.white38),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AboutMayakScreen(
                      engine: engine,
                      onOpenAdminUnlock: widget.onOpenAdminUnlock,
                      onOpenAdminDashboard: widget.onOpenAdminDashboard,
                    ),
                  ),
                );
              },
            ),
          ]),
        ],
      ),
    );
  }
}

class ConnectionsSettingsScreen extends StatefulWidget {
  final MeshEngine engine;
  final VoidCallback onShowQrAdd;

  const ConnectionsSettingsScreen({
    super.key,
    required this.engine,
    required this.onShowQrAdd,
  });

  @override
  State<ConnectionsSettingsScreen> createState() =>
      _ConnectionsSettingsScreenState();
}

class _ConnectionsSettingsScreenState extends State<ConnectionsSettingsScreen> {
  MeshEngine get engine => widget.engine;

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    engine.addListenerState(_onUpdate);
  }

  @override
  void dispose() {
    engine.removeListenerState(_onUpdate);
    super.dispose();
  }

  Widget _connectionCard({
    required IconData icon,
    required String title,
    required String statusText,
    required Color statusColor,
    required String tutorial,
    required Widget actionButton,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      decoration: BoxDecoration(
        color: MayakTheme.bgSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x26FFFFFF), width: 1),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: MayakTheme.bgElevated,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x26FFFFFF)),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          title: Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          subtitle: Text(statusText,
              style: TextStyle(fontSize: 12, color: statusColor)),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MayakTheme.bgDeep,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: Text(
                tutorial,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.45, color: Colors.white70),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: actionButton),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Подключения',
            style: TextStyle(fontWeight: FontWeight.w600)),
        shape: const Border(
          bottom: BorderSide(color: Color(0x22FFFFFF), width: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 6, bottom: 32),
        children: [
          _connectionCard(
            icon: Icons.wifi_rounded,
            title: 'Wi-Fi / Локальная сеть (LAN)',
            statusText: engine.cachedIps.isNotEmpty
                ? 'IP: ${engine.cachedIps.first}:${engine.listenPort} • В сети: ${engine.connectedPeersCount}'
                : 'Подключись к Wi-Fi или раздай точку доступа',
            statusColor: engine.connectedPeersCount > 0
                ? MayakTheme.accentEmerald
                : Colors.white54,
            tutorial:
                'Как подключиться по Wi-Fi (максимальная скорость и 15–18 FPS в ВЧ):\n'
                '1. Подключите оба устройства к одному Wi-Fi роутеру — или раздайте точку доступа с одного телефона (интернет не нужен!).\n'
                '2. На ПК с Windows один раз нажмите «Открыть порты Windows», чтобы Брандмауэр пропустил 42069/42070/42072.\n'
                '3. Нажмите «Сканировать Wi-Fi» ниже — узлы найдутся за 2–5 секунд.',
            actionButton: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: engine.isScanningSubnet
                      ? null
                      : () => engine.scanLocalSubnet(),
                  icon: const Icon(Icons.wifi_find_rounded, size: 18),
                  label: Text(engine.isScanningSubnet
                      ? 'Сканирование...'
                      : 'Сканировать Wi-Fi'),
                ),
                if (Platform.isWindows)
                  OutlinedButton.icon(
                    onPressed: () async {
                      final r = await engine.configureWindowsPublicFirewall();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Брандмауэр Windows: $r')),
                      );
                    },
                    icon: const Icon(Icons.security_rounded, size: 18),
                    label: const Text('Открыть порты Windows'),
                  ),
              ],
            ),
          ),
          if (Platform.isAndroid)
            _connectionCard(
              icon: Icons.bluetooth_searching_rounded,
              title: 'Bluetooth / Устройства рядом (BLE + RFCOMM)',
              statusText: engine.bleMeshActive
                  ? 'Активен (Google Nearby + нативный BT RFCOMM)'
                  : 'Выключен — нажми, чтобы включить',
              statusColor: engine.bleMeshActive
                  ? MayakTheme.accentEmerald
                  : Colors.white54,
              tutorial:
                  'Как соединить телефоны без Wi-Fi (работает на Tecno, Xiaomi, Samsung, Huawei):\n'
                  '1. Включите Bluetooth на обоих телефонах.\n'
                  '2. Для автопоиска Google Nearby также включите Геолокацию (GPS) в шторке.\n'
                  '3. Если на каком-то телефоне Nearby не находит соседа — просто один раз сопрягите телефоны в обычных настройках Bluetooth: встроенный движок BT RFCOMM соединит их сам без GPS и без Google Play.',
              actionButton: OutlinedButton.icon(
                onPressed: () => engine.toggleAndroidBleMesh(),
                icon: Icon(
                  engine.bleMeshActive
                      ? Icons.bluetooth_disabled_rounded
                      : Icons.bluetooth_rounded,
                  size: 18,
                ),
                label: Text(engine.bleMeshActive
                    ? 'Выключить Bluetooth Mesh'
                    : 'Включить Bluetooth Mesh'),
              ),
            ),
          _connectionCard(
            icon: Icons.qr_code_2_rounded,
            title: 'QR-код и прямой IP',
            statusText: 'Мгновенная привязка узла и обмен ключами',
            statusColor: Colors.white54,
            tutorial:
                'Когда автопоиск заблокирован в гостевом Wi-Fi:\n'
                '1. На одном устройстве откройте «QR-код и IP» и покажите QR.\n'
                '2. На втором отсканируйте QR-код (или введите IP:порт вручную).\n'
                '3. Узлы мгновенно обменяются ключами X25519/Ed25519 и подключатся напрямую.',
            actionButton: OutlinedButton.icon(
              onPressed: widget.onShowQrAdd,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: const Text('Открыть QR-код / Ввести IP'),
            ),
          ),
          _connectionCard(
            icon: Icons.inventory_2_outlined,
            title: 'Mesh-буфер (Офлайн-доставка)',
            statusText: 'В буфере сейчас: ${engine.totalBufferedCount} пакет(ов)',
            statusColor: engine.totalBufferedCount > 0
                ? MayakTheme.accentAmber
                : MayakTheme.accentEmerald,
            tutorial:
                'Как работает Store-and-Forward буфер:\n'
                '• Если собеседник не в сети, зашифрованный пакет хранится в буфере и автоматически досылается при встрече (или через промежуточный узел в цепочке A ↔ B ↔ C).\n'
                '• Если накопились старые неактуальные пакеты — очистите буфер кнопкой ниже.',
            actionButton: OutlinedButton.icon(
              onPressed: engine.totalBufferedCount == 0
                  ? null
                  : () async {
                      final n = await engine.clearOutboxAndTransitBuffer();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Буфер очищен ($n шт.)')),
                      );
                    },
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('Очистить буфер отправки'),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutMayakScreen extends StatefulWidget {
  final MeshEngine engine;
  final VoidCallback onOpenAdminUnlock;
  final VoidCallback onOpenAdminDashboard;

  const AboutMayakScreen({
    super.key,
    required this.engine,
    required this.onOpenAdminUnlock,
    required this.onOpenAdminDashboard,
  });

  @override
  State<AboutMayakScreen> createState() => _AboutMayakScreenState();
}

class _AboutMayakScreenState extends State<AboutMayakScreen> {
  int _logoTaps = 0;
  int _verTaps = 0;
  int _seqStartMs = 0;

  void _resetIfExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_seqStartMs == 0 || now - _seqStartMs > 5000) {
      _logoTaps = 0;
      _verTaps = 0;
      _seqStartMs = now;
    }
  }

  void _onLogoTap() {
    _resetIfExpired();
    if (_verTaps > 0) {
      _logoTaps = 1;
      _verTaps = 0;
      _seqStartMs = DateTime.now().millisecondsSinceEpoch;
    } else {
      _logoTaps++;
    }
  }

  Future<void> _onVersionTap() async {
    _resetIfExpired();
    if (_logoTaps >= 3) {
      _verTaps++;
      if (_verTaps >= 2) {
        _logoTaps = 0;
        _verTaps = 0;
        final fastOk = await widget.engine.tryFastAdminUnlockFromCache();
        if (!mounted) return;
        if (fastOk) {
          widget.onOpenAdminDashboard();
        } else {
          widget.onOpenAdminUnlock();
        }
      }
    } else {
      _logoTaps = 0;
      _verTaps = 0;
    }
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12.5,
                    color: Colors.white,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('О приложении',
            style: TextStyle(fontWeight: FontWeight.w600)),
        shape: const Border(
          bottom: BorderSide(color: Color(0x22FFFFFF), width: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Center(
            child: GestureDetector(
              onTap: _onLogoTap,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white38, width: 1.2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset('assets/mayak_icon.png', fit: BoxFit.cover),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Center(
            child: Text(
              'МАЯК',
              style: TextStyle(
                fontSize: 22,
                letterSpacing: 3.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: GestureDetector(
              onTap: _onVersionTap,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  'Версия 2.1.0 • Автономный P2P & Mesh мессенджер',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: MayakTheme.bgSurface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0x24FFFFFF)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Криптография и защита (E2EE)',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                _infoRow('Обмен ключами', 'Double X25519 (эпимерный + статический) + HKDF-SHA256'),
                _infoRow('Шифрование', 'ChaCha20-Poly1305 AEAD (256-бит ключ, 96-бит nonce)'),
                _infoRow('Подпись', 'Ed25519 (проверка подлинности каждого пакета)'),
                _infoRow('Приватность', 'Sealed Sender + защита от replay-атак (окно seq)'),
                _infoRow('Звонки и Рация', 'Сквозное шифрование UDP 42072 и BLE/TCP call_bin/ptt_bin'),
                _infoRow('Серверы', '0 серверов • Без номера телефона и регистрации'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: MayakTheme.bgSurface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0x24FFFFFF)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Возможности узла',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text(
                  '• Прямые чаты, Multi-Hop групповые комнаты (до 5 ретрансляций) и «Избранное».\n'
                  '• Голосовые и видеозвонки (ВЧ с PiP-окошком своей камеры, сворачиванием в чат и звонком поверх экрана).\n'
                  '• Глобальная Рация (PTT) со звуками эфира и Roger Beep.\n'
                  '• Передача файлов до 1 ГБ без сжатия по модели Telegram (заблюренное превью + скачивание по нажатию).',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.5, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SavedMessagesScreen extends StatefulWidget {
  final MeshEngine engine;
  const SavedMessagesScreen({super.key, required this.engine});

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  final _ctrl = TextEditingController();
  MeshEngine get engine => widget.engine;

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    engine.addListenerState(_onUpdate);
  }

  @override
  void dispose() {
    engine.removeListenerState(_onUpdate);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notes = engine.getSavedMessages();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Избранное',
            style: TextStyle(fontWeight: FontWeight.w600)),
        shape: const Border(
          bottom: BorderSide(color: Color(0x22FFFFFF), width: 1),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: notes.isEmpty
                ? const Center(
                    child: Text('Личные локальные заметки (хранятся только на устройстве)',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(14),
                    itemCount: notes.length,
                    itemBuilder: (_, i) {
                      final n = notes[i];
                      return Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          onLongPress: () => engine.deleteSavedNote(n.msgId),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            constraints: const BoxConstraints(maxWidth: 320),
                            decoration: BoxDecoration(
                              color: MayakTheme.bgElevated,
                              borderRadius: BorderRadius.circular(6),
                              border:
                                  Border.all(color: const Color(0x2AFFFFFF)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(n.text,
                                    style:
                                        const TextStyle(color: Colors.white)),
                                const SizedBox(height: 3),
                                Text(n.timeFormatted,
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.white54)),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: const BoxDecoration(
              color: MayakTheme.bgSurface,
              border: Border(top: BorderSide(color: Color(0x22FFFFFF))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: InputDecoration(
                      hintText: 'Заметка в Избранное...',
                      filled: true,
                      fillColor: MayakTheme.bgDeep,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide:
                            const BorderSide(color: Color(0x26FFFFFF)),
                      ),
                    ),
                    onSubmitted: (_) async {
                      final t = _ctrl.text;
                      _ctrl.clear();
                      await engine.addSavedNote(t);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.send_rounded),
                  onPressed: () async {
                    final t = _ctrl.text;
                    _ctrl.clear();
                    await engine.addSavedNote(t);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
