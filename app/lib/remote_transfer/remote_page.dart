import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/remote_transfer/remote_client.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/remote_transfer/remote_route.dart';
import 'package:localsend_app/remote_transfer/remote_runtime.dart';
import 'package:localsend_app/remote_transfer/remote_settings.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/open_file.dart' as saved_file;
import 'package:localsend_app/widget/device_drop_target.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uri_content/uri_content.dart';

String remoteTransferLabel(BuildContext context) => Localizations.localeOf(context).languageCode == 'zh' ? '可信设备' : 'Trusted devices';

class RemotePage extends StatefulWidget {
  final List<CrossFile> selectedFiles;
  final RemotePeer? relayTarget;

  const RemotePage({this.selectedFiles = const [], this.relayTarget, super.key});

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
      if (widget.relayTarget case final target?) {
        unawaited(_send(target, relayOnly: true));
      } else if (await canTryLan() && mounted) {
        unawaited(scanTrustedLan(context.ref));
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the device’s secure storage');
    }
  }

  void _runtimeChanged() {
    if (mounted) setState(() {});
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

  Future<void> _send(RemotePeer peer, {bool relayOnly = false, List<CrossFile>? droppedFiles}) async {
    if (_choosing || _client?.transfer != null) return;
    final ref = context.ref;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    setState(() {
      _choosing = true;
      _error = null;
    });
    try {
      final files = droppedFiles ?? widget.selectedFiles;
      final file = files.isEmpty ? await openFile() : null;
      if ((file == null && files.isEmpty) || !mounted) return;
      final local = relayOnly ? null : await reachableTrustedLan(ref, peer, discover: true);
      if (!mounted) return;
      if (_client?.transfer != null) throw StateError('Finish the current transfer first');
      if (local != null) {
        final selected = file == null ? files : [await CrossFileConverters.convertXFile(file)];
        if (!mounted) return;
        await ref.notifier(sendProvider).startSession(target: local, files: selected, background: false);
      } else {
        if (files.length > 1) {
          throw StateError(zh ? '中继目前一次只能发一个文件，请选一个文件重试。' : 'The relay supports one file per transfer. Select a single file and retry.');
        }
        final client = await _runtime!.waitForPeer(peer.id);
        if (!mounted) return;
        if (client == null) throw StateError(zh ? '对方未连接到中继' : 'This device is offline on the relay');
        if (file != null) {
          await client.offer(peer, file);
        } else {
          await _offerSelected(client, peer, files.single);
        }
      }
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = zh ? '无法开始传输' : 'Could not start the transfer');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _offerSelected(RemoteClient client, RemotePeer peer, CrossFile selected) async {
    if (selected.bytes case final bytes?) {
      await client.offer(peer, XFile.fromData(Uint8List.fromList(bytes), name: selected.name), fileName: selected.name);
      return;
    }
    final path = selected.path!;
    if (!path.startsWith('content://')) {
      await client.offer(peer, XFile(path), fileName: selected.name);
      return;
    }
    // The Android document picker can return a URI rather than a filesystem path.
    // Stage it on disk so the relay can read chunks without loading the file in memory.
    final staging = await (await getTemporaryDirectory()).createTemp('localsend-relay-');
    final file = File(p.join(staging.path, 'source'));
    try {
      await UriContent().getContentStream(Uri.parse(path)).cast<List<int>>().pipe(file.openWrite());
      if (mounted) {
        await client.offer(peer, XFile(file.path), fileName: selected.name, staging: staging);
        return;
      }
    } catch (_) {
      await staging.delete(recursive: true);
      rethrow;
    }
    await staging.delete(recursive: true);
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

    final page = Scaffold(
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
                  if (Platform.isWindows && _runtime!.peers.isNotEmpty) const DeviceDropHint(),
                  for (final peer in _runtime!.peers.values)
                    DeviceDropTarget(
                      onDrop: busy ? null : (files) => _send(peer, droppedFiles: files),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.devices),
                        title: Text(peer.name),
                        subtitle: Text(
                          client?.online.containsKey(peer.id) == true
                              ? 'Online via relay'
                              : nearby[peer.lanFingerprint]?.https == true
                              ? 'Discovered on local network'
                              : 'Offline',
                        ),
                        onTap: busy ? null : () => _send(peer),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return Platform.isWindows ? DropTarget(onDragDone: (event) async => DeviceDropTarget.sendDroppedFiles(context, event), child: page) : page;
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
