import 'package:meta/meta.dart';

/// 单个稿件变体快照（非破坏性重生成；schemaVersion 49）
///
/// message_variants 表行的 UI 消费面投影：序号/正文/思考串/来源指令/
/// 创建时间。过程数据（agent 步骤/时间线/摘要/锚）保留在表内，
/// 切换变体时由持久层同事务改写，不进本投影。
@immutable
class MessageVariantRecord {
  const MessageVariantRecord({
    required this.variantIndex,
    required this.createdAtMs,
    this.content,
    this.thinkingContent,
    this.sourceInput,
  });

  /// 变体序号（0 起；0 = 该轮最初版本）
  final int variantIndex;

  /// 稿件正文快照
  final String? content;

  /// 思考合并串快照
  final String? thinkingContent;

  /// 生成该变体时的用户指令（editAndResend 变体与初版指令可能不同）
  final String? sourceInput;

  /// 创建时间（毫秒时间戳）
  final int createdAtMs;
}
