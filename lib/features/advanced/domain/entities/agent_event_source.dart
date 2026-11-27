import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// 事件负载内的模型来源元数据（工程上下文模式：来源三元组）
///
/// 事件日志此前不记录产生该消息的模型端点——跨轮重放无法证明历史
/// assistant 消息与当前模型同源（思考块/签名只在原模型/协议下合法）。
/// 本对象随 assistant/message 事件持久化：协议、modelId 与端点指纹。
///
/// 端点指纹 = sha256(baseUrl 的 UTF-8 字节) 十六进制前 16 位：
/// - 确定性：同一 baseUrl 恒同值，跨进程/跨设备可比；
/// - 非敏感：单向散列，日志不含明文 URL（query 可能携带密钥）与任何 Key。
///
/// 散列以 UTF-8 字节为输入（[hashEncoding] 标记 v1）。历史版本曾把
/// UTF-16 codeUnits 直接当字节传入——非 ASCII 端点被截低 8 位会产生
/// 碰撞，因此旧负载不标记编码版本即不可信：无 `source` 键或无编码
/// 标记的事件 → [fromData] 返回 null，读取侧按「来源未知」处理（重放
/// 时清除思考/签名表示），不得用当前配置冒充历史来源，也不得回退用
/// 旧算法匹配。
@immutable
class AgentEventSourceMeta {
  const AgentEventSourceMeta({
    required this.protocol,
    required this.modelId,
    required this.endpointFingerprint,
  });

  /// 协议名（NamingConfig.protocol.name：anthropic/openaiCompatible/…）
  final String protocol;

  /// 模型 ID
  final String modelId;

  /// 端点指纹（sha256(baseUrl) 前 16 位十六进制）
  final String endpointFingerprint;

  /// 事件 data 中的负载键
  static const String dataKey = 'source';

  /// 负载内的散列编码标记键与当前版本（v1 = UTF-8 字节输入）。
  /// 旧算法（UTF-16 codeUnits 直传）时代的负载无此标记，读取侧
  /// 按来源未知降级，不做旧算法回退匹配。
  static const String encodingKey = 'encoding';
  static const String hashEncoding = 'utf8-v1';

  /// baseUrl → 确定性非敏感端点指纹（sha256 输入为 UTF-8 字节）
  static String fingerprintEndpoint(String baseUrl) =>
      sha256.convert(utf8.encode(baseUrl)).toString().substring(0, 16);

  /// 从 assistant/message 事件 data 解析；缺键/坏值/缺编码标记（旧算法
  /// 时代的负载）返回 null（来源未知）
  static AgentEventSourceMeta? fromData(Map<String, dynamic> data) {
    final raw = data[dataKey];
    if (raw is! Map) return null;
    if (raw[encodingKey] != hashEncoding) return null;
    final protocol = raw['protocol'];
    final modelId = raw['modelId'];
    final endpoint = raw['endpoint'];
    if (protocol is! String ||
        modelId is! String ||
        endpoint is! String ||
        protocol.isEmpty ||
        modelId.isEmpty ||
        endpoint.isEmpty) {
      return null;
    }
    return AgentEventSourceMeta(
      protocol: protocol,
      modelId: modelId,
      endpointFingerprint: endpoint,
    );
  }

  Map<String, dynamic> toJson() => {
        'protocol': protocol,
        'modelId': modelId,
        'endpoint': endpointFingerprint,
        encodingKey: hashEncoding,
      };

  /// 与当前轮来源三元组比对（协议 + 模型 + 端点指纹全等）
  bool matches({
    required String otherProtocol,
    required String otherModelId,
    required String otherEndpointFingerprint,
  }) =>
      protocol == otherProtocol &&
      modelId == otherModelId &&
      endpointFingerprint == otherEndpointFingerprint;
}
