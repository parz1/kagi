import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/client.dart';
import '../core/controller.dart';

part 'theme.dart';
part 'dialogs.dart';
part 'components.dart';

class VaultHome extends StatefulWidget {
  final VaultController controller;
  final void Function(bool) onBackend;
  final bool canNative;
  const VaultHome({
    super.key,
    required this.controller,
    required this.onBackend,
    required this.canNative,
  });
  @override
  State<VaultHome> createState() => _VaultHomeState();
}

class _VaultHomeState extends State<VaultHome> {
  VaultController get c => widget.controller;
  KagiPalette get p => context.kp;
  final search = TextEditingController();
  final searchFocus = FocusNode();
  String kind = 'all';
  bool ascending = true;
  int _seenSearchRequests = 0;
  @override
  void initState() {
    super.initState();
    c.addListener(_receiveNativeShortcut);
  }

  void _receiveNativeShortcut() {
    if (_seenSearchRequests == c.searchFocusRequests) return;
    _seenSearchRequests = c.searchFocusRequests;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) searchFocus.requestFocus();
    });
  }

  bool get canManage => c.current?.capabilities.manage == true && !c.busy;
  bool get canSync => c.current?.capabilities.directorySync == true && !c.busy;
  List<KeyItem> get items {
    final result = c.visibleKeys
        .where((item) => kind == 'all' || item.kind == kind)
        .toList();
    result.sort(
      (a, b) => ascending
          ? a.title.toLowerCase().compareTo(b.title.toLowerCase())
          : b.title.toLowerCase().compareTo(a.title.toLowerCase()),
    );
    return result;
  }

  Map<String, int> get kindCounts {
    final visible = c.visibleKeys;
    return {
      'all': visible.length,
      for (final k in ['secret', 'totp', 'passkey'])
        k: visible.where((item) => item.kind == k).length,
    };
  }

  KeyItem? get selected =>
      items.where((item) => item.ref == c.selectedRef).firstOrNull;
  String get sectionTitle => c.archived
      ? '已归档'
      : c.selectedSpace != null
      ? c.current?.spaces
                .where((s) => s.id == c.selectedSpace)
                .firstOrNull
                ?.name ??
            'Space'
      : '所有条目';
  bool get filtered =>
      c.selectedSpace != null ||
      c.selectedTag != null ||
      c.query.isNotEmpty ||
      kind != 'all';

  @override
  void dispose() {
    c.removeListener(_receiveNativeShortcut);
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  Future<void> action(Future<bool> task, [String? success]) async {
    final ok = await task;
    if (!mounted) return;
    final message = ok ? success : c.error;
    if (message != null) toast(message, error: !ok);
  }

  void toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                size: 17,
                color: error
                    ? const Color(0xFFFF8A80)
                    : const Color(0xFF8FE3B5),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
  }

  void navigate({String? space, String? tag, bool archived = false}) {
    search.clear();
    c.query = '';
    kind = 'all';
    c.filter(space: space, tag: tag, showArchived: archived);
  }

  void chooseKind(String value) {
    setState(() {
      kind = value;
    });
    c.select(null);
  }

  Future<void> openItem(KeyItem item, bool phone) async {
    c.select(item);
    if (!phone) return;
    await Navigator.push(
      context,
      PageRouteBuilder<void>(
        transitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 140),
        transitionsBuilder: (context, animation, secondary, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(.06, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
        pageBuilder: (context, animation, secondary) => ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final current = c.current?.keys
                .where((k) => k.ref == item.ref)
                .firstOrNull;
            return Scaffold(
              appBar: AppBar(
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        current?.title ?? '条目详情',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ModeMark(c.current?.mode ?? 'fake'),
                  ],
                ),
                actions: [
                  if (c.current?.status == 'ready')
                    IconButton(
                      tooltip: '锁定保险库',
                      onPressed: c.lock,
                      icon: const Icon(Icons.lock_outline, size: 20),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
              body: c.current?.status == 'ready' && current != null
                  ? inspector(current, phone: true)
                  : Center(
                      child: Text(
                        '保险库已锁定，请返回解锁。',
                        style: TextStyle(color: context.kp.muted),
                      ),
                    ),
            );
          },
        ),
      ),
    );
    c.select(null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final width = MediaQuery.sizeOf(context).width;
      final desktop = width >= 980;
      final status = c.current?.status;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              searchFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              searchFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () {
            if (canManage && status == 'ready') editDialog();
          },
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
            if (canManage && status == 'ready') editDialog();
          },
          const SingleActivator(
            LogicalKeyboardKey.keyL,
            meta: true,
            shift: true,
          ): c.lock,
          const SingleActivator(
            LogicalKeyboardKey.keyL,
            control: true,
            shift: true,
          ): c.lock,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: p.canvas,
            appBar: desktop || status != 'ready'
                ? null
                : AppBar(
                    titleSpacing: 0,
                    title: Row(
                      children: [
                        const _Brand(compact: true),
                        const SizedBox(width: 10),
                        backendMenu(),
                      ],
                    ),
                    actions: [
                      IconButton(
                        tooltip: '同步与冲突',
                        onPressed: canSync ? syncDialog : null,
                        icon: Badge(
                          isLabelVisible: c.conflicts.isNotEmpty,
                          backgroundColor: p.danger,
                          smallSize: 7,
                          child: const Icon(Icons.sync_rounded, size: 20),
                        ),
                      ),
                      IconButton(
                        tooltip: '锁定保险库',
                        onPressed: c.lock,
                        icon: const Icon(Icons.lock_outline, size: 20),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
            drawer: !desktop && status == 'ready'
                ? Drawer(
                    width: 280,
                    child: SafeArea(child: sidebar(phone: true)),
                  )
                : null,
            body: status == null
                ? c.error == null
                      ? const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : stateView('error')
                : status != 'ready'
                ? stateView(status)
                : desktop
                ? Row(
                    children: [
                      SizedBox(
                        key: const Key('vault-sidebar'),
                        width: 232,
                        child: sidebar(),
                      ),
                      VerticalDivider(width: 1, color: p.line),
                      Expanded(child: tablePanel()),
                      VerticalDivider(width: 1, color: p.line),
                      SizedBox(
                        width: width >= 1200 ? 360 : 320,
                        child: selected == null
                            ? emptyInspector()
                            : inspector(selected!),
                      ),
                    ],
                  )
                : phoneList(),
          ),
        ),
      );
    },
  );

  Widget backendMenu() => PopupMenuButton<bool>(
    tooltip: '选择保险库',
    onSelected: widget.onBackend,
    position: PopupMenuPosition.under,
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: true,
        checked: c.client.isDemo,
        child: const Text('演示保险库'),
      ),
      if (widget.canNative)
        CheckedPopupMenuItem(
          value: false,
          checked: !c.client.isDemo,
          child: const Text('本机保险库'),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeMark(c.current?.mode ?? (c.client.isDemo ? 'fake' : 'native')),
          const SizedBox(width: 2),
          Icon(Icons.unfold_more_rounded, size: 15, color: p.faint),
        ],
      ),
    ),
  );

  Widget sidebar({bool phone = false}) {
    void go({String? space, String? tag, bool archived = false}) {
      navigate(space: space, tag: tag, archived: archived);
      if (phone) Navigator.pop(context);
    }

    final keys = c.current!.keys;
    return Material(
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 60,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 12, 0),
              child: Row(
                children: [
                  const _Brand(),
                  const Spacer(),
                  if (!phone) backendMenu(),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
              children: [
                navTile(
                  '所有条目',
                  Icon(Icons.layers_outlined, size: 17, color: p.muted),
                  c.selectedSpace == null &&
                      c.selectedTag == null &&
                      !c.archived,
                  () => go(),
                  count: keys.where((k) => !k.metadata.archived).length,
                  phone: phone,
                ),
                navTile(
                  '已归档',
                  Icon(Icons.inventory_2_outlined, size: 17, color: p.muted),
                  c.archived,
                  () => go(archived: true),
                  phone: phone,
                  count: keys.where((k) => k.metadata.archived).length,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 10, 4),
                  child: Row(
                    children: [
                      const Expanded(child: _Label('Space')),
                      _ToolIcon(
                        key: const Key('add-space'),
                        label: '新建 Space',
                        icon: Icons.add_rounded,
                        size: 16,
                        onPressed: canManage ? spaceDialog : null,
                      ),
                    ],
                  ),
                ),
                for (final (index, space) in c.current!.spaces.indexed)
                  navTile(
                    space.name,
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: _indexed(index, dark: p.isDark),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    c.selectedSpace == space.id && !c.archived,
                    () => go(space: space.id),
                    phone: phone,
                    count: keys
                        .where(
                          (k) =>
                              k.metadata.space == space.id &&
                              !k.metadata.archived,
                        )
                        .length,
                    menu: PopupMenuButton<String>(
                      tooltip: '管理 ${space.name}',
                      enabled: canManage,
                      padding: EdgeInsets.zero,
                      position: PopupMenuPosition.under,
                      icon: Icon(Icons.more_horiz, size: 15, color: p.faint),
                      onSelected: (value) => value == 'rename'
                          ? spaceDialog(space)
                          : action(
                              c.changeSpace('remove', space.id, null),
                              'Space 已删除',
                            ),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('重命名'),
                        ),
                        if (space.id != 'default')
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('删除空 Space'),
                          ),
                      ],
                    ),
                  ),
                if (c.tags.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 18, 10, 8),
                    child: _Label('标签'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final tag in c.tags) tagChip(tag, go, phone),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          const SizedBox(height: 6),
          navTile(
            '同步与冲突',
            Icon(Icons.sync_rounded, size: 17, color: p.muted),
            false,
            canSync ? syncDialog : null,
            phone: phone,
            count: c.conflicts.isEmpty ? null : c.conflicts.length,
            alert: c.conflicts.isNotEmpty,
          ),
          navTile(
            '锁定保险库',
            Icon(Icons.lock_outline_rounded, size: 17, color: p.muted),
            false,
            c.lock,
            phone: phone,
            trailing: phone
                ? null
                : Text('⇧⌘L', style: TextStyle(fontSize: 11, color: p.faint)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 10, 12),
            child: Row(
              children: [
                Icon(
                  c.client.isDemo
                      ? Icons.science_outlined
                      : Icons.verified_user_outlined,
                  size: 14,
                  color: p.faint,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    c.client.isDemo
                        ? '演示保险库 · 虚构数据'
                        : c.current?.mode == 'software'
                        ? 'Swift 测试保险库'
                        : '本机保险库 · 已加密',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: p.faint),
                  ),
                ),
                if (c.client.isDemo)
                  _ToolIcon(
                    label: '模拟验证',
                    icon: Icons.tune_rounded,
                    size: 15,
                    onPressed: fakeDialog,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget tagChip(
    String tag,
    void Function({String? space, String? tag, bool archived}) go,
    bool phone,
  ) {
    final active = c.selectedTag == tag;
    return Material(
      color: active ? p.accent : p.canvas.withValues(alpha: p.isDark ? .4 : .9),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: () => go(tag: tag),
        child: Container(
          constraints: BoxConstraints(minHeight: phone ? 36 : 26),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: active ? p.accent : p.line),
          ),
          child: Text(
            '#$tag',
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? p.onAccent : p.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget navTile(
    String title,
    Widget leading,
    bool active,
    VoidCallback? onTap, {
    int? count,
    Widget? menu,
    Widget? trailing,
    bool phone = false,
    bool alert = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
    child: Material(
      color: active ? p.selection : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: phone ? 44 : 34,
          child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: Center(
                    child: IconTheme.merge(
                      data: IconThemeData(color: active ? p.accent : p.muted),
                      child: leading,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: phone ? 15 : 13,
                      color: active ? p.accent : p.ink,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                ?trailing,
                if (count != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: alert
                        ? BoxDecoration(
                            color: p.danger,
                            borderRadius: BorderRadius.circular(10),
                          )
                        : null,
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: alert
                            ? Colors.white
                            : active
                            ? p.accent
                            : p.faint,
                      ),
                    ),
                  ),
                if (menu != null) SizedBox(width: 24, height: 26, child: menu),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget searchField({bool phone = false}) => TextField(
    key: const Key('search'),
    controller: search,
    focusNode: searchFocus,
    onChanged: (value) {
      c.search(value);
      setState(() {});
    },
    style: TextStyle(fontSize: phone ? 15 : 13, color: p.ink),
    decoration: InputDecoration(
      hintText: phone ? '搜索名称、引用、标签' : '搜索条目',
      prefixIcon: Icon(Icons.search_rounded, size: phone ? 20 : 17),
      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 34),
      suffixIcon: search.text.isEmpty
          ? (phone
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      '⌘F',
                      style: TextStyle(fontSize: 11, color: p.faint),
                    ),
                  ))
          : IconButton(
              tooltip: '清除搜索',
              icon: const Icon(Icons.cancel_rounded, size: 16),
              onPressed: () {
                search.clear();
                c.search('');
                setState(() {});
              },
            ),
      suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      contentPadding: EdgeInsets.symmetric(
        horizontal: 10,
        vertical: phone ? 12 : 9,
      ),
    ),
  );

  Widget addButton({bool phone = false, bool compact = false}) =>
      phone || compact
      ? FilledButton(
          key: const Key('add-key'),
          onPressed: canManage ? () => editDialog() : null,
          style: FilledButton.styleFrom(
            minimumSize: Size.square(phone ? 44 : 34),
            maximumSize: Size.square(phone ? 44 : 34),
            padding: EdgeInsets.zero,
          ),
          child: Tooltip(
            message: phone ? '添加条目' : '添加条目（⌘N）',
            child: Icon(Icons.add_rounded, size: phone ? 22 : 19),
          ),
        )
      : Tooltip(
          message: '添加条目（⌘N）',
          child: FilledButton.icon(
            key: const Key('add-key'),
            onPressed: canManage ? () => editDialog() : null,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('新建'),
          ),
        );

  Widget sortButton({bool compact = false}) {
    void toggle() => setState(() {
      ascending = !ascending;
    });
    final icon = Icon(
      ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
      size: 14,
    );
    final label = ascending ? '名称 A–Z' : '名称 Z–A';
    return compact
        ? _ToolIcon(
            label: '按$label排序',
            icon: ascending
                ? Icons.arrow_upward_rounded
                : Icons.arrow_downward_rounded,
            size: 15,
            onPressed: toggle,
          )
        : TextButton.icon(
            onPressed: toggle,
            icon: icon,
            label: Text(label, style: const TextStyle(fontSize: 12)),
          );
  }

  Widget tablePanel() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = _Columns(constraints.maxWidth);
      final list = items;
      return Material(
        color: p.canvas,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              sectionTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.3,
                                color: p.ink,
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            '${list.length}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: p.faint,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: (constraints.maxWidth * .4).clamp(140, 300),
                      height: 34,
                      child: searchField(),
                    ),
                    const SizedBox(width: 6),
                    _ToolIcon(
                      label: '刷新',
                      icon: Icons.refresh_rounded,
                      onPressed: c.busy ? null : () => action(c.load()),
                    ),
                    const SizedBox(width: 6),
                    addButton(compact: constraints.maxWidth < 560),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _KindFilter(
                            value: kind,
                            counts: kindCounts,
                            onChanged: chooseKind,
                          ),
                          if (c.selectedTag != null) ...[
                            const SizedBox(width: 8),
                            _Pill(
                              '#${c.selectedTag}',
                              icon: Icons.sell_outlined,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (filtered)
                    TextButton(
                      onPressed: () => navigate(),
                      child: const Text('清除筛选', style: TextStyle(fontSize: 12)),
                    ),
                  sortButton(compact: constraints.maxWidth < 600),
                ],
              ),
            ),
            SizedBox(
              height: 2,
              child: c.busy
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null,
            ),
            Divider(height: 1, color: p.lineSoft),
            Expanded(
              child: list.isEmpty
                  ? emptyList()
                  : ListView.builder(
                      key: const Key('key-table'),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: list.length,
                      itemBuilder: (_, index) => _KeyRow(
                        key: Key('item-${list[index].ref}'),
                        item: list[index],
                        columns: columns,
                        selected: c.selectedRef == list[index].ref,
                        onTap: () => openItem(list[index], false),
                      ),
                    ),
            ),
            Container(
              height: 30,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.lineSoft)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: p.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '离线可用',
                    style: TextStyle(fontSize: 11.5, color: p.faint),
                  ),
                  const Spacer(),
                  Text(
                    c.client.isDemo
                        ? '演示数据，不读取真实密钥'
                        : c.lastSync == null
                        ? '本地加密库'
                        : '同步已完成',
                    style: TextStyle(fontSize: 11.5, color: p.faint),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget phoneList() {
    final list = items;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Material(
      color: p.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          sectionTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.5,
                            color: p.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${list.length}',
                        style: TextStyle(fontSize: 14, color: p.faint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                addButton(phone: true),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: searchField(phone: true),
          ),
          SingleChildScrollView(
            key: const Key('phone-filters'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                _KindFilter(
                  value: kind,
                  counts: kindCounts,
                  onChanged: chooseKind,
                ),
                if (c.selectedTag != null) ...[
                  const SizedBox(width: 8),
                  _Pill('#${c.selectedTag}', icon: Icons.sell_outlined),
                ],
                const SizedBox(width: 4),
                _ToolIcon(
                  label: '刷新',
                  icon: Icons.refresh_rounded,
                  onPressed: c.busy ? null : () => action(c.load()),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 2,
            child: c.busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Divider(height: 1, color: p.lineSoft),
          Expanded(
            child: list.isEmpty
                ? emptyList()
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: list.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, indent: 70, color: p.lineSoft),
                    itemBuilder: (_, index) {
                      final item = list[index];
                      return InkWell(
                        key: Key('item-${item.ref}'),
                        onTap: () => openItem(item, true),
                        child: SizedBox(
                          height: 66 * scale,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                _Avatar(item.kind, item.title, size: 40),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: p.ink,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        item.ref,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: mono(12, p.muted),
                                      ),
                                    ],
                                  ),
                                ),
                                if (item.kind != 'secret') ...[
                                  const SizedBox(width: 8),
                                  _Pill(kindShort(item.kind)),
                                ],
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: p.faint,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget emptyState(
    IconData icon,
    String title,
    String? subtitle,
    Widget? cta,
  ) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: p.field, shape: BoxShape.circle),
            child: Icon(icon, size: 24, color: p.faint),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: p.muted, height: 1.5),
            ),
          ],
          if (cta != null) ...[const SizedBox(height: 14), cta],
        ],
      ),
    ),
  );

  Widget emptyList() =>
      c.query.isNotEmpty || kind != 'all' || c.selectedTag != null
      ? emptyState(
          Icons.search_off_rounded,
          '没有匹配的条目',
          '换个关键词，或清除筛选条件。',
          OutlinedButton(
            onPressed: () => navigate(),
            child: const Text('清除筛选'),
          ),
        )
      : emptyState(
          c.archived ? Icons.inventory_2_outlined : Icons.key_rounded,
          c.archived ? '没有归档的条目' : '这里还没有条目',
          c.archived ? '归档的条目会保留密文与历史版本。' : '值只在你确认后才会被使用。',
          c.archived
              ? null
              : FilledButton.icon(
                  onPressed: canManage ? () => editDialog() : null,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('添加第一个条目'),
                ),
        );

  Widget emptyInspector() => Material(
    color: p.panel,
    child: emptyState(
      Icons.touch_app_outlined,
      '选择条目查看详情',
      '⌘F 搜索 · ⌘N 新建 · ⇧⌘L 锁定',
      null,
    ),
  );

  Widget inspector(KeyItem item, {bool phone = false}) {
    final caps = c.current!.capabilities;
    final spaceName =
        c.current!.spaces
            .where((s) => s.id == item.metadata.space)
            .firstOrNull
            ?.name ??
        item.metadata.space;
    final valueStyle = TextStyle(fontSize: phone ? 15 : 13, color: p.ink);
    final showingCode =
        item.kind == 'totp' && c.otpRef == item.ref && c.otp != null;
    final usable =
        !c.busy &&
        !item.metadata.archived &&
        (item.kind == 'totp' ? caps.totp : caps.copySecret);
    return Material(
      color: phone ? p.canvas : p.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!phone)
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '条目详情',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: p.faint,
                        ),
                      ),
                    ),
                    _ToolIcon(
                      label: '关闭详情',
                      icon: Icons.close_rounded,
                      onPressed: () => c.select(null),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, phone ? 20 : 4, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Avatar(item.kind, item.title, size: 52),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!phone)
                              Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 19,
                                  height: 1.25,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.2,
                                  color: p.ink,
                                ),
                              ),
                            Row(
                              children: [
                                Flexible(
                                  child: SelectableText(
                                    item.ref,
                                    maxLines: 1,
                                    style: mono(12, p.muted),
                                  ),
                                ),
                                _ToolIcon(
                                  label: '复制引用',
                                  icon: Icons.copy_rounded,
                                  size: 14,
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: item.ref),
                                    );
                                    if (mounted) toast('已复制引用 ${item.ref}');
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 5,
                              runSpacing: 5,
                              children: [
                                _Pill(
                                  kindShort(item.kind),
                                  icon: kindIcon(item.kind),
                                ),
                                _Pill(
                                  spaceName,
                                  neutral: true,
                                  icon: Icons.folder_outlined,
                                ),
                                if (item.metadata.archived)
                                  const _Pill(
                                    '已归档',
                                    neutral: true,
                                    icon: Icons.inventory_2_outlined,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _Group(
                    padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.kind == 'totp'
                                      ? '一次性验证码'
                                      : item.kind == 'passkey'
                                      ? '通行密钥'
                                      : '密钥值',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: p.muted,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.lock_rounded,
                                size: 12,
                                color: p.faint,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '已加密',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: p.faint,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (showingCode)
                            _OTPDisplay(code: c.otp!, demo: c.client.isDemo)
                          else
                            Text(
                              item.kind == 'passkey'
                                  ? '私钥不可导出'
                                  : item.kind == 'totp'
                                  ? '••• •••'
                                  : '••••••••••••••••',
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: item.kind == 'passkey'
                                  ? TextStyle(fontSize: 14, color: p.ink)
                                  : TextStyle(
                                      fontSize: 22,
                                      letterSpacing: 2.5,
                                      color: p.faint,
                                      height: 1.3,
                                    ),
                            ),
                          const SizedBox(height: 14),
                          if (item.kind == 'passkey')
                            Text(
                              '系统提供者尚未接入',
                              style: TextStyle(fontSize: 12, color: p.muted),
                            )
                          else
                            Row(
                              children: [
                                Icon(
                                  Icons.fingerprint,
                                  size: 15,
                                  color: p.faint,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    c.client.isDemo ? '模拟验证' : '每次使用都需系统验证',
                                    maxLines: 2,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: p.muted,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.icon(
                                  key: const Key('use-key'),
                                  onPressed: usable
                                      ? () => action(
                                          item.kind == 'totp'
                                              ? c.generateOTP(item)
                                              : c.copy(item),
                                          item.kind == 'totp'
                                              ? null
                                              : c.client.isDemo
                                              ? '已复制演示值，30 秒后清除'
                                              : '已复制，30 秒后自动清除',
                                        )
                                      : null,
                                  style: FilledButton.styleFrom(
                                    minimumSize: Size(0, phone ? 44 : 34),
                                  ),
                                  icon: Icon(
                                    item.kind == 'totp'
                                        ? Icons.password_rounded
                                        : Icons.content_copy_rounded,
                                    size: 15,
                                  ),
                                  label: Text(
                                    item.kind == 'totp' ? '生成验证码' : '复制',
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _Group(
                    children: [
                      _InfoRow('Space', Text(spaceName, style: valueStyle)),
                      _InfoRow(
                        '类型',
                        Text(kindLabel(item.kind), style: valueStyle),
                      ),
                      _InfoRow(
                        '版本',
                        Text('第 ${item.version} 版', style: valueStyle),
                      ),
                      _InfoRow(
                        '状态',
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: item.metadata.archived
                                    ? p.faint
                                    : p.success,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              item.metadata.archived ? '已归档' : '可用',
                              style: valueStyle.copyWith(
                                color: item.metadata.archived
                                    ? p.muted
                                    : p.success,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _InfoRow(
                        '标签',
                        item.metadata.tags.isEmpty
                            ? Text(
                                '—',
                                style: valueStyle.copyWith(color: p.faint),
                              )
                            : Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 4,
                                runSpacing: 4,
                                children: item.metadata.tags
                                    .map((tag) => _Pill('#$tag', neutral: true))
                                    .toList(),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Padding(
                    padding: EdgeInsets.only(left: 4, bottom: 7),
                    child: _Label('备注'),
                  ),
                  _Group(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Text(
                        item.metadata.notes?.isNotEmpty == true
                            ? item.metadata.notes!
                            : '未填写',
                        style: TextStyle(
                          fontSize: phone ? 15 : 13,
                          color: item.metadata.notes?.isNotEmpty == true
                              ? p.ink
                              : p.faint,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('edit-key'),
                          onPressed: canManage ? () => editDialog(item) : null,
                          style: OutlinedButton.styleFrom(
                            minimumSize: Size(0, phone ? 44 : 34),
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 15),
                          label: const Text('编辑信息'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextButton.icon(
                          key: const Key('archive-key'),
                          onPressed: canManage
                              ? () => confirmArchive(item)
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: item.metadata.archived
                                ? p.accent
                                : p.danger,
                            minimumSize: Size(0, phone ? 44 : 34),
                          ),
                          icon: Icon(
                            item.metadata.archived
                                ? Icons.unarchive_outlined
                                : Icons.archive_outlined,
                            size: 15,
                          ),
                          label: Text(item.metadata.archived ? '恢复条目' : '归档条目'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget stateView(String status) {
    final title = status == 'unconfigured'
        ? '连接本地保险库'
        : status == 'error'
        ? '无法连接核心'
        : status == 'syncRecovery'
        ? '上次同步尚未完成'
        : '保险库已锁定';
    final subtitle = status == 'unconfigured'
        ? '先在终端完成建库，或体验演示保险库。'
        : status == 'syncRecovery'
        ? '使用上次的同步目标恢复安装。'
        : c.client.isDemo
        ? '使用虚构数据，模拟批准、拒绝与锁定。'
        : '通过系统验证打开本地库。';
    final icon = status == 'error'
        ? Icons.link_off_rounded
        : status == 'syncRecovery'
        ? Icons.sync_problem_rounded
        : status == 'unconfigured'
        ? Icons.terminal_rounded
        : Icons.lock_rounded;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -.35),
          radius: 1.1,
          colors: [p.accentSoft, p.canvas],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Positioned(
                          left: 6,
                          top: 6,
                          child: _AppMark(size: 68),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: p.card,
                              shape: BoxShape.circle,
                              border: Border.all(color: p.line),
                            ),
                            child: Icon(icon, size: 16, color: p.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.3,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: p.muted, height: 1.6),
                ),
                if (status == 'unconfigured')
                  Container(
                    margin: const EdgeInsets.only(top: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.line),
                    ),
                    child: Row(
                      children: [
                        Text('\$', style: mono(13, p.faint)),
                        const SizedBox(width: 8),
                        SelectableText('kagi init', style: mono(13, p.ink)),
                      ],
                    ),
                  ),
                if (c.error != null)
                  Container(
                    margin: const EdgeInsets.only(top: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: p.danger.withValues(alpha: p.isDark ? .14 : .07),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.danger.withValues(alpha: .3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 16,
                          color: p.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            c.error!,
                            style: TextStyle(color: p.danger, fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
                if (status == 'locked')
                  FilledButton.icon(
                    key: const Key('unlock'),
                    onPressed: c.busy ? null : () => action(c.unlock()),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.fingerprint, size: 20),
                    label: Text(c.busy ? '正在验证…' : '解锁保险库'),
                  ),
                if (status == 'syncRecovery')
                  FilledButton(
                    onPressed: c.busy ? null : syncDialog,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    child: const Text('继续同步恢复'),
                  ),
                if (status == 'error')
                  OutlinedButton(
                    onPressed: c.busy ? null : () => action(c.load()),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    child: const Text('重试连接'),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    if (c.client.isDemo)
                      TextButton(
                        onPressed: fakeDialog,
                        child: const Text('设置模拟验证结果'),
                      ),
                    if (!c.client.isDemo)
                      TextButton(
                        onPressed: () => widget.onBackend(true),
                        child: const Text('体验演示保险库'),
                      ),
                    if (c.client.isDemo && widget.canNative)
                      TextButton(
                        onPressed: () => widget.onBackend(false),
                        child: const Text('连接本机保险库'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> confirmArchive(KeyItem item) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.metadata.archived ? '恢复这个条目？' : '归档这个条目？'),
        content: Text(
          item.metadata.archived
              ? '恢复后，条目可再次被发现和使用。'
              : '归档会停止正常发现和使用，保留密文与历史版本。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: item.metadata.archived
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: context.kp.danger,
                    foregroundColor: Colors.white,
                  ),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await action(
        c.update(item, item.metadata.withArchived(!item.metadata.archived)),
        item.metadata.archived ? '条目已恢复' : '条目已归档',
      );
    }
  }

  Future<void> fakeDialog() async {
    if (c.client is! FakeKagiClient) return;
    final fake = c.client as FakeKagiClient;
    await showDialog<void>(
      context: context,
      builder: (context) {
        final p = context.kp;
        return AlertDialog(
          title: const Text('模拟验证'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('仅影响内存演示库，不会改变系统认证。'),
                const SizedBox(height: 12),
                for (final entry in [
                  (FakeDecision.approve, '批准', Icons.check_circle_outline),
                  (FakeDecision.deny, '拒绝', Icons.block_rounded),
                  (FakeDecision.locked, '设备锁定', Icons.lock_outline),
                ])
                  ListTile(
                    dense: true,
                    leading: Icon(entry.$3, size: 18),
                    title: Text(
                      entry.$2,
                      style: TextStyle(fontSize: 13, color: p.ink),
                    ),
                    selected: fake.decision == entry.$1,
                    selectedTileColor: p.selection,
                    trailing: fake.decision == entry.$1
                        ? Icon(Icons.check_rounded, color: p.accent, size: 18)
                        : null,
                    onTap: () {
                      fake.decision = entry.$1;
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> editDialog([KeyItem? item]) async {
    final draft = await showDialog<KeyDraft>(
      context: context,
      builder: (_) => _EditDialog(
        item: item,
        spaces: c.current!.spaces,
        initialSpace: c.selectedSpace,
      ),
    );
    if (draft == null) return;
    await action(
      item == null ? c.create(draft) : c.update(item, draft.metadata),
      item == null ? '条目已添加' : '管理信息已更新',
    );
  }

  Future<void> spaceDialog([Space? space]) async {
    final draft = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _SpaceDialog(space: space),
    );
    if (draft != null) {
      await action(
        c.changeSpace(space == null ? 'create' : 'rename', draft.$1, draft.$2),
        'Space 已保存',
      );
    }
  }

  Future<void> syncDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SyncDialog(controller: c),
    );
  }
}
