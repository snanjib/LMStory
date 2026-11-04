import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client.dart';

/// Run in Chrome with LMSTORY_TEST_SERVER pointing at the local delay fixture.
void main() {
  const server = String.fromEnvironment('LMSTORY_TEST_SERVER');
  final enabled = kIsWeb && server.isNotEmpty;
  test(
    'Web 首数据之前不启动短空闲计时',
    () async {
      final chunks = await HttpClient()
          .streamPost(
            '$server/late',
            {},
            connectTimeout: const Duration(milliseconds: 20),
            readTimeout: const Duration(milliseconds: 50),
            responseStartTimeout: const Duration(seconds: 2),
          )
          .toList();
      expect(chunks.join(), 'first');
    },
    skip: !enabled,
  );

  test(
    'Web 首响应超时不会被abort的loadend吞掉',
    () async {
      await expectLater(
        HttpClient()
            .streamPost(
              '$server/silent',
              {},
              readTimeout: const Duration(milliseconds: 10),
              responseStartTimeout: const Duration(milliseconds: 100),
            )
            .toList(),
        throwsA(
          isA<AppHttpException>()
              .having((e) => e.code, 'code', 'response_start_timeout'),
        ),
      );
    },
    skip: !enabled,
  );

  test(
    'Web 响应头之前取消返回取消异常',
    () async {
      final token = CancellationToken();
      final response = HttpClient()
          .streamPost(
            '$server/cancel',
            {},
            cancelToken: token,
            responseStartTimeout: const Duration(seconds: 2),
          )
          .toList();
      final assertion =
          expectLater(response, throwsA(isA<CancelledException>()));
      Timer(const Duration(milliseconds: 20), token.cancel);
      await assertion;
    },
    skip: !enabled,
  );

  test(
    'Web 首数据之后启用空闲超时',
    () async {
      await expectLater(
        HttpClient()
            .streamPost(
              '$server/idle',
              {},
              readTimeout: const Duration(milliseconds: 100),
              responseStartTimeout: const Duration(seconds: 2),
            )
            .toList(),
        throwsA(isA<TimeoutException>()),
      );
    },
    skip: !enabled,
  );
}
