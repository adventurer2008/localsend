import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/remote_transfer/remote_identity.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:refena_flutter/refena_flutter.dart';

Future<bool> canTryLan() async {
  if (kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS)) return true;
  try {
    final networks = await Connectivity().checkConnectivity();
    if (networks.contains(ConnectivityResult.wifi) || networks.contains(ConnectivityResult.ethernet)) return true;
    // A VPN can hide the underlying Wi-Fi transport from connectivity_plus.
    if (defaultTargetPlatform == TargetPlatform.android) return await hasLocalNetworkTransportAndroid();
    final info = NetworkInfo();
    return await info.getWifiIP() != null || await info.getWifiIPv6() != null;
  } catch (_) {
    // Let the pinned LAN probe decide when the platform cannot report the network.
    return true;
  }
}

Future<Device?> reachableTrustedLan(Ref ref, RemotePeer peer, {Device? candidate, bool discover = false}) async {
  if (!await canTryLan()) return null;
  final origin = ref.read(deviceFullInfoProvider);
  if (!origin.https || origin.port < 0) return null;

  Device? nearby() => ref.read(nearbyDevicesProvider).devices[peer.lanFingerprint];
  final known = candidate ?? nearby();
  if (known != null && await _probeLan(ref, origin, known, peer)) return known;
  if (!discover) return null;

  await scanTrustedLan(ref);
  final discovered = nearby();
  if (discovered == null || (discovered.ip == known?.ip && discovered.port == known?.port)) return null;
  return await _probeLan(ref, origin, discovered, peer) ? discovered : null;
}

Future<void> scanTrustedLan(Ref ref) async {
  try {
    await ref.global.dispatchAsync(StartSmartScan()).timeout(const Duration(seconds: 2));
  } catch (_) {
    // Local discovery is optional for a relay transfer.
  }
}

Future<bool> _probeLan(Ref ref, Device origin, Device target, RemotePeer peer) async {
  if (target.ip == null || !target.https || target.fingerprint != peer.lanFingerprint) return false;
  final client = ref.read(httpProvider).pinnedTo(peer.lanFingerprint, timeoutMs: 2000);
  try {
    await client.register(protocol: target.getProtocolType(), ip: target.ip!, port: target.port, payload: origin.toRegisterDto());
    return true;
  } catch (_) {
    return false;
  } finally {
    client.dispose();
  }
}
