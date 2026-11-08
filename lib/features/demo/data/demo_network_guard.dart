import 'dart:convert';

import 'package:dio/dio.dart' show Options;
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:meta/meta.dart';

/// 一次被拦截的远程调用企图记录
class DemoNetworkAttempt {
  const DemoNetworkAttempt({
    required this.via,
    required this.detail,
    required this.at,
  });

  /// 拦截层：guardedDio / guardedHttp / replayUnmatched / embeddingUnmatched
  final String via;

  /// 企图详情（路径/用途等非敏感描述）
  final String detail;

  final DateTime at;

  @override
  String toString() => '$via($detail)@${at.toIso8601String()}';
}

/// 演示环境网络守卫：任何远程调用企图在此计数并就地失败。
///
/// 这是「演示零远程调用」的证据源：测试与人工验收读取
/// [attemptCount]（期望恒 0——非 0 即存在企图，无论网络是否可用）。
/// 守卫不依赖断网环境，因此不能用「网络错误」冒充「没有发请求」。
class DemoNetworkGuard {
  final List<DemoNetworkAttempt> _attempts = [];

  List<DemoNetworkAttempt> get attempts => List.unmodifiable(_attempts);

  int get attemptCount => _attempts.length;

  void record(String via, String detail) {
    _attempts.add(
      DemoNetworkAttempt(via: via, detail: detail, at: DateTime.now()),
    );
  }

  /// 测试辅助：清空计数
  @visibleForTesting
  void reset() => _attempts.clear();
}

/// 演示环境网络阻断：企图被守卫记录后抛出的本地异常。
class DemoNetworkBlockedException implements Exception {
  const DemoNetworkBlockedException(this.via, this.detail);

  final String via;
  final String detail;

  @override
  String toString() => 'DemoNetworkBlockedException: $via($detail)';
}

/// 演示环境 DioClient：全部网络方法记录企图后抛错，不建立任何连接。
///
/// 基座 Dio 构造仍会发生（无副作用——不发起请求），拦截点在全部
/// 公开网络方法上；新增方法由完备性守卫测试对账（防止未来穿透）。
class GuardedDioClient extends DioClient {
  GuardedDioClient(this._guard);

  final DemoNetworkGuard _guard;

  Never _block(String method, String path) {
    _guard.record('guardedDio', '$method $path');
    throw DemoNetworkBlockedException('guardedDio', '$method $path');
  }

  @override
  Future<ApiResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    _block('GET', path);
  }

  @override
  Future<ApiResponse<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    _block('POST', path);
  }

  @override
  Future<ApiResponse<T>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    _block('PUT', path);
  }

  @override
  Future<ApiResponse<T>> patch<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    _block('PATCH', path);
  }

  @override
  Future<ApiResponse<T>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    _block('DELETE', path);
  }
}

/// 演示环境 SSE HttpClient：流式 POST 记录企图后抛错。
class GuardedHttpClient extends HttpClient {
  GuardedHttpClient(this._guard);

  final DemoNetworkGuard _guard;

  @override
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
    _guard.record('guardedHttp', 'POST $url');
    // 以流错误交付（与真实网络层失败同型：订阅方在流上收到错误）
    return Stream<String>.error(
      DemoNetworkBlockedException('guardedHttp', 'POST $url'),
    );
  }
}
