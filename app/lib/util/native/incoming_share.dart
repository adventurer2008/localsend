import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/remote_transfer/remote_runtime.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_foundation/path_provider_foundation.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('IncomingShare');
AppLifecycleListener? _listener;
Future<bool> _pending = Future.value(false);

Future<bool> startIncomingShares(BuildContext context, Ref ref) {
  final android = defaultTargetPlatform == TargetPlatform.android;

  Future<bool> schedule() {
    return _pending = _pending.then((_) async {
      try {
        final batches = android
            ? (await takeIncomingSharesAndroid()).whereType<Map<Object?, Object?>>().map((data) => _ShareBatch.fromMap(data))
            : await _readIosInbox();
        var received = false;
        for (final batch in batches) {
          received = true;
          var failed = batch.failed;
          final files = <CrossFile>[];
          for (final path in batch.paths) {
            try {
              files.add(await CrossFileConverters.convertFile(File(path)));
            } catch (error) {
              _logger.warning('Could not open a shared file', error);
              failed++;
            }
          }
          if (files.isNotEmpty) {
            await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddFilesAction(files: files, converter: Future.value));
          }
          final text = batch.text?.trim();
          if (text != null && text.isNotEmpty) {
            ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: text));
          }
          if (files.isNotEmpty || (text?.isNotEmpty ?? false)) {
            ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
            if (context.mounted &&
                ref.read(sendProvider).isEmpty &&
                ref.read(serverProvider)?.session == null &&
                ref.read(remoteRuntimeProvider).client?.transfer == null) {
              final home = ModalRoute.of(context);
              if (home != null && !home.isCurrent) {
                Navigator.of(context).popUntil((route) => route == home);
              }
            }
          }
          if (failed > 0 && context.mounted) {
            final zh = Localizations.localeOf(context).languageCode == 'zh';
            context.showSnackBar(zh ? '有 $failed 项共享内容无法读取。' : 'Could not read $failed shared item(s).');
          }
          await batch.manifest?.delete();
        }
        return received;
      } catch (error, stackTrace) {
        _logger.warning('Could not import shared items', error, stackTrace);
        return false;
      }
    });
  }

  if (android) {
    listenForIncomingSharesAndroid(() => unawaited(schedule()));
  } else {
    _listener?.dispose();
    _listener = AppLifecycleListener(onResume: () => unawaited(schedule()));
  }
  return schedule();
}

class _ShareBatch {
  final List<String> paths;
  final String? text;
  final int failed;
  final File? manifest;

  _ShareBatch.fromMap(Map<Object?, Object?> data, {this.manifest})
    : paths = (data['paths'] as List).cast<String>().map((path) {
        final directory = manifest?.parent.path;
        if (directory == null) return path;
        final absolute = p.normalize(p.join(directory, path));
        if (!p.isWithin(directory, absolute)) throw const FormatException('Invalid share attachment path');
        return absolute;
      }).toList(),
      text = data['text'] as String?,
      failed = data['failed'] as int? ?? 0;
}

Future<List<_ShareBatch>> _readIosInbox() async {
  final path = await PathProviderFoundation().getContainerPath(appGroupIdentifier: 'group.org.localsend.localsendApp');
  if (path == null) return [];
  final inbox = Directory(p.join(path, 'IncomingShares'));
  if (!await inbox.exists()) return [];
  final batches = <_ShareBatch>[];
  await for (final entry in inbox.list(followLinks: false)) {
    if (entry is! Directory || p.basename(entry.path).startsWith('.')) continue;
    final manifest = File(p.join(entry.path, 'manifest.json'));
    if (!await manifest.exists()) continue;
    try {
      batches.add(_ShareBatch.fromMap(jsonDecode(await manifest.readAsString()) as Map<String, dynamic>, manifest: manifest));
    } catch (error) {
      _logger.warning('Invalid share inbox item', error);
    }
  }
  return batches;
}
