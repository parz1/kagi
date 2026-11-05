import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

class CoreFailure implements Exception {
  final int code;
  final String message;
  const CoreFailure(this.code, this.message);
  @override
  String toString() => message;
}

class KeyMetadata {
  final String? title, notes;
  final String space;
  final List<String> tags;
  final bool archived;
  const KeyMetadata({
    this.title,
    this.notes,
    this.space = 'default',
    this.tags = const [],
    this.archived = false,
  });
  factory KeyMetadata.fromJson(Map<String, dynamic> json) => KeyMetadata(
    title: json['title'],
    notes: json['notes'],
    space: json['space'] ?? 'default',
    tags: List<String>.from(json['tags'] ?? []),
    archived: json['archived'] ?? false,
  );
  Map<String, dynamic> toJson() => {
    'title': title,
    'notes': notes,
    'space': space,
    'tags': tags,
    'archived': archived,
  };
  KeyMetadata withArchived(bool value) => KeyMetadata(
    title: title,
    notes: notes,
    space: space,
    tags: tags,
    archived: value,
  );
}

class Space {
  final String id, name;
  const Space(this.id, this.name);
  factory Space.fromJson(Map<String, dynamic> json) =>
      Space(json['id'], json['name']);
}

class KeyItem {
  final String entry, revision, ref, kind, updated;
  final int version;
  final KeyMetadata metadata;
  const KeyItem({
    required this.entry,
    required this.revision,
    required this.ref,
    required this.kind,
    required this.updated,
    required this.version,
    required this.metadata,
  });
  String get title => metadata.title ?? ref;
  factory KeyItem.fromJson(Map<String, dynamic> json) {
    final record = Map<String, dynamic>.from(json['record']);
    return KeyItem(
      entry: json['entry'],
      revision: json['revision'],
      ref: record['ref'],
      kind: record['kind'],
      updated: record['updated'],
      version: record['latestVersion'],
      metadata: KeyMetadata.fromJson(record['metadata']),
    );
  }
}

class CoreCapabilities {
  final bool manage, copySecret, totp, directorySync, passkeyProvider;
  const CoreCapabilities({
    this.manage = false,
    this.copySecret = false,
    this.totp = false,
    this.directorySync = false,
    this.passkeyProvider = false,
  });
  factory CoreCapabilities.fromJson(Map<String, dynamic> json) =>
      CoreCapabilities(
        manage: json['manage'] == true,
        copySecret: json['copySecret'] == true,
        totp: json['totp'] == true,
        directorySync: json['directorySync'] == true,
        passkeyProvider: json['passkeyProvider'] == true,
      );
}

class VaultSnapshot {
  final String mode, status;
  final String? vaultID;
  final List<Space> spaces;
  final List<KeyItem> keys;
  final CoreCapabilities capabilities;
  const VaultSnapshot({
    required this.mode,
    required this.status,
    this.vaultID,
    this.spaces = const [],
    this.keys = const [],
    this.capabilities = const CoreCapabilities(),
  });
  factory VaultSnapshot.fromJson(Map<String, dynamic> json) => VaultSnapshot(
    mode: json['mode'],
    status: json['status'],
    vaultID: json['vaultID'],
    capabilities: CoreCapabilities.fromJson(
      Map<String, dynamic>.from(json['capabilities'] ?? {}),
    ),
    spaces: (json['spaces'] as List? ?? [])
        .map((e) => Space.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    keys: (json['keys'] as List? ?? [])
        .map((e) => KeyItem.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class KeyDraft {
  final String ref, value, kind;
  final KeyMetadata metadata;
  const KeyDraft(this.ref, this.value, this.kind, this.metadata);
}

class OTPCode {
  final String code;
  final DateTime expires;
  const OTPCode(this.code, this.expires);
  factory OTPCode.fromJson(Map<String, dynamic> json) => OTPCode(
    json['code'],
    DateTime.fromMillisecondsSinceEpoch(
      (json['validUntil'] as num).toInt() * 1000,
    ),
  );
}

class SyncConflict {
  final String id, item;
  final Map<String, dynamic> local, remote;
  const SyncConflict(this.id, this.item, this.local, this.remote);
  factory SyncConflict.fromJson(Map<String, dynamic> json) => SyncConflict(
    json['id'],
    json['item'],
    Map<String, dynamic>.from(json['local']),
    Map<String, dynamic>.from(json['remote']),
  );
  String describe(bool ours) {
    final side = ours ? local : remote;
    final keys = side['keys'] as List? ?? [];
    final spaces = side['spaces'] as List? ?? [];
    if (keys.isEmpty && spaces.isEmpty) {
      return side['present'] == false ? '此侧不存在' : '库文件发生变化';
    }
    return [
      ...keys.map(
        (k) =>
            '${k['metadata']?['title'] ?? k['ref']} · 第 ${k['latestVersion']} 版 · ${k['metadata']?['archived'] == true ? '已归档' : '可用'}',
      ),
      ...spaces.map((s) => 'Space：${s['name']}'),
    ].join('\n');
  }
}

class SyncOutcome {
  final VaultSnapshot snapshot;
  final List<SyncConflict> conflicts;
  const SyncOutcome(this.snapshot, this.conflicts);
}

/// Platform-neutral business contract. No generic raw-secret read or recovery-key endpoint.
abstract class KagiClient {
  bool get isDemo;
  Future<VaultSnapshot> snapshot();
  Future<VaultSnapshot> unlock();
  Future<void> lock();
  Future<VaultSnapshot> create(KeyDraft draft);
  Future<VaultSnapshot> update(KeyItem expected, KeyMetadata metadata);
  Future<VaultSnapshot> space(String action, String id, String? name);
  Future<void> copySecret(KeyItem expected);
  Future<OTPCode> totp(KeyItem expected);
  Future<SyncOutcome> synchronize(
    String remotePath,
    Map<String, String> resolutions,
  );
}

abstract class JsonKagiClient extends KagiClient {
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> arguments,
  );
  @override
  Future<VaultSnapshot> snapshot() async =>
      VaultSnapshot.fromJson(await invoke('snapshot', {}));
  @override
  Future<VaultSnapshot> unlock() async =>
      VaultSnapshot.fromJson(await invoke('unlock', {}));
  @override
  Future<void> lock() async {
    await invoke('lock', {});
  }

  @override
  Future<VaultSnapshot> create(KeyDraft draft) async => VaultSnapshot.fromJson(
    await invoke('create', {
      'ref': draft.ref,
      'value': draft.value,
      'kind': draft.kind,
      'metadata': draft.metadata.toJson(),
    }),
  );
  @override
  Future<VaultSnapshot> update(KeyItem expected, KeyMetadata metadata) async =>
      VaultSnapshot.fromJson(
        await invoke('update', {
          'ref': expected.ref,
          'revision': expected.revision,
          'metadata': metadata.toJson(),
        }),
      );
  @override
  Future<VaultSnapshot> space(String action, String id, String? name) async =>
      VaultSnapshot.fromJson(
        await invoke('space', {'action': action, 'id': id, 'name': ?name}),
      );
  Map<String, dynamic> _expected(KeyItem item) => {
    'ref': item.ref,
    'revision': item.revision,
  };
  @override
  Future<void> copySecret(KeyItem expected) async {
    await invoke('copySecret', _expected(expected));
  }

  @override
  Future<OTPCode> totp(KeyItem expected) async =>
      OTPCode.fromJson(await invoke('totp', _expected(expected)));
  @override
  Future<SyncOutcome> synchronize(
    String path,
    Map<String, String> resolutions,
  ) async {
    final result = await invoke('sync', {
      'remotePath': path,
      'resolutions': resolutions,
    });
    return SyncOutcome(
      VaultSnapshot.fromJson(result['snapshot']),
      (result['sync']['conflicts'] as List)
          .map((e) => SyncConflict.fromJson(e))
          .toList(),
    );
  }
}

class NativeKagiClient extends JsonKagiClient {
  static const channel = MethodChannel('dev.kagi/core.v1');
  @override
  bool get isDemo => false;
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final text = await channel.invokeMethod<String>(
        'request',
        jsonEncode({'version': 1, 'method': method, 'arguments': arguments}),
      );
      final response = jsonDecode(text ?? '') as Map<String, dynamic>;
      if (response['version'] != 1) throw const CoreFailure(65, '核心协议版本不匹配。');
      if (response['error'] != null) {
        throw CoreFailure(
          response['error']['code'],
          response['error']['message'],
        );
      }
      return Map<String, dynamic>.from(response['result']);
    } on MissingPluginException {
      throw const CoreFailure(78, '此平台还没有接入原生核心，请选择演示保险库。');
    } on PlatformException {
      throw const CoreFailure(70, '原生桥接调用失败，请重试。');
    } on FormatException {
      throw const CoreFailure(65, '核心返回格式无效。');
    }
  }
}

enum FakeDecision { approve, deny, locked }

class FakeKagiClient extends JsonKagiClient {
  FakeDecision decision = FakeDecision.approve;
  bool _locked = false, _conflict = false;
  int _revision = 10;
  final List<Map<String, dynamic>> _keys = [];
  final List<Map<String, dynamic>> _spaces = [
    {'id': 'default', 'name': '个人'},
    {'id': 'work', 'name': '工作室'},
    {'id': 'lab', 'name': '实验室'},
  ];
  final Map<String, String> _values = {};
  final Future<void> Function(String)? copy;
  FakeKagiClient({this.copy, bool seeded = true}) {
    if (seeded) {
      _add('openai/api-key', 'OpenAI', 'secret', 'work', [
        '生产',
        'API',
      ], '工作室的应用服务密钥');
      _add('github/access-token', 'GitHub', 'secret', 'work', [
        '开发',
        '代码',
      ], '代码仓库与自动化任务');
      _add('google/authenticator', 'Google', 'totp', 'default', [
        '验证器',
      ], '日常账号的两步验证');
      _add('cloudflare/dns-token', 'Cloudflare', 'secret', 'work', [
        '基础设施',
      ], '域名与 DNS 管理');
      _add('github/passkey', 'GitHub Passkey', 'passkey', 'default', [
        '通行密钥',
      ], '仅演示凭据管理，未接入系统提供者');
      _add('supabase/dev-token', 'Supabase', 'secret', 'lab', [
        '开发',
        '数据库',
      ], '研究用开发环境');
      _add('vercel/deploy-token', 'Vercel', 'secret', 'work', ['部署'], '站点部署');
      _add('linear/api-token', 'Linear', 'secret', 'work', ['协作'], '工作室任务管理');
      _add('npm/publish-token', 'npm', 'secret', 'work', ['开发'], '包发布令牌');
      _add('docker/registry-token', 'Docker Hub', 'secret', 'work', [
        '基础设施',
      ], '容器镜像仓库');
      _add('tailscale/auth-key', 'Tailscale', 'secret', 'lab', [
        '基础设施',
      ], '实验设备接入');
      _add('proton/authenticator', 'Proton Mail', 'totp', 'default', [
        '验证器',
      ], '个人邮箱两步验证');
    }
  }
  @override
  bool get isDemo => true;
  void simulateConflict() {
    _conflict = _keys.isNotEmpty;
  }

  void _add(
    String ref,
    String title,
    String kind,
    String space,
    List<String> tags,
    String notes, {
    String value = 'FAKE-KAGI-DEMO-VALUE',
  }) {
    final item = {
      'entry': 'demo-${++_revision}',
      'revision': 'demo-r$_revision',
      'record': {
        'ref': ref,
        'kind': kind,
        'created': '2026-10-30T00:00:00Z',
        'updated': '2026-10-30T00:00:00Z',
        'latestVersion': 1,
        'metadata': KeyMetadata(
          title: title,
          space: space,
          tags: tags,
          notes: notes,
        ).toJson(),
      },
    };
    _keys.add(item);
    _values[ref] = value;
  }

  Map<String, dynamic> _snapshot() => jsonDecode(
    jsonEncode({
      'mode': 'fake',
      'status': _locked ? 'locked' : 'ready',
      'vaultID': 'demo-vault',
      'spaces': _locked ? [] : _spaces,
      'keys': _locked ? [] : _keys,
      'capabilities': {
        'manage': true,
        'copySecret': true,
        'totp': true,
        'passkeyProvider': false,
        'directorySync': true,
      },
    }),
  );
  void _authorize() {
    if (decision == FakeDecision.deny) {
      throw const CoreFailure(77, '已取消本次验证，保险库没有修改。');
    }
    if (decision == FakeDecision.locked) {
      _locked = true;
      throw const CoreFailure(75, '模拟设备已锁定。');
    }
  }

  Map<String, dynamic> _checkedItem(Map<String, dynamic> args) {
    final found = _keys
        .where((k) => k['record']['ref'] == args['ref'])
        .firstOrNull;
    if (found == null) throw const CoreFailure(66, '条目不存在。');
    if (found['revision'] != args['revision']) {
      throw const CoreFailure(75, '条目已变化，请刷新。');
    }
    return found;
  }

  void _validateMetadata(Map<String, dynamic> metadata) {
    if (!_spaces.any((s) => s['id'] == metadata['space'])) {
      throw const CoreFailure(66, 'Space 不存在。');
    }
    final title = metadata['title'] as String?;
    final notes = metadata['notes'] as String?;
    final tags = List<String>.from(metadata['tags']);
    if ((title?.length ?? 0) > 120 ||
        (notes?.length ?? 0) > 4000 ||
        tags.length > 32 ||
        tags.any((t) => t.isEmpty || t.length > 64)) {
      throw const CoreFailure(64, '管理字段长度不符合要求。');
    }
  }

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> args,
  ) async {
    await Future<void>.value();
    if (method == 'lock') {
      _locked = true;
      return {'locked': true};
    }
    if (method == 'snapshot') return _snapshot();
    if (method == 'unlock') {
      _authorize();
      _locked = false;
      return _snapshot();
    }
    if (_locked) throw const CoreFailure(75, '保险库已锁定。');
    _authorize();
    switch (method) {
      case 'create':
        final ref = args['ref'] as String;
        if (!RegExp(r'^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*$')
                .hasMatch(ref) ||
            ref.length > 200 ||
            ref.split('/').any((s) => s.length > 64)) {
          throw const CoreFailure(64, '引用请使用小写字母、数字和 . _ -，用 / 分段。');
        }
        if (_keys.any((k) => k['record']['ref'] == ref)) {
          throw const CoreFailure(64, '此引用已存在。');
        }
        if (!(args['value'] as String).isNotEmpty ||
            !['secret', 'totp'].contains(args['kind'])) {
          throw const CoreFailure(64, '请填写密钥或 TOTP 种子。');
        }
        final metadata = Map<String, dynamic>.from(args['metadata']);
        _validateMetadata(metadata);
        _add(
          ref,
          metadata['title'] ?? ref,
          args['kind'],
          metadata['space'],
          List<String>.from(metadata['tags']),
          metadata['notes'] ?? '',
          value: args['value'],
        );
        return _snapshot();
      case 'update':
        final item = _checkedItem(args);
        final metadata = Map<String, dynamic>.from(args['metadata']);
        _validateMetadata(metadata);
        item['record']['metadata'] = metadata;
        item['revision'] = 'demo-r${++_revision}';
        return _snapshot();
      case 'copySecret':
        final item = _checkedItem(args);
        if (item['record']['kind'] != 'secret' ||
            item['record']['metadata']['archived'] == true) {
          throw const CoreFailure(64, '此凭据不能复制。');
        }
        if (copy != null) await copy!(_values[args['ref']]!);
        return {'copied': true, 'clearAfter': 30};
      case 'totp':
        final item = _checkedItem(args);
        if (item['record']['kind'] != 'totp' ||
            item['record']['metadata']['archived'] == true) {
          throw const CoreFailure(64, '此条目不是可用的 TOTP。');
        }
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return {
          'code': '246810',
          'validFrom': now - now % 30,
          'validUntil': now - now % 30 + 30,
        };
      case 'space':
        final id = args['id'] as String;
        final existing = _spaces.where((s) => s['id'] == id).firstOrNull;
        if (args['action'] == 'create') {
          if (existing != null ||
              !RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(id) ||
              (args['name'] as String).trim().isEmpty) {
            throw const CoreFailure(64, 'Space ID 或名称无效。');
          }
          _spaces.add({'id': id, 'name': args['name']});
        } else if (args['action'] == 'rename' && existing != null) {
          existing['name'] = args['name'];
        } else if (args['action'] == 'remove' && existing != null) {
          if (id == 'default' ||
              _keys.any((k) => k['record']['metadata']['space'] == id)) {
            throw const CoreFailure(64, '默认或非空 Space 不能删除。');
          }
          _spaces.remove(existing);
        } else {
          throw const CoreFailure(66, 'Space 不存在。');
        }
        return _snapshot();
      case 'sync':
        final choices = Map<String, String>.from(args['resolutions']);
        if (choices.isNotEmpty &&
            (!_conflict ||
                choices.length != 1 ||
                !['local', 'remote'].contains(choices['demo-conflict-1']))) {
          throw const CoreFailure(64, '冲突选择已过期。');
        }
        if (_conflict && choices.isEmpty) {
          final record = _keys.first['record'];
          final theirs = jsonDecode(jsonEncode(record));
          theirs['latestVersion'] = 2;
          return {
            'snapshot': _snapshot(),
            'sync': {
              'revision': 'demo-head',
              'conflicts': [
                {
                  'id': 'demo-conflict-1',
                  'item': 'key:${record['ref']}',
                  'local': {
                    'keys': [record],
                    'spaces': [],
                    'present': true,
                  },
                  'remote': {
                    'keys': [theirs],
                    'spaces': [],
                    'present': true,
                  },
                },
              ],
            },
          };
        }
        if (_conflict && choices['demo-conflict-1'] == 'remote') {
          _keys.first['record']['latestVersion'] = 2;
          _keys.first['revision'] = 'demo-r${++_revision}';
        }
        _conflict = false;
        return {
          'snapshot': _snapshot(),
          'sync': {'revision': 'demo-head', 'conflicts': []},
        };
      default:
        throw const CoreFailure(64, '不支持的演示操作。');
    }
  }
}
