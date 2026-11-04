import 'dart:convert';

import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';

/// 流式分隔标记解析器（旧版兼容，四步重构后仅降级场景使用，DOC-09A-1 §1.4）
///
/// LLM 流式输出含分隔标记，标记前为展示正文（流式显示），标记后为
/// JSON 载荷（不流式、直接解析）：
/// - 请求1（草稿）：`[生成正文]<<<KEYWORDS>>>["关键词1","关键词2"]`
/// - 请求2（修正）：`[回复正文]<<<EVENT_SUMMARY>>>{...JSON...}`
///
/// **核心问题**（P1 总览技术风险 R1）：SSE 分片可能把标记切断，如
/// chunk1 末尾 `<<<KEYW` + chunk2 开头 `ORDS>>>`。本解析器跨 chunk
/// 缓冲，不假设标记在单个 chunk 内完整出现。
///
/// 算法：有状态累加器，[feed] 增量喂入文本。
/// - 标记完整出现时，切分展示正文与 JSON 载荷
/// - 标记未完整出现时，仅保留"buffer 末尾中恰好是 marker 前缀"的部分，
///   其余安全输出为展示正文（最大化流式显示实时性）
class StreamMarkerParser {
  StreamMarkerParser({required String marker}) : _marker = marker;

  /// 分隔标记（如 `<<<KEYWORDS>>>` / `<<<EVENT_SUMMARY>>>`）
  final String _marker;

  final StringBuffer _buffer = StringBuffer();

  /// 标记是否已检测到
  bool _markerFound = false;

  /// 已确认为展示正文并输出的长度（buffer 内偏移）
  int _committedLength = 0;

  /// 喂入一个文本增量，返回可立即展示的新增文本（可能为空）。
  ///
  /// [onMarkerFound] 在检测到标记时回调一次（仅首次）。标记本身不展示。
  /// 标记检测到后，后续增量全部归入 JSON 载荷，[feed] 返回空字符串。
  String feed(String delta, {void Function()? onMarkerFound}) {
    if (delta.isEmpty) return '';

    if (_markerFound) {
      // 标记已找到，后续全属 JSON 载荷
      _buffer.write(delta);
      return '';
    }

    _buffer.write(delta);
    final full = _buffer.toString();

    // 查找完整标记
    final idx = full.indexOf(_marker);
    if (idx >= 0) {
      _markerFound = true;
      final newDisplay = full.substring(_committedLength, idx);
      _committedLength = idx;
      onMarkerFound?.call();
      return newDisplay;
    }

    // 标记未完整出现：保留末尾"恰好是 marker 前缀"的部分
    final holdBack = _longestSuffixPrefix(full, _marker);
    final safeEnd = full.length - holdBack;
    if (safeEnd > _committedLength) {
      final newDisplay = full.substring(_committedLength, safeEnd);
      _committedLength = safeEnd;
      return newDisplay;
    }
    return '';
  }

  /// 标记是否已找到
  bool get markerFound => _markerFound;

  /// JSON 载荷（标记后全部文本，已 trim 首尾空白）。
  ///
  /// 流结束后调用。未找到标记返回 null。
  String? get jsonPayload {
    if (!_markerFound) return null;
    final full = _buffer.toString();
    final payload = full.substring(_committedLength + _marker.length);
    return payload.trim();
  }

  /// 展示正文全文（标记前的全部文本）。流结束或标记找到后可用。
  String get displayText {
    final full = _buffer.toString();
    final end = _markerFound ? _committedLength : full.length;
    return full.substring(0, end);
  }

  /// 重置（复用同一实例）
  void reset() {
    _buffer.clear();
    _markerFound = false;
    _committedLength = 0;
  }

  /// 计算 buffer 末尾中"恰好是 marker 前缀"的最长长度。
  ///
  /// 例：buffer="生成文本\n<<<"，marker="<<<KEYWORDS>>>"
  /// → 末尾 "<<<" 恰是 marker 前 3 字符 → 返回 3
  /// → safeEnd = 11 - 3 = 8，输出 "生成文本\n"，仅保留 "<<<" 待下片确认
  int _longestSuffixPrefix(String buffer, String marker) {
    final maxK = buffer.length < marker.length ? buffer.length : marker.length;
    for (var k = maxK; k > 0; k--) {
      if (buffer.endsWith(marker.substring(0, k))) {
        return k;
      }
    }
    return 0;
  }
}

/// 解析请求1（草稿）关键词 JSON（5 类关键词）
///
/// 期望格式（新）：
/// `{"characters":["李逍遥"],"items":["七星剑"],"locations":["蜀山"],"actions":["斩妖"],"plots":["灵儿被掳走"]}`
/// 兼容格式（旧）：`["古碑","后山"]`（全部归入 characters）
///
/// **返回值语义**（+）：
/// - `null` = 解析失败（format error）：JSON 格式错误、非对象非数组、空字符串。
///   Controller 应触发 E013 重试。
/// - 非 null 但 `isEmpty` = 合法空（legitimate empty）：有效 JSON，但
///   5 类元素全被过滤。Controller 不重试，进入 compact 模式。
/// - 非 null 且 `isNotEmpty` = 正常解析结果。
///
/// **设计理由**：把 keywords 从 2 类（entities/events）扩展为 5 类
/// （characters/items/locations/actions/plots），与记忆库分类结构对齐。
ClassifiedKeywords? parseKeywords(String json) {
  final preprocessed = _preprocessJson(json);
  try {
    final decoded = jsonDecode(preprocessed);

    // 新格式：5 类对象
    if (decoded is Map<String, dynamic>) {
      return _coerceClassifiedKeywords(decoded);
    }

    // 旧格式兼容：数组 ["古碑"] → 全部归入 characters
    if (decoded is List) {
      final characters = decoded
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return ClassifiedKeywords(characters: characters);
    }

    // 格式错误：非对象非数组
    return null;
  } on FormatException {
    return null;
  }
}

/// 解析请求2（修正）事件摘要 JSON
///
/// v0.2 Phase C 方案二：扩展为 5W1E 6 字段结构。
/// 期望格式（必填字段：what/tags/importance/event_ended）：
/// ```json
/// {
///   "what":"勇者斩杀了巨龙",
///   "when":"战斗结束时",
///   "where":"火山口",
///   "who":"勇者与巨龙",
///   "significance":"获得了关键道具",
///   "extra":"巨龙临死前留下一句预言",
///   "summary":"勇者斩杀巨龙获得关键道具",  // 可选
///   "tags":["战斗","关键道具"],
///   "importance":4,
///   "event_ended":false
/// }
/// ```
///
/// [turnNumber] 由程序填充（基于会话当前轮次），非 LLM 输出。
/// 解析失败返回 null。importance 越界（<1 或 >5）会夹紧到 [1,5]。
///
/// 容错策略：
/// - 必填字段 `what` 缺失或非字符串 → 解析失败返回 null
/// - 旧格式（仅有 summary，无 what）：兼容性回退——若 what 缺失但 summary
///   存在，则用 summary 反填 what（向后兼容旧 LLM 输出）
/// - event_ended 缺失或类型不匹配 → false（保守默认，避免误触发宏摘要）
EventSummary? parseEventSummary(String json, {required int turnNumber}) {
  final preprocessed = _preprocessJson(json);
  try {
    final decoded = jsonDecode(preprocessed);
    if (decoded is! Map<String, dynamic>) return null;

    // 必填字段 what（v0.2 Phase C 方案二）
    // 兼容旧格式：若 what 缺失但 summary 存在，用 summary 反填 what
    final what = _coerceNonEmptyString(decoded['what']);
    final summary = _coerceNonEmptyString(decoded['summary']);
    final whatOrFallback = what ?? summary;
    if (whatOrFallback == null) return null;

    // 使用 _coerceImportance 支持 int/double/String 三种类型，
    // 与工具调用路径（SummarizePhaseHandler._coerceImportance）保持一致。
    final importance = _coerceImportance(decoded['importance']);
    if (importance == null) return null;

    final tagsRaw = decoded['tags'];
    final tags = tagsRaw is List
        ? tagsRaw.whereType<String>().toList()
        : const <String>[];

    // event_ended 容错解析（DOC-10 §4.2）
    final eventEnded = _coerceBool(decoded['event_ended']);

    // 5W1E 其余字段（v0.2 Phase C 方案二新增）
    final when = _coerceNonEmptyString(decoded['when']);
    final where = _coerceNonEmptyString(decoded['where']);
    final who = _coerceNonEmptyString(decoded['who']);
    final significance = _coerceNonEmptyString(decoded['significance']);
    final extra = _coerceNonEmptyString(decoded['extra']);

    // 叙事时间（2026-07-25 新增，叙事时间机制）
    final narrativeTime = _coerceNonEmptyString(decoded['narrativeTime']);

    return EventSummary(
      // 若 what 缺失但 summary 存在（旧格式兼容），用 summary 反填 what
      // summary 字段始终保留原值（向后兼容 + 历史小窗展示）
      what: whatOrFallback,
      summary: summary,
      importance: importance,
      tags: tags,
      turnNumber: turnNumber,
      eventEnded: eventEnded,
      when: when,
      where: where,
      who: who,
      significance: significance,
      extra: extra,
      narrativeTime: narrativeTime,
    );
  } on FormatException {
    return null;
  }
}

// ==================== JSON 提取容错（增强）====================

/// 预处理 JSON 文本：剥离 markdown 包裹 + 提取嵌入的 JSON 对象/数组
///
///  新增。背景：国产模型即使有 response_format 约束或 prompt 强约束，
/// 仍可能输出：
/// - markdown 代码块包裹（```json ... ``` 或 ``` ... ```）
/// - JSON 前后添加说明文字（"以下是结果：{...}"）
/// - 多个 JSON 片段（取最后一个完整对象）
///
/// 处理顺序（fast path 优先，正常合法 JSON 零额外开销）：
/// 1. trim 后首字符是 `{`/`[` → 尝试直接 jsonDecode，成功则返回（fast path）
/// 2. 剥离 markdown 代码块包裹 → 尝试解析
/// 3. 提取第一个 `{` 到最后一个 `}`（JSON 对象）
/// 4. 提取第一个 `[` 到最后一个 `]`（JSON 数组）
/// 5. 全部失败 → 返回原文本（让调用方的 jsonDecode 抛 FormatException）
///
/// 应用到所有 JSON 解析函数（parseKeywords/parseEventSummary/
/// parseDraftJsonResult/parseReviseJsonResult/parseCompactReviseJsonResult）。
String _preprocessJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return text;

  // Fast path：trim 后直接是合法 JSON
  final firstChar = trimmed[0];
  if (firstChar == '{' || firstChar == '[') {
    try {
      jsonDecode(trimmed);
      return trimmed;
    } on FormatException {
      // 首字符对但整体不合法（如 {...} 后有尾部垃圾），继续提取
    }
  }

  // 2. 剥离 markdown 代码块包裹
  final markdownMatch =
      RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(text);
  if (markdownMatch != null) {
    final inner = markdownMatch.group(1)!;
    try {
      jsonDecode(inner);
      return inner;
    } on FormatException {
      // 内部仍不合法，继续
    }
  }

  // 3. 提取第一个 { 到最后一个 }（JSON 对象）
  final firstBrace = text.indexOf('{');
  final lastBrace = text.lastIndexOf('}');
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    final candidate = text.substring(firstBrace, lastBrace + 1);
    try {
      jsonDecode(candidate);
      return candidate;
    } on FormatException {
      // 大括号配对但不合法（如嵌套错误），继续
    }
  }

  // 4. 提取第一个 [ 到最后一个 ]（JSON 数组）
  final firstBracket = text.indexOf('[');
  final lastBracket = text.lastIndexOf(']');
  if (firstBracket >= 0 && lastBracket > firstBracket) {
    final candidate = text.substring(firstBracket, lastBracket + 1);
    try {
      jsonDecode(candidate);
      return candidate;
    } on FormatException {
      // 中括号配对但不合法，继续
    }
  }

  // 5. 修复字符串值内的原始控制字符（增强）
  // LLM 常见错误：在 JSON 字符串值内输出原始换行符/制表符（应为 \\n/\\t 转义），
  // 导致 jsonDecode 失败。本步骤遍历 JSON 文本，在字符串值内把原始控制字符
  // 替换为转义序列后再尝试解析。修复「第二轮起草稿格式异常」问题——
  // 第二轮 LLM 看到完整对话历史后，draft 字段值更容易含未转义换行符。
  final repaired = _repairStringControlChars(text);
  if (repaired != null) {
    try {
      jsonDecode(repaired);
      return repaired;
    } on FormatException {
      // 修复后仍不合法，继续
    }
  }

  // 6. 全部提取失败，返回原文本（调用方 jsonDecode 会抛 FormatException）
  return text;
}

/// 修复 JSON 字符串值内的原始控制字符（增强）
///
/// LLM 常见错误：在 JSON 字符串值内输出原始换行符/制表符/回车符
/// （应为 `\\n`/`\\t`/`\\r` 转义序列），导致 `jsonDecode` 失败。
/// 本函数遍历 JSON 文本，在字符串值内（`"..."` 之间）把原始控制字符
/// 替换为对应的转义序列。
///
/// 算法要点：
/// - 跟踪是否在字符串内（遇到未转义的 `"` 切换状态）
/// - 处理 `\"` 转义（不误判字符串闭合）
/// - 在字符串内遇到 `\n`/`\r`/`\t` 替换为 `\\n`/`\\r`/`\\t`
/// - 字符串外的控制字符不动（如 JSON 格式化的换行）
///
/// 返回修复后的字符串；如果未修改返回 null（调用方据此跳过）。
String? _repairStringControlChars(String text) {
  var inString = false;
  var modified = false;
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (ch == r'\' && i + 1 < text.length) {
        // 转义序列：原样写入反斜杠和下一字符
        buf
          ..write(ch)
          ..write(text[i + 1]);
        i++;
      } else if (ch == '"') {
        // 字符串闭合
        inString = false;
        buf.write(ch);
      } else if (ch == '\n') {
        buf.write(r'\n');
        modified = true;
      } else if (ch == '\r') {
        buf.write(r'\r');
        modified = true;
      } else if (ch == '\t') {
        buf.write(r'\t');
        modified = true;
      } else {
        buf.write(ch);
      }
    } else {
      if (ch == '"') {
        inString = true;
      }
      buf.write(ch);
    }
  }
  return modified ? buf.toString() : null;
}

/// 从混合文本中提取 JSON + JSON 之前的文本
///
///  新增。用于分隔标记模式标记未找到时的兜底：
/// 模型可能输出"正文 + JSON"但不输出分隔标记（或标记被篡改）。
/// 本函数找到最后一个合法 JSON 对象/数组，返回 (JSON之前的文本, JSON字符串)。
///
/// 与 [_preprocessJson] 的区别：
/// - [_preprocessJson]：假设整段文本"应该"是 JSON，提取后整段替换
/// - [extractJsonFromMixed]：明确知道文本含非 JSON 内容（正文），需要分离
///
/// 返回 null 表示未找到合法 JSON。
({String textBefore, String json})? extractJsonFromMixed(String text) {
  // 1. 剥离 markdown 代码块包裹
  final markdownMatch =
      RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(text);
  if (markdownMatch != null) {
    final inner = markdownMatch.group(1)!;
    try {
      jsonDecode(inner);
      return (textBefore: text.substring(0, markdownMatch.start), json: inner);
    } on FormatException {
      // 内部不合法，继续
    }
  }

  // 2. 从末尾找最后一个合法 JSON 对象 { ... }
  //    从最后一个 } 往前找配对的 {（深度计数）
  var lastBrace = text.lastIndexOf('}');
  while (lastBrace >= 0) {
    var depth = 0;
    for (var i = lastBrace; i >= 0; i--) {
      final ch = text[i];
      if (ch == '}') {
        depth++;
      } else if (ch == '{') {
        depth--;
        if (depth == 0) {
          final candidate = text.substring(i, lastBrace + 1);
          try {
            jsonDecode(candidate);
            return (
              textBefore: text.substring(0, i),
              json: candidate,
            );
          } on FormatException {
            // 配对但不合法，继续找上一个 }
            break;
          }
        }
      }
    }
    lastBrace = text.lastIndexOf('}', lastBrace - 1);
  }

  // 3. 从末尾找最后一个合法 JSON 数组 [ ... ]
  var lastBracket = text.lastIndexOf(']');
  while (lastBracket >= 0) {
    var depth = 0;
    for (var i = lastBracket; i >= 0; i--) {
      final ch = text[i];
      if (ch == ']') {
        depth++;
      } else if (ch == '[') {
        depth--;
        if (depth == 0) {
          final candidate = text.substring(i, lastBracket + 1);
          try {
            jsonDecode(candidate);
            return (
              textBefore: text.substring(0, i),
              json: candidate,
            );
          } on FormatException {
            break;
          }
        }
      }
    }
    lastBracket = text.lastIndexOf(']', lastBracket - 1);
  }

  return null;
}

// ==================== JSON 兜底模式解析（DOC-09B §8.6）====================

/// JSON 兜底模式下请求1（草稿）完整 JSON 解析结果（：keywords 改为分类结构）
class DraftJsonResult {
  const DraftJsonResult({required this.draft, required this.keywords});

  /// 生成正文
  final String draft;

  /// 检索关键词（分类结构，可能为空）
  final ClassifiedKeywords keywords;
}

/// JSON 兜底模式下请求2（修正）完整 JSON 解析结果
class ReviseJsonResult {
  const ReviseJsonResult({required this.reply, required this.eventSummary});

  /// 最终回复正文
  final String reply;

  /// 事件摘要
  final EventSummary eventSummary;
}

/// 容错读取 JSON Map 字段，支持字段名漂移修复（增强）
///
/// 按顺序尝试 `candidateKeys`，返回第一个存在的字段值。
/// 用于修复 LLM 输出常见的字段名漂移：
/// - `draft_text` / `generatedText` / `Draft` → `draft`
/// - `event_summary` / `eventSummary` / `EventSummary` → `eventSummary`
Object? _readWithAliases(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key)) return json[key];
  }
  return null;
}

/// 把任意值转换为非空字符串，失败返回 null（增强）
///
/// 仅接受 String 类型。num/bool/null → null。
///
/// **设计理由**：文本型字段（draft/reply/summary）若被 LLM 误写成数字
/// （如 `draft: 123`），强转为 "123" 对用户无意义——宁可判失败触发重试，
/// 也不要展示无意义内容。列表型字段（keywords/tags）的容错由
/// [_coerceStringList] 处理（String 按逗号切分）。
String? _coerceNonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 把任意值转换为 [1, 5] 整数，失败返回 null（增强）
///
/// 修复 LLM 输出 `importance: "3"`（字符串）、`importance: 3.5`（小数）等类型错误。
int? _coerceImportance(Object? value) {
  if (value == null) return null;
  int num;
  if (value is int) {
    num = value;
  } else if (value is double) {
    num = value.toInt();
  } else if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null) {
      final parsedDouble = double.tryParse(value.trim());
      if (parsedDouble == null) return null;
      num = parsedDouble.toInt();
    } else {
      num = parsed;
    }
  } else {
    return null;
  }
  if (num < 1) num = 1;
  if (num > 5) num = 5;
  return num;
}

/// 把任意值转换为 bool（DOC-10 §4.2 新增）
///
/// 解析 event_ended 字段：bool / 字符串 "true"/"false" / "1"/"0"。
/// 缺失或类型不匹配时返回 false（保守默认，避免误触发宏摘要）。
bool _coerceBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.trim().toLowerCase();
    return lower == 'true' || lower == '1';
  }
  return false;
}

/// 把任意值转换为字符串列表，失败/为空返回空列表（增强）
///
/// 修复 LLM 输出 `keywords: "古碑"`（字符串而非数组）、`tags: "标签1,标签2"` 等。
List<String> _coerceStringList(Object? value) {
  if (value == null) return const <String>[];
  if (value is List) {
    return value.map(_coerceNonEmptyString).whereType<String>().toList();
  }
  if (value is String) {
    // 字符串误用为数组：按中英文逗号切分
    final parts = value.split(RegExp('[,，]'));
    return parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
  return const <String>[];
}

/// 把任意值转换为 ClassifiedKeywords（5 类关键词）
///
/// 支持三种输入格式（按优先级）：
/// - 对象 `{characters, items, locations, actions, plots}` → 直接解析 5 类
/// - 数组 `["古碑"]` → 全部归入 characters（兼容旧格式）
/// - 字符串 `"古碑,后山"` → 切分后归入 characters（容错）
///
/// 永不返回 null（缺失/类型不符返回空 [ClassifiedKeywords]），
/// 因为 draft 有效时 keywords 即使为空也不应判整个解析失败。
ClassifiedKeywords _coerceClassifiedKeywords(Object? value) {
  if (value == null) return const ClassifiedKeywords();

  if (value is Map<String, dynamic>) {
    return ClassifiedKeywords(
      characters: _coerceStringList(value['characters']),
      items: _coerceStringList(value['items']),
      locations: _coerceStringList(value['locations']),
      actions: _coerceStringList(value['actions']),
      plots: _coerceStringList(value['plots']),
    );
  }

  // 旧格式兼容：数组或字符串 → 全部归入 characters
  if (value is List || value is String) {
    final flattened = _coerceStringList(value);
    return ClassifiedKeywords(characters: flattened);
  }

  return const ClassifiedKeywords();
}

/// 解析 JSON 兜底模式下的请求1（生成）完整 JSON（DOC-09B §8.6）
///
/// 期望格式（新）：
/// `{"draft":"生成正文","keywords":{"entities":["古碑"],"events":["碑文显现"]}}`
///
/// ** 增强**：字段名漂移修复（draft_text/generatedText → draft）+
/// 类型转换（数字→字符串）+ keywords 字符串切分为数组。
/// ** 增强**：keywords 从扁平数组改为 {entities, events} 分类结构，
/// 兼容旧数组格式（全部归入 entities）。
///
/// 解析失败、draft 缺失/为空 → 返回 null。
/// keywords 缺失或类型不符 → 降级为空 ClassifiedKeywords（不返回 null）。
DraftJsonResult? parseDraftJsonResult(String json) {
  final preprocessed = _preprocessJson(json);
  try {
    final decoded = jsonDecode(preprocessed);
    if (decoded is! Map<String, dynamic>) return null;

    // 字段名漂移修复
    final draftValue = _readWithAliases(decoded, [
      'draft',
      'draft_text',
      'generatedText',
      'Draft',
      'content',
      'reply',
    ]);
    final draft = _coerceNonEmptyString(draftValue);
    if (draft == null) return null;

    final keywordsValue = _readWithAliases(decoded, [
      'keywords',
      'keyword',
      'Keywords',
      'keywords_list',
    ]);
    // keywords 解析为分类结构（兼容旧数组格式）
    final keywords = _coerceClassifiedKeywords(keywordsValue);

    return DraftJsonResult(draft: draft, keywords: keywords);
  } on FormatException {
    return null;
  }
}

/// 解析 JSON 兜底模式下的请求2（修正）完整 JSON（DOC-09B §8.6）
///
/// 期望格式：
/// `{"reply":"回复正文","eventSummary":{"summary":"...","importance":N,"tags":[...]}}`
///
/// ** 增强**：字段名漂移修复 + 类型转换（importance 字符串/小数→整数）。
///
/// [turnNumber] 由程序填充（非 LLM 输入）。任一关键字段缺失/类型不符/为空 → 返回 null。
/// importance 越界夹紧到 [1,5]；tags 非数组降级为空数组。
ReviseJsonResult? parseReviseJsonResult(
  String json, {
  required int turnNumber,
}) {
  final preprocessed = _preprocessJson(json);
  try {
    final decoded = jsonDecode(preprocessed);
    if (decoded is! Map<String, dynamic>) return null;

    // reply 字段名漂移修复
    final replyValue = _readWithAliases(decoded, [
      'reply',
      'final_reply',
      'finalReply',
      'Reply',
      'response',
      'answer',
      'content',
    ]);
    final reply = _coerceNonEmptyString(replyValue);
    if (reply == null) return null;

    // eventSummary 字段名漂移修复
    final esRaw = _readWithAliases(decoded, [
      'eventSummary',
      'event_summary',
      'EventSummary',
      'summary',
    ]);
    Map<String, dynamic>? esMap;
    if (esRaw is Map<String, dynamic>) {
      esMap = esRaw;
    } else if (esRaw is String) {
      // 字符串误用：尝试解析为 JSON 对象
      try {
        final innerDecoded = jsonDecode(esRaw);
        if (innerDecoded is Map<String, dynamic>) esMap = innerDecoded;
      } on FormatException {
        // 忽略，下方 null 检查会处理
      }
    }
    if (esMap == null) return null;

    final summaryValue = _readWithAliases(esMap, [
      'summary',
      'event',
      'event_summary',
      'description',
    ]);
    final summary = _coerceNonEmptyString(summaryValue);
    if (summary == null) return null;

    final importanceValue = _readWithAliases(esMap, [
      'importance',
      'Importance',
      'priority',
      'level',
    ]);
    final importance = _coerceImportance(importanceValue);
    if (importance == null) return null;

    final tagsValue = _readWithAliases(esMap, ['tags', 'Tags', 'labels']);
    final tags = _coerceStringList(tagsValue);

    return ReviseJsonResult(
      reply: reply,
      eventSummary: EventSummary(
        summary: summary,
        importance: importance,
        tags: tags,
        turnNumber: turnNumber,
      ),
    );
  } on FormatException {
    return null;
  }
}

// ==================== Compact 修正 JSON 解析（Stage 4 降级，DOC-09A-2 §6.6）====================

/// Compact 修正 JSON 解析结果（仅含 eventSummary，无 reply）
///
/// 用于 `StreamConfig.skipReviewWhenEmptyRetrieval`=true 触发的 compact 模式
/// （见 lib/core/config/intermediate_config.dart）。
/// 生成内容直接作为最终回复，本结果仅承载 LLM 生成的事件摘要。
class CompactReviseJsonResult {
  const CompactReviseJsonResult({required this.eventSummary});

  final EventSummary eventSummary;
}

/// 解析 compact 模式下的请求2（修正）完整 JSON（DOC-09A-2 §6.6）
///
/// 期望格式：`{"eventSummary":{"summary":"...","importance":N,"tags":[...]}}`
///
/// 与 [parseReviseJsonResult] 的差异：不含 reply 字段（生成即最终）。
/// ** 增强**：与 [parseReviseJsonResult] 相同的字段名漂移修复 + 类型转换。
///
/// [turnNumber] 由程序填充（非 LLM 输出）。
/// eventSummary 缺失/类型不符/summary 为空/importance 非数字 → 返回 null。
/// importance 越界夹紧到 [1,5]；tags 非数组降级为空数组。
CompactReviseJsonResult? parseCompactReviseJsonResult(
  String json, {
  required int turnNumber,
}) {
  final preprocessed = _preprocessJson(json);
  try {
    final decoded = jsonDecode(preprocessed);
    if (decoded is! Map<String, dynamic>) return null;

    // eventSummary 字段名漂移修复
    final esRaw = _readWithAliases(decoded, [
      'eventSummary',
      'event_summary',
      'EventSummary',
      'summary',
    ]);
    Map<String, dynamic>? esMap;
    if (esRaw is Map<String, dynamic>) {
      esMap = esRaw;
    } else if (esRaw is String) {
      try {
        final innerDecoded = jsonDecode(esRaw);
        if (innerDecoded is Map<String, dynamic>) esMap = innerDecoded;
      } on FormatException {
        // 忽略
      }
    }
    if (esMap == null) return null;

    final summaryValue = _readWithAliases(esMap, [
      'summary',
      'event',
      'event_summary',
      'description',
    ]);
    final summary = _coerceNonEmptyString(summaryValue);
    if (summary == null) return null;

    final importanceValue = _readWithAliases(esMap, [
      'importance',
      'Importance',
      'priority',
      'level',
    ]);
    final importance = _coerceImportance(importanceValue);
    if (importance == null) return null;

    final tagsValue = _readWithAliases(esMap, ['tags', 'Tags', 'labels']);
    final tags = _coerceStringList(tagsValue);

    return CompactReviseJsonResult(
      eventSummary: EventSummary(
        summary: summary,
        importance: importance,
        tags: tags,
        turnNumber: turnNumber,
      ),
    );
  } on FormatException {
    return null;
  }
}
