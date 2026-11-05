part of 'vault_app.dart';

String kindLabel(String kind) => switch (kind) {
  'totp' => 'TOTP 验证器',
  'passkey' => 'Passkey',
  _ => '密钥',
};

class _Brand extends StatelessWidget {
  final bool compact;
  const _Brand({this.compact = false});
  @override
  Widget build(BuildContext context) {
    final showWord =
        !compact || MediaQuery.textScalerOf(context).scale(17) <= 22;
    return Semantics(
      label: 'Kagi',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 21 : 23,
            height: compact ? 21 : 23,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: const Icon(Icons.key_rounded, size: 16, color: Colors.white),
          ),
          if (showWord) ...[
            const SizedBox(width: 7),
            const Text(
              'kagi',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -.5,
                color: ink,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeMark extends StatelessWidget {
  final String mode;
  const _ModeMark(this.mode);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      mode == 'fake'
          ? '演示'
          : mode == 'software'
          ? '测试'
          : '本机',
      style: const TextStyle(fontSize: 10, color: muted),
    ),
  );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: muted,
    ),
  );
}

class _ToolIcon extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const _ToolIcon({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 980;
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: muted,
      style: IconButton.styleFrom(
        minimumSize: Size.square(phone ? 44 : 28),
        maximumSize: Size.square(phone ? 44 : 28),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final bool neutral;
  const _Pill(this.text, {this.neutral = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: neutral ? rail : selection,
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10, color: neutral ? muted : accent),
    ),
  );
}

class _EntryIcon extends StatelessWidget {
  final String kind, title;
  final bool small;
  const _EntryIcon(this.kind, this.title, {this.small = false});
  @override
  Widget build(BuildContext context) => Container(
    width: small ? 25 : 30,
    height: small ? 25 : 30,
    decoration: BoxDecoration(
      color: kind == 'totp'
          ? const Color(0xFFE9F0EC)
          : kind == 'passkey'
          ? const Color(0xFFF0ECE6)
          : selection,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Icon(
      kind == 'totp'
          ? Icons.timelapse
          : kind == 'passkey'
          ? Icons.fingerprint
          : Icons.key_outlined,
      size: small ? 15 : 18,
      color: kind == 'totp'
          ? const Color(0xFF3F6B50)
          : kind == 'passkey'
          ? const Color(0xFF795F43)
          : accent,
    ),
  );
}

class _Columns {
  final double width;
  const _Columns(this.width);
  bool get reference => width >= 620;
  bool get space => width >= 450;
  bool get tags => width >= 620;
}

class _TableCells extends StatelessWidget {
  final KeyItem? item;
  final _Columns columns;
  const _TableCells({this.item, required this.columns});
  @override
  Widget build(BuildContext context) {
    final entry = item;
    const label = TextStyle(fontSize: 10, color: muted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: entry == null
                ? const Text('名称', style: label)
                : Row(
                    children: [
                      _EntryIcon(entry.kind, entry.title, small: true),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: ink,
                              ),
                            ),
                            if (!columns.reference)
                              Text(
                                entry.ref,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
          ),
          if (columns.reference)
            Expanded(
              flex: 3,
              child: entry == null
                  ? const Text('引用', style: label)
                  : Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        entry.ref,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: muted,
                        ),
                      ),
                    ),
            ),
          SizedBox(
            width: 65,
            child: Text(
              entry == null
                  ? '类型'
                  : entry.kind == 'totp'
                  ? 'TOTP'
                  : kindLabel(entry.kind),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: entry == null
                  ? label
                  : const TextStyle(fontSize: 11, color: muted),
            ),
          ),
          if (columns.space)
            SizedBox(
              width: 75,
              child: entry == null
                  ? const Text('Space', style: label)
                  : _SpaceName(entry.metadata.space),
            ),
          if (columns.tags)
            SizedBox(
              width: 105,
              child: entry == null
                  ? const Text('标签', style: label)
                  : Text(
                      entry.metadata.tags.isEmpty
                          ? '—'
                          : entry.metadata.tags
                                .take(2)
                                .map((tag) => '#$tag')
                                .join(' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: muted),
                    ),
            ),
        ],
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
    final name =
        home?.c.current?.spaces.where((s) => s.id == id).firstOrNull?.name ??
        id;
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: muted),
    );
  }
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
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: widget.selected,
    child: Material(
      color: widget.selected
          ? selection
          : hovered
          ? const Color(0xFFF6F8F8)
          : Colors.white,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (value) => setState(() {
          hovered = value;
        }),
        onFocusChange: (value) => setState(() {
          focused = value;
        }),
        child: Container(
          height:
              42 *
              (MediaQuery.textScalerOf(context).scale(12) / 12).clamp(1, 4),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: widget.selected || focused ? accent : Colors.transparent,
                width: 2,
              ),
              top: BorderSide(color: focused ? accent : Colors.transparent),
              right: BorderSide(color: focused ? accent : Colors.transparent),
              bottom: BorderSide(
                color: focused ? accent : const Color(0xFFEEF1F2),
              ),
            ),
          ),
          child: _TableCells(item: widget.item, columns: widget.columns),
        ),
      ),
    ),
  );
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
    final seconds = widget.code.expires
        .difference(DateTime.now())
        .inSeconds
        .clamp(0, 86400);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          seconds > 0 ? widget.code.code : '已过期',
          style: const TextStyle(
            fontSize: 26,
            letterSpacing: 3,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
            color: accent,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${widget.demo ? '演示码 / ' : ''}$seconds 秒后失效',
          style: const TextStyle(fontSize: 10, color: muted),
        ),
      ],
    );
  }
}
