import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/remote_transfer/remote_route.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/crypto.dart' as crypto;
import 'package:localsend_isolates/rust/api/http.dart' as http;
import 'package:localsend_isolates/rust/api/model.dart' as model;
import 'package:localsend_isolates/rust/api/server.dart' as server;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:refena_flutter/refena_flutter.dart';

const _connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
const _networkInfo = MethodChannel('dev.fluttercommunity.plus/network_info');
const _android = MethodChannel('org.localsend.localsend_app/localsend');

Device device(String fingerprint, {required String ip, required int port, required String name}) => Device(
  signalingId: null,
  ip: ip,
  version: '2.2',
  port: port,
  https: true,
  fingerprint: fingerprint,
  alias: name,
  deviceModel: null,
  deviceType: DeviceType.desktop,
  download: false,
  channels: const [],
);

void main() {
  final messenger = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  late List<String> networks;
  late String? wifiAddress;

  setUp(() {
    networks = ['wifi'];
    wifiAddress = null;
    messenger.setMockMethodCallHandler(_connectivity, (_) async => networks);
    messenger.setMockMethodCallHandler(_networkInfo, (_) async => wifiAddress);
    messenger.setMockMethodCallHandler(_android, (_) async => wifiAddress != null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_connectivity, null);
    messenger.setMockMethodCallHandler(_networkInfo, null);
    messenger.setMockMethodCallHandler(_android, null);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform Wi-Fi → cellular → Wi-Fi uses the current network even under a VPN', () async {
      debugDefaultTargetPlatformOverride = platform;
      expect(await canTryLan(), isTrue);

      networks = ['mobile', 'vpn'];
      expect(await canTryLan(), isFalse);

      // iOS and some Android VPNs may report only the tunnel as the default network.
      networks = ['vpn'];
      wifiAddress = '192.168.0.10';
      expect(await canTryLan(), isTrue);

      wifiAddress = null;
      expect(await canTryLan(), isFalse);
    });
  }

  test(
    'Pinned HTTPS verifies the real LAN endpoint before selecting it and rejects stale and mismatched targets',
    () async {
      await RustLib.init().timeout(const Duration(seconds: 5));
      final sender = await crypto.generateSecurityContext();
      final receiver = await crypto.generateSecurityContext();
      final relayIdentity = await RemoteIdentity.fromSeed(Uint8List(64));
      final host = Platform.environment['LOCALSEND_TEST_LAN_ADDRESS'] ?? '127.0.0.1';
      final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reservation.port;
      await reservation.close();
      final listener = await server.startServer(
        port: port,
        tls: server.TlsConfig(cert: receiver.certificate, privateKey: receiver.privateKey),
        alias: 'Receiver',
        version: '2.2',
        fingerprint: receiver.certificateHash,
        verifyChecksums: false,
      );
      final temporary = await Directory.systemTemp.createTemp('localsend-lan-test-');
      addTearDown(() => temporary.delete(recursive: true));
      final input = await File.fromUri(temporary.uri.resolve('outgoing.bin')).writeAsBytes([1, 2, 3, 4]);
      final received = File.fromUri(temporary.uri.resolve('incoming.bin'));
      final offer = Completer<server.RsServerEvent_PrepareUpload>();
      final events = listener.listen().listen((event) {
        switch (event) {
          case server.RsServerEvent_PrepareUpload():
            offer.complete(event);
          case server.RsServerEvent_FileUpload(:final sessionId, :final fileId, :final file):
            unawaited(listener.respondFileUpload(sessionId: sessionId, fileId: fileId, path: received.path, fileSize: file.size).drain<void>());
          default:
            break;
        }
      });
      addTearDown(() {
        // This native server lives in the dedicated Flutter test process.
        // The process closes the listener even if native shutdown is still draining.
        unawaited(events.cancel());
        unawaited(listener.stop());
      });
      final target = device(receiver.certificateHash, ip: host, port: port, name: 'Receiver');
      final origin = device(sender.certificateHash, ip: host, port: 53317, name: 'Sender');
      final trusted = RemotePeer.parse(relayIdentity.card('Receiver', receiver.certificateHash));
      final container = RefenaContainer(
        overrides: [
          deviceFullInfoProvider.overrideWithBuilder((_) => origin),
          httpProvider.overrideWithBuilder(
            (_) => HttpClientCollection(
              privateKey: sender.privateKey,
              certificate: sender.certificate,
              discovery: http.createClient(privateKey: sender.privateKey, cert: sender.certificate, version: http.LsHttpClientVersion.v2),
            ),
          ),
        ],
      );
      addTearDown(container.disposeContainer);

      for (final platform in [TargetPlatform.windows, TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        networks = ['wifi'];
        expect(await reachableTrustedLan(container, trusted, candidate: target), same(target), reason: '$platform uses the reachable LAN IP');
        if (platform != TargetPlatform.windows) {
          networks = ['mobile'];
          expect(await reachableTrustedLan(container, trusted, candidate: target), isNull, reason: 'Do not use a cached LAN IP on cellular');
        }
        networks = ['wifi'];
        expect(await reachableTrustedLan(container, trusted, candidate: target), same(target), reason: 'Direct transfer is preferred again');
      }

      final wrongPeer = RemotePeer.parse(relayIdentity.card('Wrong certificate', sender.certificateHash));
      final wrongTarget = device(sender.certificateHash, ip: host, port: port, name: 'Wrong certificate');
      expect(await reachableTrustedLan(container, wrongPeer, candidate: wrongTarget), isNull);

      final stale = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final stalePort = stale.port;
      await stale.close();
      expect(
        await reachableTrustedLan(
          container,
          trusted,
          candidate: device(receiver.certificateHash, ip: host, port: stalePort, name: 'Stale'),
        ),
        isNull,
      );

      final direct = (await reachableTrustedLan(container, trusted, candidate: target))!;
      final client = container.read(httpProvider).pinnedTo(direct.fingerprint);
      addTearDown(client.dispose);
      const fileId = 'test-file';
      final size = BigInt.from(await input.length());
      final waiting = client.prepareUpload(
        protocol: model.ProtocolType.https,
        ip: direct.ip!,
        port: direct.port,
        payload: model.PrepareUploadRequestDto(
          info: origin.toRegisterDto(),
          files: {fileId: model.FileDto(id: fileId, fileName: 'outgoing.bin', size: size, fileType: 'application/octet-stream')},
        ),
        cancelToken: createCancellationToken(),
      );
      final incoming = await offer.future.timeout(const Duration(seconds: 5));
      expect(incoming.certFingerprint, sender.certificateHash);
      expect(await received.exists(), isFalse);
      await listener.respondPrepareUpload(acceptedFileIds: [fileId]).timeout(const Duration(seconds: 5));
      final accepted = (await waiting.timeout(const Duration(seconds: 5))).response!;
      final sent = await client
          .upload(
            protocol: model.ProtocolType.https,
            ip: direct.ip!,
            port: direct.port,
            sessionId: accepted.sessionId,
            fileId: fileId,
            token: accepted.files[fileId]!,
            path: input.path,
            contentLength: size,
            cancelToken: createCancellationToken(),
          )
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(sent.whereType<http.RsUploadEvent_Failed>(), isEmpty);
      expect(await received.readAsBytes(), [1, 2, 3, 4]);
    },
    skip: Platform.environment['LOCALSEND_NATIVE_TEST'] != '1' ? 'Set LOCALSEND_NATIVE_TEST=1 with the LocalSend native library available' : false,
  );
}
