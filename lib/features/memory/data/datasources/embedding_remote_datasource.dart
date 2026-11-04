import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';

/// Embedding API 数据源（Data 层实现）
///
/// 调用 OpenAI 兼容 `/embeddings` 端点生成向量（版本号由 baseUrl 携带，见 ApiUrlResolver）。
/// 实现 [EmbeddingService] Domain 层抽象接口。
///
/// 异常处理：
/// - 429 限流 → [EmbeddingRateLimitedException] (E104)
/// - 其他 HTTP 错误 → 透传 [AppHttpException]（由 DioClient 已转换）
///
/// 实现依据：DOC-05-8 §9.11。
class EmbeddingRemoteDS implements EmbeddingService {
  EmbeddingRemoteDS({required DioClient dioClient}) : _dioClient = dioClient;

  final DioClient _dioClient;

  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    final url = ApiUrlResolver.resolve(baseUrl, '/embeddings');
    final body = <String, dynamic>{
      'model': model,
      'input': text,
    };
    // 非对称模型白名单注入 input_type。
    // NVIDIA NIM 的 nemotron / nv-embed 族是双向非对称嵌入——查询与入库
    // 文本走两个编码方向，端点强制要求 input_type=query|passage，缺失时
    // 全部向量化请求回 400。其余模型一律不注入：OpenAI 兼容端点对未知
    // 请求参数普遍回 400，白名单外注入会把正常模型全部打挂。
    final lowerModel = model.toLowerCase();
    if (lowerModel.contains('nemotron') || lowerModel.contains('nv-embed')) {
      body['input_type'] =
          kind == EmbeddingInputKind.query ? 'query' : 'passage';
    }

    final ApiResponse<Map<String, dynamic>> response;
    try {
      response = await _dioClient.post<Map<String, dynamic>>(
        url,
        data: body,
        options: Options(
          headers: {
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          // embedding 超时配置（advanced.embedding.timeout_ms）接线
          receiveTimeout: timeout,
        ),
      );
    } on AppHttpException catch (e) {
      // 429 限流 → EmbeddingRateLimitedException
      if (e.statusCode == 429) {
        throw EmbeddingRateLimitedException(e.responseBody ?? 'Rate limited');
      }
      // 其他 HTTP 错误透传 AppHttpException
      rethrow;
    }

    // 解析响应：data[0].embedding → Float32List
    final data = response.data;
    if (data == null) {
      throw const AppHttpException('Embedding response body is null');
    }
    final dataArray = data['data'] as List?;
    if (dataArray == null || dataArray.isEmpty) {
      throw const AppHttpException('Embedding response missing data array');
    }
    final firstEntry = dataArray[0] as Map<String, dynamic>;
    final vector = firstEntry['embedding'] as List;
    return Float32List.fromList(
      vector.map((e) => (e as num).toDouble()).toList(),
    );
  }
}
