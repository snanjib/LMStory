// 原生平台（Android/iOS/桌面）SSE 流式请求实现
//
// 使用 package:http 的 dart:io HttpClient，支持真正的流式。
// 仅在原生平台编译（dart:io 可用），Web 平台使用 stream_post_web.dart。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client_types.dart';

/// 原生平台 SSE 流式 POST 请求实现
///
/// 使用 package:http 的 dart:io HttpClient，支持真正的流式。
/// `cancelToken` 用于取消请求，`connectTimeout`/`readTimeout` 控制超时。

/// 进程级共享 SSE 客户端。
///
/// 此前每轮流式请求 `http.Client()` 即弃——同一供应商每轮付全新
/// TCP+TLS 握手（远程端点 100-300ms/轮常驻延迟），且各实例独立连接
/// 池、空闲 socket 滞留至 idle 超时。共享实例由 dart:io HttpClient
/// 连接池统一管理 keep-alive 复用（默认 idle 15s，突发多轮对话内
/// 免握手）。进程生命周期单例，无需显式 close。
final http.Client _sharedStreamClient = http.Client();

Stream<String> platformStreamPost(
  String url,
  Map<String, String> headers, {
  String? body,
  Encoding encoding = utf8,
  Duration? connectTimeout,
  Duration? readTimeout,
  CancellationToken? cancelToken,
}) async* {
  final connTimeout = connectTimeout ?? const Duration(seconds: 15);
  final rdTimeout = readTimeout ?? const Duration(seconds: 30);

  final request = http.Request('POST', Uri.parse(url));
  // Accept 头由适配器 headers 统一给出（application/json）：
  // 三家协议的 SSE 响应体均为 JSON 帧，主流供应商不按 Accept 协商。
  // 此处不再预设 text/event-stream——它恒被适配器 headers 覆盖，
  // 只会误导读者以为出网 Accept 是 text/event-stream（XC-7）。
  request.headers.addAll({
    'Content-Type': 'application/json',
    ...headers,
  });
  if (body != null) {
    request
      ..body = body
      ..encoding = encoding;
  }

  // 检查取消信号（请求前）
  if (cancelToken?.isCancelled ?? false) {
    throw const CancelledException('Request was cancelled before sending');
  }

  // 带超时的连接（：共享客户端连接复用）
  final response = await _sharedStreamClient.send(request).timeout(
    connTimeout,
    onTimeout: () {
      throw TimeoutException(
        'Connection timed out after ${connTimeout.inSeconds}s',
      );
    },
  );

  // 检查取消信号（请求后、读取流之前）
  if (cancelToken?.isCancelled ?? false) {
    await response.stream.drain<void>();
    throw const CancelledException('Request was cancelled after connecting');
  }

  if (response.statusCode != 200) {
    // 限制错误响应体读取大小（最大 64KB）
    final responseBytes = <int>[];
    var totalSize = 0;
    await for (final chunk in response.stream) {
      totalSize += chunk.length;
      if (totalSize > 64 * 1024) break;
      responseBytes.addAll(chunk);
    }
    final responseBody = utf8.decode(responseBytes, allowMalformed: true);
    throw AppHttpException(
      'SSE request failed with status ${response.statusCode}',
      statusCode: response.statusCode,
      uri: request.url,
      responseBody: responseBody,
      // 拾取 Retry-After 子集，限流冷却贯穿重试链路
      headers: HttpErrorHeaders.fromMap(response.headers),
    );
  }

  // 使用 StreamController 转发流，支持取消
  final controller = StreamController<String>();

  Timer? readTimer = Timer(rdTimeout, () {
    if (!controller.isClosed) {
      controller
        ..addError(
          TimeoutException(
            'No data received for ${rdTimeout.inSeconds}s',
          ),
        )
        ..close();
    }
  });

  final subscription = response.stream.transform(utf8.decoder).listen(
    (data) {
      if (!controller.isClosed) {
        readTimer?.cancel();
        readTimer = Timer(rdTimeout, () {
          if (!controller.isClosed) {
            controller
              ..addError(
                TimeoutException(
                  'No data received for ${rdTimeout.inSeconds}s',
                ),
              )
              ..close();
          }
        });
        controller.add(data);
      }
    },
    onError: (Object error) {
      readTimer?.cancel();
      if (!controller.isClosed) {
        controller.addError(error);
      }
    },
    onDone: () {
      readTimer?.cancel();
      if (!controller.isClosed) {
        controller.close();
      }
    },
  );

  controller.onCancel = () {
    readTimer?.cancel();
    subscription.cancel();
  };

  cancelToken?.bind(() {
    readTimer?.cancel();
    subscription.cancel();
    if (!controller.isClosed) {
      controller
        ..addError(const CancelledException('Request was cancelled'))
        ..close();
    }
  });

  yield* controller.stream;
}
