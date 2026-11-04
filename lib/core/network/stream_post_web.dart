import 'dart:async';
import 'dart:convert';

// XHR progress exposes incremental responseText without BrowserClient buffering.
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client_types.dart';

Stream<String> platformStreamPost(
  String url,
  Map<String, String> headers, {
  String? body,
  Encoding encoding = utf8,
  Duration? connectTimeout,
  Duration? readTimeout,
  Duration? responseStartTimeout,
  CancellationToken? cancelToken,
}) async* {
  if (cancelToken?.isCancelled ?? false) {
    throw const CancelledException('Request was cancelled before sending');
  }
  final connTimeout = connectTimeout ?? const Duration(seconds: 15);
  final idleTimeout = readTimeout ?? const Duration(seconds: 30);
  final uri = Uri.parse(url);
  final xhr = html.HttpRequest();
  final controller = StreamController<String>();
  final subscriptions = <StreamSubscription<dynamic>>[];
  Timer? firstTimer;
  Timer? idleTimer;
  var processed = 0;

  void fail(Exception error) {
    if (controller.isClosed) return;
    firstTimer?.cancel();
    idleTimer?.cancel();
    // Publish the terminal error before abort dispatches loadend/status=0.
    controller.addError(error);
    unawaited(controller.close());
    xhr.abort();
  }

  void armIdle() {
    idleTimer?.cancel();
    idleTimer = Timer(
      idleTimeout,
      () => fail(
        TimeoutException('No data received for ${idleTimeout.inSeconds}s'),
      ),
    );
  }

  void acceptData() {
    if (controller.isClosed) return;
    final text = xhr.responseText ?? '';
    if (text.length <= processed) return;
    firstTimer?.cancel();
    armIdle();
    controller.add(text.substring(processed));
    processed = text.length;
  }

  AppHttpException statusError() => AppHttpException(
        'SSE request failed with status ${xhr.status}',
        statusCode: xhr.status,
        uri: uri,
        responseBody: xhr.responseText ?? '',
        headers: HttpErrorHeaders(
          retryAfter: xhr.getResponseHeader('retry-after'),
          retryAfterMs: xhr.getResponseHeader('retry-after-ms'),
          requestId: xhr.getResponseHeader('x-request-id') ??
              xhr.getResponseHeader('request-id'),
        ),
      );

  subscriptions
    ..add(
      xhr.onReadyStateChange.listen((_) {
        if (controller.isClosed ||
            xhr.readyState != html.HttpRequest.HEADERS_RECEIVED) {
          return;
        }
        if (responseStartTimeout == null) firstTimer?.cancel();
        if (xhr.status != 200) fail(statusError());
      }),
    )
    ..add(xhr.onProgress.listen((_) => acceptData()))
    ..add(
      xhr.onError.listen(
        (_) => fail(
          AppHttpException(
            'SSE request network error',
            statusCode: 0,
            uri: uri,
          ),
        ),
      ),
    )
    ..add(
      xhr.onLoadEnd.listen((_) {
        if (controller.isClosed) return;
        if (xhr.status != 200) {
          fail(statusError());
          return;
        }
        acceptData();
        firstTimer?.cancel();
        idleTimer?.cancel();
        unawaited(controller.close());
      }),
    );

  xhr
    ..open('POST', url)
    ..setRequestHeader('Content-Type', 'application/json');
  headers.forEach(xhr.setRequestHeader);
  firstTimer = Timer(
    responseStartTimeout ?? connTimeout,
    () => fail(
      responseStartTimeout == null
          ? TimeoutException(
              'Connection timed out after ${connTimeout.inSeconds}s',
            )
          : AppHttpException(
              'No response data after ${responseStartTimeout.inSeconds}s',
              code: 'response_start_timeout',
              uri: uri,
            ),
    ),
  );
  if (responseStartTimeout == null) armIdle();
  void cancel() => fail(const CancelledException('Request was cancelled'));
  cancelToken?.bind(cancel);
  try {
    if (!controller.isClosed) xhr.send(body);
    yield* controller.stream;
  } finally {
    firstTimer.cancel();
    idleTimer?.cancel();
    cancelToken?.unbind(cancel);
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (xhr.readyState != html.HttpRequest.DONE) xhr.abort();
  }
}
