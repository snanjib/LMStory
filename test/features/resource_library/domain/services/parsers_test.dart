import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_library/domain/services/character_card_parser.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';

/// 导入解析器单元测试（DOC-15 §5）
///
/// 合成 fixture 覆盖核心逻辑；真实样本）若存在则额外验证。
void main() {
  group('CharacterCardParser.extractCardJson', () {
    test('从 PNG tEXt 提取 V2 chara JSON', () {
      const json =
          '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"测试"}}';
      final png = _buildPng({'chara': json});
      expect(CharacterCardParser.extractCardJson(png), json);
    });

    test('V3 ccv3 优先于 chara', () {
      final png = _buildPng({
        'chara': '{"spec":"chara_card_v2","data":{"name":"V2"}}',
        'ccv3': '{"spec":"chara_card_v3","data":{"name":"V3"}}',
      });
      expect(
        CharacterCardParser.extractCardJson(png),
        contains('chara_card_v3'),
      );
    });

    test('无 chara/ccv3 → 抛 FormatException', () {
      expect(
        () => CharacterCardParser.extractCardJson(_buildPng({})),
        throwsFormatException,
      );
    });

    test('无效 PNG 签名 → 抛 FormatException', () {
      expect(
        () => CharacterCardParser.extractCardJson(Uint8List.fromList([1, 2])),
        throwsFormatException,
      );
    });
  });

  group('CharacterCardParser.parse', () {
    test('V3 data 结构 + 内嵌 worldbook（字符串类型容错）', () {
      final json = jsonEncode({
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'data': {
          'name': 'ReZero',
          'description': '描述',
          'personality': '内向',
          'character_book': {
            'name': '书',
            'entries': [
              {
                'keys': '["货币汇率"]',
                'secondary_keys': '[]',
                'comment': '货币',
                'content': '1金币=100银币',
                'constant': 'True',
                'enabled': 'True',
              },
            ],
          },
        },
      });
      final card = CharacterCardParser.parse(json);
      expect(card.name, 'ReZero');
      expect(card.personality, '内向');
      expect(card.specVersion, 'v3');
      expect(card.embeddedEntries, hasLength(1));
      expect(card.embeddedEntries.single.keys, ['货币汇率']);
      expect(card.embeddedEntries.single.content, '1金币=100银币');
      expect(card.embeddedEntries.single.constant, isTrue);
    });

    test('V1 扁平结构（无 data）', () {
      final json = jsonEncode({
        'name': '旧卡',
        'description': '描述',
        'personality': '开朗',
      });
      final card = CharacterCardParser.parse(json);
      expect(card.name, '旧卡');
      expect(card.specVersion, 'v1');
    });
  });

  group('WorldbookParser.parse', () {
    test('独立导出：entries 字典 camelCase', () {
      final json = jsonEncode({
        'entries': {
          '0': {
            'key': ['魔王信长'],
            'keysecondary': <String>[],
            'comment': '标题',
            'content': '正文',
            'constant': false,
            'disable': false,
            'vectorized': false,
          },
        },
      });
      final entries = WorldbookParser.parse(json);
      expect(entries, hasLength(1));
      expect(entries.single.keys, ['魔王信长']);
      expect(entries.single.enabled, isTrue);
      expect(entries.single.constant, isFalse);
    });

    test('独立导出：disable=true → enabled=false', () {
      final json = jsonEncode({
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
            'disable': true,
          },
        },
      });
      final entries = WorldbookParser.parse(json);
      expect(entries.single.enabled, isFalse);
    });

    test('内嵌：entries 数组 snake_case + 字符串类型容错', () {
      final json = jsonEncode({
        'entries': [
          {
            'keys': '["a", "b"]',
            'secondary_keys': '[]',
            'comment': 'c',
            'content': 'd',
            'constant': 'False',
            'enabled': 'True',
          },
        ],
      });
      final entries = WorldbookParser.parse(json);
      expect(entries.single.keys, ['a', 'b']);
      expect(entries.single.constant, isFalse);
      expect(entries.single.enabled, isTrue);
    });
  });

  group('WorldbookParser.parseBook：顶层 name', () {
    test('顶层 name 存在 → 暴露为书名（消毒后）', () {
      final json = jsonEncode({
        'name': '奇妙的世界书',
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      });
      final result = WorldbookParser.parseBook(json);
      expect(result.name, '奇妙的世界书');
      expect(result.entries, hasLength(1));
      // parse 仍返回词条列表（既有调用方兼容）
      expect(WorldbookParser.parse(json), hasLength(1));
    });

    test('顶层 name 缺失 / 非字符串 / 清洗后为空 → 空串回退', () {
      String bookName(Map<String, dynamic> book) =>
          WorldbookParser.parseBook(jsonEncode(book)).name;
      final entries = {
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      };
      expect(bookName(entries), '', reason: '缺失');
      expect(bookName({...entries, 'name': 42}), '', reason: '非字符串忽略');
      expect(
        bookName({...entries, 'name': '\u200b'}),
        '',
        reason: '全零宽字符：消毒后为空，视为未提供',
      );
      expect(bookName({...entries, 'name': '  书名  '}), '书名', reason: '前后空白剥净');
    });
  });

  group('真实样本验证（若存在）', () {
    test('ReZero 角色卡 PNG', () {
      final f = File('doc/misc/世界书角色卡样本/ReZero_V2.5.png');
      if (!f.existsSync()) {
        markTestSkipped('样本不存在，跳过');
        return;
      }
      final json = CharacterCardParser.extractCardJson(f.readAsBytesSync());
      final card = CharacterCardParser.parse(json);
      expect(card.name, isNotEmpty);
      expect(card.embeddedEntries, isNotEmpty);
    });

    test('型月世界书 JSON', () {
      final f = File('doc/misc/世界书角色卡样本/奇妙的世界书DLC_型月篇2026_08_05.json');
      if (!f.existsSync()) {
        markTestSkipped('样本不存在，跳过');
        return;
      }
      final entries = WorldbookParser.parse(f.readAsStringSync());
      expect(entries, isNotEmpty);
    });
  });
}

/// 构造最小 PNG（含签名 + 若干 tEXt chunk + IEND），CRC 用占位字节。
Uint8List _buildPng(Map<String, String> textChunks) {
  final bytes = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  for (final entry in textChunks.entries) {
    final data = utf8
        .encode('${entry.key}\u0000${base64Encode(utf8.encode(entry.value))}');
    _addChunk(bytes, 'tEXt', data);
  }
  _addChunk(bytes, 'IEND', const []);
  return bytes.toBytes();
}

void _addChunk(BytesBuilder b, String type, List<int> data) {
  b
    ..add(_uint32(data.length))
    ..add(type.codeUnits)
    ..add(data)
    ..add(const [0, 0, 0, 0]); // 占位 CRC
}

List<int> _uint32(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
