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
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.white,
      fontFamily: 'SF Pro Text',
      dividerColor: line,
      focusColor: accent.withValues(alpha: .14),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 12,
          height: 1.45,
          color: ink,
        ),
        bodySmall: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 11,
          height: 1.4,
          color: muted,
        ),
        titleLarge: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      appBarTheme: const AppBarTheme(
        toolbarHeight: 48,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        shape: Border(bottom: BorderSide(color: line)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF6F8F9),
        hintStyle: const TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 12,
          color: muted,
        ),
        labelStyle: const TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 12,
          color: muted,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: line),
        ),
        titleTextStyle: const TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 30),
          textStyle: const TextStyle(
            fontFamily: 'SF Pro Text',
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: const BorderSide(color: line),
          minimumSize: const Size(0, 30),
          textStyle: const TextStyle(fontFamily: 'SF Pro Text', fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: muted,
          minimumSize: const Size(0, 28),
          textStyle: const TextStyle(fontFamily: 'SF Pro Text', fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        surfaceTintColor: Colors.transparent,
        color: Colors.white,
        textStyle: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 12,
          color: ink,
        ),
      ),
    ),
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
