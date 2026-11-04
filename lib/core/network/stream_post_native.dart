import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/network/request_scope.dart';
import 'package:lmstory/core/network/transport_client_native.dart';

/// Stream with per-request abort and separate first-byte/idle deadlines.
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
  final connTimeout = connectTimeout ?? const Duration(seconds: 15);
  final rdTimeout = readTimeout ?? const Duration(seconds: 30);
  final uri = Uri.parse(url);
  final scope = RequestScope(
    uri: uri,
    cancelToken: cancelToken,
    responseStartTimeout: responseStartTimeout,
  );
  try {
    scope.check();
    final request = http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: scope.abortTrigger,
    )..headers.addAll({'Content-Type': 'application/json', ...headers});
    if (body != null) {
      request
        ..body = body
        ..encoding = encoding;
    }
    var sending = transportClient(connTimeout).send(request);
    if (responseStartTimeout == null) {
      sending = sending.timeout(
        connTimeout,
        onTimeout: () {
          final error = TimeoutException(
            'Connection timed out after ${connTimeout.inSeconds}s',
          );
          scope.fail(error);
          throw error;
        },
      );
    }
    final response = await scope.wait(sending);
    final bytes = scope.body(response, idle: rdTimeout);
    if (response.statusCode != 200) {
      final responseBytes = <int>[];
      await for (final chunk in bytes) {
        responseBytes.addAll(chunk.take(65536 - responseBytes.length));
        if (responseBytes.length >= 65536) break;
      }
      throw AppHttpException(
        'SSE request failed with status ${response.statusCode}',
        statusCode: response.statusCode,
        uri: uri,
        responseBody: utf8.decode(responseBytes, allowMalformed: true),
        headers: HttpErrorHeaders.fromMap(response.headers),
      );
    }
    yield* bytes.transform(encoding.decoder);
  } finally {
    scope.dispose();
  }
}
