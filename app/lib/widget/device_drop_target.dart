import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:logging/logging.dart';

final _logger = Logger('DeviceDropTarget');

/// Marks a device tile for the enclosing page's native drop handler.
class DeviceDropTarget extends StatelessWidget {
  final Future<void> Function(List<CrossFile>)? onDrop;
  final Widget child;

  const DeviceDropTarget({required this.onDrop, required this.child, super.key});

  static Future<bool> sendDroppedFiles(BuildContext context, DropDoneDetails event) async {
    if (!Platform.isWindows || ModalRoute.isCurrentOf(context) != true) return false;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, event.globalPosition, View.of(context).viewId);
    for (final hit in result.path) {
      if (hit.target case RenderMetaData(metaData: DeviceDropTarget(:final onDrop))) {
        if (onDrop != null && event.files.isNotEmpty) {
          try {
            final files = <String, CrossFile>{};
            for (final item in event.files) {
              final dropped = await Directory(item.path).exists()
                  ? await readDirectoryForSending(item.path)
                  : [await CrossFileConverters.convertXFile(item)];
              for (final file in dropped) {
                files[file.path!] = file;
              }
            }
            if (context.mounted && ModalRoute.isCurrentOf(context) == true && files.isNotEmpty) {
              await onDrop(files.values.toList());
            }
          } catch (error, stackTrace) {
            _logger.warning('Could not send dropped files', error, stackTrace);
            if (context.mounted && ModalRoute.isCurrentOf(context) == true) {
              final zh = Localizations.localeOf(context).languageCode == 'zh';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(zh ? '无法发送拖入的文件' : 'Could not send the dropped files')),
              );
            }
          }
        }
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Platform.isWindows ? MetaData(metaData: this, behavior: HitTestBehavior.opaque, child: child) : child;
}

class DeviceDropHint extends StatelessWidget {
  const DeviceDropHint({super.key});

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Text(
      zh ? '把文件拖到设备上即可发送' : 'Drop files onto a device to send them',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
