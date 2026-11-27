import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 正文版本绑定留痕（UTF-8 绑定散列 v1 + replay/binding 事件）。
///
/// 绑定是不可变的**生成事实**：persist 成功即写，切换/编辑/重生成不重算
/// 不改写。变体切换的轨迹身份核对（先 attemptId 后 proseHash）与压缩
/// 承接链的证据资格判定都读它。

/// 绑定留痕负载内的散列编码标记键与当前版本（v1 = UTF-8 字节输入）。
///
/// 历史版本曾把 UTF-16 codeUnits 直接当字节传入散列——非 ASCII 正文
/// 碰撞实锤。无编码标记或非 v1 的旧留痕按未绑定降级，禁止回退匹配。
const String kTrajectoryBindingEncodingKey = 'encoding';
const String kTrajectoryBindingHashEncoding = 'utf8-v1';

/// 确定性绑定摘要（与 replay/binding 事件同源算法；输入为 UTF-8 字节）
String trajectoryBindingHash(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

/// replay/binding 事件的读取侧记录
class TrajectoryBindingRecord {
  const TrajectoryBindingRecord({
    required this.turn,
    required this.variantIndex,
    required this.proseHash,
    required this.inputHash,
    this.attemptId,
  });

  final int turn;
  final int variantIndex;
  final String proseHash;
  final String inputHash;

  /// 生成该版本的尝试身份（新留痕恒有；早期留痕可能缺失——身份缺失按
  /// 未绑定处理，切换核对待遮蔽）
  final String? attemptId;
}

/// 构造 replay/binding 留痕事件（persist 成功后追加，log-only）
AgentDurableEvent replayBindingEvent({
  required int turn,
  required String attemptId,
  required int variantIndex,
  required String prose,
  required String userInput,
  String? chatMessageId,
}) {
  return AgentDurableEvent(
    type: AgentEventTypes.replayBinding,
    data: {
      'turn': turn,
      'attemptId': attemptId,
      'variantIndex': variantIndex,
      'proseHash': trajectoryBindingHash(prose),
      'inputHash': trajectoryBindingHash(userInput),
      // 正文消息 ID（压缩覆盖映射的 boundaryMessageId 优先取它；旧数据
      // 缺此键时提交服务回退 chat 配对解析）
      if (chatMessageId != null && chatMessageId.isNotEmpty)
        'chatMessageId': chatMessageId,
      kTrajectoryBindingEncodingKey: kTrajectoryBindingHashEncoding,
    },
  );
}

/// 解析 replay/binding 事件（编码标记缺失/非 v1 或字段不全 → null，按
/// 未绑定降级——不回退用旧算法匹配后放行）
TrajectoryBindingRecord? trajectoryBindingFromEvent(
  AgentDurableEvent event,
) {
  if (event.type != AgentEventTypes.replayBinding) return null;
  if (event.data[kTrajectoryBindingEncodingKey] !=
      kTrajectoryBindingHashEncoding) {
    return null;
  }
  final turn = event.data['turn'];
  final proseHash = event.data['proseHash'];
  final inputHash = event.data['inputHash'];
  if (turn is! int || proseHash is! String || inputHash is! String) {
    return null;
  }
  return TrajectoryBindingRecord(
    turn: turn,
    variantIndex: (event.data['variantIndex'] as num?)?.toInt() ?? 0,
    proseHash: proseHash,
    inputHash: inputHash,
    attemptId: event.data['attemptId'] as String?,
  );
}

/// 账本内指定（轮，变体）的最新绑定（后写覆盖前写；无绑定返回 null）
TrajectoryBindingRecord? latestBindingForVariant({
  required List<AgentDurableEvent> events,
  required int turn,
  required int variantIndex,
}) {
  TrajectoryBindingRecord? latest;
  for (final event in events) {
    final record = trajectoryBindingFromEvent(event);
    if (record == null) continue;
    if (record.turn == turn && record.variantIndex == variantIndex) {
      latest = record;
    }
  }
  return latest;
}
