/// 记忆检索查询规范化（事实层与经历层共用的唯一实现）
///
/// 背景：两层此前各写一套 FTS 表达式构造，
/// 且各带一类必然 miss 的缺陷——
/// - 事实层把整个 query 当**一个短语**做 trigram MATCH（`"图书馆 值班员"`
///   要求字面连续出现），模型惯用的空格分隔关键词列表 100% 召不回；
/// - 经历层按 `[\s,，]+` 切分后**删除标点并粘连**（`林墨(主角)` →
///   `林墨主角`），且 `、。！？；` 不分词，同样必然 miss；
/// - 两层都依赖 trigram 分词器，而 trigram 无法为 <3 rune 的查询生成
///   token——中文双字人名/地名（"老人""古碑"）在 FTS 通道恒不可召回
///   （事实层有 <3 字符 LIKE 兜底，经历层此前没有）。
///
/// 本文件把「切词 → 去噪 → 短词分流 → LIKE 转义」收口为唯一实现，
/// 由两个 Repository 共用，避免口径再次分叉。
abstract final class MemoryQuery {
  /// trigram 分词器可召回的最小查询长度（rune 数）。
  ///
  /// FTS5 trigram 按 3 字符滑动窗口建 token，查询短于 3 字符时无法构成
  /// token，MATCH 恒空——这类词必须走 LIKE 子串通道。
  static const int trigramMinRunes = 3;

  /// 词元数量上限（防模型把整段文字塞进 query 时构造出超长表达式）。
  static const int defaultMaxTerms = 8;

  /// 原始查询 → 规范化词元列表。
  ///
  /// 规则：trim → 按 Unicode 空白/标点/符号切分 → 剔除 FTS5 语法字符
  /// → 去空 → 去重（保序）→ 截断到 [maxTerms]。
  ///
  /// 全空白 / 全标点 / null → 空列表（调用方据此区分"缺少检索词"与
  /// "检索无结果"）。
  static List<String> tokenize(
    String? raw, {
    int maxTerms = defaultMaxTerms,
  }) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final result = <String>[];
    for (final piece in raw.split(_separators)) {
      // 防御：Unicode 标点分类外的少数 FTS5 语法字符（引号/星号等）
      // 一并剔除，避免拼进 MATCH 表达式造成语法错误。
      final cleaned = piece.replaceAll(_ftsSyntaxChars, '').trim();
      if (cleaned.isEmpty || result.contains(cleaned)) continue;
      result.add(cleaned);
      if (result.length >= maxTerms) break;
    }
    return result;
  }

  /// 多段原始查询合并切词（如 name + query），按出现顺序保序去重。
  static List<String> tokenizeAll(
    Iterable<String?> raws, {
    int maxTerms = defaultMaxTerms,
  }) {
    final result = <String>[];
    for (final raw in raws) {
      for (final term in tokenize(raw, maxTerms: maxTerms)) {
        if (result.contains(term)) continue;
        result.add(term);
        if (result.length >= maxTerms) return result;
      }
    }
    return result;
  }

  /// 短词判定：trigram 无法召回，必须走 LIKE 子串通道。
  static bool isShortTerm(String term) => term.runes.length < trigramMinRunes;

  /// 构造 FTS5 MATCH 表达式（长词逐个加引号，OR 连接；短词跳过）。
  ///
  /// 返回空串 = 无可用于 FTS 的词元（调用方跳过 FTS 通道）。
  static String buildMatchExpression(Iterable<String> terms) {
    final quoted = <String>[];
    for (final term in terms) {
      if (term.isEmpty || isShortTerm(term)) continue;
      quoted.add('"${term.replaceAll('"', '""')}"');
    }
    return quoted.join(' OR ');
  }

  /// LIKE 通配符转义（配 `LIKE ? ESCAPE '\'` 使用）。
  static String escapeLike(String term) => term
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// 空白 + Unicode 标点 + Unicode 符号。
  ///
  /// 含 CJK 标点（、。！？；：「」）与全角逗号，解决经历层此前只按
  /// `[\s,，]` 切分、其余标点"删掉粘成一个词"的假阴性。
  static final RegExp _separators = RegExp(
    r'[\s\p{P}\p{S}]+',
    unicode: true,
  );

  /// FTS5 语法字符（分隔符已覆盖绝大多数，此处兜底）。
  static final RegExp _ftsSyntaxChars = RegExp('["*():^]');
}
