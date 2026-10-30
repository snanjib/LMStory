import 'dart:convert';
import 'dart:typed_data';
import 'package:lmstory/core/text/injection_guard.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/domain/services/type_coercion.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 角色卡解析器（DOC-15 §5.1）
///
/// - [extractCardJson]：从 PNG `tEXt` chunk 提取 V1/V2（`chara`）/ V3（`ccv3`）
///   base64 JSON，V3 优先（参照 SillyTavern `extractDataFromPng` 算法）。
/// - [parse]：从角色卡 JSON 抽取 A 类字段（name/description/personality）与
///   内嵌世界书词条（character_book）。
///
/// 解析失败抛 [FormatException]。
class CharacterCardParser {
  const CharacterCardParser._();

  static const _pngSignature = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  /// 从 PNG 字节提取角色卡 JSON（V1/V2/V3），V3 优先
  static String extractCardJson(Uint8List data) {
    if (data.length < 8 || !_startsWithSignature(data)) {
      throw FormatException(t.settings.resourceLibrary.importErrors.invalidPng);
    }

    final found = <String, String>{}; // keyword(lower) -> json
    var idx = 8;
    while (idx + 8 <= data.length) {
      final length = _readUint32(data, idx);
      final type = String.fromCharCodes(data.sublist(idx + 4, idx + 8));
      final dataEnd = idx + 8 + length;
      if (dataEnd > data.length) break;

      if (type == 'IEND') break;

      if (type == 'tEXt') {
        final chunkData = data.sublist(idx + 8, dataEnd);
        final sep = chunkData.indexOf(0);
        if (sep >= 0) {
          final keyword = String.fromCharCodes(chunkData.sublist(0, sep));
          final text = chunkData.sublist(sep + 1);
          if (keyword.toLowerCase() == 'chara' ||
              keyword.toLowerCase() == 'ccv3') {
            try {
              found[keyword.toLowerCase()] = utf8.decode(
                base64Decode(String.fromCharCodes(text)),
              );
            } on FormatException {
              // 忽略无法 base64 解码的 chunk
            }
          }
        }
      }

      idx = dataEnd + 4; // 跳过 4 字节 CRC
    }

    // V3（ccv3）优先
    final json = found['ccv3'] ?? found['chara'];
    if (json == null) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.pngNoMetadata,
      );
    }
    return json;
  }

  /// 解析角色卡 JSON，返回 A 类字段 + 内嵌世界书
  static ParsedCharacterCard parse(String json) {
    final dynamic root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.cardJsonInvalid(
          detail: e.message,
        ),
      );
    }
    if (root is! Map) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.cardNotObject,
      );
    }

    final map = Map<String, dynamic>.from(root);
    // V2/V3 字段在 data 下；V1 为扁平结构
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : map;

    // 内嵌世界书（顶层 character_book + extensions 内藏 lorebook，DOC-15 决策 #7）
    final embedded = <NormalizedWorldEntry>[];
    _collectBook(embedded, data['character_book']);
    final extensions = data['extensions'];
    if (extensions is Map) {
      _collectBook(embedded, extensions['character_book']);
      _collectBook(embedded, extensions['embedded_lorebook']);
    }

    // 卡字段逐一消毒（name/description/personality 是导入内容的
    // 主注入面；内嵌世界书经 WorldbookParser.normalizeEntry 自行消毒）。
    // 富字段供内容查看器消费；导入链仍只读 name/description/personality。
    return ParsedCharacterCard(
      name: sanitizeUntrusted(coerceString(data['name']), maxLength: 100),
      description: sanitizeUntrusted(coerceString(data['description'])),
      personality: sanitizeUntrusted(coerceString(data['personality'])),
      specVersion: _detectVersion(map),
      embeddedEntries: embedded,
      scenario: sanitizeUntrusted(coerceString(data['scenario'])),
      firstMes: sanitizeUntrusted(coerceString(data['first_mes'])),
      alternateGreetings: [
        for (final g in _stringList(data['alternate_greetings']))
          sanitizeUntrusted(g),
      ],
      mesExample: sanitizeUntrusted(coerceString(data['mes_example'])),
      tags: [
        for (final tag in _stringList(data['tags'])) sanitizeUntrusted(tag),
      ],
      creatorNotes: sanitizeUntrusted(coerceString(data['creator_notes'])),
      systemPrompt: sanitizeUntrusted(coerceString(data['system_prompt'])),
      creator: sanitizeUntrusted(coerceString(data['creator']), maxLength: 100),
      nickname: sanitizeUntrusted(
        _stringList(data['nickname']).join('、'),
        maxLength: 100,
      ),
      age: sanitizeUntrusted(
        coerceString(data['age']),
        maxLength: 20,
      ),
      extraFields: _collectExtraFields(data),
    );
  }

  /// 查看器「其他字段」组：未消费的字符串/字符串列表字段。
  ///
  /// 复杂结构（Map/混合 List）不入列——查看器不出原始 JSON，
  /// 这类字段只能在原始 JSON 里看（查看器不承载）。
  static List<CardExtraField> _collectExtraFields(Map<String, dynamic> data) {
    const consumed = {
      'name', 'description', 'personality', 'scenario', 'first_mes',
      'alternate_greetings', 'mes_example', 'tags', 'creator_notes',
      'system_prompt', 'creator', 'nickname', 'age',
      // 已单独消费或查看器不展示的结构字段
      'character_book', 'extensions', 'avatar', 'avatar_url',
      'character_version', 'group_only_greetings', 'creator_notes_multilingual',
      'system_prompt_multilingual', 'post_history_instructions',
      'post_history_instructions_multilingual', 'tags_probability',
    };
    final extras = <CardExtraField>[];
    for (final entry in data.entries) {
      if (consumed.contains(entry.key)) continue;
      final v = entry.value;
      String value;
      if (v is String && v.trim().isNotEmpty) {
        value = sanitizeUntrusted(v);
      } else if (v is List && v.isNotEmpty && v.every((e) => e is String)) {
        value = sanitizeUntrusted((v as List<String>).join('、'));
      } else {
        continue;
      }
      if (value.isEmpty) continue;
      extras.add(CardExtraField(key: entry.key, value: value));
    }
    return extras;
  }

  /// 字符串列表消毒读取（null/非列表/含非字符串项 → 空表）。
  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is String && e.trim().isNotEmpty) out.add(e);
    }
    return out;
  }

  /// 从世界书对象（{ entries: [...] }）收集词条到 [out]
  static void _collectBook(List<NormalizedWorldEntry> out, dynamic book) {
    if (book is! Map) return;
    final entries = book['entries'];
    // entries 为字典格式（SillyTavern 世界书导出的
    // 原生形态，聚合工具把它塞进 character_book/extensions.embedded_lorebook
    // 时保留 dict）→ 取 values 归一化，与 WorldbookParser 的双支持对齐；
    // 此前静默丢弃，"内容全在 character_book"的卡会导入成近乎空壳。
    final List<dynamic> entryList;
    if (entries is List) {
      entryList = entries;
    } else if (entries is Map) {
      entryList = entries.values.toList();
    } else {
      return;
    }
    for (final e in entryList) {
      if (e is Map) {
        out.add(WorldbookParser.normalizeEntry(Map<String, dynamic>.from(e)));
      }
    }
  }

  /// 检测卡规范版本：v3 / v2 / v1（无 spec 字段为 V1）
  static String _detectVersion(Map<String, dynamic> map) {
    final spec = coerceString(map['spec']);
    final specVersion = coerceString(map['spec_version']);
    if (spec.contains('v3') || specVersion.startsWith('3')) return 'v3';
    if (spec.contains('v2') || specVersion.startsWith('2')) return 'v2';
    return 'v1';
  }

  static bool _startsWithSignature(Uint8List data) {
    for (var i = 0; i < 8; i++) {
      if (data[i] != _pngSignature[i]) return false;
    }
    return true;
  }

  static int _readUint32(Uint8List data, int offset) {
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }
}
