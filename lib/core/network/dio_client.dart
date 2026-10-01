import 'package:dio/dio.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';

/// 统一 API 响应类型，隔离 Dio 实现细节
class ApiResponse<T> {
  const ApiResponse({
    required this.data,
    required this.statusCode,
    this.headers,
  });

  final T? data;
  final int statusCode;
  final Map<String, String>? headers;

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;
}

/// Dio HTTP 客户端
///
/// 用于非 SSE 的 REST API 请求（如 GET /models）。
/// SSE 流式请求使用 `HttpClient`（基于 package:http）。
class DioClient {
  DioClient({
    String? baseUrl,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl ?? '',
            connectTimeout: connectTimeout,
            receiveTimeout: receiveTimeout,
            headers: {
              'Content-Type': 'application/json',
            },
          ),
        );

  final Dio _dio;

  void addInterceptor(Interceptor interceptor) {
    _dio.interceptors.add(interceptor);
  }

  Future<ApiResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    try {
      final response = await _dio.get<T>(
        path,
        queryParameters: queryParameters,
        options: _mergeTimeouts(options, connectTimeout, receiveTimeout),
      );
      return _toApiResponse(response);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<ApiResponse<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) async {
    try {
      final response = await _dio.post<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: _mergeTimeouts(options, connectTimeout, receiveTimeout),
      );
      return _toApiResponse(response);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<ApiResponse<T>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    try {
      final response = await _dio.put<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      );
      return _toApiResponse(response);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<ApiResponse<T>> patch<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    try {
      final response = await _dio.patch<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      );
      return _toApiResponse(response);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Future<ApiResponse<T>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    try {
      final response = await _dio.delete<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      );
      return _toApiResponse(response);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// per-request 超时合并（调用点透传方案——
  /// 用户 network.* 超时对获取模型/模型实测等 REST 路径同样生效；
  /// 构造下沉方案被否：失去热生效+初始化时序风险）。
  Options? _mergeTimeouts(
    Options? options,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  ) {
    if (connectTimeout == null && receiveTimeout == null) return options;
    final effective = options ?? Options();
    if (connectTimeout != null) effective.connectTimeout = connectTimeout;
    if (receiveTimeout != null) effective.receiveTimeout = receiveTimeout;
    return effective;
  }

  /// 将 DioException 转换为领域层异常，隔离实现细节
  ///
  /// 补 uri 与响应头（Retry-After 等）——
  /// 语义链（retry_after.dart 冷却解析）此前只在 SSE/裸 http 路生效，
  /// DioClient 封套丢头导致模型列表/测试连接/embedding 的 429 冷却
  /// 信息全损。
  Exception _mapDioException(DioException e) {
    final response = e.response;
    return AppHttpException(
      e.message ?? 'Network request failed',
      code: _mapDioExceptionType(e.type),
      statusCode: response?.statusCode,
      uri: e.requestOptions.uri,
      responseBody: response?.data?.toString(),
      headers: response == null
          ? null
          : HttpErrorHeaders.fromMap(
              response.headers.map.map(
                (key, values) => MapEntry(key, values.join(', ')),
              ),
            ),
    );
  }

  String _mapDioExceptionType(DioExceptionType type) => switch (type) {
        DioExceptionType.connectionTimeout => 'connection_timeout',
        DioExceptionType.sendTimeout => 'send_timeout',
        DioExceptionType.receiveTimeout => 'receive_timeout',
        DioExceptionType.connectionError => 'connection_error',
        DioExceptionType.cancel => 'cancel',
        DioExceptionType.badResponse => 'bad_response',
        DioExceptionType.badCertificate => 'bad_certificate',
        _ => 'unknown',
      };

  ApiResponse<T> _toApiResponse<T>(Response<T> response) {
    return ApiResponse<T>(
      data: response.data,
      statusCode: response.statusCode ?? 0,
      headers: response.headers.map.map(
        (key, values) => MapEntry(key, values.join(', ')),
      ),
    );
  }

  void close() => _dio.close();
}
