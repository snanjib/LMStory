import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client_types.dart';

/// One request owns its deadlines and abort trigger, never the shared client.
class RequestScope {
  RequestScope({
    required this.uri,
    this.cancelToken,
    Duration? responseStartTimeout,
    Duration? totalTimeout,
  }) {
    cancelToken?.bind(_cancel);
    if (_error != null) return;
    if (responseStartTimeout != null) {
      _firstTimer = Timer(
        responseStartTimeout,
        () => fail(
          AppHttpException(
            'No response data after ${responseStartTimeout.inSeconds}s',
            code: 'response_start_timeout',
            uri: uri,
          ),
        ),
      );
    }
    if (totalTimeout != null) {
      _totalTimer = Timer(
        totalTimeout,
        () => fail(
          AppHttpException(
            'Complete response exceeded ${totalTimeout.inSeconds}s',
            code: 'non_streaming_timeout',
            uri: uri,
          ),
        ),
      );
    }
  }

  final Uri uri;
  final CancellationToken? cancelToken;
  final _abort = Completer<void>();
  final _failure = Completer<Exception>();
  Timer? _firstTimer;
  Timer? _totalTimer;
  Exception? _error;

  Future<void> get abortTrigger => _abort.future;
  void _cancel() => fail(const CancelledException('Request was cancelled'));

  void fail(Exception error) {
    if (_error != null) return;
    _error = error;
    _firstTimer?.cancel();
    _totalTimer?.cancel();
    _failure.complete(error);
    if (!_abort.isCompleted) _abort.complete();
  }

  void receivedData() => _firstTimer?.cancel();

  void check() {
    if (_error case final error?) throw error;
  }

  Future<T> wait<T>(Future<T> pending) async {
    check();
    final value = await Future.any<T>([
      pending,
      _failure.future.then<T>((error) => throw error),
    ]);
    check();
    return value;
  }

  /// Failure also interrupts a response stream whose server never closes it.
  Stream<List<int>> body(http.StreamedResponse response, {Duration? idle}) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    void stop(Object error) {
      if (controller.isClosed) return;
      controller.addError(error);
      unawaited(controller.close());
      unawaited(subscription?.cancel());
      timer?.cancel();
    }

    void armIdle() {
      timer?.cancel();
      if (idle != null) {
        timer = Timer(idle, () {
          final error =
              TimeoutException('No data received for ${idle.inSeconds}s');
          fail(error);
          stop(error);
        });
      }
    }

    controller.onListen = () {
      if (_error case final error?) {
        stop(error);
        return;
      }
      // With a first-response deadline the short idle timer begins at data.
      if (_firstTimer == null) armIdle();
      subscription = response.stream.listen(
        (bytes) {
          if (controller.isClosed || bytes.isEmpty) return;
          receivedData();
          armIdle();
          controller.add(bytes);
        },
        onError: (Object error, StackTrace stack) {
          stop(_error ?? error);
        },
        onDone: () {
          timer?.cancel();
          if (!controller.isClosed) unawaited(controller.close());
        },
      );
      unawaited(_failure.future.then(stop));
    };
    controller.onCancel = () async {
      timer?.cancel();
      await subscription?.cancel();
    };
    return controller.stream;
  }

  void dispose() {
    if (!_abort.isCompleted) _abort.complete();
    _firstTimer?.cancel();
    _totalTimer?.cancel();
    cancelToken?.unbind(_cancel);
  }
}
