import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/remote_transfer/remote_client.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/remote_transfer/remote_runtime.dart';
import 'package:localsend_app/remote_transfer/remote_settings.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/open_file.dart' as saved_file;
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:refena_flutter/refena_flutter.dart';

String remoteTransferLabel(BuildContext context) => Localizations.localeOf(context).languageCode == 'zh' ? '可信设备' : 'Trusted devices';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  RemoteRuntime? _runtime;
  RemoteSettings? get _settings => _runtime?.settings;
  RemoteIdentity? get _identity => _runtime?.identity;
  RemoteClient? get _client => _runtime?.client;
  bool _choosing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final runtime = context.ref.read(remoteRuntimeProvider);
      _runtime = runtime;
      runtime.openPages++;
      runtime.addListener(_runtimeChanged);
      await runtime.initialize();
      if (!mounted) return;
      setState(() {});
      unawaited(_scan(context.ref));
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the device’s secure storage');
    }
  }

  void _runtimeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _scan(Ref ref) async {
    try {
      await ref.global.dispatchAsync(StartSmartScan());
    } catch (_) {
      // Local discovery is optional when using the relay.
    }
  }

  void _connect() {
    setState(() => _error = null);
    _runtime!.reconnect();
  }

  Future<String?> _prompt(String title, String label, [String initial = '']) => showDialog<String>(
    context: context,
    builder: (context) => _InputDialog(title: title, label: label, initial: initial),
  );

  Future<void> _editUrl() async {
    final value = await _prompt('Relay server', 'wss://relay.example.com/v1/relay', _settings!.url);
    if (value == null || !mounted) return;
    try {
      await _runtime!.setUrl(value);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save the relay address');
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  Future<void> _send(RemotePeer peer) async {
    if (_choosing || _client?.transfer != null) return;
    final ref = context.ref;
    setState(() {
      _choosing = true;
      _error = null;
    });
    try {
      final file = await openFile();
      if (file == null || !mounted) return;
      final local = await _reachableLan(ref, peer);
      if (!mounted) return;
      if (_client?.transfer != null) throw StateError('Finish the current transfer first');
      if (local != null) {
        final selected = await CrossFileConverters.convertXFile(file);
        if (!mounted) return;
        await ref.notifier(sendProvider).startSession(target: local, files: [selected], background: false);
      } else {
        final client = _client;
        if (client == null || client.online[peer.id] == null) throw StateError('This device is offline');
        await client.offer(peer, file);
      }
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start the transfer');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Device? _lanCandidate(Ref ref, RemotePeer peer) {
    final local = ref.read(nearbyDevicesProvider).devices[peer.lanFingerprint];
    return local != null && local.https && local.ip != null ? local : null;
  }

  Future<Device?> _reachableLan(Ref ref, RemotePeer peer) async {
    final origin = ref.read(deviceFullInfoProvider);
    if (!origin.https || origin.port < 0) return null;
    final known = _lanCandidate(ref, peer);
    if (known != null && await _probeLan(ref, origin, known)) return known;
    await _scan(ref).timeout(const Duration(seconds: 2), onTimeout: () {});
    if (!mounted) return null;
    final discovered = _lanCandidate(ref, peer);
    if (discovered == null || (discovered.ip == known?.ip && discovered.port == known?.port)) return null;
    return await _probeLan(ref, origin, discovered) ? discovered : null;
  }

  Future<bool> _probeLan(Ref ref, Device origin, Device local) async {
    try {
      await ref
          .read(httpProvider)
          .pinnedTo(local.fingerprint)
          .register(protocol: local.getProtocolType(), ip: local.ip!, port: local.port, payload: origin.toRegisterDto())
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      // An old discovery result must not prevent sending via the relay.
      return false;
    }
  }

  @override
  void dispose() {
    _runtime?.removeListener(_runtimeChanged);
    if (_runtime != null) _runtime!.openPages--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final identity = _identity;
    final client = _client;
    final transfer = client?.transfer;
    final nearby = context.watch(nearbyDevicesProvider).devices;
    final busy = _choosing || transfer != null;

    return Scaffold(
      appBar: AppBar(title: Text(remoteTransferLabel(context))),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error case final error?) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (_runtime?.error case final error?) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (settings == null || identity == null) ...[
                  if (_error == null) const LinearProgressIndicator(),
                ] else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Relay server'),
                    subtitle: Text(settings.url.isEmpty ? 'Set the address of your server' : client?.status ?? settings.url),
                    trailing: IconButton(tooltip: 'Edit relay address', onPressed: busy ? null : _editUrl, icon: const Icon(Icons.edit)),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(onPressed: () => _copy(identity.id), child: const Text('Copy relay allowlist key')),
                      if (client != null && !client.connected) OutlinedButton(onPressed: busy ? null : _connect, child: const Text('Reconnect')),
                      if (client != null && client.connected)
                        OutlinedButton(onPressed: busy ? null : _runtime!.disconnect, child: const Text('Disconnect')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    Localizations.localeOf(context).languageCode == 'zh'
                        ? '服务器白名单内的设备自动可信。应用运行时保持连接，收到文件后由你确认。'
                        : 'Server-whitelisted devices are trusted automatically. Stay connected while the app runs and confirm incoming files.',
                  ),
                  const Divider(),
                  if (transfer != null) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(transfer.name),
                      subtitle: Text('${transfer.peer.name} · ${transfer.size.asReadableFileSize}'),
                    ),
                    if (transfer.phase == RemotePhase.offered)
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(onPressed: () => client!.decide(true), child: Text(t.general.accept)),
                          OutlinedButton(onPressed: () => client!.decide(false), child: Text(t.general.decline)),
                        ],
                      )
                    else ...[
                      LinearProgressIndicator(value: transfer.size == 0 ? null : transfer.transferred / transfer.size),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(onPressed: client!.cancel, child: Text(t.general.cancel)),
                      ),
                    ],
                  ],
                  if (client?.savedPath case final saved?)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.general.open),
                      subtitle: Text(saved),
                      onTap: () => saved_file.openFile(context, saved.guessFileType(), saved),
                    ),
                  for (final peer in (client?.peers ?? settings.peers).values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.devices),
                      title: Text(peer.name),
                      subtitle: Text(
                        nearby[peer.lanFingerprint]?.https == true
                            ? 'Local network'
                            : client?.online.containsKey(peer.id) == true
                            ? 'Online via relay'
                            : 'Offline',
                      ),
                      onTap: busy ? null : () => _send(peer),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InputDialog extends StatefulWidget {
  final String title;
  final String label;
  final String initial;

  const _InputDialog({required this.title, required this.label, required this.initial});

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(t.general.cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Save')),
    ],
  );
}
