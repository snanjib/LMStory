/// 完稿文风 lint（体验重构 §5.3.3 机检兜底层：品味一次编码、机器持续强制）
///
/// 确定性本地检查，不调用模型。检查项（故事模式多年调优规则的可执行化）：
/// - 禁用词表（AI 高频词：彰显/凸显/勾勒/沉淀/磅礴/那一刻/时光荏苒…）
/// - 破折号（—— / — / -- 铁律严禁）
/// - 虚假对仗/翻案腔（"不是A，而是B" / "不仅X，更Y"及同族："与其说…不如说"
///   "看似…实则""你以为…其实"）
/// - 明喻堆积（仿佛/宛如/犹如 合计超限）
/// - 开场客套（好的/以下是/我来续写/收到；论述起手式：说白了/说穿了/先说结论）
/// - 句长方差过小（节奏单调）
/// - 段落过长
/// - 无标点长段（长会话退化治理 ：skill 遵循衰减的直接症状——整段
///   连续数十字无任何分隔符，sentenceVariance/paragraphLength 均不命中）
///
/// 违规反馈给模型定向重写一次（只改标记处）；仍超阈值则放行并记录审计层。
/// 文风错误与事实错误不相关、局部窗口即可查，lint 成本极低。
///
/// 2026-08-30：虚假对仗与开场客套词表微扩，参考 lieflat-less-ai-tone
/// 实测研究（283 万字对照语料，MIT）。
library;

/// 无标点长段判定阈值：单段内连续 ≥ 此字数未出现任何分隔符即命中
///（长会话退化治理 ，命名常量可调）
const int kNoPunctuationRunLimit = 60;

/// 分隔符全集（中英文标点与空白）：这些字符会打断"无标点连跑"计数。
/// 含引号/书名号/括号族，避免对合法使用《》【】（）的正文误报。
const String _separatorChars = '，。！？；：、·…—～“”‘’"\'（）《》〈〉【】[],.!?;:()\n\r\t ';

/// 单条违规
class AgentStyleLintViolation {
  const AgentStyleLintViolation({
    required this.rule,
    required this.evidence,
  });

  /// 规则标识（bannedWord / emDash / fakeContrast / similePile /
  /// opener / sentenceVariance / paragraphLength / runNoPunctuation）
  final String rule;

  /// 违规证据（命中文本片段或统计说明，供模型定向定位）
  final String evidence;
}

/// lint 报告
class AgentStyleLintReport {
  const AgentStyleLintReport({required this.violations});

  final List<AgentStyleLintViolation> violations;

  bool get isClean => violations.isEmpty;

  /// 反馈给模型的定向重写指令（逐条列出，明确"只改标记处"）
  String buildFeedback() {
    final lines = <String>[
      '文风检查未通过，以下 ${violations.length} 处违反文风铁律：',
      for (var i = 0; i < violations.length; i++)
        '${i + 1}. [${violations[i].rule}] ${violations[i].evidence}',
      '只修正以上标记处的表达，保持情节、结构与其余文字完全不变，然后重新输出完整正文并调用 finish_round。',
    ];
    return lines.join('\n');
  }
}

/// 完稿文风 lint 服务（纯函数，无副作用）
class AgentStyleLint {
  const AgentStyleLint({
    this.bannedWords = defaultBannedWords,
    this.maxSimiles = 2,
    this.minSentenceStdDev = 4.0,
    this.minSentencesForVariance = 6,
    this.maxParagraphLength = 400,
    this.noPunctuationRunLimit = kNoPunctuationRunLimit,
  });

  /// AI 高频词（故事模式 intermediate_prompts_v2 审查词表精编）
  static const List<String> defaultBannedWords = [
    '彰显',
    '凸显',
    '勾勒',
    '沉淀',
    '磅礴',
    '镌刻',
    '赋予',
    '蕴含',
    '时光荏苒',
    '岁月如梭',
    '那一刻',
    '这一刻',
    '时光仿佛',
  ];

  final List<String> bannedWords;

  /// 明喻词（仿佛/宛如/犹如/像是）合计出现上限；一章至多一次明喻，
  /// 正文长度下余量取 2
  final int maxSimiles;

  /// 句长标准差下限（字符；低于即节奏单调）
  final double minSentenceStdDev;

  /// 句长方差检查最少句数（短文本不判）
  final int minSentencesForVariance;

  /// 单段最大字符数
  final int maxParagraphLength;

  /// 无标点长段阈值：单段内连续 ≥ 此字数无任何分隔符即命中
  final int noPunctuationRunLimit;

  AgentStyleLintReport lint(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const AgentStyleLintReport(violations: []);

    final violations = [
      ..._lintBannedWords(trimmed),
      ..._lintEmDash(trimmed),
      ..._lintFakeContrast(trimmed),
      ..._lintSimilePile(trimmed),
      ..._lintOpener(trimmed),
      ..._lintSentenceVariance(trimmed),
      ..._lintParagraphLength(trimmed),
      ..._lintNoPunctuationRun(trimmed),
    ];

    return AgentStyleLintReport(violations: violations);
  }

  List<AgentStyleLintViolation> _lintBannedWords(String text) {
    final hits = <AgentStyleLintViolation>[];
    for (final word in bannedWords) {
      if (text.contains(word)) {
        hits.add(
          AgentStyleLintViolation(
            rule: 'bannedWord',
            evidence: '高频词「$word」',
          ),
        );
      }
    }
    return hits;
  }

  List<AgentStyleLintViolation> _lintEmDash(String text) {
    if (text.contains('——') || text.contains('—') || text.contains('--')) {
      return const [
        AgentStyleLintViolation(
          rule: 'emDash',
          evidence: '使用了破折号（严禁；用句号/逗号/冒号/括号断句）',
        ),
      ];
    }
    return const [];
  }

  List<AgentStyleLintViolation> _lintFakeContrast(String text) {
    final hits = <AgentStyleLintViolation>[];
    final notBut = RegExp(r'不是[^，。；！？\n]{1,12}[，,]\s*(而是|却是)');
    for (final match in notBut.allMatches(text).take(3)) {
      hits.add(
        AgentStyleLintViolation(
          rule: 'fakeContrast',
          evidence: '虚假对仗「${match.group(0)}」（直接说要的那个）',
        ),
      );
    }
    final notOnly = RegExp(r'不仅[^，。；！？\n]{1,12}[，,]\s*(更|还)');
    for (final match in notOnly.allMatches(text).take(2)) {
      hits.add(
        AgentStyleLintViolation(
          rule: 'fakeContrast',
          evidence: '虚假对仗「${match.group(0)}」',
        ),
      );
    }
    final variants = <RegExp>[
      RegExp(r'与其说[^，。；！？\n]{1,12}[，,]?\s*不如说'),
      RegExp(r'看似[^，。；！？\n]{1,12}[，,]?\s*实则'),
      RegExp(r'你以为[^，。；！？\n]{1,12}[，,]?\s*其实'),
    ];
    for (final rx in variants) {
      for (final match in rx.allMatches(text).take(1)) {
        hits.add(
          AgentStyleLintViolation(
            rule: 'fakeContrast',
            evidence: '虚假对仗「${match.group(0)}」（直接说要的那个）',
          ),
        );
      }
    }
    return hits;
  }

  List<AgentStyleLintViolation> _lintSimilePile(String text) {
    var count = 0;
    for (final word in ['仿佛', '宛如', '犹如', '像是']) {
      count += word.allMatches(text).length;
    }
    if (count > maxSimiles) {
      return [
        AgentStyleLintViolation(
          rule: 'similePile',
          evidence: '明喻词（仿佛/宛如/犹如/像是）出现 $count 次（上限 $maxSimiles）',
        ),
      ];
    }
    return const [];
  }

  List<AgentStyleLintViolation> _lintOpener(String text) {
    final opener = RegExp(
      r'^\s*(好的|以下是|我来|让我|收到|说白了|说穿了|先说结论)[，,。：:]',
    );
    if (opener.hasMatch(text)) {
      return const [
        AgentStyleLintViolation(
          rule: 'opener',
          evidence: '开场客套（正文直接开始，删掉应答语）',
        ),
      ];
    }
    return const [];
  }

  List<AgentStyleLintViolation> _lintSentenceVariance(String text) {
    final sentences = text
        .split(RegExp('[。！？]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (sentences.length < minSentencesForVariance) return const [];

    final lengths = sentences.map((s) => s.length).toList();
    final mean = lengths.reduce((a, b) => a + b) / lengths.length;
    final variance =
        lengths.map((l) => (l - mean) * (l - mean)).reduce((a, b) => a + b) /
            lengths.length;
    final stdDev = _sqrt(variance);
    if (stdDev < minSentenceStdDev) {
      return [
        AgentStyleLintViolation(
          rule: 'sentenceVariance',
          evidence: '句长标准差 ${stdDev.toStringAsFixed(1)}（< '
              '$minSentenceStdDev，节奏单调；长短句交错）',
        ),
      ];
    }
    return const [];
  }

  List<AgentStyleLintViolation> _lintParagraphLength(String text) {
    final hits = <AgentStyleLintViolation>[];
    final paragraphs =
        text.split('\n').map((p) => p.trim()).where((p) => p.isNotEmpty);
    var overlong = 0;
    for (final paragraph in paragraphs) {
      if (paragraph.length > maxParagraphLength) overlong++;
    }
    if (overlong > 0) {
      hits.add(
        AgentStyleLintViolation(
          rule: 'paragraphLength',
          evidence: '$overlong 段超过 $maxParagraphLength 字（合理分段）',
        ),
      );
    }
    return hits;
  }

  /// 无标点长段（长会话退化治理 ，对 R4 全盲缺口）
  ///
  /// 无标点文本按 `[。！？]` 分句只剩 1 句（sentenceVariance 不判）、
  /// 段落 <400 字时 paragraphLength 也不命中——两条既有检查对"整段连续
  /// 数十字无标点"全盲。此检查按"段内最长无分隔符连跑"判定，报告段号、
  /// 起始位置与连跑字数。每段只报最长的一跑，全文至多 3 段（防噪声）。
  List<AgentStyleLintViolation> _lintNoPunctuationRun(String text) {
    final hits = <AgentStyleLintViolation>[];
    final lines = text.split('\n');
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex].trim();
      if (line.length < noPunctuationRunLimit) continue;

      var runStart = -1;
      int? bestStart;
      var bestLength = 0;
      void closeRun(int endExclusive) {
        if (runStart < 0) return;
        final length = endExclusive - runStart;
        if (length > bestLength) {
          bestLength = length;
          bestStart = runStart;
        }
        runStart = -1;
      }

      for (var i = 0; i < line.length; i++) {
        if (_separatorChars.contains(line[i])) {
          closeRun(i);
        } else if (runStart < 0) {
          runStart = i;
        }
      }
      closeRun(line.length);

      if (bestLength >= noPunctuationRunLimit) {
        final start = bestStart!;
        final excerpt = line.substring(
          start,
          (start + 16).clamp(0, line.length),
        );
        hits.add(
          AgentStyleLintViolation(
            rule: 'runNoPunctuation',
            evidence: '第 ${lineIndex + 1} 段第 ${start + 1} 字起连续 '
                '$bestLength 字无任何标点或空白（「$excerpt…」；请按语义断句）',
          ),
        );
        if (hits.length >= 3) break;
      }
    }
    return hits;
  }

  /// 牛顿法平方根（避免 dart:math 依赖差异，精度足够 lint 用）
  static double _sqrt(double value) {
    if (value <= 0) return 0;
    var x = value;
    for (var i = 0; i < 20; i++) {
      x = 0.5 * (x + value / x);
    }
    return x;
  }
}
