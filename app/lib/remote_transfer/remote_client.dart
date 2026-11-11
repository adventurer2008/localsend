import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/remote_transfer/remote_session.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _chunkSize = 256 * 1024;
const _maxChunkWindow = 8;
const _maxFileSize = 1 << 40;
const _maxFiles = 10000;
final _sessionId = RegExp(r'^[a-f0-9]{32}$');

enum RemotePhase { waiting, offered, receiving, awaitingAck, awaitingReceipt }

typedef RemoteFileSource = ({XFile file, String name});
typedef _OutgoingFile = ({XFile file, String name, int size});

class RemoteTransfer {
  final RemoteSession session;
  final RemotePeer peer;
  final String? fileName;
  final int fileCount;
  final int size;
  final List<_OutgoingFile> _files;
  RemotePhase phase;
  int transferred = 0;
  final _pendingChunks = Queue<int>();
  int _fileIndex = 0;
  int _fileOffset = 0;
  bool _headerSent = false;
  final _receivedNames = <String>[];
  final _usedNames = <String>{};
  final _duplicateNumbers = <String, int>{};
  int _remainingInFile = 0;
  Directory? staging;
  RandomAccessFile? writer;

  RemoteTransfer(this.session, this.peer, this.fileName, this.fileCount, this.size, this.phase, [this._files = const []]);

  String get name => fileName ?? '$fileCount files';

  Future<void> dispose() async {
    try {
      await writer?.close();
    } finally {
      final dir = staging;
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

class RemoteClient extends ChangeNotifier {
  final RemoteIdentity identity;
  final Uri uri;
  final Map<String, RemotePeer> peers;
  final String? localCard;
  final Future<void> Function(Iterable<RemotePeer>)? onDirectory;
  final Future<Directory> Function() documentsDirectory;
  final _epoch = encodeRemoteBytes(remoteRandomBytes(16));
  final _seenOffers = <String>{};
  WebSocket? _socket;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  int _chunkWindow = 1;
  bool connected = false;
  bool automaticTrust = false;
  String status = 'Connecting…';
  List<String> savedPaths = const [];
  String? get savedPath => savedPaths.firstOrNull;
  Map<String, String> online = {};
  RemoteTransfer? transfer;

  RemoteClient({
    required this.identity,
    required this.uri,
    required Map<String, RemotePeer> peers,
    this.localCard,
    this.onDirectory,
    this.documentsDirectory = getApplicationDocumentsDirectory,
  }) : peers = Map.of(peers);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _queue(Future<void> Function() task) {
    final next = _tail.then((_) async {
      if (!_disposed) await task();
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> run() async {
    HttpClient? http;
    Timer? loginTimer;
    WebSocket? socket;
    try {
      // A direct TLS connection avoids routing remote-device sessions through
      // a machine-wide HTTP proxy. The platform TLS trust store is still used.
      http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..findProxy = ((_) => 'DIRECT');
      socket = await WebSocket.connect(uri.toString(), customClient: http).timeout(const Duration(seconds: 12));
      if (_disposed) return;
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 30);
      loginTimer = Timer(const Duration(seconds: 10), () {
        if (!connected) unawaited(socket?.close());
      });
      await for (final raw in socket) {
        await _queue(() async {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          await _handle(frame);
        });
      }
      if (!_disposed) {
        status = connected ? 'Relay disconnected' : 'Relay refused the connection. Check the server allowlist and device ID.';
      }
    } catch (_) {
      status = connected ? 'Relay connection failed' : 'Could not connect to the relay. Check its URL and TLS certificate.';
    } finally {
      loginTimer?.cancel();
      http?.close(force: true);
      if (socket != null) unawaited(socket.close());
      await _queue(() async {
        connected = false;
        online = {};
        await _clearTransfer();
        _changed();
      });
    }
  }

  void _write(Map<String, Object> frame) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) throw const SocketException('Relay disconnected');
    socket.add(jsonEncode(frame));
  }

  Future<void> disconnect() async {
    await _socket?.close();
  }

  Future<void> offer(RemotePeer peer, XFile file, {String? fileName, Directory? staging}) =>
      offerFiles(peer, [(file: file, name: fileName ?? file.name)], staging: staging);

  Future<void> offerFiles(RemotePeer peer, List<RemoteFileSource> sources, {Directory? staging}) async {
    var started = false;
    await _queue(() async {
      final peerEpoch = online[peer.id];
      if (!connected || transfer != null || peerEpoch == null) throw StateError('Device is offline or busy');
      if (sources.isEmpty || sources.length > _maxFiles) throw StateError('Select between 1 and $_maxFiles files');
      final files = <_OutgoingFile>[];
      var totalSize = 0;
      for (final source in sources) {
        final name = safeRemoteFileName(source.name);
        final size = await source.file.length();
        if (size < 0 || size > _maxFileSize - totalSize) throw StateError('Unsupported transfer size');
        totalSize += size;
        files.add((file: source.file, name: name, size: size));
      }
      final id = remoteRandomBytes(16).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final key = await identity.transferKey(peer, identity.id, peer.id, id, peerEpoch);
      final session = RemoteSession(id, identity.id, peer.id, key);
      final name = files.length == 1 ? files.single.name : null;
      final metadata = name == null ? {'fileCount': files.length, 'size': totalSize} : {'name': name, 'size': totalSize};
      final offer = await session.seal('offer', utf8.encode(jsonEncode(metadata)));
      _write({...offer, 'to': peer.id, 'epoch': peerEpoch});
      transfer = RemoteTransfer(session, peer, name, files.length, totalSize, RemotePhase.waiting, files)..staging = staging;
      started = true;
      status = 'Waiting for ${peer.name} to accept';
      _changed();
    });
    if (!started) throw StateError('Relay disconnected');
  }

  Future<void> decide(bool accept) => _queue(() async {
    final current = transfer;
    if (current == null || current.phase != RemotePhase.offered) return;
    try {
      if (accept) {
        final documents = await documentsDirectory();
        final root = await Directory(p.join(documents.path, 'LocalSend Remote')).create(recursive: true);
        current.staging = await root.createTemp('.receiving-');
        if (current.fileName case final name?) {
          await _openIncomingFile(current, name, current.size);
        }
        current.phase = RemotePhase.receiving;
        _write(await current.session.seal('accept'));
        status = 'Receiving ${current.name}';
      } else {
        _write(await current.session.seal('decline'));
        await _clearTransfer();
        status = 'Transfer declined';
      }
    } catch (_) {
      await _abort(current, 'Could not accept and save the transfer');
    }
    _changed();
  });

  Future<void> cancel() => _queue(() async {
    final current = transfer;
    if (current != null) await _abort(current, 'Transfer cancelled');
  });

  Future<void> _handle(Map<String, dynamic> frame) async {
    switch (frame['type']) {
      case 'challenge' when !connected:
        final signature = await identity.signChallenge(frame['nonce'] as String, _epoch);
        final payload = <String, Object>{
          'type': 'auth',
          'id': identity.id,
          'epoch': _epoch,
          'signature': signature,
        };
        final card = localCard;
        if (card != null) {
          payload['card'] = card;
          payload['cardSignature'] = await identity.signCard(card);
        }
        _write(payload);
      case 'ready' when !connected:
        automaticTrust = frame['directoryVersion'] == 1;
        final window = frame['chunkWindow'];
        // Older relays require an ACK before they will forward the next chunk.
        _chunkWindow = window is int && window >= 1 && window <= _maxChunkWindow ? window : 1;
        connected = true;
        status = 'Connected to relay';
      case 'peers' when connected:
        if (automaticTrust) {
          final entries = frame['directory'] as List;
          if (entries.length > 32) throw const FormatException('Device directory too large');
          final trusted = <String, RemotePeer>{};
          for (final entry in entries) {
            final peer = await RemoteIdentity.verifyCard(entry as Map<String, dynamic>);
            if (peer.id != identity.id) trusted[peer.id] = peer;
          }
          peers
            ..clear()
            ..addAll(trusted);
          await onDirectory?.call(peers.values);
          final current = transfer;
          if (current != null && !peers.containsKey(current.peer.id)) await _abort(current, 'Device is no longer trusted');
        }
        online = {
          for (final entry in (frame['online'] as List).cast<Map<String, dynamic>>())
            if (peers.containsKey(entry['id'])) entry['id'] as String: entry['epoch'] as String,
        };
      case 'offer' when connected:
        await _receiveOffer(frame);
      default:
        final current = transfer;
        if (current == null || current.session.id != frame['session']) return;
        if (frame['type'] == 'aborted') {
          status = frame['reason'] as String;
          await _clearTransfer();
        } else {
          try {
            await _receiveFrame(current, frame);
          } catch (_) {
            await _abort(current, 'Transfer failed. Check the device pairing, file, and storage.');
          }
        }
    }
    _changed();
  }

  Future<void> _receiveOffer(Map<String, dynamic> frame) async {
    final id = frame['session'] as String;
    final peer = peers[frame['from']];
    if (!_sessionId.hasMatch(id)) throw const FormatException('Invalid transfer ID');
    try {
      if (transfer != null || peer == null || _seenOffers.contains(id)) throw StateError('Untrusted or duplicate transfer');
      if (_seenOffers.length >= 2048) throw StateError('Reconnect to start a new transfer');
      final key = await identity.transferKey(peer, peer.id, identity.id, id, _epoch);
      final session = RemoteSession(id, identity.id, peer.id, key);
      final meta = jsonDecode(utf8.decode(await session.open(frame))) as Map<String, dynamic>;
      final size = meta['size'] as int;
      if (size < 0 || size > _maxFileSize) throw const FormatException('Unsupported file size');
      final fileCount = meta['fileCount'] as int?;
      if (fileCount != null && (fileCount < 2 || fileCount > _maxFiles || meta.containsKey('name'))) {
        throw const FormatException('Invalid file count');
      }
      final name = fileCount == null ? safeRemoteFileName(meta['name'] as String) : null;
      _seenOffers.add(id);
      transfer = RemoteTransfer(session, peer, name, fileCount ?? 1, size, RemotePhase.offered);
      status = '${peer.name} wants to send ${fileCount == null ? 'a file' : '$fileCount files'}';
    } catch (_) {
      // Unknown peers, modified offers and replays never reach the confirmation UI.
      _write({'type': 'abort', 'session': id});
    }
  }

  Future<void> _receiveFrame(RemoteTransfer current, Map<String, dynamic> frame) async {
    final bytes = await current.session.open(frame);
    final type = frame['type'];
    if (type != 'chunk' && bytes.isNotEmpty) throw const FormatException('Unexpected control data');
    switch ((current.phase, type)) {
      case (RemotePhase.waiting, 'accept'):
        await _fillWindow(current);
      case (RemotePhase.awaitingAck, 'ack'):
        // ACKs are ordered and sent only after the receiver writes the chunk.
        if (current._pendingChunks.isEmpty) throw const FormatException('Unexpected chunk acknowledgement');
        current.transferred += current._pendingChunks.removeFirst();
        await _fillWindow(current);
      case (RemotePhase.waiting, 'decline'):
        await _clearTransfer();
        status = '${current.peer.name} declined the transfer';
      case (RemotePhase.receiving, 'chunk'):
        if (bytes.isEmpty || bytes.length > _chunkSize) {
          throw const FormatException('Invalid chunk length');
        }
        await _receiveChunk(current, bytes);
        _write(await current.session.seal('ack'));
      case (RemotePhase.receiving, 'finish'):
        if (current.transferred != current.size || current._receivedNames.length != current.fileCount || current.writer != null) {
          throw const FormatException('Incomplete transfer');
        }
        final staging = current.staging!;
        final saved = await staging.rename(p.join(staging.parent.path, current.session.id));
        current.staging = null;
        savedPaths = List.unmodifiable(current._receivedNames.map((name) => p.join(saved.path, name)));
        _write(await current.session.seal('receipt'));
        await _clearTransfer();
        status = 'Saved ${current.name}';
      case (RemotePhase.awaitingReceipt, 'receipt'):
        await _clearTransfer();
        status = 'Sent ${current.name} to ${current.peer.name}';
      default:
        throw const FormatException('Unexpected transfer step');
    }
  }

  Future<void> _receiveChunk(RemoteTransfer current, List<int> bytes) async {
    final writer = current.writer;
    if (writer == null) {
      if (current.fileCount == 1 || current._receivedNames.length >= current.fileCount || bytes.length > 4096) {
        throw const FormatException('Unexpected file header');
      }
      final header = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final size = header['size'] as int;
      if (size < 0 || size > current.size - current.transferred) throw const FormatException('Invalid file size');
      await _openIncomingFile(current, safeRemoteFileName(header['name'] as String), size);
      return;
    }
    if (bytes.length > current._remainingInFile) throw const FormatException('Invalid chunk length');
    await writer.writeFrom(bytes);
    current.transferred += bytes.length;
    current._remainingInFile -= bytes.length;
    if (current._remainingInFile == 0) {
      await writer.close();
      current.writer = null;
    }
  }

  Future<void> _openIncomingFile(RemoteTransfer current, String name, int size) async {
    final directory = current.staging!.path;
    var uniqueName = name;
    final normalized = name.toLowerCase();
    var number = current._duplicateNumbers[normalized] ?? 1;
    while (current._usedNames.contains(uniqueName.toLowerCase()) || await File(p.join(directory, uniqueName)).exists()) {
      final suffix = ' (${++number})';
      final extension = p.extension(name);
      uniqueName = '${p.basenameWithoutExtension(name)}$suffix$extension';
      if (utf8.encode(uniqueName).length > 255) uniqueName = '${String.fromCharCodes(name.runes.take(60))}$suffix';
    }
    final file = await File(p.join(directory, uniqueName)).create(exclusive: true);
    current._duplicateNumbers[normalized] = number;
    current._usedNames.add(uniqueName.toLowerCase());
    current._receivedNames.add(uniqueName);
    current._remainingInFile = size;
    if (size > 0) current.writer = await file.open(mode: FileMode.write);
  }

  Future<void> _fillWindow(RemoteTransfer current) async {
    current.phase = RemotePhase.awaitingAck;
    status = 'Sending ${current.name}';
    while (current._pendingChunks.length < _chunkWindow && current._fileIndex < current.fileCount) {
      final file = current._files[current._fileIndex];
      if (current.fileCount > 1 && !current._headerSent) {
        // File headers travel as encrypted chunks so the relay and its window stay unchanged.
        final header = utf8.encode(jsonEncode({'name': file.name, 'size': file.size}));
        _write(await current.session.seal('chunk', header));
        current._pendingChunks.addLast(0);
        current._headerSent = true;
        continue;
      }
      final offset = current._fileOffset;
      if (offset == file.size) {
        if (await file.file.length() != file.size) throw StateError('Source file size changed');
        current._fileIndex++;
        current._fileOffset = 0;
        current._headerSent = false;
        continue;
      }
      final end = offset + _chunkSize < file.size ? offset + _chunkSize : file.size;
      final buffer = BytesBuilder(copy: false);
      await for (final bytes in file.file.openRead(offset, end)) {
        if (buffer.length + bytes.length > end - offset) throw StateError('Source file changed');
        buffer.add(bytes);
      }
      if (buffer.length != end - offset) throw StateError('Source file changed');
      _write(await current.session.seal('chunk', buffer.takeBytes()));
      current._fileOffset = end;
      current._pendingChunks.addLast(end - offset);
    }
    if (current._fileIndex == current.fileCount && current._pendingChunks.isEmpty) {
      current.phase = RemotePhase.awaitingReceipt;
      _write(await current.session.seal('finish'));
      status = 'Waiting for delivery confirmation';
    }
  }

  Future<void> _abort(RemoteTransfer current, String reason) async {
    if (_socket?.readyState == WebSocket.open) _write({'type': 'abort', 'session': current.session.id});
    await _clearTransfer();
    status = reason;
    _changed();
  }

  Future<void> _clearTransfer() async {
    final current = transfer;
    transfer = null;
    try {
      await current?.dispose();
    } on FileSystemException catch (error) {
      debugPrint('Could not remove relay staging file: ${error.osError?.errorCode}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final socket = _socket;
    if (socket != null) unawaited(socket.close());
    unawaited(_tail.whenComplete(_clearTransfer));
    super.dispose();
  }
}

String safeRemoteFileName(String name) {
  final forbidden = RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]');
  final value = name.replaceAll(forbidden, '_').replaceAll(RegExp(r'[ .]+$'), '').trimLeft();
  if (value.isEmpty || value.length > 180) throw const FormatException('Invalid filename');
  final reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)', caseSensitive: false);
  return reserved.hasMatch(value) ? '_$value' : value;
}
