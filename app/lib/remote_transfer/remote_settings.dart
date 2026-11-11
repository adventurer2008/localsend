import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RemoteSettings {
  static const _urlKey = 'remoteTransfer.relayUrl';
  static const _peersKey = 'remoteTransfer.peers';

  final SharedPreferences _prefs;

  RemoteSettings._(this._prefs);

  static Future<RemoteSettings> load() async => RemoteSettings._(await SharedPreferences.getInstance());

  String get url => _prefs.getString(_urlKey) ?? '';

  Map<String, RemotePeer> get peers {
    final result = <String, RemotePeer>{};
    for (final card in _prefs.getStringList(_peersKey) ?? const <String>[]) {
      try {
        final peer = RemotePeer.parse(card);
        result[peer.id] = peer;
      } on FormatException {
        // Ignore a malformed persisted card.
      }
    }
    return result;
  }

  static Uri relayUri(String text) {
    final uri = Uri.parse(text.trim());
    if (uri.scheme != 'wss' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment || uri.path != '/v1/relay') {
      throw const FormatException('Use a wss:// server URL ending in /v1/relay');
    }
    return uri;
  }

  Future<void> setUrl(String value) async {
    final normalized = relayUri(value).toString();
    if (url != normalized) await setPeers(const []);
    final saved = await _prefs.setString(_urlKey, normalized);
    if (!saved) throw StateError('Could not save relay URL');
  }

  Future<void> setPeers(Iterable<RemotePeer> peers) async {
    final saved = await _prefs.setStringList(_peersKey, peers.map((peer) => peer.card).toList());
    if (!saved) throw StateError('Could not save trusted devices');
  }
}
