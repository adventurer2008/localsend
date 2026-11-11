import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/remote_transfer/remote_client.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/remote_transfer/remote_settings.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart' show Provider;

final remoteRuntimeProvider = Provider((ref) => RemoteRuntime(() => ref.read(deviceFullInfoProvider)));

/// Owns the connection for the application lifetime, independently of pages.
class RemoteRuntime extends ChangeNotifier {
  final Device Function() _device;
  RemoteClient? client;
  RemoteSettings? settings;
  RemoteIdentity? identity;
  String? error;
  int openPages = 0;
  Future<void>? _initializing;
  Timer? _retry;
  int _generation = 0;
  bool _disposed = false;
  bool _paused = false;

  RemoteRuntime(this._device);

  Future<void> initialize() => _initializing ??= _initialize();

  Map<String, RemotePeer> get peers => client?.peers ?? settings?.peers ?? const {};

  Future<RemoteClient?> waitForPeer(String id) async {
    if (client?.online.containsKey(id) == true) return client;
    if (_paused || settings?.url.isNotEmpty != true) return null;
    final available = Completer<RemoteClient>();
    void check() {
      final connection = client;
      if (connection != null && connection.online.containsKey(id) && !available.isCompleted) {
        available.complete(connection);
      }
    }

    addListener(check);
    try {
      await available.future.timeout(const Duration(seconds: 8));
      return client?.online.containsKey(id) == true ? client : null;
    } on TimeoutException {
      return null;
    } finally {
      removeListener(check);
    }
  }

  Future<void> _initialize() async {
    try {
      settings = await RemoteSettings.load();
      identity = await RemoteIdentity.load();
      if (!_disposed) reconnect();
    } catch (_) {
      error = 'Could not open the device’s secure storage';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void reconnect() {
    if (_disposed || settings == null || identity == null) return;
    _paused = false;
    _retry?.cancel();
    final generation = ++_generation;
    final previous = client;
    previous?.removeListener(_notify);
    previous?.dispose();
    client = null;
    error = null;
    if (settings!.url.isEmpty) {
      _notify();
      return;
    }
    try {
      final device = _device();
      final connection = RemoteClient(
        identity: identity!,
        uri: RemoteSettings.relayUri(settings!.url),
        peers: settings!.peers,
        localCard: identity!.card(device.alias, device.fingerprint),
        onDirectory: (peers) async {
          if (!_disposed && generation == _generation) await settings!.setPeers(peers);
        },
      );
      client = connection;
      connection.addListener(_notify);
      unawaited(_run(connection, generation));
    } catch (_) {
      error = 'Could not start the relay connection';
    }
    _notify();
  }

  Future<void> _run(RemoteClient connection, int generation) async {
    await connection.run();
    if (_disposed || _paused || generation != _generation) return;
    _retry = Timer(const Duration(seconds: 5), reconnect);
  }

  Future<void> setUrl(String value) async {
    RemoteSettings.relayUri(value);
    _generation++;
    _retry?.cancel();
    client?.removeListener(_notify);
    client?.dispose();
    client = null;
    await settings!.setUrl(value);
    if (!_disposed) reconnect();
  }

  void ensureConnected({bool refresh = false}) {
    if (!_paused && (client?.connected != true || (refresh && client?.transfer == null))) reconnect();
  }

  void disconnect() {
    _paused = true;
    _retry?.cancel();
    final connection = client;
    if (connection != null) unawaited(connection.disconnect());
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    client?.removeListener(_notify);
    client?.dispose();
    super.dispose();
  }
}
