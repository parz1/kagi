import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kagi_gui/main.dart';
import 'package:kagi_gui/core/client.dart';
import 'package:kagi_gui/core/controller.dart';

Future<void> mount(
  WidgetTester tester, {
  Size size = const Size(1280, 820),
  KagiClient? client,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(KagiApp(initialClient: client ?? FakeKagiClient()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'desktop three-column layout filters and selects detail without overflow',
    (tester) async {
      await mount(tester);
      expect(find.byKey(const Key('key-table')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('vault-sidebar'))).width, 172);
      expect(
        tester
            .getSize(find.byKey(const Key('item-google/authenticator')))
            .height,
        42,
      );
      expect(find.text('所有条目'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('item-google/authenticator')));
      await tester.pumpAndSettle();
      expect(find.text('TOTP 验证器'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('search')), 'supabase');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('item-supabase/dev-token')), findsOneWidget);
      expect(find.byKey(const Key('item-google/authenticator')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [360.0, 390.0, 768.0]) {
    testWidgets('mobile navigation and back at width $width', (tester) async {
      await mount(tester, size: Size(width, 844));
      expect(find.byKey(const Key('key-table')), findsNothing);
      await tester.tap(find.byKey(const Key('item-openai/api-key')));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('create form writes through client and archive hides entry', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('add-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('draft-title')), 'New service');
    await tester.enterText(find.byKey(const Key('draft-ref')), 'new/token');
    await tester.enterText(
      find.byKey(const Key('draft-value')),
      'FAKE-NEW-SECRET',
    );
    await tester.tap(find.byKey(const Key('save-draft')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('item-new/token')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('archive-key')));
    await tester.tap(find.byKey(const Key('archive-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('item-new/token')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('TOTP is temporary and lock clears it', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('item-google/authenticator')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-key')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('246810'), findsOneWidget);
    await tester.tap(find.text('锁定保险库'));
    await tester.pumpAndSettle();
    expect(find.text('246810'), findsNothing);
    expect(find.byKey(const Key('unlock')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('sync conflict requires a choice and can resolve', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('同步与冲突'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模拟双设备冲突'));
    await tester.pumpAndSettle();
    expect(find.text('保留本机版本'), findsOneWidget);
    final disabled = tester.widget<FilledButton>(
      find.byKey(const Key('sync-submit')),
    );
    expect(disabled.onPressed, isNull);
    await tester.tap(find.text('保留远端版本'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-submit')));
    await tester.pumpAndSettle();
    expect(find.text('保留远端版本'), findsNothing);
    expect(find.text('同步完成，所有修改已保留。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('native transport errors are visible with no fake fallback', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          NativeKagiClient.channel,
          (_) async => jsonEncode({
            'version': 1,
            'error': {'code': 65, 'message': 'FAKE native failure'},
          }),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeKagiClient.channel, null),
    );
    await mount(tester, client: NativeKagiClient());
    expect(find.text('FAKE native failure'), findsOneWidget);
    expect(find.byKey(const Key('item-openai/api-key')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('pending native install has a reachable recovery action', (
    tester,
  ) async {
    await mount(tester, client: RecoveryClient());
    await tester.tap(find.byKey(const Key('unlock')));
    await tester.pumpAndSettle();
    expect(find.text('上次同步尚未完成'), findsOneWidget);
    await tester.tap(find.text('继续同步恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-submit')));
    await tester.pumpAndSettle();
    expect(find.text('同步完成，所有修改已保留。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unsupported native capabilities disable unsafe affordances', (
    tester,
  ) async {
    await mount(tester, client: LimitedClient());
    expect(
      tester.widget<IconButton>(find.byKey(const Key('add-key'))).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('use-key'))).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop shortcuts focus search, create and lock', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    final search = tester.widget<TextField>(find.byKey(const Key('search')));
    expect(search.focusNode!.hasFocus, true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('draft-title')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unlock')), findsOneWidget);
  });
  testWidgets('type filter shows actual TOTP rows only', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('筛选凭据类型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kind-totp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('item-google/authenticator')), findsOneWidget);
    expect(find.byKey(const Key('item-proton/authenticator')), findsOneWidget);
    expect(find.byKey(const Key('item-openai/api-key')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('compact desktop at minimum width keeps table usable', (
    tester,
  ) async {
    await mount(tester, size: const Size(980, 620));
    expect(find.byKey(const Key('key-table')), findsOneWidget);
    await tester.tap(find.byKey(const Key('item-google/authenticator')));
    await tester.pumpAndSettle();
    expect(find.text('生成验证码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('phone supports enlarged text and 44 point primary actions', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester, size: const Size(360, 844));
    await tester.tap(find.byKey(const Key('item-google/authenticator')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('use-key'))).height,
      greaterThanOrEqualTo(44),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('reduced motion opens phone detail without a transition', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await mount(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('item-google/authenticator')));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(
      tester.element(find.byKey(const Key('use-key'))),
    );
    expect(route!.transitionDuration, Duration.zero);
    expect(tester.takeException(), isNull);
  });
  testWidgets('compact Space control can create a named space', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('add-space')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('space-id')), 'review');
    await tester.enterText(find.byKey(const Key('space-name')), '审阅');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('审阅'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('fake denial and lock leave mutation unapplied', () async {
    final client = FakeKagiClient();
    final item = (await client.snapshot()).keys.first;
    client.decision = FakeDecision.deny;
    await expectLater(
      client.update(item, item.metadata.withArchived(true)),
      throwsA(isA<CoreFailure>()),
    );
    expect((await client.snapshot()).keys.first.metadata.archived, false);
    client.decision = FakeDecision.locked;
    await expectLater(client.copySecret(item), throwsA(isA<CoreFailure>()));
    expect((await client.snapshot()).status, 'locked');
  });
  test('late TOTP response after lock cannot restore a code', () async {
    final client = DelayedClient();
    final controller = VaultController(client);
    await controller.load();
    final item = controller.current!.keys.firstWhere((k) => k.kind == 'totp');
    controller.select(item);
    final pending = controller.generateOTP(item);
    await Future<void>.delayed(Duration.zero);
    controller.lock();
    client.pending.complete({
      'code': '246810',
      'validUntil':
          DateTime.now()
              .add(const Duration(seconds: 30))
              .millisecondsSinceEpoch ~/
          1000,
    });
    await pending;
    expect(controller.otp, isNull);
    expect(controller.current!.status, 'locked');
    controller.dispose();
  });
  test('native protocol version is checked', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          NativeKagiClient.channel,
          (_) async => jsonEncode({'version': 2, 'result': {}}),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeKagiClient.channel, null),
    );
    await expectLater(
      NativeKagiClient().snapshot(),
      throwsA(isA<CoreFailure>()),
    );
  });
}

class DelayedClient extends FakeKagiClient {
  final pending = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> arguments,
  ) => method == 'totp' ? pending.future : super.invoke(method, arguments);
}

class RecoveryClient extends FakeKagiClient {
  @override
  Future<VaultSnapshot> snapshot() async =>
      const VaultSnapshot(mode: 'fake', status: 'locked');
  @override
  Future<VaultSnapshot> unlock() async => const VaultSnapshot(
    mode: 'fake',
    status: 'syncRecovery',
    capabilities: CoreCapabilities(directorySync: true),
  );
}

class LimitedClient extends FakeKagiClient {
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final result = await super.invoke(method, arguments);
    if (method == 'snapshot') result['capabilities'] = <String, bool>{};
    return result;
  }
}
