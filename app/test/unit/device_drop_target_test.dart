import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/widget/device_drop_target.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';

class _MetadataApi implements RustLibApi {
  @override
  Future<FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('a Windows drop sends only the dropped files to the visible tile under the cursor', (tester) async {
    RustLib.initMock(api: _MetadataApi());
    addTearDown(RustLib.dispose);
    final directory = Directory.systemTemp.createTempSync('localsend-drop-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}drop.txt')..writeAsStringSync('hello');
    final sends = <(String, List<CrossFile>)>[];
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(
              body: Column(
                children: [
                  for (final device in ['First', 'Second'])
                    DeviceDropTarget(
                      onDrop: (files) async => sends.add((device, files)),
                      child: ListTile(title: Text(device)),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );

    Future<bool?> dropAt(Offset position) => tester.runAsync(
      () => DeviceDropTarget.sendDroppedFiles(
        pageContext,
        DropDoneDetails(files: [DropItemFile(file.path)], localPosition: position, globalPosition: position),
      ),
    );

    final secondTile = tester.getCenter(find.text('Second'));
    expect(await dropAt(const Offset(300, 350)), isFalse);
    expect(sends, isEmpty);
    expect(await dropAt(secondTile), isTrue);
    final (device, files) = sends.single;
    expect(device, 'Second');
    expect(files.single.path, file.path);

    final dialog = showDialog<void>(
      context: pageContext,
      builder: (_) => const AlertDialog(title: Text('Dialog')),
    );
    await tester.pumpAndSettle();
    expect(await dropAt(secondTile), isFalse);
    expect(sends, hasLength(1));
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    await dialog;
  }, skip: !Platform.isWindows);
}
