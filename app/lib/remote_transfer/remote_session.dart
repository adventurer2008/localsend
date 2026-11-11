import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';

/// Each direction has its own sequence. The authenticated data binds the
/// payload to the session, peer, direction and protocol step.
class RemoteSession {
  static final _cipher = AesGcm.with256bits();

  final String id;
  final String localId;
  final String peerId;
  final SecretKey key;
  int _sendSequence = 0;
  int _receiveSequence = 0;

  RemoteSession(this.id, this.localId, this.peerId, this.key);

  List<int> _aad(String type, String from, String to, int seq) => utf8.encode('localsend-relay/frame/v1:$id:$from:$to:$type:$seq');

  Future<Map<String, Object>> seal(String type, [List<int> bytes = const []]) async {
    final seq = _sendSequence++;
    final box = await _cipher.encrypt(bytes, secretKey: key, aad: _aad(type, localId, peerId, seq));
    return {
      'type': type,
      'session': id,
      'seq': seq,
      'body': encodeRemoteBytes(box.concatenation()),
    };
  }

  Future<List<int>> open(Map<String, dynamic> frame) async {
    final type = frame['type'] as String;
    final seq = frame['seq'] as int;
    if (frame['from'] != peerId || frame['session'] != id || seq != _receiveSequence) {
      throw const FormatException('Unexpected relay frame');
    }
    final body = decodeRemoteBytes(frame['body'] as String);
    if (body.length < 28) throw const FormatException('Truncated relay frame');
    final bytes = await _cipher.decrypt(
      SecretBox.fromConcatenation(body, nonceLength: 12, macLength: 16, copy: false),
      secretKey: key,
      aad: _aad(type, peerId, localId, seq),
    );
    _receiveSequence++;
    return bytes;
  }
}
