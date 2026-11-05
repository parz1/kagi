import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kagi_gui/core/client.dart';
import 'package:kagi_gui/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'macOS MethodChannel uses the isolated Swift vault, never Dart fake data',
    (tester) async {
      final client = NativeKagiClient();
      final before = await client.snapshot();
      // Stop before authentication if the test environment did not reach the host process.
      expect(
        before.mode,
        'software',
        reason: 'Run only with KAGI_GUI_TEST_HOME pointing to a fake temporary vault.',
      );
      expect(before.status, 'locked');
      await tester.pumpWidget(KagiApp(initialClient: client));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unlock')));
      await tester.pumpAndSettle();
      expect(find.text('Swift 测试保险库'), findsOneWidget);
      const draft = KeyDraft(
        'gui/native-token',
        'FAKE-NATIVE-BRIDGE-SECRET',
        'secret',
        KeyMetadata(title: 'Native Bridge', tags: ['test']),
      );
      final created = await client.create(draft);
      expect(created.mode, 'software');
      final key = created.keys.firstWhere((k) => k.ref == draft.ref);
      expect(key.title, 'Native Bridge');
      final updated = await client.update(
        key,
        const KeyMetadata(title: 'Updated native', tags: ['gui']),
      );
      expect(
        updated.keys.firstWhere((k) => k.ref == draft.ref).revision,
        isNot(key.revision),
      );
      await expectLater(
        client.update(key, key.metadata),
        throwsA(isA<CoreFailure>()),
      );
      await client.unlock();
      final otp = await client.create(
        const KeyDraft(
          'gui/native-otp',
          'JBSWY3DPEHPK3PXP',
          'totp',
          KeyMetadata(title: 'Native OTP'),
        ),
      );
      final code = await client.totp(
        otp.keys.firstWhere((k) => k.ref == 'gui/native-otp'),
      );
      expect(code.code, matches(RegExp(r'^\d{6}$')));
      await client.lock();
      expect((await client.snapshot()).keys, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
