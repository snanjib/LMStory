import 'dart:async';

import 'package:lmstory/core/services/data_store_operation_guard.dart';

/// Owns one session's mutations and shares the store's overwrite protection.
final class StorySessionOperations {
  StorySessionOperations(DataStoreOperationGuard? store, this._sessionId)
      : _store = store ?? DataStoreOperationGuard();

  static final _activeByStore = Expando<Map<String, _SessionOperation>>();

  final DataStoreOperationGuard _store;
  late final Map<String, _SessionOperation> _owners =
      _activeByStore[_store] ??= {};
  String _sessionId;
  _SessionOperation? _active;
  _SessionOperation? _opening;
  Completer<void>? _retryWait;

  bool get isBusy {
    final owner = _owners[_sessionId];
    return _active != null || (owner != null && !identical(owner, _opening));
  }

  Future<void>? get completion => _active?.done.future;

  /// Wait for work already using this session before reading or repairing it.
  Future<void> initialize(Future<void> Function() load) async {
    final opening = _opening;
    if (opening != null) return opening.done.future;
    if (_active != null) return;
    final release = _store.tryBeginWrite();
    if (release == null) return;
    final work = _opening = _SessionOperation();
    try {
      var owner = _owners[_sessionId];
      while (owner != null) {
        await owner.done.future;
        owner = _owners[_sessionId];
      }
      _claim(work, _sessionId);
      await load();
    } finally {
      _opening = null;
      _finish(work, release);
    }
  }

  /// Claim the real ID before the repository creates a visible session row.
  void reserveMaterializedId(String sessionId) {
    final active = _active;
    if (active == null || _owners.containsKey(sessionId)) {
      throw StateError('Cannot reserve session ID $sessionId');
    }
    _claim(active, sessionId);
  }

  void adoptMaterializedId(String sessionId) {
    if (_active?.sessionIds.contains(sessionId) != true) {
      throw StateError('Session ID was not reserved: $sessionId');
    }
    _sessionId = sessionId;
  }

  void _claim(_SessionOperation work, String sessionId) {
    _owners[sessionId] = work;
    work.sessionIds.add(sessionId);
  }

  void _finish(_SessionOperation work, void Function() release) {
    for (final id in work.sessionIds) {
      _owners.remove(id);
    }
    release();
    work.done.complete();
  }

  Future<void> waitForRetry(Duration delay) async {
    final wait = _retryWait = Completer<void>();
    final timer = Timer(delay, wait.complete);
    try {
      await wait.future;
    } finally {
      timer.cancel();
      _retryWait = null;
    }
  }

  void interruptRetryWait() {
    final wait = _retryWait;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  Future<T> run<T>(
    T rejected,
    Future<T> Function() operation, {
    void Function()? afterRelease,
  }) async {
    if (isBusy) return rejected;
    final release = _store.tryBeginWrite();
    if (release == null) return rejected;
    final work = _active = _SessionOperation();
    try {
      final opening = _opening;
      if (opening != null) await opening.done.future;
      if (_owners.containsKey(_sessionId)) return rejected;
      _claim(work, _sessionId);
      return await operation();
    } finally {
      _active = null;
      _finish(work, release);
      if (work.sessionIds.isNotEmpty) afterRelease?.call();
    }
  }

  /// Work that can overlap a round still has to finish before an overwrite.
  Future<void> runBackgroundWrite(Future<void> Function() write) async {
    final release = _store.tryBeginWrite();
    if (release == null) return;
    try {
      await write();
    } finally {
      release();
    }
  }

  void Function()? tryBeginWrite() => _store.tryBeginWrite();
}

final class _SessionOperation {
  final done = Completer<void>();
  final sessionIds = <String>{};
}
