part of 'vault_app.dart';

class _EditDialog extends StatefulWidget {
  final KeyItem? item;
  final List<Space> spaces;
  final String? initialSpace;
  const _EditDialog({this.item, required this.spaces, this.initialSpace});
  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController title, ref, value, tags, notes;
  late String space;
  String kind = 'secret';
  String? error;
  @override
  void initState() {
    super.initState();
    final item = widget.item;
    title = TextEditingController(text: item?.metadata.title);
    ref = TextEditingController(text: item?.ref);
    value = TextEditingController();
    tags = TextEditingController(text: item?.metadata.tags.join(', '));
    notes = TextEditingController(text: item?.metadata.notes);
    space = item?.metadata.space ?? widget.initialSpace ?? 'default';
    kind = item?.kind ?? 'secret';
  }

  @override
  void dispose() {
    title.dispose();
    ref.dispose();
    value.clear();
    value.dispose();
    tags.dispose();
    notes.dispose();
    super.dispose();
  }

  void save() {
    final reference = ref.text.trim();
    if (reference.isEmpty || (widget.item == null && value.text.isEmpty)) {
      setState(() {
        error = '请填写引用和密钥值。';
      });
      return;
    }
    final normalizedTags =
        tags.text
            .split(RegExp('[,，]'))
            .map((t) => t.trim().toLowerCase())
            .where((t) => t.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    Navigator.pop(
      context,
      KeyDraft(
        reference,
        value.text,
        kind,
        KeyMetadata(
          title: title.text.trim().isEmpty ? null : title.text.trim(),
          notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
          space: space,
          tags: normalizedTags,
          archived: widget.item?.metadata.archived ?? false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.item == null ? '添加条目' : '编辑管理信息'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('draft-title'),
              autofocus: true,
              controller: title,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('draft-ref'),
              controller: ref,
              enabled: widget.item == null,
              decoration: const InputDecoration(
                labelText: '唯一引用，例如 openai/api-key',
              ),
            ),
            if (widget.item == null) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: kind,
                items: const [
                  DropdownMenuItem(value: 'secret', child: Text('普通密钥')),
                  DropdownMenuItem(value: 'totp', child: Text('TOTP 验证器')),
                ],
                onChanged: (value) => setState(() {
                  kind = value!;
                }),
                decoration: const InputDecoration(labelText: '类型'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('draft-value'),
                controller: value,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: kind == 'totp' ? 'otpauth URI 或 Base32 种子' : '密钥值',
                ),
              ),
            ],
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: space,
              items: widget.spaces
                  .map(
                    (s) => DropdownMenuItem(value: s.id, child: Text(s.name)),
                  )
                  .toList(),
              onChanged: (value) => space = value!,
              decoration: const InputDecoration(labelText: 'Space'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('draft-tags'),
              controller: tags,
              decoration: const InputDecoration(labelText: '标签，用逗号分隔'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('draft-notes'),
              controller: notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '备注'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  style: TextStyle(fontSize: 12.5, color: context.kp.danger),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('save-draft'),
        onPressed: save,
        child: const Text('验证并保存'),
      ),
    ],
  );
}

class _SyncDialog extends StatefulWidget {
  final VaultController controller;
  const _SyncDialog({required this.controller});
  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  final path = TextEditingController();
  final Map<String, String> choices = {};
  bool busy = false;
  String? message;
  VaultController get c => widget.controller;
  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> sync() async {
    setState(() {
      busy = true;
      message = null;
    });
    final ok = await c.sync(
      c.client.isDemo ? '/demo/remote' : path.text.trim(),
      choices,
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (ok && c.conflicts.isEmpty) choices.clear();
      message = ok
          ? c.conflicts.isEmpty
                ? '同步完成，所有修改已保留。'
                : '双方版本均已保留，请核对后选择。'
          : c.error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('同步与冲突'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              c.client.isDemo
                  ? '演示同步：不会连接任何云端或读取本机文件。'
                  : '当前支持独立目录仓库。iCloud、Google Drive、WebDAV 将分别接入。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: context.kp.muted,
              ),
            ),
            const SizedBox(height: 18),
            if (!c.client.isDemo)
              TextField(
                key: const Key('sync-path'),
                controller: path,
                decoration: const InputDecoration(labelText: '独立仓库的绝对目录路径'),
              ),
            if (c.client.isDemo)
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        (c.client as FakeKagiClient).simulateConflict();
                        choices.clear();
                        unawaited(sync());
                      },
                icon: const Icon(Icons.compare_arrows, size: 17),
                label: const Text('模拟双设备冲突'),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Text(
                  message!,
                  style: TextStyle(fontSize: 12.5, color: context.kp.accent),
                ),
              ),
            for (final conflict in c.conflicts)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      conflict.item,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (final side in ['local', 'remote'])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: busy
                              ? null
                              : () => setState(() {
                                  choices[conflict.id] = side;
                                }),
                          borderRadius: BorderRadius.circular(5),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: choices[conflict.id] == side
                                  ? context.kp.selection
                                  : context.kp.card,
                              border: Border.all(
                                color: choices[conflict.id] == side
                                    ? context.kp.accent
                                    : context.kp.line,
                              ),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  choices[conflict.id] == side
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                  size: 18,
                                  color: context.kp.accent,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        side == 'local' ? '保留本机版本' : '保留远端版本',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        conflict.describe(side == 'local'),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: context.kp.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(
        key: const Key('sync-submit'),
        onPressed:
            busy ||
                (c.conflicts.isNotEmpty &&
                    c.conflicts.any((x) => choices[x.id] == null))
            ? null
            : sync,
        child: Text(
          busy
              ? '正在同步…'
              : c.conflicts.isEmpty
              ? '检查并同步'
              : '验证并应用选择',
        ),
      ),
    ],
  );
}

class _SpaceDialog extends StatefulWidget {
  final Space? space;
  const _SpaceDialog({this.space});
  @override
  State<_SpaceDialog> createState() => _SpaceDialogState();
}

class _SpaceDialogState extends State<_SpaceDialog> {
  late final TextEditingController id, name;
  String? error;
  @override
  void initState() {
    super.initState();
    id = TextEditingController(text: widget.space?.id);
    name = TextEditingController(text: widget.space?.name);
  }

  @override
  void dispose() {
    id.dispose();
    name.dispose();
    super.dispose();
  }

  void save() {
    final idValue = id.text.trim(), nameValue = name.text.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(idValue) ||
        nameValue.isEmpty ||
        nameValue.length > 120) {
      setState(() {
        error = '请填写有效 ID 和显示名称。';
      });
      return;
    }
    Navigator.pop(context, (idValue, nameValue));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.space == null ? '新建 Space' : '重命名 Space'),
    content: SizedBox(
      width: 320,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('space-id'),
              controller: id,
              enabled: widget.space == null,
              autofocus: widget.space == null,
              decoration: const InputDecoration(labelText: 'ID，例如 work'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('space-name'),
              controller: name,
              autofocus: widget.space != null,
              onSubmitted: (_) => save(),
              decoration: const InputDecoration(labelText: '显示名称'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  style: TextStyle(fontSize: 12.5, color: context.kp.danger),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: save, child: const Text('保存')),
    ],
  );
}
