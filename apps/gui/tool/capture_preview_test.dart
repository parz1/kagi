// 本地视觉检查：只用演示库与假数据。字体按候选路径加载（macOS 或 Linux），
// 找不到就跳过；输出目录由 KAGI_SHOTS 指定，默认 .preview。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kagi_gui/main.dart';
import 'package:kagi_gui/core/client.dart';

const sans = [
  '/System/Library/Fonts/PingFang.ttc',
  '/System/Library/Fonts/Hiragino Sans GB.ttc',
  '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
];
const mono = [
  '/System/Library/Fonts/SFNSMono.ttf',
  '/System/Library/Fonts/Menlo.ttc',
  '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
];

Future<void> load(
  WidgetTester tester,
  List<String> paths,
  List<String> families,
) async {
  final path = paths.where((p) => File(p).existsSync()).firstOrNull;
  if (path == null) return;
  final bytes = File(path).readAsBytesSync();
  for (final family in families) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await tester.runAsync(loader.load);
  }
}

void main() {
  testWidgets('capture fake layouts', (tester) async {
    await load(tester, sans, [
      'Roboto',
      '.AppleSystemUIFont',
      'SF Pro Text',
      'PingFang SC',
    ]);
    await load(tester, mono, ['monospace', 'SF Mono', 'Menlo']);
    final icons = File(
      'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await tester.runAsync(loader.load);
    }
    final root = Directory(Platform.environment['KAGI_SHOTS'] ?? '.preview')
      ..createSync(recursive: true);
    final capture = GlobalKey();

    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${root.path}/$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final dark in [false, true]) {
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      final suffix = dark ? '-dark' : '';
      for (final size in [
        const Size(1280, 800),
        const Size(980, 640),
        const Size(390, 844),
      ]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: KagiApp(initialClient: FakeKagiClient()),
          ),
        );
        await tester.pumpAndSettle();
        final phone = size.width < 700;
        if (size.width < 1200 && !phone) {
          await tester.tap(find.byKey(const Key('item-google/authenticator')));
          await shot('compact$suffix');
          continue;
        }
        if (!phone) {
          await shot('desktop$suffix');
          await tester.tap(find.byKey(const Key('item-google/authenticator')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('use-key')));
          await tester.pump(const Duration(milliseconds: 50));
          await shot('desktop-totp$suffix');
          await tester.tap(find.byKey(const Key('add-key')));
          await shot('desktop-add$suffix');
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await shot('desktop-locked$suffix');
        } else {
          await shot('phone-list$suffix');
          await tester.tap(find.byKey(const Key('item-openai/api-key')));
          await shot('phone-detail$suffix');
        }
      }
    }
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
