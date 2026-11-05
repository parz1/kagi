part of 'vault_app.dart';

String kindLabel(String kind) => switch (kind) {
  'totp' => 'TOTP 验证器',
  'passkey' => 'Passkey',
  _ => '密钥',
};

/// 列表、徽标里用的短名，避免与详情中的完整类型名重复。
String kindShort(String kind) => switch (kind) {
  'totp' => 'TOTP',
  'passkey' => 'Passkey',
  _ => '密钥',
};

IconData kindIcon(String kind) => switch (kind) {
  'totp' => Icons.timer_outlined,
  'passkey' => Icons.fingerprint,
  _ => Icons.key_rounded,
};

bool isPhone(BuildContext context) => MediaQuery.sizeOf(context).width < 980;

class _Brand extends StatelessWidget {
  final bool compact;
  const _Brand({this.compact = false});
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final showWord =
        !compact || MediaQuery.textScalerOf(context).scale(17) <= 22;
    return Semantics(
      label: 'Kagi',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AppMark(size: compact ? 24 : 26),
          if (showWord) ...[
            const SizedBox(width: 8),
            Text(
              'kagi',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -.6,
                color: p.ink,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppMark extends StatelessWidget {
  final double size;
  const _AppMark({this.size = 26});
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final top = Color.lerp(p.accent, Colors.white, p.isDark ? .05 : .18)!;
    final bottom = Color.lerp(p.accent, Colors.black, p.isDark ? .25 : .12)!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ),
        borderRadius: BorderRadius.circular(size * .28),
        boxShadow: [
          BoxShadow(
            color: p.accent.withValues(alpha: p.isDark ? .25 : .30),
            blurRadius: size * .35,
            offset: Offset(0, size * .08),
          ),
        ],
      ),
      child: Icon(Icons.key_rounded, size: size * .62, color: Colors.white),
    );
  }
}

class _ModeMark extends StatelessWidget {
  final String mode;
  const _ModeMark(this.mode);
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final color = mode == 'native'
        ? p.success
        : mode == 'software'
        ? p.accent
        : const Color(0xFFD08A1E);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.isDark ? .16 : .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            mode == 'fake'
                ? '演示'
                : mode == 'software'
                ? '测试'
                : '本机',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      letterSpacing: .2,
      color: context.kp.faint,
    ),
  );
}

class _ToolIcon extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  const _ToolIcon({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.size = 17,
  });
  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: size),
      color: context.kp.muted,
      style: IconButton.styleFrom(
        minimumSize: Size.square(phone ? 44 : 30),
        maximumSize: Size.square(phone ? 44 : 30),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final bool neutral;
  final IconData? icon;
  const _Pill(this.text, {this.neutral = false, this.icon});
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final fg = neutral ? p.muted : p.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: neutral ? p.field : p.accentSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 条目头像：名称首字母配稳定色相；TOTP / Passkey 带角标。
class _Avatar extends StatelessWidget {
  final String kind, title;
  final double size;
  const _Avatar(this.kind, this.title, {this.size = 34});
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final seed = title.trim().isEmpty ? '?' : title.trim();
    final letter = String.fromCharCode(seed.runes.first).toUpperCase();
    final bg = _hue(seed, dark: p.isDark, foreground: false);
    final fg = _hue(seed, dark: p.isDark, foreground: true);
    final badge = size * .46;
    return SizedBox(
      width: size + 3,
      height: size + 3,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(size * .28),
            ),
            child: Text(
              letter,
              style: TextStyle(
                fontSize: size * .44,
                height: 1,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ),
          if (kind != 'secret')
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: badge,
                height: badge,
                decoration: BoxDecoration(
                  color: p.card,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.canvas, width: 1.5),
                ),
                child: Icon(kindIcon(kind), size: badge * .72, color: p.accent),
              ),
            ),
        ],
      ),
    );
  }
}

/// 类型筛选：分段按钮，比下拉菜单少一次点击。
class _KindFilter extends StatelessWidget {
  final String value;
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;
  const _KindFilter({
    required this.value,
    required this.counts,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final phone = isPhone(context);
    return Semantics(
      label: '筛选凭据类型',
      container: true,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const {
              'all': '全部',
              'secret': '密钥',
              'totp': 'TOTP',
              'passkey': 'Passkey',
            }.entries)
              _segment(context, p, entry.key, entry.value, phone),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    KagiPalette p,
    String key,
    String label,
    bool phone,
  ) {
    final active = key == value;
    return Semantics(
      selected: active,
      button: true,
      child: Material(
        color: active ? p.card : Colors.transparent,
        elevation: active ? 1 : 0,
        shadowColor: Colors.black.withValues(alpha: .2),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          key: Key('kind-$key'),
          borderRadius: BorderRadius.circular(7),
          onTap: () => onChanged(key),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: phone ? 36 : 26),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active ? p.ink : p.muted,
                    ),
                  ),
                  if ((counts[key] ?? 0) > 0) ...[
                    const SizedBox(width: 5),
                    Text(
                      '${counts[key]}',
                      style: TextStyle(fontSize: 11, color: p.faint),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SpaceName extends StatelessWidget {
  final String id;
  const _SpaceName(this.id);
  @override
  Widget build(BuildContext context) {
    final home = context.findAncestorStateOfType<_VaultHomeState>();
    final spaces = home?.c.current?.spaces ?? const <Space>[];
    final index = spaces.indexWhere((s) => s.id == id);
    final name = index < 0 ? id : spaces[index].name;
    final p = context.kp;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: _indexed(index < 0 ? 0 : index, dark: p.isDark),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: p.muted),
          ),
        ),
      ],
    );
  }
}

class _Columns {
  final double width;
  const _Columns(this.width);
  bool get tags => width >= 600;
  bool get space => width >= 470;
}

class _KeyRow extends StatefulWidget {
  final KeyItem item;
  final _Columns columns;
  final bool selected;
  final VoidCallback onTap;
  const _KeyRow({
    super.key,
    required this.item,
    required this.columns,
    required this.selected,
    required this.onTap,
  });
  @override
  State<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends State<_KeyRow> {
  bool hovered = false, focused = false;
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final item = widget.item;
    final scale = (MediaQuery.textScalerOf(context).scale(13) / 13).clamp(
      1.0,
      4.0,
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: widget.selected
              ? p.selection
              : hovered
              ? p.hover
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(9),
            onHover: (value) => setState(() {
              hovered = value;
            }),
            onFocusChange: (value) => setState(() {
              focused = value;
            }),
            child: Container(
              height: 56 * scale,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: focused ? p.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  _Avatar(item.kind, item.title),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: p.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.ref,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(11.5, p.muted),
                        ),
                      ],
                    ),
                  ),
                  if (widget.columns.tags && item.metadata.tags.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 170),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final tag in item.metadata.tags.take(2))
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: _Pill('#$tag', neutral: true),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (widget.columns.space)
                    SizedBox(
                      width: 92,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: _SpaceName(item.metadata.space),
                      ),
                    ),
                  SizedBox(
                    width: 62,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: item.kind == 'secret'
                          ? Text(
                              kindShort(item.kind),
                              style: TextStyle(fontSize: 12, color: p.faint),
                            )
                          : _Pill(kindShort(item.kind)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情里的分组卡片（类似系统设置的分组列表）。
class _Group extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  const _Group({required this.children, this.padding = EdgeInsets.zero});
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(height: 1, indent: 14, color: p.lineSoft));
      }
      rows.add(children[i]);
    }
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String title;
  final Widget value;
  const _InfoRow(this.title, this.value);
  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: isPhone(context) ? 46 : 40),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                title,
                style: TextStyle(fontSize: 12.5, color: p.muted),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: value),
            ),
          ],
        ),
      ),
    );
  }
}

class _OTPDisplay extends StatefulWidget {
  final OTPCode code;
  final bool demo;
  const _OTPDisplay({required this.code, required this.demo});
  @override
  State<_OTPDisplay> createState() => _OTPDisplayState();
}

class _OTPDisplayState extends State<_OTPDisplay> {
  Timer? timer;
  late final int total = widget.code.expires
      .difference(DateTime.now())
      .inSeconds
      .clamp(1, 86400);
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.kp;
    final seconds = widget.code.expires
        .difference(DateTime.now())
        .inSeconds
        .clamp(0, 86400);
    final urgent = seconds <= 5;
    final color = urgent ? p.danger : p.accent;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  seconds > 0 ? widget.code.code : '已过期',
                  style: mono(
                    30,
                    seconds > 0 ? p.ink : p.faint,
                    weight: FontWeight.w600,
                    spacing: 4,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.demo ? '演示码 · ' : ''}$seconds 秒后失效',
                style: TextStyle(
                  fontSize: 12,
                  color: urgent ? p.danger : p.muted,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 38,
          height: 38,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: seconds / total,
                strokeWidth: 3,
                color: color,
                backgroundColor: p.lineSoft,
              ),
              Text(
                '$seconds',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
