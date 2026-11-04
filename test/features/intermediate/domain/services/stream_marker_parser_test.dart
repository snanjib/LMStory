import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/intermediate/domain/services/stream_marker_parser.dart';

/// StreamMarkerParser 单元测试（计划 §5）
///
/// 验证跨 chunk 标记切分、JSON 载荷累积、解析容错、重置复用。
void main() {
  const marker = '<<<KEYWORDS>>>';

  group('StreamMarkerParser.feed', () {
    test('1. 标记在单个 chunk 内完整出现 → 正确切分', () {
      final parser = StreamMarkerParser(marker: marker);
      final out1 = parser.feed('草稿正文一段');
      final out2 = parser.feed('草稿正文二段<<<KEYWORDS>>>["古碑"]');

      expect(out1, '草稿正文一段');
      expect(out2, '草稿正文二段');
      expect(parser.markerFound, isTrue);
      expect(parser.displayText, '草稿正文一段草稿正文二段');
      expect(parser.jsonPayload, '["古碑"]');
    });

    test('2. 标记跨 2 个 chunk 切断 → 正确切分且不丢字', () {
      final parser = StreamMarkerParser(marker: marker);
      final out1 = parser.feed('草稿正文<<<KEYW');
      // 此时末尾 "<<<KEYW" 是 marker 前缀，holdBack=7，应已输出 "草稿正文"
      expect(out1, '草稿正文');
      expect(parser.markerFound, isFalse);

      final out2 = parser.feed('ORDS>>>["古碑","后山"]');
      expect(out2, '');
      expect(parser.markerFound, isTrue);
      expect(parser.displayText, '草稿正文');
      expect(parser.jsonPayload, '["古碑","后山"]');
    });

    test('3. 标记逐字符切断（极端情况）→ 仍正确切分', () {
      final parser = StreamMarkerParser(marker: marker);
      // '正文' + '<<<KEYWORDS>>>' 逐字符喂入（marker 14 字符全切断）
      final parts = '正文'.split('') + '<<<KEYWORDS>>>'.split('');
      final buffer = StringBuffer();
      for (final ch in parts) {
        buffer.write(parser.feed(ch));
      }
      expect(parser.markerFound, isTrue);
      expect(buffer.toString(), '正文');
      expect(parser.jsonPayload, '');
    });

    test('4. 无标记 → 全部为展示正文，jsonPayload 为 null', () {
      final parser = StreamMarkerParser(marker: marker);
      final out1 = parser.feed('只有正文');
      parser.feed('没有标记的部分');

      expect(out1, '只有正文');
      // 第二次 feed 可能因 holdBack 暂留少量字符，但 displayText 最终完整
      expect(parser.markerFound, isFalse);
      expect(parser.jsonPayload, isNull);
      expect(parser.displayText, '只有正文没有标记的部分');
    });

    test('5. 标记在开头 → 展示正文为空 + 回调触发一次', () {
      final parser = StreamMarkerParser(marker: marker);
      var callbackCount = 0;
      final out = parser.feed(
        '<<<KEYWORDS>>>["a"]',
        onMarkerFound: () => callbackCount++,
      );

      expect(out, '');
      expect(parser.markerFound, isTrue);
      expect(parser.displayText, '');
      expect(parser.jsonPayload, '["a"]');
      expect(callbackCount, 1);
    });

    test('6. JSON 载荷跨 chunk 累积 → jsonPayload 正确', () {
      final parser = StreamMarkerParser(marker: marker)
        ..feed('正文<<<KEYWORDS>>>');
      expect(parser.markerFound, isTrue);

      // 标记找到后，后续 feed 返回空，载荷累积
      final out1 = parser.feed('{"summary"');
      final out2 = parser.feed(':"事件"}');
      expect(out1, '');
      expect(out2, '');
      expect(parser.jsonPayload, '{"summary":"事件"}');
    });

    test('7. onMarkerFound 仅首次回调一次', () {
      var count = 0;
      StreamMarkerParser(marker: marker)
        ..feed('正文<<<KEYWORDS>>>["a"]', onMarkerFound: () => count++)
        ..feed('更多载荷', onMarkerFound: () => count++);
      expect(count, 1);
    });
  });

  group('parseKeywords', () {
    test('8. 正常 JSON 字符串数组（旧格式）→ 全部归入 characters', () {
      // 旧数组格式兼容，全部归入 characters（entityTerms = characters + items + locations）
      final result = parseKeywords('["古碑", "后山", "碑文"]');
      expect(result, isNotNull);
      expect(result!.entityTerms, ['古碑', '后山', '碑文']);
      expect(result.eventTerms, isEmpty);
    });

    test('8b. 新对象格式 5 类 → 正确分类', () {
      final result = parseKeywords(
        '{"characters":["李逍遥"],"items":["古碑"],"locations":["蜀山"],"actions":["斩妖"],"plots":["碑文显现"]}',
      );
      expect(result, isNotNull);
      // entityTerms = characters + items + locations
      expect(result!.entityTerms, ['李逍遥', '古碑', '蜀山']);
      // eventTerms = actions + plots
      expect(result.eventTerms, ['斩妖', '碑文显现']);
    });

    test('8c. 新对象格式缺子字段 → 降级为空列表', () {
      // 所有实体类缺失（characters/items/locations）
      final noEntities = parseKeywords('{"actions":["战斗"],"plots":[]}');
      expect(noEntities, isNotNull);
      expect(noEntities!.entityTerms, isEmpty);
      expect(noEntities.eventTerms, ['战斗']);

      // 所有经历类缺失（actions/plots）
      final noEvents =
          parseKeywords('{"characters":["古碑"],"items":[],"locations":[]}');
      expect(noEvents, isNotNull);
      expect(noEvents!.entityTerms, ['古碑']);
      expect(noEvents.eventTerms, isEmpty);

      // 所有 5 类都缺失（含无关字段）→ 合法空
      final allMissing = parseKeywords('{"a":1}');
      expect(allMissing, isNotNull);
      expect(allMissing!.isEmpty, isTrue);
    });

    test('9. 格式错误（非 JSON / 非对象非数组）→ 返回 null（V2：触发 E013 重试）', () {
      // 这些是格式错误，返回 null 让控制器走 E013 重试分支（V2 迁移）
      expect(parseKeywords('not json'), isNull); // 非 JSON
      expect(parseKeywords(''), isNull); // 空串无法解析
      expect(parseKeywords('"hello"'), isNull); // JSON 字符串，非对象非数组
      expect(parseKeywords('123'), isNull); // JSON 数字
      expect(parseKeywords('true'), isNull); // JSON bool
      expect(parseKeywords('null'), isNull); // JSON null
    });

    test('9b. 合法空（全过滤后为空）→ 返回非 null 但 isEmpty（B3-4：进入 compact 模式）', () {
      // 旧数组格式全过滤为空
      expect(parseKeywords('["", "  "]')!.isEmpty, isTrue); // 全空被过滤
      expect(parseKeywords('[1, 2, 3]')!.isEmpty, isTrue); // 非字符串元素被过滤
      expect(parseKeywords('[]')!.isEmpty, isTrue); // 显式空数组
      // 5 类对象格式全过滤为空
      expect(
        parseKeywords(
          '{"characters":[],"items":[],"locations":[],"actions":[],"plots":[]}',
        )!
            .isEmpty,
        isTrue,
      );
    });

    test('9c. 混合元素仅取字符串 + trim（旧数组格式）', () {
      // 旧数组格式归入 characters（entityTerms = characters + items + locations）
      final mixed = parseKeywords('["a", 1, true, "b"]');
      expect(mixed, isNotNull);
      expect(mixed!.entityTerms, ['a', 'b']);
      expect(mixed.eventTerms, isEmpty);

      final trimmed = parseKeywords('["  古碑  ", "后山"]');
      expect(trimmed, isNotNull);
      expect(trimmed!.entityTerms, ['古碑', '后山']);
    });
  });

  group('parseEventSummary', () {
    test('10. 正常解析 + importance 越界 clamp + tags 非数组降级', () {
      // 正常
      final normal = parseEventSummary(
        '{"summary":"勇者击败恶龙","tags":["战斗","胜利"],"importance":4}',
        turnNumber: 7,
      );
      expect(normal, isNotNull);
      expect(normal!.summary, '勇者击败恶龙');
      expect(normal.importance, 4);
      expect(normal.tags, ['战斗', '胜利']);
      expect(normal.turnNumber, 7);

      // importance > 5 clamp 到 5
      final high = parseEventSummary(
        '{"summary":"事件","tags":[],"importance":9}',
        turnNumber: 1,
      );
      expect(high!.importance, 5);

      // importance < 1 clamp 到 1
      final low = parseEventSummary(
        '{"summary":"事件","tags":[],"importance":0}',
        turnNumber: 1,
      );
      expect(low!.importance, 1);

      // tags 非数组 → 降级空
      final badTags = parseEventSummary(
        '{"summary":"事件","tags":"战斗","importance":3}',
        turnNumber: 1,
      );
      expect(badTags!.tags, isEmpty);

      // summary 空 → null
      final emptySummary = parseEventSummary(
        '{"summary":"","tags":[],"importance":3}',
        turnNumber: 1,
      );
      expect(emptySummary, isNull);

      // 非 JSON → null
      expect(
        parseEventSummary('not json', turnNumber: 1),
        isNull,
      );
      // 非对象 → null
      expect(
        parseEventSummary('["a"]', turnNumber: 1),
        isNull,
      );
    });

    test('10b. summary 非字符串类型（int/bool/null）→ null（不抛 TypeError）', () {
      // 修复前：`as String?` 对 int/bool 抛 TypeError，不被 FormatException 捕获
      // 修复后：使用 _coerceNonEmptyString 类型安全检查
      expect(
        parseEventSummary('{"summary":123,"importance":3}', turnNumber: 1),
        isNull,
      );
      expect(
        parseEventSummary('{"summary":true,"importance":3}', turnNumber: 1),
        isNull,
      );
      expect(
        parseEventSummary('{"summary":null,"importance":3}', turnNumber: 1),
        isNull,
      );
      expect(
        parseEventSummary('{"summary":["a"],"importance":3}', turnNumber: 1),
        isNull,
      );
    });

    test('10c. importance 为字符串数字 → 成功解析（与工具调用路径一致）', () {
      // 修复前：`is! num` 拒绝 "3"（字符串）→ 返回 null
      // 修复后：使用 _coerceImportance 支持 int/double/String
      final result = parseEventSummary(
        '{"summary":"事件","importance":"3"}',
        turnNumber: 1,
      );
      expect(result, isNotNull);
      expect(result!.importance, 3);

      // 字符串小数也应支持
      final result2 = parseEventSummary(
        '{"summary":"事件","importance":"4.5"}',
        turnNumber: 1,
      );
      expect(result2, isNotNull);
      expect(result2!.importance, 4);

      // 非数字字符串 → null
      expect(
        parseEventSummary(
          '{"summary":"事件","importance":"high"}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    // ==================== v0.2 Phase C 方案二：5W1E 字段测试 ====================

    test('10d. 5W1E 完整字段 → 全部正确解析', () {
      // v0.2 Phase C 方案二：5W1E 6 字段 + summary 兼容字段
      final result = parseEventSummary(
        '{"what":"勇者斩杀了巨龙","when":"战斗结束时","where":"火山口","who":"勇者与巨龙","significance":"获得了关键道具","extra":"巨龙临死前留下一句预言","summary":"勇者斩杀巨龙获得关键道具","tags":["战斗","关键道具"],"importance":4,"event_ended":false}',
        turnNumber: 7,
      );

      expect(result, isNotNull);
      expect(result!.what, '勇者斩杀了巨龙');
      expect(result.when, '战斗结束时');
      expect(result.where, '火山口');
      expect(result.who, '勇者与巨龙');
      expect(result.significance, '获得了关键道具');
      expect(result.extra, '巨龙临死前留下一句预言');
      // summary 字段始终保留原值（向后兼容）
      expect(result.summary, '勇者斩杀巨龙获得关键道具');
      expect(result.importance, 4);
      expect(result.tags, ['战斗', '关键道具']);
      expect(result.turnNumber, 7);
      expect(result.eventEnded, isFalse);
    });

    test('10e. what 缺失但 summary 存在 → 向后兼容（what = summary 反填）', () {
      // 旧格式 LLM 输出只有 summary，没有 what 字段
      // 新解析逻辑：用 summary 反填 what，summary 字段保留原值
      final result = parseEventSummary(
        '{"summary":"勇者击败恶龙","tags":["战斗"],"importance":3}',
        turnNumber: 1,
      );

      expect(result, isNotNull);
      expect(result!.what, '勇者击败恶龙'); // 由 summary 反填
      expect(result.summary, '勇者击败恶龙'); // summary 保留原值
    });

    test('10f. what 和 summary 都缺失 → 返回 null（必填字段缺失）', () {
      // what 是必填字段，缺失且 summary 也缺失 → 解析失败
      expect(
        parseEventSummary(
          '{"tags":["tag"],"importance":3}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('10g. what 和 summary 都为空字符串 → 返回 null', () {
      expect(
        parseEventSummary(
          '{"what":"","summary":"","tags":[],"importance":3}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('10h. 仅 what 字段（最简合法输入）→ 解析成功，其余 5W1E 为 null', () {
      final result = parseEventSummary(
        '{"what":"发生了某事","importance":3,"tags":[]}',
        turnNumber: 1,
      );

      expect(result, isNotNull);
      expect(result!.what, '发生了某事');
      expect(result.summary, isNull); // summary 未提供
      expect(result.when, isNull);
      expect(result.where, isNull);
      expect(result.who, isNull);
      expect(result.significance, isNull);
      expect(result.extra, isNull);
    });

    test('10i. 5W1E 字段类型容错：非字符串 → 视为 null（不抛异常）', () {
      // _coerceNonEmptyString 仅接受 String 类型，num/bool/null → null
      final result = parseEventSummary(
        '{"what":"事件","when":123,"where":true,"who":null,"significance":["数组"],"extra":{"key":"val"},"importance":3,"tags":[]}',
        turnNumber: 1,
      );

      expect(result, isNotNull);
      expect(result!.what, '事件');
      // 所有类型错误的字段都应为 null（不抛异常）
      expect(result.when, isNull);
      expect(result.where, isNull);
      expect(result.who, isNull);
      expect(result.significance, isNull);
      expect(result.extra, isNull);
    });

    test('10j. 5W1E 字段去空格：纯空白字符串 → 视为 null', () {
      // _coerceNonEmptyString 对纯空白字符串返回 null
      // 注：JSON 中 \t 和 \n 是转义序列，JSON 解码后是真实制表符和换行符
      final result = parseEventSummary(
        r'{"what":"事件","when":"   ","where":"\t\n","importance":3,"tags":[]}',
        turnNumber: 1,
      );

      expect(result, isNotNull);
      expect(result!.what, '事件');
      expect(result.when, isNull); // 纯空白被 trim 后为空
      expect(result.where, isNull);
    });

    test('10k. event_ended 字段容错：bool / 字符串 / 缺失', () {
      // bool true
      final t = parseEventSummary(
        '{"what":"事件","importance":3,"tags":[],"event_ended":true}',
        turnNumber: 1,
      );
      expect(t!.eventEnded, isTrue);

      // 字符串 "true"
      final s = parseEventSummary(
        '{"what":"事件","importance":3,"tags":[],"event_ended":"true"}',
        turnNumber: 1,
      );
      expect(s!.eventEnded, isTrue);

      // 字符串 "1"
      final one = parseEventSummary(
        '{"what":"事件","importance":3,"tags":[],"event_ended":"1"}',
        turnNumber: 1,
      );
      expect(one!.eventEnded, isTrue);

      // 缺失 → 保守默认 false
      final missing = parseEventSummary(
        '{"what":"事件","importance":3,"tags":[]}',
        turnNumber: 1,
      );
      expect(missing!.eventEnded, isFalse);

      // 非法类型 → false
      final invalid = parseEventSummary(
        '{"what":"事件","importance":3,"tags":[],"event_ended":"yes"}',
        turnNumber: 1,
      );
      expect(invalid!.eventEnded, isFalse);
    });

    test('10l. what 字段类型错误（int）→ 解析失败返回 null', () {
      // what 必须是 String，否则视为缺失
      // 此处 what=123（int）+ summary 缺失 → whatOrFallback=null → 解析失败
      expect(
        parseEventSummary(
          '{"what":123,"importance":3,"tags":[]}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('10m. what 类型错误但 summary 存在 → 仍能用 summary 反填（向后兼容）', () {
      // what=123（int）→ 视为缺失；summary 存在 → 反填 what
      final result = parseEventSummary(
        '{"what":123,"summary":"勇者击败恶龙","importance":3,"tags":[]}',
        turnNumber: 1,
      );

      expect(result, isNotNull);
      expect(result!.what, '勇者击败恶龙');
      expect(result.summary, '勇者击败恶龙');
    });

    test('10n. 5W1E 部分字段提供 → 仅解析提供的字段，其余为 null', () {
      // 只提供 what + when + who（典型场景：地点和意义信息不重要）
      final result = parseEventSummary(
        '{"what":"勇者与公主重逢","when":"黄昏","who":"勇者与公主","importance":4,"tags":["重逢"]}',
        turnNumber: 5,
      );

      expect(result, isNotNull);
      expect(result!.what, '勇者与公主重逢');
      expect(result.when, '黄昏');
      expect(result.who, '勇者与公主');
      expect(result.where, isNull);
      expect(result.significance, isNull);
      expect(result.extra, isNull);
      expect(result.summary, isNull);
    });
  });

  group('reset', () {
    test('reset 后实例可复用', () {
      final parser = StreamMarkerParser(marker: marker)
        ..feed('第一轮正文<<<KEYWORDS>>>["a"]');
      expect(parser.markerFound, isTrue);

      parser.reset();
      expect(parser.markerFound, isFalse);
      expect(parser.jsonPayload, isNull);
      expect(parser.displayText, '');

      // 复用
      final out = parser.feed('第二轮正文<<<KEYWORDS>>>["b"]');
      expect(out, '第二轮正文');
      expect(parser.markerFound, isTrue);
      expect(parser.jsonPayload, '["b"]');
    });
  });

  // ====================  JSON 兜底解析 ====================

  group('parseDraftJsonResult', () {
    test('11. 正常 JSON（旧数组格式 keywords）→ 全部归入 characters', () {
      // 旧数组格式归入 characters（entityTerms = characters + items + locations）
      final result = parseDraftJsonResult(
        '{"draft":"草稿正文","keywords":["古碑", "后山", "碑文"]}',
      );
      expect(result, isNotNull);
      expect(result!.draft, '草稿正文');
      expect(result.keywords.entityTerms, ['古碑', '后山', '碑文']);
      expect(result.keywords.eventTerms, isEmpty);
    });

    test('11b. 新对象格式 keywords → 正确分类到 5 类', () {
      final result = parseDraftJsonResult(
        '{"draft":"草稿正文","keywords":{"characters":["李逍遥"],"items":["古碑"],"locations":["蜀山"],"actions":["斩妖"],"plots":["碑文显现"]}}',
      );
      expect(result, isNotNull);
      expect(result!.draft, '草稿正文');
      // entityTerms = characters + items + locations
      expect(result.keywords.entityTerms, ['李逍遥', '古碑', '蜀山']);
      // eventTerms = actions + plots
      expect(result.keywords.eventTerms, ['斩妖', '碑文显现']);
    });

    test('12. keywords 缺失 → 降级为空 ClassifiedKeywords（draft 有效仍返回）', () {
      final result = parseDraftJsonResult('{"draft":"草稿正文"}');
      expect(result, isNotNull);
      expect(result!.draft, '草稿正文');
      expect(result.keywords.isEmpty, isTrue);
    });

    test('13. keywords 非数组（字符串）→ B4-1 容错：按逗号切分归入 characters', () {
      //  增强：列表型字段（keywords/tags）若被 LLM 误写成字符串，
      // 按中英文逗号切分而非降级为空，避免丢失 LLM 已提取的关键词。
      // 切分结果归入 characters（字符串视为旧扁平格式）。
      final single = parseDraftJsonResult(
        '{"draft":"草稿","keywords":"古碑"}',
      );
      expect(single, isNotNull);
      expect(single!.keywords.entityTerms, ['古碑']);
      expect(single.keywords.eventTerms, isEmpty);

      final multi = parseDraftJsonResult(
        '{"draft":"草稿","keywords":"古碑,后山,碑文"}',
      );
      expect(multi, isNotNull);
      expect(multi!.keywords.entityTerms, ['古碑', '后山', '碑文']);

      // 中文逗号也支持
      final cn = parseDraftJsonResult(
        '{"draft":"草稿","keywords":"古碑，后山"}',
      );
      expect(cn, isNotNull);
      expect(cn!.keywords.entityTerms, ['古碑', '后山']);
    });

    test('14. draft 缺失/为空/非字符串 → 返回 null', () {
      expect(parseDraftJsonResult('{"keywords":["a"]}'), isNull);
      expect(parseDraftJsonResult('{"draft":"","keywords":["a"]}'), isNull);
      expect(parseDraftJsonResult('{"draft":"  ","keywords":["a"]}'), isNull);
      expect(parseDraftJsonResult('{"draft":123}'), isNull);
    });

    test('15. 非 JSON / 非对象 → 返回 null', () {
      expect(parseDraftJsonResult('not json'), isNull);
      expect(parseDraftJsonResult('["a","b"]'), isNull);
      expect(parseDraftJsonResult(''), isNull);
    });

    test('16. keywords 元素去空 + trim（旧数组格式）', () {
      // 旧数组格式归入 characters（entityTerms = characters + items + locations）
      final result = parseDraftJsonResult(
        '{"draft":"草稿","keywords":["  古碑  ", "", "  "]}',
      );
      expect(result, isNotNull);
      expect(result!.keywords.entityTerms, ['古碑']);
      expect(result.keywords.eventTerms, isEmpty);
    });
  });

  group('parseReviseJsonResult', () {
    test('17. 正常 JSON → 正确解析 reply + eventSummary', () {
      final result = parseReviseJsonResult(
        '{"reply":"回复正文","eventSummary":{"summary":"事件","tags":["战斗"],"importance":4}}',
        turnNumber: 7,
      );
      expect(result, isNotNull);
      expect(result!.reply, '回复正文');
      expect(result.eventSummary.summary, '事件');
      expect(result.eventSummary.importance, 4);
      expect(result.eventSummary.tags, ['战斗']);
      expect(result.eventSummary.turnNumber, 7);
    });

    test('18. importance 越界 clamp + tags 非数组（字符串）B4-1 容错切分', () {
      final high = parseReviseJsonResult(
        '{"reply":"r","eventSummary":{"summary":"s","tags":[],"importance":9}}',
        turnNumber: 1,
      );
      expect(high!.eventSummary.importance, 5);

      final low = parseReviseJsonResult(
        '{"reply":"r","eventSummary":{"summary":"s","tags":[],"importance":0}}',
        turnNumber: 1,
      );
      expect(low!.eventSummary.importance, 1);

      // tags 写成字符串 → 按逗号切分（非降级为空）
      final singleTag = parseReviseJsonResult(
        '{"reply":"r","eventSummary":{"summary":"s","tags":"战斗","importance":3}}',
        turnNumber: 1,
      );
      expect(singleTag!.eventSummary.tags, ['战斗']);

      final multiTag = parseReviseJsonResult(
        '{"reply":"r","eventSummary":{"summary":"s","tags":"战斗,胜利","importance":3}}',
        turnNumber: 1,
      );
      expect(multiTag!.eventSummary.tags, ['战斗', '胜利']);
    });

    test('19. reply 缺失/为空/非字符串 → null', () {
      expect(
        parseReviseJsonResult(
          '{"eventSummary":{"summary":"s","importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
      expect(
        parseReviseJsonResult(
          '{"reply":"","eventSummary":{"summary":"s","importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
      expect(
        parseReviseJsonResult(
          '{"reply":123,"eventSummary":{"summary":"s","importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('20. eventSummary 缺失/非对象/字段缺失 → null', () {
      // eventSummary 缺失
      expect(
        parseReviseJsonResult('{"reply":"r"}', turnNumber: 1),
        isNull,
      );
      // eventSummary 非对象
      expect(
        parseReviseJsonResult(
          '{"reply":"r","eventSummary":"不是对象"}',
          turnNumber: 1,
        ),
        isNull,
      );
      // summary 缺失
      expect(
        parseReviseJsonResult(
          '{"reply":"r","eventSummary":{"importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
      // summary 为空
      expect(
        parseReviseJsonResult(
          '{"reply":"r","eventSummary":{"summary":"","importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
      // importance 缺失
      expect(
        parseReviseJsonResult(
          '{"reply":"r","eventSummary":{"summary":"s"}}',
          turnNumber: 1,
        ),
        isNull,
      );
      // importance 非数字
      expect(
        parseReviseJsonResult(
          '{"reply":"r","eventSummary":{"summary":"s","importance":"高"}}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('21. 非 JSON / 非对象 → null', () {
      expect(
        parseReviseJsonResult('not json', turnNumber: 1),
        isNull,
      );
      expect(
        parseReviseJsonResult('["a"]', turnNumber: 1),
        isNull,
      );
      expect(
        parseReviseJsonResult('', turnNumber: 1),
        isNull,
      );
    });
  });

  // ==================== Stage 4 Compact 修正 JSON 解析 ====================

  group('parseCompactReviseJsonResult', () {
    test('22. 正常 JSON → 正确解析 eventSummary（无 reply 字段）', () {
      final result = parseCompactReviseJsonResult(
        '{"eventSummary":{"summary":"勇者进入古墓","tags":["探索","古墓"],"importance":3}}',
        turnNumber: 5,
      );
      expect(result, isNotNull);
      expect(result!.eventSummary.summary, '勇者进入古墓');
      expect(result.eventSummary.importance, 3);
      expect(result.eventSummary.tags, ['探索', '古墓']);
      expect(result.eventSummary.turnNumber, 5);
    });

    test('23. importance 越界 clamp + tags 字符串 B4-1 容错切分', () {
      final high = parseCompactReviseJsonResult(
        '{"eventSummary":{"summary":"s","tags":[],"importance":9}}',
        turnNumber: 1,
      );
      expect(high!.eventSummary.importance, 5);

      final low = parseCompactReviseJsonResult(
        '{"eventSummary":{"summary":"s","tags":[],"importance":0}}',
        turnNumber: 1,
      );
      expect(low!.eventSummary.importance, 1);

      // tags 写成字符串 → 按逗号切分（非降级为空）
      final singleTag = parseCompactReviseJsonResult(
        '{"eventSummary":{"summary":"s","tags":"战斗","importance":3}}',
        turnNumber: 1,
      );
      expect(singleTag!.eventSummary.tags, ['战斗']);

      final multiTag = parseCompactReviseJsonResult(
        '{"eventSummary":{"summary":"s","tags":"战斗,胜利","importance":3}}',
        turnNumber: 1,
      );
      expect(multiTag!.eventSummary.tags, ['战斗', '胜利']);
    });

    test('24. eventSummary 缺失/非对象 → null', () {
      // eventSummary 缺失
      expect(
        parseCompactReviseJsonResult('{}', turnNumber: 1),
        isNull,
      );
      // eventSummary 非对象
      expect(
        parseCompactReviseJsonResult(
          '{"eventSummary":"不是对象"}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('25. summary 缺失/为空/非字符串 → null', () {
      expect(
        parseCompactReviseJsonResult(
          '{"eventSummary":{"importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
      expect(
        parseCompactReviseJsonResult(
          '{"eventSummary":{"summary":"","importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
      expect(
        parseCompactReviseJsonResult(
          '{"eventSummary":{"summary":123,"importance":3}}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('26. importance 缺失/非数字 → null', () {
      expect(
        parseCompactReviseJsonResult(
          '{"eventSummary":{"summary":"s"}}',
          turnNumber: 1,
        ),
        isNull,
      );
      expect(
        parseCompactReviseJsonResult(
          '{"eventSummary":{"summary":"s","importance":"高"}}',
          turnNumber: 1,
        ),
        isNull,
      );
    });

    test('27. 非 JSON / 非对象 → null', () {
      expect(
        parseCompactReviseJsonResult('not json', turnNumber: 1),
        isNull,
      );
      expect(
        parseCompactReviseJsonResult('["a"]', turnNumber: 1),
        isNull,
      );
      expect(
        parseCompactReviseJsonResult('', turnNumber: 1),
        isNull,
      );
    });

    test('28. 多余字段（reply 等）被忽略，仅解析 eventSummary', () {
      // 即使包含 reply 字段也忽略，只取 eventSummary
      final result = parseCompactReviseJsonResult(
        '{"reply":"不应出现","eventSummary":{"summary":"s","tags":[],"importance":3}}',
        turnNumber: 2,
      );
      expect(result, isNotNull);
      expect(result!.eventSummary.summary, 's');
      expect(result.eventSummary.importance, 3);
    });
  });

  // ====================  extractJsonFromMixed ====================

  group('extractJsonFromMixed', () {
    test('29. 正文 + JSON 对象 → 正确分离', () {
      // 5 类关键词 JSON
      const text =
          '这是正文。{"characters":["李逍遥"],"items":["古碑"],"locations":[],"actions":[],"plots":[]}';
      final result = extractJsonFromMixed(text);
      expect(result, isNotNull);
      expect(result!.textBefore, '这是正文。');
      expect(
        result.json,
        '{"characters":["李逍遥"],"items":["古碑"],"locations":[],"actions":[],"plots":[]}',
      );
    });

    test('30. 正文 + JSON 数组 → 正确分离', () {
      const text = '草稿正文。["关键词1","关键词2"]';
      final result = extractJsonFromMixed(text);
      expect(result, isNotNull);
      expect(result!.textBefore, '草稿正文。');
      expect(result.json, '["关键词1","关键词2"]');
    });

    test('31. markdown 代码块包裹 JSON → 剥离后提取', () {
      const text = '正文内容。\n```json\n{"summary":"事件","importance":3}\n```\n';
      final result = extractJsonFromMixed(text);
      expect(result, isNotNull);
      expect(result!.textBefore, '正文内容。\n');
      expect(result.json, '{"summary":"事件","importance":3}');
    });

    test('32. 无 JSON 文本 → 返回 null', () {
      expect(extractJsonFromMixed('纯文本无 JSON'), isNull);
      expect(extractJsonFromMixed(''), isNull);
    });

    test('33. JSON 在开头（无前置正文）→ textBefore 为空', () {
      const text = '{"summary":"事件","importance":3}';
      final result = extractJsonFromMixed(text);
      expect(result, isNotNull);
      expect(result!.textBefore, '');
      expect(result.json, '{"summary":"事件","importance":3}');
    });

    test('34. 多个 JSON 对象 → 取最后一个合法的', () {
      const text = '前段。{"a":1} 后段。{"b":2}';
      final result = extractJsonFromMixed(text);
      expect(result, isNotNull);
      expect(result!.textBefore, '前段。{"a":1} 后段。');
      expect(result.json, '{"b":2}');
    });

    test('35. 嵌套 JSON 对象 → 深度计数配对', () {
      const text = '正文。{"outer":{"inner":"value"}}';
      final result = extractJsonFromMixed(text);
      expect(result, isNotNull);
      expect(result!.textBefore, '正文。');
      expect(result.json, '{"outer":{"inner":"value"}}');
    });

    test('36. parseKeywords 配合 _preprocessJson：markdown 包裹的 keywords', () {
      // _preprocessJson 已应用到 parseKeywords，markdown 包裹应自动剥离（5 类）
      const text =
          '```json\n{"characters":["李逍遥"],"items":["古碑"],"locations":[],"actions":[],"plots":[]}\n```';
      final result = parseKeywords(text);
      expect(result, isNotNull);
      // entityTerms = characters + items + locations
      expect(result!.entityTerms, ['李逍遥', '古碑']);
    });

    test('37. parseEventSummary 配合 _preprocessJson：前后有说明文字', () {
      // _preprocessJson 提取嵌入的 JSON 对象
      const text = '以下是结果：{"summary":"事件","importance":3,"tags":[]} 完成';
      final result = parseEventSummary(text, turnNumber: 1);
      expect(result, isNotNull);
      expect(result!.summary, '事件');
      expect(result.importance, 3);
    });
  });
}
