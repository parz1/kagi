import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/client.dart';
import '../core/controller.dart';

part 'dialogs.dart';
part 'components.dart';

const ink = Color(0xFF1F2933);
const muted = Color(0xFF5F6C76);
const accent = Color(0xFF1E6470);
const line = Color(0xFFDDE2E5);
const rail = Color(0xFFF2F4F5);
const selection = Color(0xFFE7F0F1);

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
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    }
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
            : const Duration(milliseconds: 120),
        reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        transitionsBuilder: (context, animation, secondary, child) =>
            FadeTransition(opacity: animation, child: child),
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
                ],
              ),
              body: c.current?.status == 'ready' && current != null
                  ? inspector(current, phone: true)
                  : const Center(child: Text('保险库已锁定，请返回解锁。')),
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
      final desktop = MediaQuery.sizeOf(context).width >= 980;
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
            appBar: desktop
                ? null
                : AppBar(
                    titleSpacing: 0,
                    title: Row(
                      children: [
                        const _Brand(compact: true),
                        const SizedBox(width: 10),
                        _ModeMark(
                          c.current?.mode ??
                              (c.client.isDemo ? 'fake' : 'native'),
                        ),
                      ],
                    ),
                    actions: [
                      backendMenu(),
                      IconButton(
                        tooltip: '同步与冲突',
                        onPressed: status == 'ready' && canSync
                            ? syncDialog
                            : null,
                        icon: const Icon(Icons.sync_outlined, size: 20),
                      ),
                      IconButton(
                        tooltip: '锁定保险库',
                        onPressed: status == 'ready' ? c.lock : null,
                        icon: const Icon(Icons.lock_outline, size: 20),
                      ),
                    ],
                  ),
            drawer: !desktop && status == 'ready'
                ? Drawer(
                    width: 260,
                    child: SafeArea(child: sidebar(phone: true)),
                  )
                : null,
            body: status == null
                ? c.error == null
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : stateView('error')
                : status != 'ready'
                ? stateView(status)
                : desktop
                ? Row(
                    children: [
                      SizedBox(
                        key: const Key('vault-sidebar'),
                        width: 172,
                        child: sidebar(),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: tablePanel()),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 300,
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
    icon: const Icon(Icons.unfold_more, size: 17),
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
  );

  Widget sidebar({bool phone = false}) {
    void go({String? space, String? tag, bool archived = false}) {
      navigate(space: space, tag: tag, archived: archived);
      if (phone) Navigator.pop(context);
    }

    return Material(
      color: rail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const _Brand(),
                  const Spacer(),
                  if (!phone) backendMenu(),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 10),
          navTile(
            '所有条目',
            Icons.apps_outlined,
            c.selectedSpace == null && c.selectedTag == null && !c.archived,
            () => go(),
            count: c.current!.keys.where((k) => !k.metadata.archived).length,
            phone: phone,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 3, 8, 6),
                  child: Row(
                    children: [
                      const Expanded(child: _Label('Space')),
                      _ToolIcon(
                        key: const Key('add-space'),
                        label: '新建 Space',
                        icon: Icons.add,
                        onPressed: canManage ? spaceDialog : null,
                      ),
                    ],
                  ),
                ),
                for (final space in c.current!.spaces)
                  navTile(
                    space.name,
                    space.id == 'default'
                        ? Icons.person_outline
                        : space.id == 'work'
                        ? Icons.work_outline
                        : Icons.science_outlined,
                    c.selectedSpace == space.id && !c.archived,
                    () => go(space: space.id),
                    phone: phone,
                    count: c.current!.keys
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
                      iconSize: 14,
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 8, 8),
                  child: _Label('标签'),
                ),
                for (final tag in c.tags)
                  navTile(
                    tag,
                    Icons.tag,
                    c.selectedTag == tag,
                    () => go(tag: tag),
                    phone: phone,
                    compact: true,
                  ),
                const SizedBox(height: 14),
                navTile(
                  '已归档',
                  Icons.archive_outlined,
                  c.archived,
                  () => go(archived: true),
                  phone: phone,
                  count: c.current!.keys
                      .where((k) => k.metadata.archived)
                      .length,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          navTile(
            '同步与冲突',
            Icons.sync_outlined,
            false,
            canSync ? syncDialog : null,
            phone: phone,
            count: c.conflicts.isEmpty ? null : c.conflicts.length,
          ),
          navTile('锁定保险库', Icons.lock_outline, false, c.lock, phone: phone),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    c.client.isDemo
                        ? '演示保险库'
                        : c.current?.mode == 'software'
                        ? 'Swift 测试保险库'
                        : '本机保险库',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                if (c.client.isDemo)
                  _ToolIcon(
                    label: '模拟验证',
                    icon: Icons.tune,
                    onPressed: fakeDialog,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget navTile(
    String title,
    IconData icon,
    bool active,
    VoidCallback? onTap, {
    int? count,
    Widget? menu,
    bool phone = false,
    bool compact = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    child: Material(
      color: active ? selection : Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          height: phone
              ? 44
              : compact
              ? 27
              : 32,
          child: Padding(
            padding: const EdgeInsets.only(left: 9, right: 5),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: compact ? 13 : 16,
                  color: active ? accent : muted,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: phone ? 14 : 12,
                      color: active ? accent : ink,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (count != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '$count',
                      style: const TextStyle(fontSize: 10, color: muted),
                    ),
                  ),
                if (menu != null) SizedBox(width: 19, height: 24, child: menu),
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
    onChanged: c.search,
    style: TextStyle(fontSize: phone ? 14 : 12),
    decoration: InputDecoration(
      hintText: phone ? '搜索名称、引用、标签' : '搜索条目',
      prefixIcon: Icon(Icons.search, size: phone ? 19 : 16),
      prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 32),
      suffixIcon: search.text.isEmpty
          ? null
          : IconButton(
              tooltip: '清除搜索',
              icon: const Icon(Icons.close, size: 15),
              onPressed: () {
                search.clear();
                c.search('');
              },
            ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: 10,
        vertical: phone ? 11 : 8,
      ),
    ),
  );

  Widget addButton({bool phone = false}) => IconButton.filled(
    key: const Key('add-key'),
    tooltip: '添加条目',
    onPressed: canManage ? () => editDialog() : null,
    style: IconButton.styleFrom(
      backgroundColor: accent,
      foregroundColor: Colors.white,
      minimumSize: Size.square(phone ? 44 : 30),
      maximumSize: Size.square(phone ? 44 : 30),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    icon: const Icon(Icons.add, size: 19),
  );

  Widget typeMenu() => SizedBox(
    height: MediaQuery.sizeOf(context).width < 980 ? 44 : 30,
    child: PopupMenuButton<String>(
      tooltip: '筛选凭据类型',
      initialValue: kind,
      onSelected: chooseKind,
      itemBuilder: (_) => [
        for (final entry in const {
          'all': '全部类型',
          'secret': '密钥',
          'totp': 'TOTP 验证器',
          'passkey': 'Passkey',
        }.entries)
          CheckedPopupMenuItem(
            key: Key('kind-${entry.key}'),
            value: entry.key,
            checked: entry.key == kind,
            child: Text(entry.value),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_list, size: 15, color: muted),
            const SizedBox(width: 5),
            Text(
              kind == 'all' ? '全部类型' : kindLabel(kind),
              style: const TextStyle(fontSize: 11, color: muted),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.expand_more, size: 13, color: muted),
          ],
        ),
      ),
    ),
  );

  Widget tablePanel() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = _Columns(constraints.maxWidth);
      return Material(
        color: Colors.white,
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Text(
                      sectionTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${items.length}',
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: (constraints.maxWidth * .38).clamp(140, 260),
                      height: 32,
                      child: searchField(),
                    ),
                    const SizedBox(width: 8),
                    _ToolIcon(
                      label: '刷新',
                      icon: Icons.refresh,
                      onPressed: c.busy ? null : () => action(c.load()),
                    ),
                    const SizedBox(width: 6),
                    addButton(),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              height: 34,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    typeMenu(),
                    const SizedBox(width: 8),
                    const SizedBox(
                      height: 12,
                      child: VerticalDivider(width: 1),
                    ),
                    const SizedBox(width: 7),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => setState(() {
                        ascending = !ascending;
                      }),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Row(
                          children: [
                            const Text(
                              '名称',
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              ascending
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 12,
                              color: muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (c.selectedTag != null) ...[
                      const SizedBox(width: 8),
                      _Pill('# ${c.selectedTag}'),
                    ],
                    const Spacer(),
                    if (c.selectedSpace != null ||
                        c.selectedTag != null ||
                        c.query.isNotEmpty ||
                        kind != 'all')
                      TextButton(
                        onPressed: () => navigate(),
                        child: const Text(
                          '清除筛选',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (c.busy) const LinearProgressIndicator(minHeight: 2),
            Container(
              height: 28,
              decoration: const BoxDecoration(
                color: rail,
                border: Border(bottom: BorderSide(color: line)),
              ),
              child: _TableCells(columns: columns),
            ),
            Expanded(
              child: items.isEmpty
                  ? emptyList()
                  : ListView.builder(
                      key: const Key('key-table'),
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      itemBuilder: (_, index) => _KeyRow(
                        key: Key('item-${items[index].ref}'),
                        item: items[index],
                        columns: columns,
                        selected: c.selectedRef == items[index].ref,
                        onTap: () => openItem(items[index], false),
                      ),
                    ),
            ),
            Container(
              height: 27,
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: line)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  const Icon(
                    Icons.offline_bolt_outlined,
                    size: 12,
                    color: muted,
                  ),
                  const SizedBox(width: 5),
                  const Text(
                    '离线可用',
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                  const Spacer(),
                  Text(
                    c.client.isDemo
                        ? '演示数据，不读取真实密钥'
                        : c.lastSync == null
                        ? '本地加密库'
                        : '同步已完成',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget phoneList() => Material(
    color: Colors.white,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 8),
          child: Row(
            children: [
              Text(
                sectionTitle,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '${items.length}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
              const Spacer(),
              addButton(phone: true),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: searchField(phone: true),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              typeMenu(),
              if (c.selectedTag != null) _Pill('# ${c.selectedTag}'),
              const Spacer(),
              _ToolIcon(
                label: '刷新',
                icon: Icons.refresh,
                onPressed: c.busy ? null : () => action(c.load()),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (c.busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: items.isEmpty
              ? emptyList()
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Padding(
                    padding: EdgeInsets.only(left: 52),
                    child: Divider(height: 1),
                  ),
                  itemBuilder: (_, index) {
                    final item = items[index];
                    return InkWell(
                      key: Key('item-${item.ref}'),
                      onTap: () => openItem(item, true),
                      child: SizedBox(
                        height:
                            58 *
                            MediaQuery.textScalerOf(context).scale(14) /
                            14,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              _EntryIcon(item.kind, item.title, small: true),
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
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: ink,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      item.ref,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                item.kind == 'secret'
                                    ? ''
                                    : kindLabel(item.kind),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(width: 5),
                              const Icon(
                                Icons.chevron_right,
                                size: 17,
                                color: muted,
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

  Widget emptyList() => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('没有匹配的条目', style: TextStyle(fontSize: 13, color: ink)),
          const SizedBox(height: 8),
          if (c.query.isNotEmpty || kind != 'all' || c.selectedTag != null)
            TextButton(onPressed: () => navigate(), child: const Text('清除筛选'))
          else
            TextButton(
              onPressed: canManage ? () => editDialog() : null,
              child: const Text('添加第一个条目'),
            ),
        ],
      ),
    ),
  );
  Widget emptyInspector() => const Center(
    child: Padding(
      padding: EdgeInsets.all(20),
      child: Text('选择条目查看详情', style: TextStyle(fontSize: 12, color: muted)),
    ),
  );

  Widget inspector(KeyItem item, {bool phone = false}) => Material(
    color: Colors.white,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!phone)
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: line)),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '条目详情',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
                _ToolIcon(
                  label: '关闭详情',
                  icon: Icons.close,
                  onPressed: () => c.select(null),
                ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(phone ? 18 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!phone)
                  Row(
                    children: [
                      _EntryIcon(item.kind, item.title, small: true),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                if (!phone) const SizedBox(height: 10),
                SelectableText(
                  item.ref,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: muted,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: EdgeInsets.all(phone ? 14 : 12),
                  decoration: const BoxDecoration(
                    color: rail,
                    border: Border(left: BorderSide(color: accent, width: 2)),
                  ),
                  child: Column(
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
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                          ),
                          const Icon(
                            Icons.lock_outline,
                            size: 12,
                            color: muted,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (item.kind == 'totp' &&
                          c.otpRef == item.ref &&
                          c.otp != null)
                        _OTPDisplay(code: c.otp!, demo: c.client.isDemo)
                      else
                        Text(
                          item.kind == 'passkey'
                              ? '私钥不可导出'
                              : item.kind == 'totp'
                              ? '••• •••'
                              : '••••••••••••',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            fontSize: item.kind == 'passkey' ? 13 : 21,
                            letterSpacing: item.kind == 'passkey' ? 0 : 2,
                            color: ink,
                          ),
                        ),
                      const SizedBox(height: 12),
                      if (item.kind == 'passkey')
                        const Text(
                          '系统提供者尚未接入',
                          style: TextStyle(fontSize: 11, color: muted),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                c.client.isDemo ? '模拟验证' : '操作时验证',
                                style: TextStyle(fontSize: 10, color: muted),
                              ),
                            ),
                            FilledButton.icon(
                              key: const Key('use-key'),
                              onPressed:
                                  c.busy ||
                                      item.metadata.archived ||
                                      (item.kind == 'totp'
                                          ? !c.current!.capabilities.totp
                                          : !c.current!.capabilities.copySecret)
                                  ? null
                                  : () => action(
                                      item.kind == 'totp'
                                          ? c.generateOTP(item)
                                          : c.copy(item),
                                      item.kind == 'totp'
                                          ? null
                                          : c.client.isDemo
                                          ? '已复制演示值，30 秒后清除'
                                          : '已复制，30 秒后自动清除',
                                    ),
                              style: FilledButton.styleFrom(
                                minimumSize: Size(0, phone ? 44 : 30),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                              icon: Icon(
                                item.kind == 'totp'
                                    ? Icons.fingerprint
                                    : Icons.content_copy_outlined,
                                size: 14,
                              ),
                              label: Text(item.kind == 'totp' ? '生成验证码' : '复制'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                metadataRow(
                  'Space',
                  Text(
                    c.current!.spaces
                            .where((s) => s.id == item.metadata.space)
                            .firstOrNull
                            ?.name ??
                        item.metadata.space,
                    style: TextStyle(fontSize: phone ? 14 : 12, color: ink),
                  ),
                ),
                metadataRow(
                  '类型',
                  Text(
                    kindLabel(item.kind),
                    style: TextStyle(fontSize: phone ? 14 : 12, color: ink),
                  ),
                ),
                metadataRow(
                  '版本',
                  Text(
                    '第 ${item.version} 版',
                    style: TextStyle(fontSize: phone ? 14 : 12, color: ink),
                  ),
                ),
                metadataRow(
                  '状态',
                  Text(
                    item.metadata.archived ? '已归档' : '可用',
                    style: TextStyle(
                      fontSize: phone ? 14 : 12,
                      color: item.metadata.archived ? muted : accent,
                    ),
                  ),
                ),
                metadataRow(
                  '标签',
                  item.metadata.tags.isEmpty
                      ? Text(
                          '—',
                          style: TextStyle(
                            fontSize: phone ? 14 : 12,
                            color: muted,
                          ),
                        )
                      : Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: item.metadata.tags
                              .map((tag) => _Pill('# $tag', neutral: true))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 14),
                const _Label('备注'),
                const SizedBox(height: 7),
                Text(
                  item.metadata.notes?.isNotEmpty == true
                      ? item.metadata.notes!
                      : '未填写',
                  style: TextStyle(
                    fontSize: phone ? 14 : 12,
                    color: muted,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('edit-key'),
                      onPressed: canManage ? () => editDialog(item) : null,
                      icon: const Icon(Icons.edit_outlined, size: 14),
                      label: const Text('编辑信息'),
                    ),
                    TextButton.icon(
                      key: const Key('archive-key'),
                      onPressed: canManage ? () => confirmArchive(item) : null,
                      icon: Icon(
                        item.metadata.archived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                        size: 14,
                      ),
                      label: Text(item.metadata.archived ? '恢复条目' : '归档条目'),
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

  Widget metadataRow(String title, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 55,
          child: Text(
            title,
            style: TextStyle(
              fontSize: MediaQuery.sizeOf(context).width < 980 ? 12 : 11,
              color: muted,
            ),
          ),
        ),
        Expanded(child: value),
      ],
    ),
  );

  Widget stateView(String status) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(alignment: Alignment.centerLeft, child: _Brand()),
            const SizedBox(height: 24),
            Text(
              status == 'unconfigured'
                  ? '连接本地保险库'
                  : status == 'error'
                  ? '无法连接核心'
                  : status == 'syncRecovery'
                  ? '上次同步尚未完成'
                  : '保险库已锁定',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              status == 'unconfigured'
                  ? '先在终端完成建库，或体验演示保险库。'
                  : status == 'syncRecovery'
                  ? '使用上次的同步目标恢复安装。'
                  : c.client.isDemo
                  ? '使用虚构数据，模拟批准、拒绝与锁定。'
                  : '通过系统验证打开本地库。',
              style: const TextStyle(fontSize: 12, color: muted, height: 1.7),
            ),
            if (status == 'unconfigured')
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: SelectableText(
                  'kagi init',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  c.error!,
                  style: const TextStyle(
                    color: Color(0xFFAA3C36),
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            if (status == 'locked')
              FilledButton.icon(
                key: const Key('unlock'),
                onPressed: c.busy ? null : () => action(c.unlock()),
                icon: const Icon(Icons.fingerprint, size: 17),
                label: Text(c.busy ? '正在验证…' : '解锁保险库'),
              ),
            if (status == 'syncRecovery')
              FilledButton(
                onPressed: c.busy ? null : syncDialog,
                child: const Text('继续同步恢复'),
              ),
            if (status == 'error')
              OutlinedButton(
                onPressed: c.busy ? null : () => action(c.load()),
                child: const Text('重试连接'),
              ),
            if (c.client.isDemo)
              TextButton(onPressed: fakeDialog, child: const Text('设置模拟验证结果')),
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
      ),
    ),
  );

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
      builder: (context) => AlertDialog(
        title: const Text('模拟验证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '仅影响内存演示库，不会改变系统认证。',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            for (final entry in [
              (FakeDecision.approve, '批准'),
              (FakeDecision.deny, '拒绝'),
              (FakeDecision.locked, '设备锁定'),
            ])
              ListTile(
                title: Text(entry.$2),
                trailing: fake.decision == entry.$1
                    ? const Icon(Icons.check, color: accent)
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
