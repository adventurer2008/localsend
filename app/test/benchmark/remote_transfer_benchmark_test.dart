import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:localsend_app/remote_transfer/remote_client.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../unit/remote_transfer_test.dart' show peerOf, until;

void main() {
  final enabled = Platform.environment['LOCALSEND_RELAY_BENCHMARK'] == '1';
  const fileSize = 100000000;
  for (final delayMs in [0, 40]) {
    test(
      '100 MB relay transfer with ${2 * delayMs} ms added round-trip delay',
      () async {
        final temp = await Directory.systemTemp.createTemp('localsend-relay-bench-');
        addTearDown(() => temp.delete(recursive: true));
        final alice = await RemoteIdentity.fromSeed(Uint8List(64)..fillRange(0, 64, 11));
        final bob = await RemoteIdentity.fromSeed(Uint8List(64)..fillRange(0, 64, 22));
        final bobCard = peerOf(bob, 'Bob');
        final relayDirectory = File('../relay/server.mjs').existsSync() ? '../relay' : 'relay';
        final relay = await Process.start('node', [
          '--input-type=module',
          '-e',
          '''
import { createRelay } from './server.mjs';
import { WebSocket } from 'ws';
const delay = $delayMs;
if (delay) {
  const send = WebSocket.prototype.send;
  WebSocket.prototype.send = function (...args) {
    setTimeout(() => {
      if (this.readyState === WebSocket.OPEN) send.apply(this, args);
    }, delay);
  };
}
const { server } = createRelay(${jsonEncode([alice.id, bob.id])});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
''',
        ], workingDirectory: relayDirectory);
        addTearDown(() async {
          relay.kill();
          await relay.exitCode;
        });
        final port = await relay.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 8));
        final uri = Uri.parse('ws://127.0.0.1:$port/v1/relay');

        RemoteClient client(RemoteIdentity identity, String name) {
          final result = RemoteClient(
            identity: identity,
            uri: uri,
            peers: {},
            localCard: peerOf(identity, name).card,
            documentsDirectory: () async => temp,
          );
          final running = result.run();
          addTearDown(() async {
            result.dispose();
            await running;
          });
          return result;
        }

        final sender = client(alice, 'Alice');
        final receiver = client(bob, 'Bob');
        final input = File(p.join(temp.path, '100MB.bin'));
        final random = Random(42);
        final block = List.generate(1000000, (_) => random.nextInt(256));
        final output = input.openWrite();
        for (var offset = 0; offset < fileSize; offset += block.length) {
          output.add(block);
          await output.flush();
        }
        await output.close();
        final digest = await sha256.bind(input.openRead()).first;
        await until(() => sender.online.containsKey(bob.id));
        final timings = <double>[];
        for (var run = 0; run < 3; run++) {
          await sender.offer(bobCard, XFile(input.path));
          await until(() => receiver.transfer?.phase == RemotePhase.offered);
          final delivered = Completer<void>();
          void onChange() {
            if (sender.transfer == null && !delivered.isCompleted) delivered.complete();
          }

          sender.addListener(onChange);
          final timer = Stopwatch()..start();
          try {
            await receiver.decide(true);
            await delivered.future.timeout(const Duration(minutes: 2));
          } finally {
            timer.stop();
            sender.removeListener(onChange);
          }
          expect(sender.status, startsWith('Sent'));
          final saved = File(receiver.savedPath!);
          expect(await saved.length(), fileSize);
          expect(await sha256.bind(saved.openRead()).first, digest);
          await saved.parent.delete(recursive: true);
          timings.add(timer.elapsedMicroseconds / 1000000);
        }
        final median = (timings.toList()..sort())[1];
        // ignore: avoid_print
        print(
          'RTT +${2 * delayMs} ms: ${timings.map((t) => t.toStringAsFixed(2)).join(', ')} s; '
          'median ${median.toStringAsFixed(2)} s, ${(100 / median).toStringAsFixed(2)} MB/s',
        );
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
