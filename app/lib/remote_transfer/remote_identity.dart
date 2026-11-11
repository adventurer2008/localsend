import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

String encodeRemoteBytes(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

Uint8List decodeRemoteBytes(String value, [int? length]) {
  final bytes = base64Url.decode(base64Url.normalize(value));
  if ((length != null && bytes.length != length) || encodeRemoteBytes(bytes) != value) {
    throw const FormatException('Invalid relay encoding');
  }
  return bytes;
}

Uint8List remoteRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

class RemotePeer {
  final String name;
  final String id;
  final String encryptionKey;
  final String lanFingerprint;

  const RemotePeer(this.name, this.id, this.encryptionKey, this.lanFingerprint);

  factory RemotePeer.parse(String card) {
    final fields = card.trim().split('.');
    if (fields.length != 5 || fields.first != 'lsr1' || !RegExp(r'^[A-Fa-f0-9]{64}$').hasMatch(fields[4])) {
      throw const FormatException('Invalid device card');
    }
    final name = utf8.decode(decodeRemoteBytes(fields[1]));
    if (name.trim().isEmpty || name.length > 64 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('Invalid device name');
    }
    decodeRemoteBytes(fields[2], 32);
    decodeRemoteBytes(fields[3], 32);
    return RemotePeer(name, fields[2], fields[3], fields[4].toUpperCase());
  }

  String get card => 'lsr1.${encodeRemoteBytes(utf8.encode(name))}.$id.$encryptionKey.$lanFingerprint';
}

class RemoteIdentity {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
  );
  static const _storageKey = 'localsend.remote.v1.identity';
  static Future<RemoteIdentity>? _loaded;
  static final _signing = Ed25519();
  static final _exchange = X25519();

  final SimpleKeyPair _signingKey;
  final SimpleKeyPair _exchangeKey;
  final String id;
  final String encryptionKey;

  const RemoteIdentity._(this._signingKey, this._exchangeKey, this.id, this.encryptionKey);

  static Future<RemoteIdentity> load() async {
    try {
      return await (_loaded ??= _load());
    } catch (_) {
      _loaded = null;
      rethrow;
    }
  }

  static Future<RemoteIdentity> _load() async {
    final stored = await _storage.read(key: _storageKey);
    final seed = stored == null ? remoteRandomBytes(64) : decodeRemoteBytes(stored, 64);
    if (stored == null) await _storage.write(key: _storageKey, value: encodeRemoteBytes(seed));
    return fromSeed(seed);
  }

  static Future<RemoteIdentity> fromSeed(Uint8List seed) async {
    if (seed.length != 64) throw ArgumentError.value(seed.length, 'seed length');
    final signingKey = await _signing.newKeyPairFromSeed(seed.sublist(0, 32));
    final exchangeKey = await _exchange.newKeyPairFromSeed(seed.sublist(32));
    return RemoteIdentity._(
      signingKey,
      exchangeKey,
      encodeRemoteBytes((await signingKey.extractPublicKey()).bytes),
      encodeRemoteBytes((await exchangeKey.extractPublicKey()).bytes),
    );
  }

  String card(String name, String lanFingerprint) {
    final sanitized = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    final limited = String.fromCharCodes(sanitized.runes.take(32));
    return RemotePeer(limited.isEmpty ? 'LocalSend' : limited, id, encryptionKey, lanFingerprint).card;
  }

  Future<String> signChallenge(String nonce, String epoch) async {
    decodeRemoteBytes(nonce, 32);
    final signature = await _signing.sign(utf8.encode('localsend-relay/auth/v1:$nonce:$epoch'), keyPair: _signingKey);
    return encodeRemoteBytes(signature.bytes);
  }

  Future<SecretKey> transferKey(RemotePeer peer, String sender, String receiver, String session, String receiverEpoch) async {
    final shared = await _exchange.sharedSecretKey(
      keyPair: _exchangeKey,
      remotePublicKey: SimplePublicKey(decodeRemoteBytes(peer.encryptionKey, 32), type: KeyPairType.x25519),
    );
    if ((await shared.extractBytes()).every((byte) => byte == 0)) throw const FormatException('Invalid peer encryption key');
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: decodeRemoteBytes(receiverEpoch, 16),
      info: utf8.encode('localsend-relay/transfer/v1:$sender:$receiver:$session'),
    );
  }
}
