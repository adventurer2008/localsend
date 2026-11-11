import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:localsend_app/remote_transfer/remote_client.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/remote_transfer/remote_session.dart';
import 'package:localsend_app/remote_transfer/remote_settings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

RemotePeer peerOf(RemoteIdentity identity, String name) => RemotePeer.parse(identity.card(name, List.filled(64, 'A').join()));

Future<void> until(bool Function() ready) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    if (timer.elapsed > const Duration(seconds: 8)) fail('Timed out waiting for relay state');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('Only the paired devices can decrypt a frame and its session, type and sequence cannot be changed', () async {
    final alice = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 1)));
    final bob = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 2)));
    final other = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 3)));
    final epoch = encodeRemoteBytes(Uint8List(16));
    const id = '19c77cc1a8fe22cc13a514ab492b42ab';
    final sender = RemoteSession(id, alice.id, bob.id, await alice.transferKey(peerOf(bob, 'Bob'), alice.id, bob.id, id, epoch));
    final receiver = RemoteSession(id, bob.id, alice.id, await bob.transferKey(peerOf(alice, 'Alice'), alice.id, bob.id, id, epoch));
    final stranger = RemoteSession(id, bob.id, alice.id, await other.transferKey(peerOf(alice, 'Alice'), alice.id, bob.id, id, epoch));
    final payload = utf8.encode('private filename and size');
    final frame = {...await sender.seal('offer', payload), 'from': alice.id};

    await expectLater(stranger.open(frame), throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(receiver.open({...frame, 'session': 'different-session'}), throwsFormatException);
    await expectLater(receiver.open({...frame, 'seq': 1}), throwsFormatException);
    await expectLater(receiver.open({...frame, 'type': 'chunk'}), throwsA(isA<SecretBoxAuthenticationError>()));
    expect(await receiver.open(frame), payload);
    await expectLater(receiver.open(frame), throwsFormatException);

    final laterEpoch = encodeRemoteBytes(Uint8List.fromList(List.filled(16, 1)));
    final nextConnection = RemoteSession(id, bob.id, alice.id, await bob.transferKey(peerOf(alice, 'Alice'), alice.id, bob.id, id, laterEpoch));
    await expectLater(nextConnection.open(frame), throwsA(isA<SecretBoxAuthenticationError>()));
  });

  test('Relay requires WSS and received filenames stay inside the save directory', () {
    expect(() => RemoteSettings.relayUri('ws://relay.example.com/v1/relay'), throwsFormatException);
    expect(() => RemoteSettings.relayUri('wss://relay.example.com/v1/relay?token=x'), throwsFormatException);
    expect(RemoteSettings.relayUri('wss://relay.example.com/v1/relay').host, 'relay.example.com');
    expect(safeRemoteFileName(r'..\name:file.txt'), '.._name_file.txt');
    expect(safeRemoteFileName('CON.txt'), '_CON.txt');
    expect(() => safeRemoteFileName('..'), throwsFormatException);
  });

  test(
    'Two Flutter clients require approval, reject strangers and stream files in both directions through the real relay',
    () async {
      final temp = await Directory.systemTemp.createTemp('localsend-relay-test-');
      addTearDown(() => temp.delete(recursive: true));
      final alice = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 11)));
      final bob = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 22)));
      final other = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 33)));
      final unpaired = await RemoteIdentity.fromSeed(Uint8List.fromList(List.filled(64, 44)));
      final aliceCard = peerOf(alice, 'Alice');
      final bobCard = peerOf(bob, 'Bob');
      final relayDirectory = File('../relay/server.mjs').existsSync() ? '../relay' : 'relay';
      final relay = await Process.start('node', [
        '--input-type=module',
        '-e',
        'import { createRelay } from "./server.mjs"; '
            'const { server } = createRelay(${jsonEncode([alice.id, bob.id, unpaired.id])}); '
            'server.listen(0, "127.0.0.1", () => console.log(server.address().port));',
      ], workingDirectory: relayDirectory);
      addTearDown(() async {
        relay.kill();
        await relay.exitCode;
      });
      final portLine = await relay.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 8));
      final uri = Uri.parse('ws://127.0.0.1:$portLine/v1/relay'); // Loopback transport for this test only.

      RemoteClient client(RemoteIdentity identity, Map<String, RemotePeer> peers, String name) {
        final result = RemoteClient(identity: identity, uri: uri, peers: peers, documentsDirectory: () async => Directory(p.join(temp.path, name)));
        final running = result.run();
        addTearDown(() async {
          result.dispose();
          await running;
        });
        return result;
      }

      final sender = client(alice, {bob.id: bobCard}, 'Alice');
      final receiver = client(bob, {alice.id: aliceCard}, 'Bob');
      final stranger = client(other, {bob.id: bobCard}, 'Stranger');
      final unpairedClient = client(unpaired, {bob.id: bobCard}, 'Unpaired');
      await until(() => sender.online.containsKey(bob.id) && receiver.online.containsKey(alice.id));
      await until(() => stranger.status.startsWith('Relay refused'));
      expect(stranger.connected, isFalse);

      final content = Uint8List.fromList(List.generate(700000, (index) => index % 256));
      final input = await File(p.join(temp.path, 'example.bin')).writeAsBytes(content);
      final outgoing = XFile(input.path);
      await until(() => unpairedClient.online.containsKey(bob.id));
      expect(receiver.online.containsKey(unpaired.id), isFalse);
      await unpairedClient.offer(bobCard, outgoing);
      await until(() => unpairedClient.transfer == null);
      expect(unpairedClient.status, contains('cancelled'));
      expect(receiver.transfer, isNull);

      await sender.offer(bobCard, outgoing);
      await until(() => receiver.transfer?.phase == RemotePhase.offered);
      expect(sender.transfer?.transferred, 0);
      expect(Directory(p.join(temp.path, 'Bob')).existsSync(), isFalse);
      await receiver.decide(false);
      await until(() => sender.transfer == null);
      expect(sender.status, contains('declined'));
      expect(receiver.savedPath, isNull);

      await sender.offer(bobCard, outgoing);
      await until(() => receiver.transfer?.phase == RemotePhase.offered);
      await receiver.decide(true);
      await until(() => receiver.savedPath != null && sender.transfer == null);
      expect(await File(receiver.savedPath!).readAsBytes(), content);
      expect(sender.status, contains('Sent'));

      final empty = await File(p.join(temp.path, 'empty.bin')).create();
      await receiver.offer(aliceCard, XFile(empty.path));
      await until(() => sender.transfer?.phase == RemotePhase.offered);
      await sender.decide(true);
      await until(() => sender.savedPath != null && receiver.transfer == null);
      expect(await File(sender.savedPath!).length(), 0);
      expect(receiver.status, contains('Sent'));

      final previousSave = receiver.savedPath;
      final larger = await File(p.join(temp.path, 'interrupted.bin')).open(mode: FileMode.write);
      await larger.truncate(24 * 1024 * 1024);
      await larger.close();
      await sender.offer(bobCard, XFile(larger.path));
      await until(() => receiver.transfer?.phase == RemotePhase.offered);
      await receiver.decide(true);
      await until(() => (receiver.transfer?.transferred ?? 0) > 0);
      await sender.disconnect();
      await until(() => receiver.transfer == null && !receiver.online.containsKey(alice.id));
      expect(receiver.savedPath, previousSave);
      final receiverFiles = Directory(p.join(temp.path, 'Bob', 'LocalSend Remote'));
      expect(await receiverFiles.list().length, 1);
    },
    skip: Platform.environment['LOCALSEND_RELAY_TEST'] != '1' ? 'Set LOCALSEND_RELAY_TEST=1 after npm ci in relay/' : false,
  );
}
