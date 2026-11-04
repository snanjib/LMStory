/// 草稿 → SillyTavern 兼容 JSON。
///
/// 新建/另存用 `build*`；编辑覆盖用 `patch*`——**深拷贝原 JSON 后只覆盖
/// 草稿触达的键**，未知字段（extensions 整包、character_book、ST 私有键）
/// 一律原样保留（数据安全底线：禁止「归一化→再序列化」重建）。
///
/// 宏（`{{char}}`/`{{user}}`）原样透传，不做任何预处理。
library;

import 'dart:convert';

import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';

Map<String, dynamic> _deepCopy(Map<String, dynamic> src) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(src)) as Map);

/// 新建/另存角色卡：V2 结构 + V1 顶层镜像。
Map<String, dynamic> buildCardJson(CardDraft draft) {
  final data = <String, dynamic>{
    for (final f in CardField.values) f.jsonName: draft.value(f),
    'tags': List<String>.of(draft.tags),
    'extensions': <String, dynamic>{},
  };
  return <String, dynamic>{
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'name': draft.value(CardField.name),
    'description': draft.value(CardField.description),
    'personality': draft.value(CardField.personality),
    'data': data,
  };
}

/// 编辑覆盖角色卡：data 段核心字段与顶层镜像按草稿覆盖，
/// `data.extensions`/`data.character_book` 等未触达键原样保留。
Map<String, dynamic> patchCardJson(
  Map<String, dynamic> original,
  CardDraft draft,
) {
  final out = _deepCopy(original);
  final data = out['data'] is Map
      ? Map<String, dynamic>.from(out['data'] as Map)
      : <String, dynamic>{};
  for (final f in CardField.values) {
    data[f.jsonName] = draft.value(f);
  }
  data['tags'] = List<String>.of(draft.tags);
  out['data'] = data;
  out['name'] = draft.value(CardField.name);
  out['description'] = draft.value(CardField.description);
  out['personality'] = draft.value(CardField.personality);
  return out;
}

/// 新建/另存世界书：独立导出形态（entries 字典，键为条目 id），
/// 书级键取 ST 默认（token_budget 不自算、scan_depth 跟随全局）。
Map<String, dynamic> buildWorldbookJson(WorldbookDraft draft) =>
    <String, dynamic>{
      'name': draft.name,
      'description': draft.description,
      'scan_depth': null,
      'token_budget': null,
      'recursive_scanning': false,
      'entries': <String, dynamic>{
        for (final e in draft.entries) e.id: _mergeEntry({}, e),
      },
    };

/// 编辑覆盖世界书：草稿条目集是编辑后的全量集合——原书条目按 id 对位
/// 深合并（未知字段保留），不在草稿中的原条目即视为删除。
///
/// 数组格式原书（内嵌
/// character_book 的 snake_case 形态，导入侧一直接受）——此前
/// `worldbookDraftFromJson` 只认 dict，数组书预填出零条目空草稿，AI
/// 覆盖保存把整书清空。现预填按 uid 读取数组条目；patch 以 uid 为键
/// 转 dict 基底对位合并，输出归一为独立导出的 dict 形态（本应用新建
/// 导出的同款形态，导入/投影/解析两端双形态兼容）。条目级未知字段仍
/// 深拷贝保留；与 camelCase 可写子集语义冲突的 snake_case 孪生键
/// （keys/secondary_keys/insertion_order/enabled）在写出时清理，
/// 防止新旧两套字段并存自相矛盾。
Map<String, dynamic> patchWorldbookJson(
  Map<String, dynamic> original,
  WorldbookDraft draft,
) {
  final out = _deepCopy(original);
  out['name'] = draft.name;
  out['description'] = draft.description;
  final rawEntries = out['entries'];
  Map<String, dynamic>? oldEntries;
  if (rawEntries is Map) {
    oldEntries = Map<String, dynamic>.from(rawEntries);
  } else if (rawEntries is List) {
    oldEntries = <String, dynamic>{};
    for (var i = 0; i < rawEntries.length; i++) {
      final e = rawEntries[i];
      if (e is! Map) continue;
      oldEntries[(e['uid'] ?? i).toString()] = e;
    }
  }
  final newEntries = <String, dynamic>{};
  for (final e in draft.entries) {
    final base = oldEntries?[e.id];
    final baseMap = base is Map
        ? Map<String, dynamic>.from(_deepCopy(Map<String, dynamic>.from(base)))
        : <String, dynamic>{};
    newEntries[e.id] = _mergeEntry(baseMap, e)
      // 数组基底带入的 snake_case 孪生键清理（已写 camelCase 等价键）
      ..remove('keys')
      ..remove('secondary_keys')
      ..remove('insertion_order')
      ..remove('enabled');
  }
  out['entries'] = newEntries;
  return out;
}

/// 条目级合并：[base]（深拷贝后的原条目，可为空）按 [e] 覆盖 v1 可写子集。
///
/// extensions 顺序：原条目整包 → `WorldEntry.extensions` 携带值覆盖 →
/// 可写子集缺省兜底（`??=`，携带值优先）。
Map<String, dynamic> _mergeEntry(Map<String, dynamic> base, WorldEntry e) {
  final out = base;
  out['key'] = List<String>.of(e.keys);
  out['keysecondary'] = List<String>.of(e.secondaryKeys);
  out['comment'] = e.comment;
  out['content'] = e.content;
  out['constant'] = e.constant;
  out['selective'] = e.selective;
  out['order'] = e.insertionOrder;
  out['disable'] = !e.enabled;
  // 独立导出格式（entries 字典+
  // camelCase）的 position 规格是 int 枚举（DOC-15 §6.2：0=before_char/
  // 1=after_char）；字符串值只属内嵌 character_book 形态。读侧
  // 双形态兼容（string/num），写 int 不破坏任何读路径。
  out['position'] = e.positionBeforeChar ? 0 : 1;

  final ext = <String, dynamic>{};
  final baseExt = base['extensions'];
  if (baseExt is Map) {
    ext.addAll(Map<String, dynamic>.from(baseExt));
  }
  ext.addAll(Map<String, dynamic>.from(e.extensions));
  // v1 可写子集缺省（显式携带值已在前一步覆盖，不会被 ??= 改写）
  ext['depth'] ??= 4;
  ext['probability'] ??= 100;
  ext['useProbability'] ??= true;
  // 显式写入 null 键（跟随全局的 ST 写法）；??= null 是无操作，须用
  // putIfAbsent 保证键存在
  ext
    ..putIfAbsent('scan_depth', () => null)
    ..putIfAbsent('case_sensitive', () => null);
  // 中文为主的目标场景：整词匹配默认关（无空格分词时 true 会令词条全哑）
  ext['match_whole_words'] ??= false;
  ext['vectorized'] ??= false;
  out['extensions'] = ext;
  return out;
}

// ==================== 原文 → 草稿（编辑模式预填）====================

/// 角色卡 rawJson → CardDraft（data 段优先，V1 扁平回退）。
CardDraft cardDraftFromJson(Map<String, dynamic> raw) {
  final data =
      raw['data'] is Map ? Map<String, dynamic>.from(raw['data'] as Map) : raw;
  var draft = CardDraft.initial();
  for (final f in CardField.values) {
    final v = data[f.jsonName];
    if (v is String && v.isNotEmpty) {
      draft = draft.withField(f, v);
    }
  }
  final tags = data['tags'];
  if (tags is List) {
    draft = draft.withTags([for (final t in tags) t.toString()]);
  }
  return draft;
}

/// 世界书 rawJson → WorldbookDraft（条目 id 取原书 uid 字符串，patch 对位用；
/// 条目 extensions 整包带回，覆盖保存时原样回写）。
///
/// entries 双形态——独立导出的 dict
/// （camelCase 字段）与内嵌 character_book 的 List（snake_case 字段，
/// 键名 keys/secondary_keys/insertion_order/enabled/uid）。此前只认
/// dict：数组书预填出零条目空草稿，AI 覆盖保存把整书清空。
WorldbookDraft worldbookDraftFromJson(Map<String, dynamic> raw) {
  var draft = WorldbookDraft.initial().withMeta(
    name: raw['name'] is String ? raw['name'] as String : '',
    description:
        raw['description'] is String ? raw['description'] as String : '',
  );
  final entries = raw['entries'];
  if (entries is Map) {
    for (final e in entries.entries) {
      final id = e.key as String;
      if (e.value is! Map) continue;
      draft = draft.upsertEntry(
        _entryFromRow(Map<String, dynamic>.from(e.value as Map), id),
      );
    }
    return draft;
  }
  // 数组格式（内嵌 character_book）——id 取条目 uid（缺省回退
  // 下标，与 patchWorldbookJson 的基底构建同规则对位）。
  if (entries is List) {
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e is! Map) continue;
      final id = (e['uid'] ?? i).toString();
      draft = draft.upsertEntry(
        _entryFromRow(Map<String, dynamic>.from(e), id),
      );
    }
  }
  return draft;
}

/// key/keys 类字段的容错读取——裸 `as List?` 对
/// 字符串标量（如 `{"key":"单键"}`）抛 TypeError 炸掉整页启动。
///
/// 口径对齐导入侧容错：List 逐元素 toString；String 按逗号切分
///（单键形态的合理展开）；其余类型返回空。
List<String> _stringList(dynamic v) {
  if (v is List) return [for (final item in v) item.toString()];
  if (v is String && v.isNotEmpty) {
    return v.contains(',')
        ? [for (final part in v.split(',')) part.trim()]
            .where((s) => s.isNotEmpty)
            .toList()
        : [v];
  }
  return const [];
}

/// dict/List 双形态条目行 → WorldEntry（字段名 camelCase 优先、
/// snake_case 兜底；enabled/disable 双键以 disable 为准，缺省读 enabled）。
WorldEntry _entryFromRow(Map<String, dynamic> m, String id) {
  final position = m['position'];
  return WorldEntry(
    id: id,
    keys: _stringList(m['key'] ?? m['keys']),
    secondaryKeys: _stringList(m['keysecondary'] ?? m['secondary_keys']),
    comment: m['comment']?.toString() ?? '',
    content: m['content']?.toString() ?? '',
    constant: m['constant'] is bool && m['constant'] as bool,
    selective: m['selective'] is bool && m['selective'] as bool,
    insertionOrder: (m['order'] ?? m['insertion_order']) is num
        ? ((m['order'] ?? m['insertion_order']) as num).toInt()
        : 100,
    enabled: m.containsKey('disable')
        ? !((m['disable'] as bool?) ?? false)
        : ((m['enabled'] as bool?) ?? true),
    // position 双形态：dict 用 'before_char'/'after_char' 字符串，
    // character_book 用数字（0=角色定义前，其余按不在定义前处理）
    positionBeforeChar: position is String
        ? position != 'after_char'
        : position is! num || position.toInt() == 0,
    extensions: m['extensions'] is Map
        ? Map<String, dynamic>.from(m['extensions'] as Map)
        : const {},
  );
}
