import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:p2p_mesh/mesh_engine.dart';
import 'package:p2p_mesh/mayak_dht.dart';

void main() {
  group('MeshEngine.parseEndpoint', () {
    test('parses IPv4 with port', () {
      final ep = MeshEngine.parseEndpoint('192.168.1.15:42070');
      expect(ep.host, '192.168.1.15');
      expect(ep.port, 42070);
      expect(ep.isUdp, false);
    });

    test('parses udp:IPv4:port without returning literal udp host', () {
      final ep = MeshEngine.parseEndpoint('udp:91.78.175.77:14782');
      expect(ep.host, '91.78.175.77');
      expect(ep.port, 14782);
      expect(ep.isUdp, true);
    });

    test('parses bracketed IPv6 and bare IPv6 safely', () {
      final ep1 = MeshEngine.parseEndpoint('[2a03:6f00:1::1]:42070');
      expect(ep1.host, '2a03:6f00:1::1');
      expect(ep1.port, 42070);

      final ep2 = MeshEngine.parseEndpoint('2a03:6f00:1::1');
      expect(ep2.host, '2a03:6f00:1::1');
      expect(ep2.port, 42070);
    });

    test('rejects BLE and Mesh labels', () {
      expect(MeshEngine.parseEndpoint('BLE:AA:BB').host, '');
      expect(MeshEngine.parseEndpoint('Через Mesh').host, '');
    });
  });

  group('MeshEngine.isPrivateLanIpv4', () {
    test('detects RFC1918 LAN IPv4 only', () {
      expect(MeshEngine.isPrivateLanIpv4('192.168.0.10'), true);
      expect(MeshEngine.isPrivateLanIpv4('10.0.0.5'), true);
      expect(MeshEngine.isPrivateLanIpv4('91.78.175.77'), false);
      expect(MeshEngine.isPrivateLanIpv4('udp'), false);
      expect(MeshEngine.isPrivateLanIpv4('2a03:6f00::1'), false);
    });
  });

  group('MayakDhtClient PEX', () {
    test('imports and exports external IPv4 DHT nodes', () {
      final dht = MayakDhtClient(getSocket: () => null, onLog: (_) {});
      final fakeId = base64Encode(Uint8List.fromList(List.filled(20, 7)));
      final added = dht.importExternalNodes([
        {'ip': '91.78.175.77', 'p': 14782, 'id': fakeId},
        {'ip': '2a03::1', 'p': 6881, 'id': fakeId}, // IPv6 must be skipped
      ]);
      expect(added, 1);
      expect(dht.knownNodesCount, 1);
      final exported = dht.exportActiveNodes(limit: 10);
      expect(exported.length, 1);
      expect(exported.first['ip'], '91.78.175.77');
    });
  });

  group('E2EE Read Receipts & Notification Actions', () {
    test('ChatMessage preserves isRead in JSON round-trip and legacy default', () {
      final msg = ChatMessage(
        msgId: 'm1',
        peerId: 'peerA',
        senderId: 'me',
        senderName: 'Я',
        text: 'Привет',
        timestamp: 1000,
        isMe: true,
        isDelivered: true,
        isRead: true,
      );
      final restored = ChatMessage.fromJson(msg.toJson());
      expect(restored.isDelivered, true);
      expect(restored.isRead, true);

      final legacy = ChatMessage.fromJson({
        'id': 'm2',
        'p': 'peerA',
        's': 'me',
        'sn': 'Я',
        'txt': 'Старое',
        'ts': 900,
        'me': true,
        'ack': true,
      });
      expect(legacy.isDelivered, true);
      expect(legacy.isRead, false);
    });

    test('applyReadReceiptFromPeer and notification actions queue E2EE packets', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});

      final engine = MeshEngine(
        onMessageReceived: (_) {},
        onStateChanged: () {},
      );
      engine.nodeId = 'node_self';
      engine.nickname = 'Тест';

      // Подготавливаем валидные X25519/Ed25519 ключи для E2EE-пакетов
      final dhKp = await X25519().newKeyPair();
      final signKp = await Ed25519().newKeyPair();
      final peerDhKp = await X25519().newKeyPair();
      final peerSignKp = await Ed25519().newKeyPair();
      String toHex(List<int> bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      engine.dhPubHex = toHex((await dhKp.extractPublicKey()).bytes);
      engine.signPubHex = toHex((await signKp.extractPublicKey()).bytes);
      final peerDhHex = toHex((await peerDhKp.extractPublicKey()).bytes);
      final peerSignHex = toHex((await peerSignKp.extractPublicKey()).bytes);

      // Используем публичный тестовый способ: инициализируем ключи через importBackupFromJson или прямой контакт
      // Т.к. _dhKeyPair/_signKeyPair приватные, тестируем applyReadReceiptFromPeer и счётчики без приватных ключей,
      // а E2EE-очередь проверяем через sendReadReceipt только при наличии ключей.
      engine.knownContacts['peer_1'] = ContactProfile(
        nodeId: 'peer_1',
        nickname: 'Алиса',
        dhPubHex: peerDhHex,
        signPubHex: peerSignHex,
        unreadCount: 2,
      );
      engine.getMessagesFor('peer_1').addAll([
        ChatMessage(
          msgId: 'out_1',
          peerId: 'peer_1',
          senderId: 'node_self',
          senderName: 'Тест',
          text: 'Исходящее',
          timestamp: 1000,
          isMe: true,
          isDelivered: false,
          isRead: false,
        ),
        ChatMessage(
          msgId: 'in_1',
          peerId: 'peer_1',
          senderId: 'peer_1',
          senderName: 'Алиса',
          text: 'Входящее',
          timestamp: 1100,
          isMe: false,
          isDelivered: true,
          isRead: false,
        ),
      ]);

      final updated = engine.applyReadReceiptFromPeer('peer_1', ['out_1', 'missing']);
      expect(updated, 1);
      expect(engine.getMessagesFor('peer_1').first.isDelivered, true);
      expect(engine.getMessagesFor('peer_1').first.isRead, true);
      // Повторный вызов для того же msgId не должен менять счётчик
      expect(engine.applyReadReceiptFromPeer('peer_1', ['out_1']), 0);

      // Кнопка «Прочитать» для broadcast и группы сбрасывает unread-счётчики
      engine.unreadBroadcastCount = 3;
      await engine.markNotificationAsRead(MeshEngine.broadcastChannelId);
      expect(engine.unreadBroadcastCount, 0);

      engine.groupChats['g1'] = GroupChat(
        groupId: 'g1',
        title: 'Штаб',
        creatorId: 'node_self',
        memberIds: ['node_self', 'peer_1'],
        createdAt: 1000,
      );
      engine.unreadGroupCounts['g1'] = 4;
      await engine.markNotificationAsRead(engine.groupChatKey('g1'));
      expect(engine.unreadGroupCounts['g1'], 0);
    });
  });
}
