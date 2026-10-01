import 'dart:convert';
import 'dart:typed_data';

import 'package:lmstory/core/text/injection_guard.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/domain/services/type_coercion.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';

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
      throw const FormatException('无效的 PNG 文件（签名校验失败）');
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
      throw const FormatException('PNG 中未找到角色卡元数据（chara/ccv3）');
    }
    return json;
  }

  /// 解析角色卡 JSON，返回 A 类字段 + 内嵌世界书
  static ParsedCharacterCard parse(String json) {
    final dynamic root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      throw FormatException('角色卡 JSON 解析失败：${e.message}');
    }
    if (root is! Map) {
      throw const FormatException('角色卡 JSON 顶层不是对象');
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
    // 主注入面；内嵌世界书经 WorldbookParser.normalizeEntry 自行消毒）
    return ParsedCharacterCard(
      name: sanitizeUntrusted(coerceString(data['name']), maxLength: 100),
      description: sanitizeUntrusted(coerceString(data['description'])),
      personality: sanitizeUntrusted(coerceString(data['personality'])),
      specVersion: _detectVersion(map),
      embeddedEntries: embedded,
    );
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
