import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/network/stream_post_native.dart'
    if (dart.library.html) 'package:lmstory/core/network/stream_post_web.dart'
    as platform;

export 'package:lmstory/core/network/http_client_types.dart'
    show CancellationToken, CancelledException;

/// SSE 流式 HTTP 客户端
///
/// 原生平台使用 package:http（dart:io HttpClient，真流式）。
/// Web 平台使用 dart:html HttpRequest + onProgress（规避 XHR 缓冲）。
/// 详见 stream_post_native.dart 和 stream_post_web.dart。
class HttpClient {
  HttpClient({
    Duration connectTimeout = const Duration(seconds: 15),
    Duration readTimeout = const Duration(seconds: 30),
  })  : _connectTimeout = connectTimeout,
        _readTimeout = readTimeout;

  final Duration _connectTimeout;
  final Duration _readTimeout;

  /// 发起 SSE 流式 POST 请求
  ///
  /// [cancelToken] 可用于取消正在进行的请求。
  /// [connectTimeout] / [readTimeout] 可覆盖默认超时（用户配置的超时值传入此处）。
  /// 返回原始响应体字符串流。
  ///
  /// 平台分流：原生平台用 package:http，Web 平台用 dart:html，
  /// 通过条件导入在编译期决定（见 stream_post.dart）。
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
  }) {
    return platform.platformStreamPost(
      url,
      headers,
      body: body,
      encoding: encoding,
      connectTimeout: connectTimeout ?? _connectTimeout,
      readTimeout: readTimeout ?? _readTimeout,
      cancelToken: cancelToken,
      responseStartTimeout: responseStartTimeout,
    );
  }

  void close() {
    // Connection pools belong to the process; requests own their abort handles.
  }
}
