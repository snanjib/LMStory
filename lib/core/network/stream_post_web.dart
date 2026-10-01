// Web 平台 SSE 流式请求实现
//
// 使用 dart:html 的 HttpRequest + onProgress 事件实现流式，
// 规避 package:http BrowserClient 的 XHR 响应缓冲问题。
//
// package:http 的 BrowserClient 在 Chromium 浏览器中会缓冲整个响应体，
// 导致 SSE 流式数据无法实时到达 Dart 代码。本实现通过监听 XHR 的
// onProgress 事件，每次触发时读取 responseText 的增量部分，
// 实现"伪流式"效果——虽然没有 fetch API 的 ReadableStream 那么纯粹，
// 但在 Chromium 中对 text/event-stream 响应能实现逐块实时回调。
//
// 仅在 Web 平台编译（dart:html 可用），原生平台使用 stream_post_native.dart。

import 'dart:async';
import 'dart:convert';

// dart:html 的 XHR onProgress 是 Web 流式落地的唯一手段（见文件头说明），
// 迁移 package:web 前保持显式豁免。
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/http_client_types.dart';

/// Web 平台 SSE 流式 POST 请求实现
///
/// 使用 dart:html 的 HttpRequest + onProgress 事件实现流式。
/// [cancelToken] 用于取消请求，[connectTimeout]/[readTimeout] 控制超时。
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

  // 检查取消信号（请求前）
  if (cancelToken?.isCancelled ?? false) {
    throw const CancelledException('Request was cancelled before sending');
  }

  final controller = StreamController<String>();
  var lastProcessedLength = 0;
  var requestSent = false;
  Timer? connectTimer;
  Timer? readTimer;
  html.HttpRequest? xhr;

  // 连接超时：请求发出后 connTimeout 内未收到 readyState 2（HEADERS_RECEIVED）
  connectTimer = Timer(connTimeout, () {
    if (!requestSent) {
      xhr?.abort();
      if (!controller.isClosed) {
        controller
          ..addError(
            TimeoutException(
              'Connection timed out after ${connTimeout.inSeconds}s',
            ),
          )
          ..close();
      }
    }
  });

  // 读取超时：每次收到数据重置，rdTimeout 内无新数据则超时
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

  // XHR 无整头枚举，限流冷却相关头逐键拾取（403/429 场景）
  HttpErrorHeaders errorHeaders(html.HttpRequest req) => HttpErrorHeaders(
        retryAfter: req.getResponseHeader('retry-after'),
        retryAfterMs: req.getResponseHeader('retry-after-ms'),
        requestId: req.getResponseHeader('x-request-id') ??
            req.getResponseHeader('request-id'),
      );

  // 创建 XHR 请求
  xhr = html.HttpRequest();

  // 监听 readyState 变化，检测连接建立
  xhr.onReadyStateChange.listen((event) {
    // readyState 2 = HEADERS_RECEIVED，表示连接已建立
    if (xhr!.readyState == 2) {
      requestSent = true;
      connectTimer?.cancel();

      // 检查 HTTP 状态码
      if (xhr.status != 200) {
        readTimer?.cancel();
        if (!controller.isClosed) {
          controller
            ..addError(
              AppHttpException(
                'SSE request failed with status ${xhr.status}',
                statusCode: xhr.status,
                uri: Uri.parse(url),
                responseBody: xhr.responseText ?? '',
                headers: errorHeaders(xhr),
              ),
            )
            ..close();
        }
        return;
      }

      // 检查取消信号（连接后、读取流之前）
      if (cancelToken?.isCancelled ?? false) {
        xhr.abort();
        if (!controller.isClosed) {
          controller
            ..addError(
              const CancelledException(
                'Request was cancelled after connecting',
              ),
            )
            ..close();
        }
      }
    }
  });

  // 监听进度事件——这是流式实现的核心
  // 每次 onProgress 触发时，responseText 包含了到目前为止收到的所有数据
  // 通过比较 lastProcessedLength，提取增量部分
  xhr.onProgress.listen((event) {
    if (controller.isClosed) return;

    // 重置读取超时
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

    // 提取增量数据
    final responseText = xhr!.responseText ?? '';
    if (responseText.length > lastProcessedLength) {
      final chunk = responseText.substring(lastProcessedLength);
      lastProcessedLength = responseText.length;
      controller.add(chunk);
    }
  });

  // 监听错误
  xhr.onError.listen((event) {
    connectTimer?.cancel();
    readTimer?.cancel();
    if (!controller.isClosed) {
      controller
        ..addError(
          AppHttpException(
            'SSE request network error',
            statusCode: 0,
            uri: Uri.parse(url),
            responseBody: '',
          ),
        )
        ..close();
    }
  });

  // 监听请求完成
  xhr.onLoadEnd.listen((event) {
    connectTimer?.cancel();
    readTimer?.cancel();
    // 处理最后可能残留的数据
    final responseText = xhr!.responseText ?? '';
    if (responseText.length > lastProcessedLength && !controller.isClosed) {
      final chunk = responseText.substring(lastProcessedLength);
      lastProcessedLength = responseText.length;
      controller.add(chunk);
    }
    // 检查最终的 HTTP 状态码（onProgress 期间可能还没收到状态码）
    if (xhr.status != 200 && xhr.status != 0 && !controller.isClosed) {
      controller
        ..addError(
          AppHttpException(
            'SSE request failed with status ${xhr.status}',
            statusCode: xhr.status,
            uri: Uri.parse(url),
            responseBody: xhr.responseText ?? '',
            headers: errorHeaders(xhr),
          ),
        )
        ..close();
      return;
    }
    if (!controller.isClosed) {
      controller.close();
    }
  });

  // 打开并发送请求
  // Accept 头由适配器 headers 统一给出（application/json，XC-7）：
  // 此处不再预设 text/event-stream——它恒被下方适配器 headers 覆盖，
  // 只会误导读者以为出网 Accept 是 text/event-stream。
  xhr
    ..open('POST', url)
    ..setRequestHeader('Content-Type', 'application/json');
  headers.forEach((key, value) {
    xhr!.setRequestHeader(key, value);
  });

  // 发送请求体
  if (body != null) {
    xhr.send(body);
  } else {
    xhr.send();
  }

  // StreamController 被取消监听时，中止 XHR 请求
  controller.onCancel = () {
    connectTimer?.cancel();
    readTimer?.cancel();
    if (xhr!.readyState != html.HttpRequest.DONE) {
      xhr.abort();
    }
  };

  // 取消令牌监听
  cancelToken?.bind(() {
    connectTimer?.cancel();
    readTimer?.cancel();
    if (xhr!.readyState != html.HttpRequest.DONE) {
      xhr.abort();
    }
    if (!controller.isClosed) {
      controller
        ..addError(const CancelledException('Request was cancelled'))
        ..close();
    }
  });

  yield* controller.stream;
}
