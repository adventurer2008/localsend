// ignore_for_file: discarded_futures, unawaited_futures

import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:localsend_isolates/util/logger.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

final _logger = Logger('ClearCacheAction');

/// Clears the cache.
/// It runs on a separate isolate to avoid blocking the UI.
class ClearCacheAction extends AsyncGlobalAction {
  @override
  Future<void> reduce() async {
    // The token statement must be outside the lambda because it must be executed on the root isolate.
    final token = ServicesBinding.rootIsolateToken!;
    await Isolate.run(() => _clear(token));
  }
}

Future<void> _clear(RootIsolateToken token) async {
  initLogger(Level.ALL);
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);

  final futures = (
    FilePicker.clearTemporaryFiles(),
    PhotoManager.clearFileCache(),
    checkPlatform([TargetPlatform.iOS, TargetPlatform.android])
        ? getTemporaryDirectory().then((cacheDir) async {
            await for (final event in cacheDir.list(followLinks: false)) {
              if (event is File) {
                event.delete().then((_) {}).catchError((error) {
                  _logger.warning('Failed to delete file: $error');
                });
              } else if (event is Directory && p.basename(event.path) == 'incoming-share') {
                await _clearStaleShares(event);
              }
            }
          })
        : Future.value(),
    checkPlatform([TargetPlatform.iOS])
        ? PathProviderFoundation()
              .getContainerPath(
                appGroupIdentifier: 'group.org.localsend.localsendApp',
              )
              .then((directoryPath) async {
                if (directoryPath == null) {
                  _logger.warning('Failed to get app group directory');
                  return;
                }

                final directory = Directory(directoryPath);
                await _clearStaleShares(Directory(p.join(directory.path, 'IncomingShares')), preserveInbox: true);

                // delete contents of the directory (only files, not directories)
                await for (final entry in directory.list(recursive: false, followLinks: false)) {
                  if (entry is File && !entry.path.fileName.startsWith('.')) {
                    _logger.info('Deleting ${entry.path}');
                    entry.deleteSync();
                  }
                }
              })
        : Future.value(),
  ).wait;

  try {
    await futures;
  } catch (e) {
    _logger.warning('Failed to clear cache: $e');
  }
}

Future<void> _clearStaleShares(Directory root, {bool preserveInbox = false}) async {
  if (!await root.exists()) return;
  final cutoff = DateTime.now().subtract(const Duration(days: 1));
  await for (final entry in root.list(followLinks: false)) {
    if (entry is! Directory || !(await entry.stat()).modified.isBefore(cutoff)) continue;
    if (preserveInbox && await File(p.join(entry.path, 'manifest.json')).exists()) continue;
    await entry.delete(recursive: true);
  }
}
