/// Coordinates writes and backup overwrites against one data store.
///
/// Callers acquire synchronously before starting asynchronous work and release
/// when that work has finished. Ordinary writes can run concurrently, while
/// an overwrite requires exclusive access.
final class DataStoreOperationGuard {
  final _writes = <Object>{};
  Object? _overwrite;

  /// Whether an overwrite currently owns the store.
  bool get isOverwriting => _overwrite != null;

  /// Starts an ordinary write or returns null while an overwrite is in flight.
  void Function()? tryBeginWrite() {
    if (isOverwriting) return null;

    final operation = Object();
    _writes.add(operation);
    return () {
      _writes.remove(operation);
    };
  }

  /// Starts an overwrite or returns null while any operation is in flight.
  void Function()? tryBeginOverwrite() {
    if (isOverwriting || _writes.isNotEmpty) return null;

    final operation = Object();
    _overwrite = operation;
    return () {
      if (identical(_overwrite, operation)) _overwrite = null;
    };
  }
}
