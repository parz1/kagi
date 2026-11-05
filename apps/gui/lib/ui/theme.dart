part of 'vault_app.dart';

/// 设计 token。浅色与深色各一套，跟随系统外观；组件通过 `context.kp` 取色，不写死颜色。
@immutable
class KagiPalette extends ThemeExtension<KagiPalette> {
  final Color canvas, sidebar, panel, card, field, ink, muted, faint, line;
  final Color lineSoft, hover, selection, accent, onAccent, accentSoft;
  final Color danger, success;
  final Brightness brightness;
  const KagiPalette({
    required this.brightness,
    required this.canvas,
    required this.sidebar,
    required this.panel,
    required this.card,
    required this.field,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.lineSoft,
    required this.hover,
    required this.selection,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.danger,
    required this.success,
  });

  static const light = KagiPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF4F4F7),
    panel: Color(0xFFF8F8FA),
    card: Color(0xFFFFFFFF),
    field: Color(0xFFF2F2F5),
    ink: Color(0xFF1B1B21),
    muted: Color(0xFF64646F),
    faint: Color(0xFF9C9CA8),
    line: Color(0xFFE3E3E9),
    lineSoft: Color(0xFFEEEEF2),
    hover: Color(0xFFF4F4F8),
    selection: Color(0xFFE8EBFD),
    accent: Color(0xFF4352D4),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFEEF0FD),
    danger: Color(0xFFC23B3B),
    success: Color(0xFF1F8458),
  );

  static const dark = KagiPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF17171B),
    sidebar: Color(0xFF1E1E23),
    panel: Color(0xFF1B1B20),
    card: Color(0xFF25252B),
    field: Color(0xFF2A2A31),
    ink: Color(0xFFF1F1F5),
    muted: Color(0xFFA3A3AF),
    faint: Color(0xFF71717C),
    line: Color(0xFF33333B),
    lineSoft: Color(0xFF29292F),
    hover: Color(0xFF222228),
    selection: Color(0xFF2B2F55),
    accent: Color(0xFF8D99FF),
    onAccent: Color(0xFF11132B),
    accentSoft: Color(0xFF262A4B),
    danger: Color(0xFFFF7B72),
    success: Color(0xFF5BC892),
  );

  bool get isDark => brightness == Brightness.dark;

  @override
  KagiPalette copyWith() => this;

  @override
  KagiPalette lerp(KagiPalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return KagiPalette(
      brightness: t < .5 ? brightness : other.brightness,
      canvas: l(canvas, other.canvas),
      sidebar: l(sidebar, other.sidebar),
      panel: l(panel, other.panel),
      card: l(card, other.card),
      field: l(field, other.field),
      ink: l(ink, other.ink),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      line: l(line, other.line),
      lineSoft: l(lineSoft, other.lineSoft),
      hover: l(hover, other.hover),
      selection: l(selection, other.selection),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      danger: l(danger, other.danger),
      success: l(success, other.success),
    );
  }
}

extension KagiPaletteContext on BuildContext {
  KagiPalette get kp =>
      Theme.of(this).extension<KagiPalette>() ?? KagiPalette.light;
}

/// 引用、验证码这类需要逐字核对的内容使用等宽字体。
const monoFamily = 'SF Mono';
const monoFallback = ['Menlo', 'Monaco', 'monospace'];

TextStyle mono(
  double size,
  Color color, {
  FontWeight? weight,
  double? spacing,
}) => TextStyle(
  fontFamily: monoFamily,
  fontFamilyFallback: monoFallback,
  fontSize: size,
  color: color,
  fontWeight: weight,
  letterSpacing: spacing,
);

/// 精选色相：彼此区分明显，避免随机色相挤在同一片红色里。
const _hues = <double>[228, 262, 300, 340, 12, 30, 45, 140, 168, 195];

/// 按顺序取色（Space 用），保证相邻几项颜色不同。
Color _indexed(int index, {required bool dark}) {
  final hue = _hues[(index * 3) % _hues.length];
  return dark
      ? HSLColor.fromAHSL(1, hue, .75, .72).toColor()
      : HSLColor.fromAHSL(1, hue, .60, .52).toColor();
}

/// 按名称稳定地取一个色相，让同一服务在列表、详情、手机端颜色一致。
Color _hue(String seed, {required bool dark, required bool foreground}) {
  var hash = 0;
  for (final unit in seed.toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final hue = _hues[hash % _hues.length];
  return dark
      ? HSLColor.fromAHSL(
          1,
          hue,
          foreground ? .75 : .32,
          foreground ? .78 : .26,
        ).toColor()
      : HSLColor.fromAHSL(
          1,
          hue,
          foreground ? .55 : .70,
          foreground ? .40 : .93,
        ).toColor();
}

ThemeData kagiTheme(Brightness brightness) {
  // 主题里的组件字样不会继承 DefaultTextStyle，显式带上平台默认字体族（macOS 为系统字体）。
  final family = Typography.material2021(platform: defaultTargetPlatform)
      .black
      .bodyMedium
      ?.fontFamily;
  TextStyle ts({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) => TextStyle(
    fontFamily: family,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );
  final p = brightness == Brightness.dark
      ? KagiPalette.dark
      : KagiPalette.light;
  final radius = BorderRadius.circular(8);
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: color, width: width),
      );
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.accent,
        brightness: brightness,
      ).copyWith(
        primary: p.accent,
        onPrimary: p.onAccent,
        surface: p.canvas,
        onSurface: p.ink,
        onSurfaceVariant: p.muted,
        outline: p.line,
        outlineVariant: p.lineSoft,
        error: p.danger,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [p],
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.canvas,
    dividerColor: p.line,
    dividerTheme: DividerThemeData(color: p.line, space: 1, thickness: 1),
    focusColor: p.accent.withValues(alpha: .14),
    hoverColor: p.hover,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.accent.withValues(alpha: .06),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textTheme: TextTheme(
      bodyLarge: ts(fontSize: 14, height: 1.45, color: p.ink),
      bodyMedium: ts(fontSize: 13, height: 1.45, color: p.ink),
      bodySmall: ts(fontSize: 12, height: 1.4, color: p.muted),
      titleLarge: ts(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -.2,
        color: p.ink,
      ),
      titleMedium: ts(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
      labelLarge: ts(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
    ),
    iconTheme: IconThemeData(color: p.muted, size: 18),
    appBarTheme: AppBarTheme(
      toolbarHeight: 52,
      backgroundColor: p.canvas,
      foregroundColor: p.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: ts(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: p.ink,
      ),
      shape: Border(bottom: BorderSide(color: p.line)),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.sidebar,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.field,
      hintStyle: ts(fontSize: 13, color: p.faint),
      labelStyle: ts(fontSize: 13, color: p.muted),
      floatingLabelStyle: ts(fontSize: 13, color: p.accent),
      prefixIconColor: p.faint,
      suffixIconColor: p.faint,
      border: border(Colors.transparent),
      enabledBorder: border(Colors.transparent),
      disabledBorder: border(Colors.transparent),
      focusedBorder: border(p.accent, 1.5),
      errorBorder: border(p.danger),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: p.isDark ? .6 : .18),
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.line),
      ),
      titleTextStyle: ts(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
      contentTextStyle: ts(fontSize: 13, height: 1.55, color: p.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.lineSoft,
        disabledForegroundColor: p.faint,
        minimumSize: const Size(0, 34),
        elevation: 0,
        textStyle: ts(fontSize: 13, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        backgroundColor: p.card,
        side: BorderSide(color: p.line),
        minimumSize: const Size(0, 34),
        textStyle: ts(fontSize: 13, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.muted,
        minimumSize: const Size(0, 32),
        textStyle: ts(fontSize: 13, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.muted,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: p.isDark ? .6 : .16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.line),
      ),
      textStyle: ts(fontSize: 13, color: p.ink),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: p.isDark ? const Color(0xFF3A3A42) : const Color(0xFF2A2A31),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: ts(fontSize: 12, color: Colors.white),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark
          ? const Color(0xFF34343C)
          : const Color(0xFF26262D),
      contentTextStyle: ts(fontSize: 13, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.accentSoft,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(p.faint.withValues(alpha: .45)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: radius),
      iconColor: p.muted,
      textColor: p.ink,
    ),
  );
}
