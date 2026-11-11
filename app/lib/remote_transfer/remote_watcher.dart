import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/remote_transfer/remote_client.dart';
import 'package:localsend_app/remote_transfer/remote_page.dart';
import 'package:localsend_app/remote_transfer/remote_runtime.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class RemoteWatcher extends StatefulWidget {
  final Widget child;

  const RemoteWatcher({required this.child, super.key});

  @override
  State<RemoteWatcher> createState() => _RemoteWatcherState();
}

class _RemoteWatcherState extends State<RemoteWatcher> with Refena, WidgetsBindingObserver {
  RemoteRuntime? _runtime;
  String? _shownOffer;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ensureRef((ref) {
      _runtime = ref.read(remoteRuntimeProvider);
      _runtime!.addListener(_onChanged);
      // postInit starts networking once the local HTTP identity is ready.
    });
  }

  void _onChanged() {
    final runtime = _runtime;
    final transfer = runtime?.client?.transfer;
    if (!mounted ||
        runtime == null ||
        transfer?.phase != RemotePhase.offered ||
        runtime.openPages > 0 ||
        _opening ||
        _shownOffer == transfer!.session.id) {
      return;
    }
    _shownOffer = transfer.session.id;
    _opening = true;
    scheduleMicrotask(() {
      if (mounted) unawaited(_openOffer(runtime, transfer.session.id));
    });
  }

  Future<void> _openOffer(RemoteRuntime runtime, String id) async {
    try {
      if (checkPlatformHasTray()) await showFromTray();
      if (!mounted || runtime.openPages > 0 || runtime.client?.transfer?.session.id != id) return;
      final navigatorContext = Routerino.context;
      if (navigatorContext.mounted) await navigatorContext.push(() => const RemotePage());
    } catch (_) {
      debugPrint('Could not open incoming remote transfer confirmation');
    } finally {
      _opening = false;
      _onChanged();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _runtime?.ensureConnected(refresh: defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runtime?.removeListener(_onChanged);
    _runtime?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
