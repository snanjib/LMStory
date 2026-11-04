import 'dart:math' as math;

import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';

/// 直接扫描保存的原文，与摘要检索的索引和重要性评分独立。
class SearchStoryTextTool implements AgentTool {
  SearchStoryTextTool({
    required AgentStoryReader reader,
    required AgentRoundDraft draft,
  })  : _reader = reader,
        _draft = draft;

  static const kOutputSchema = {
    'query': 'string',
    'total': 'int',
    'hitCount': 'int',
    'offset': 'int',
  };

  final AgentStoryReader _reader;
  final AgentRoundDraft _draft;

  @override
  String get name => 'search_story_text';

  @override
  String get description => '搜索当前会话已保存的用户输入、正文和最终回复，不受记忆重要性评分影响。'
      '摘要不足以核实细节时用；优先使用少量有辨识度的关键词，必要时移除人物名等限制。'
      '空白分隔的多个关键词须在同一轮全部出现，按字面匹配，忽略大小写。'
      '返回轮号与片段，按轮号升序分页；命中后用 read_story 回读上下文。';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '少量关键词；多个词用空白分隔，按同一轮内 AND 匹配；不支持正则语法',
          },
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
            'description': '每页命中轮数，默认 8',
          },
          'offset': {
            'type': 'integer',
            'minimum': 0,
            'description': '命中轮次的分页偏移，默认 0',
          },
        },
        'required': ['query'],
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    final raw = arguments['query'];
    if (raw is! String || raw.trim().isEmpty) {
      return AgentToolResult.failure(
        title: '缺少检索词',
        output: 'query 应为非空字符串。请提供少量关键词。',
      );
    }
    final query = raw.trim();
    final limit =
        parseIntegerArg(arguments, 'limit', min: 1, max: 20, fallback: 8);
    final offset = parseIntegerArg(arguments, 'offset', min: 0, fallback: 0);
    final error = limit.error ?? offset.error;
    if (error != null) {
      return AgentToolResult.failure(title: '参数不对', output: error);
    }
    final pageSize = limit.value ?? 8;
    final start = offset.value ?? 0;
    final terms = query.toLowerCase().split(RegExp(r'\s+')).toSet().toList();
    invocation.cancellation.throwIfCancelled();
    _draft.calledTools.add(name);
    _draft.searchQueries.add(query);
    invocation.onProgress?.call('搜索原文「$query」');
    final List<AgentStoryRound> rounds;
    try {
      rounds = await _reader.readAllRounds();
    } on AgentCancelledException {
      rethrow;
    } on Object {
      return AgentToolResult.failure(
        title: '原文读取失败',
        output: '当前无法读取历史原文。这不代表没有匹配内容，请稍后重试。',
      );
    }
    invocation.cancellation.throwIfCancelled();
    final matches = <({int turn, List<String> snippets})>[];
    final seenTurns = <int>{};
    for (final round in rounds) {
      if (round.turnNumber < 1 ||
          round.turnNumber >= _draft.turnNumber ||
          !seenTurns.add(round.turnNumber)) {
        continue;
      }
      final sources = <(String, String?)>[
        ('用户输入', round.userText),
        ('正文', round.narrativeText),
        if (round.replyText != round.narrativeText) ('最终回复', round.replyText),
      ];
      final texts = sources.map((s) => s.$2?.toLowerCase() ?? '').toList();
      if (!terms.every((term) => texts.any((text) => text.contains(term)))) {
        continue;
      }
      final snippets = <String>[];
      for (final source in sources) {
        final text = source.$2;
        if (text == null) continue;
        final present = terms.where(text.toLowerCase().contains);
        if (present.isEmpty) continue;
        snippets.add('${source.$1}：${_excerpt(text, present.first)}');
      }
      matches.add((turn: round.turnNumber, snippets: snippets));
    }
    matches.sort((a, b) => a.turn.compareTo(b.turn));
    final page = matches.skip(start).take(pageSize).toList();
    final nextOffset =
        start + page.length < matches.length ? start + page.length : null;
    final lines = <String>[
      '共 ${matches.length} 轮匹配，本页 ${page.length} 轮（按轮号升序）：',
    ];
    for (final match in page) {
      lines
        ..add('[第${match.turn}轮]')
        ..addAll(match.snippets);
    }
    if (matches.isEmpty) lines.add('当前关键词未找到匹配。可缩短查询或移除限制条件后重试；这不代表相关事件没有发生。');
    if (page.isEmpty && matches.isNotEmpty) lines.add('当前分页偏移没有结果，请减小 offset。');
    if (nextOffset != null) {
      lines.add('下一页：保持 query 与 limit，设置 offset=$nextOffset。');
    }
    lines.add('提示：用 read_story(turn=轮号) 回读上下文核实细节；片段匹配不等于事实已经核实。');
    return AgentToolResult.success(
      title: '搜索原文 · ${page.length} 轮',
      output: lines.join('\n'),
      metadata: {
        'query': query,
        'total': matches.length,
        'hitCount': page.length,
        'offset': start,
        'nextOffset': nextOffset,
      },
      outputSchema: kOutputSchema,
    );
  }

  String _excerpt(String text, String term) {
    final match =
        RegExp(RegExp.escape(term), caseSensitive: false).firstMatch(text);
    final position = text.substring(0, match?.start ?? 0).runes.length;
    final runes = text.runes.toList();
    final start = math.max(0, position - 50);
    final end = math.min(runes.length, start + 158);
    return '${start > 0 ? '…' : ''}${String.fromCharCodes(runes.sublist(start, end)).replaceAll(RegExp(r'[\r\n]+'), ' ')}${end < runes.length ? '…' : ''}';
  }
}
