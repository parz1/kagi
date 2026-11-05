import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';

/// Owns transient screen state. Sensitive code responses are invalidated on lock,
/// navigation, expiry and lifecycle changes; old asynchronous responses cannot restore them.
class VaultController extends ChangeNotifier {
  final KagiClient client;
  VaultSnapshot? current;
  String? selectedRef, selectedSpace, selectedTag, error;
  String query = '';
  bool archived = false, busy = false;
  int searchFocusRequests = 0;
  void requestSearchFocus() {
    if (current?.status != 'ready') return;
    ++searchFocusRequests;
    _notify();
  }

  OTPCode? otp;
  String? otpRef;
  List<SyncConflict> conflicts = [];
  DateTime? lastSync;
  int _epoch = 0;
  bool _disposed = false;
  Timer? _expiry;
  VaultController(this.client);
  List<KeyItem> get visibleKeys => (current?.keys ?? []).where((item) {
    if (item.metadata.archived != archived) return false;
    if (selectedSpace != null && item.metadata.space != selectedSpace) {
      return false;
    }
    if (selectedTag != null && !item.metadata.tags.contains(selectedTag)) {
      return false;
    }
    final fields = [
      item.ref,
      item.title,
      item.metadata.notes ?? '',
      ...item.metadata.tags,
    ].join(' ').toLowerCase();
    return fields.contains(query.toLowerCase());
  }).toList();
  KeyItem? get selected =>
      visibleKeys.where((k) => k.ref == selectedRef).firstOrNull;
  List<String> get tags =>
      (current?.keys.expand((k) => k.metadata.tags).toSet().toList() ?? [])
        ..sort();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _clearOTP() {
    otp = null;
    otpRef = null;
    _expiry?.cancel();
    _expiry = null;
  }

  void hideCodes() {
    _clearOTP();
    _notify();
  }

  void select(KeyItem? item) {
    _clearOTP();
    selectedRef = item?.ref;
    _notify();
  }

  void filter({String? space, String? tag, bool showArchived = false}) {
    _clearOTP();
    selectedSpace = space;
    selectedTag = tag;
    archived = showArchived;
    selectedRef = null;
    _notify();
  }

  void search(String text) {
    _clearOTP();
    query = text;
    selectedRef = null;
    _notify();
  }

  Future<bool> _run(Future<void> Function(int) action) async {
    if (busy) return false;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await action(epoch);
      return epoch == _epoch && !_disposed;
    } on CoreFailure catch (failure) {
      if (epoch == _epoch && !_disposed) {
        error = failure.message;
        if (failure.code == 75) {
          _clearOTP();
          current = VaultSnapshot(
            mode: current?.mode ?? (client.isDemo ? 'fake' : 'native'),
            status: 'locked',
          );
          selectedRef = null;
          conflicts = [];
        }
      }
      return false;
    } catch (_) {
      if (epoch == _epoch && !_disposed) error = '操作未完成，请重试。';
      return false;
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  bool _accept(int epoch) => epoch == _epoch && !_disposed;
  Future<bool> load() => _run((epoch) async {
    final value = await client.snapshot();
    if (_accept(epoch)) {
      current = value;
      selectedRef ??= visibleKeys.firstOrNull?.ref;
    }
  });
  Future<bool> unlock() => _run((epoch) async {
    final value = await client.unlock();
    if (_accept(epoch)) {
      current = value;
      selectedRef ??= visibleKeys.firstOrNull?.ref;
    }
  });
  void lock() {
    ++_epoch;
    busy = false;
    _clearOTP();
    selectedRef = null;
    conflicts = [];
    current = VaultSnapshot(
      mode: current?.mode ?? (client.isDemo ? 'fake' : 'native'),
      status: 'locked',
    );
    _notify();
    unawaited(client.lock().catchError((Object _) {}));
  }

  Future<bool> create(KeyDraft draft) => _run((epoch) async {
    final value = await client.create(draft);
    if (_accept(epoch)) {
      current = value;
      selectedRef = draft.ref;
    }
  });
  Future<bool> update(KeyItem item, KeyMetadata metadata) =>
      _run((epoch) async {
        final value = await client.update(item, metadata);
        if (_accept(epoch)) {
          current = value;
          _clearOTP();
        }
      });
  Future<bool> changeSpace(String action, String id, String? name) =>
      _run((epoch) async {
        final value = await client.space(action, id, name);
        if (_accept(epoch)) {
          current = value;
          selectedRef ??= visibleKeys.firstOrNull?.ref;
        }
      });
  Future<bool> copy(KeyItem item) => _run((_) => client.copySecret(item));
  Future<bool> generateOTP(KeyItem item) => _run((epoch) async {
    final value = await client.totp(item);
    if (!_accept(epoch) || selectedRef != item.ref) return;
    _clearOTP();
    otp = value;
    otpRef = item.ref;
    final duration = value.expires.difference(DateTime.now());
    if (duration <= Duration.zero) {
      _clearOTP();
      return;
    }
    _expiry = Timer(duration, () {
      _clearOTP();
      _notify();
    });
  });
  Future<bool> sync(String path, Map<String, String> resolutions) =>
      _run((epoch) async {
        final value = await client.synchronize(path, resolutions);
        if (_accept(epoch)) {
          current = value.snapshot;
          conflicts = value.conflicts;
          _clearOTP();
          if (conflicts.isEmpty) lastSync = DateTime.now();
        }
      });
  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _clearOTP();
    unawaited(client.lock().catchError((Object _) {}));
    super.dispose();
  }
}
