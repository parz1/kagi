import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/client.dart';
import 'core/controller.dart';
import 'ui/vault_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const backend = String.fromEnvironment('KAGI_BACKEND', defaultValue: 'fake');
  runApp(
    KagiApp(
      initialClient: backend == 'native' ? NativeKagiClient() : demoClient(),
    ),
  );
}

FakeKagiClient demoClient() => FakeKagiClient(
  copy: (value) async {
    await Clipboard.setData(ClipboardData(text: value));
    Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  },
);

class KagiApp extends StatefulWidget {
  final KagiClient initialClient;
  const KagiApp({super.key, required this.initialClient});
  @override
  State<KagiApp> createState() => _KagiAppState();
}

class _KagiAppState extends State<KagiApp> with WidgetsBindingObserver {
  late VaultController controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connect(widget.initialClient);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      NativeKagiClient.channel.setMethodCallHandler((call) async {
        if (call.method == 'shortcut' && call.arguments == 'search') {
          controller.requestSearchFocus();
        }
      });
    }
  }

  void _connect(KagiClient client) {
    controller = VaultController(client);
    unawaited(controller.load());
  }

  void _switch(bool demo) {
    controller.dispose();
    setState(() {
      _connect(demo ? demoClient() : NativeKagiClient());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      controller.hideCodes();
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      controller.lock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      NativeKagiClient.channel.setMethodCallHandler(null);
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Kagi',
    theme: kagiTheme(Brightness.light),
    darkTheme: kagiTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    builder: (context, child) {
      final phone = MediaQuery.sizeOf(context).width < 980;
      return Theme(
        data: Theme.of(context).copyWith(
          visualDensity: phone ? VisualDensity.standard : VisualDensity.compact,
          materialTapTargetSize: phone
              ? MaterialTapTargetSize.padded
              : MaterialTapTargetSize.shrinkWrap,
        ),
        child: child!,
      );
    },
    home: VaultHome(
      key: ObjectKey(controller),
      controller: controller,
      onBackend: _switch,
      canNative: !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS,
    ),
  );
}
