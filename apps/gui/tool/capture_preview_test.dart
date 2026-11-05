// Optional local visual QA. Uses a system font only when explicitly available;
// not part of portable CI and never reads a real vault.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kagi_gui/main.dart';
import 'package:kagi_gui/core/client.dart';

void main() {
  testWidgets('capture desktop and phone fake layouts', (tester) async {
    final font = File('/System/Library/Fonts/Hiragino Sans GB.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('SF Pro Text')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await tester.runAsync(loader.load);
    }
    for (final entry in {
      'monospace': '/System/Library/Fonts/SFNSMono.ttf',
      'MaterialIcons': 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (file.existsSync()) {
        final loader = FontLoader(entry.key)
          ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        await tester.runAsync(loader.load);
      }
    }
    final root = Directory('.preview');
    root.createSync(recursive: true);
    final capture = GlobalKey();
    for (final size in [const Size(1120, 720), const Size(390, 844)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: KagiApp(initialClient: FakeKagiClient()),
        ),
      );
      await tester.pumpAndSettle();
      if (size.width < 700) {
        final listBoundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await listBoundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('${root.path}/phone-list.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.byKey(const Key('item-google/authenticator')));
        await tester.pumpAndSettle();
      }
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${root.path}/${size.width > 700 ? 'desktop' : 'phone'}.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
