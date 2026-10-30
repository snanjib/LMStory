import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_import_service.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 资源导入服务单元测试：PNG 卡 / 世界书 JSON / 纯 JSON 卡自动识别
void main() {
  late FakeResourceLibraryRepository repo;
  late ResourceImportService service;

  setUp(() {
    repo = FakeResourceLibraryRepository();
    service = ResourceImportService(repository: repo);
  });

  group('导入错误文案随 UI 语言', () {
    test('en 下结构错误为英文', () async {
      await LocaleSettings.setLocale(AppLocale.enUs);
      addTearDown(() => LocaleSettings.setLocale(AppLocale.zhCn));

      await expectLater(
        service.importCardJson('{"entries":{"e1":{}}}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('worldbook JSON'),
          ),
        ),
      );
    });
  });

  group('importCardBytes', () {
    test('PNG V2 卡：按卡内 name 入库，sourceFormat=v2', () async {
      const json =
          '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"ReZero","description":"d"}}';
      final result = await service.importCardBytes(
        _buildPng({'chara': json}),
      );
      expect(result.kind, ImportKind.characterCard);
      expect(result.name, 'ReZero');
      expect(repo.cards, hasLength(1));
      expect(repo.cards.single.name, 'ReZero');
      expect(repo.cards.single.sourceFormat, 'v2');
      expect(repo.cards.single.rawJson, json);
    });

    test('卡内无 name → 用文件名回退并剥扩展名（WA10-3）', () async {
      const json = '{"spec":"chara_card_v2","data":{"description":"d"}}';
      final result = await service.importCardBytes(
        _buildPng({'chara': json}),
        fallbackName: '卡片.png',
      );
      // 只修了世界书半边，卡路径曾把
      // 「卡片.png」原样入库为显示名
      expect(result.name, '卡片');
    });

    test('无 chara/ccv3 的 PNG → 抛 FormatException，不入库', () async {
      await expectLater(
        service.importCardBytes(_buildPng({})),
        throwsFormatException,
      );
      expect(repo.cards, isEmpty);
    });
  });

  group('第十三轮守卫回归（WA13-1/WA10-8）', () {
    test('WA13-1：仅 spec 标记的空壳 V2 卡 → 拒绝，不入库', () async {
      await expectLater(
        service.importCardJson(
          jsonEncode({'spec': 'chara_card_v2', 'data': <String, dynamic>{}}),
        ),
        throwsFormatException,
      );
      expect(repo.cards, isEmpty);
    });

    test('WA13-1：有 description 的 V2 卡正常导入（守卫不误伤）', () async {
      final result = await service.importCardJson(
        jsonEncode({
          'spec': 'chara_card_v2',
          'data': {'description': '有内容的卡'},
        }),
      );
      expect(result.kind, ImportKind.characterCard);
      expect(repo.cards, hasLength(1));
    });

    test('WA10-8：空 entries 世界书 → 拒绝，不入库', () async {
      await expectLater(
        service.importWorldbookContent(
          jsonEncode({'entries': <String, dynamic>{}}),
        ),
        throwsFormatException,
      );
      expect(repo.books, isEmpty);
    });

    test('WA10-8：有词条世界书正常导入（守卫不误伤）', () async {
      final result = await service.importWorldbookContent(
        jsonEncode({
          'name': '有词条的书',
          'entries': {
            '0': {
              'key': ['魔王'],
              'content': '魔王住在城堡',
            },
          },
        }),
      );
      expect(result.kind, ImportKind.worldbook);
      expect(repo.books, hasLength(1));
    });
  });

  group('importWorldbookContent', () {
    test('无顶层 name：文件名兜底作显示名，去 .json 扩展名（WA8-3）', () async {
      final content = jsonEncode({
        'entries': {
          '0': {
            'key': ['魔王'],
            'content': '正文',
          },
        },
      });
      final result = await service.importWorldbookContent(
        content,
        fallbackName: '型月.json',
      );
      expect(result.kind, ImportKind.worldbook);
      expect(result.name, '型月');
      expect(repo.books.single.rawJson, content);
    });

    test('顶层 name 优先于文件名作显示名（WA8-3）', () async {
      final content = jsonEncode({
        'name': '奇妙的世界书',
        'entries': {
          '0': {
            'key': ['魔王'],
            'content': '正文',
          },
        },
      });
      final result = await service.importWorldbookContent(
        content,
        fallbackName: '随便起的文件名.json',
      );
      expect(result.name, '奇妙的世界书');
      expect(repo.books.single.name, '奇妙的世界书');
    });

    test('顶层 name 清洗后为空 → 回退去扩展名的文件名', () async {
      final content = jsonEncode({
        'name': '\u200b\u200b', // 全零宽字符，消毒后为空
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      });
      final result = await service.importWorldbookContent(
        content,
        fallbackName: '型月.json',
      );
      expect(result.name, '型月');
    });

    test('兜底文件名去 .png 扩展名（大小写不敏感）且只取最后一段', () async {
      final content = jsonEncode({
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      });
      // 正斜杠路径在 win/posix 都是合法分隔符，测试保持平台中立
      final png = await service.importWorldbookContent(
        content,
        fallbackName: 'downloads/世界书.PNG',
      );
      expect(png.name, '世界书', reason: '只取最后一段并去 .png 扩展名（大小写不敏感）');
    });

    test('无文件名也无顶层 name → 默认名「世界书」', () async {
      final content = jsonEncode({
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      });
      final result = await service.importWorldbookContent(content);
      expect(result.name, '世界书');
    });
  });

  group('importAuto（外部打开/分享入口）', () {
    test('bytes → 按角色卡导入', () async {
      const json = '{"spec":"chara_card_v3","data":{"name":"V3卡"}}';
      final result = await service.importAuto(
        bytes: _buildPng({'ccv3': json}),
      );
      expect(result.kind, ImportKind.characterCard);
      expect(result.name, 'V3卡');
    });

    test('JSON 含 entries → 按世界书导入', () async {
      final content = jsonEncode({
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      });
      final result = await service.importAuto(content: content);
      expect(result.kind, ImportKind.worldbook);
      expect(repo.books, hasLength(1));
      expect(repo.cards, isEmpty);
    });

    test('JSON 为 V2/V3 纯 JSON 卡（无 entries）→ 按角色卡导入', () async {
      final content = jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {'name': 'JSON卡', 'description': 'd'},
      });
      final result = await service.importAuto(content: content);
      expect(result.kind, ImportKind.characterCard);
      expect(result.name, 'JSON卡');
      expect(repo.cards.single.sourceFormat, 'v2');
    });

    test('JSON 既非世界书也非角色卡 → 抛 FormatException，不入库', () async {
      await expectLater(
        service.importAuto(content: '{"foo": 1}'),
        throwsFormatException,
      );
      expect(repo.cards, isEmpty);
      expect(repo.books, isEmpty);
    });

    test('非 JSON 内容 → 抛 FormatException', () async {
      await expectLater(
        service.importAuto(content: 'plain text'),
        throwsFormatException,
      );
    });
  });

  group('UTF-8 BOM 剥除（WA-2）', () {
    /// Windows 记事本「带 BOM 的 UTF-8」导出是真实高频来源；
    /// 三条导入路径（应用内 JSON×2 + 外部分享）统一在服务入口剥除。
    final worldbookJson = jsonEncode({
      'entries': {
        '0': {
          'key': ['魔王'],
          'content': '正文',
        },
      },
    });

    test('带 BOM 的世界书 JSON → importWorldbookContent 成功且 rawJson 无 BOM',
        () async {
      final result = await service.importWorldbookContent(
        '\uFEFF$worldbookJson',
        fallbackName: '型月.json',
      );
      expect(result.kind, ImportKind.worldbook);
      expect(result.name, '型月');
      expect(repo.books.single.rawJson, worldbookJson);
    });

    test('带 BOM 的世界书 JSON → importAuto 仍识别为世界书（外部入口）', () async {
      final result = await service.importAuto(content: '\uFEFF$worldbookJson');
      expect(result.kind, ImportKind.worldbook);
      expect(repo.books.single.rawJson, worldbookJson);
    });

    test('带 BOM 的 V2 卡 JSON → importCardJson 成功（应用内纯 JSON 卡入口）', () async {
      const cardJson =
          '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"ReZero","description":"d"}}';
      final result = await service.importCardJson('\uFEFF$cardJson');
      expect(result.kind, ImportKind.characterCard);
      expect(result.name, 'ReZero');
      expect(repo.cards.single.rawJson, cardJson);
    });

    test('带 BOM 的内容 → detectJsonKind 正确识别（外部导入确认框标签）', () {
      expect(
        ResourceImportService.detectJsonKind('\uFEFF$worldbookJson'),
        ImportKind.worldbook,
      );
      const cardJson = '{"spec":"chara_card_v2","data":{"name":"x"}}';
      expect(
        ResourceImportService.detectJsonKind('\uFEFF$cardJson'),
        ImportKind.characterCard,
      );
    });

    test('无 BOM 内容不受影响（幂等）', () async {
      final result = await service.importWorldbookContent(worldbookJson);
      expect(result.kind, ImportKind.worldbook);
      expect(repo.books.single.rawJson, worldbookJson);
    });
  });

  group('导入不设体积上限', () {
    /// 超 10MB 的世界书 JSON（按 UTF-8 字节数计）正常导入。
    /// '中' = 3 个 UTF-8 字节，直接字符串拼接构造避免 jsonEncode 开销。
    test('超 10MB 世界书 JSON → 正常导入且入库', () async {
      final oversizeContent = '中' * (10 * 1024 * 1024 ~/ 3 + 1);
      final content =
          '{"name":"大部头","entries":{"0":{"key":["x"],"content":"$oversizeContent"}}}';

      final result = await service.importWorldbookContent(
        content,
        fallbackName: '大部头.json',
      );
      expect(result.kind, ImportKind.worldbook);
      expect(result.name, '大部头');
      expect(repo.books, hasLength(1));
    });
  });

  group('JSON 嵌套深度粗检（安全评测 P3-2）', () {
    /// 600 层嵌套数组（超过 500 层上限）。用字符串拼接构造——
    /// jsonEncode 序列化同等深度自身会递归爆栈。
    final deep = '{"name":"deep","entries":{"a":${'[' * 600}1${']' * 600}}}';

    test('世界书入口深嵌套 → 拒绝且不入库', () async {
      await expectLater(
        service.importWorldbookContent(deep),
        throwsFormatException,
      );
      expect(repo.books, isEmpty);
    });

    test('角色卡入口深嵌套 → 拒绝且不入库', () async {
      await expectLater(
        service.importCardJson(deep),
        throwsFormatException,
      );
      expect(repo.cards, isEmpty);
    });

    test('结构识别深嵌套短路：detectJsonKind 返回 null（不进解析器）', () {
      expect(ResourceImportService.detectJsonKind(deep), isNull);
    });

    test('字符串字面量内的括号不计深度：正常卡含 600 个 [ 不误判', () {
      final brackets = '[' * 600;
      final card = '{"spec":"chara_card_v2","data":{"name":"文内括号",'
          '"description":"正文中出现大量括号 $brackets 也只是字符串内容"}}';
      expect(
        ResourceImportService.detectJsonKind(card),
        ImportKind.characterCard,
      );
    });
  });
}

/// 内存版仓储 fake：记录 create 调用
class FakeResourceLibraryRepository implements ResourceLibraryRepository {
  final List<CharacterCard> cards = [];
  final List<Worldbook> books = [];

  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async {
    final card = CharacterCard(
      cardId: 'card-${cards.length}',
      name: name,
      rawJson: rawJson,
      sourceFormat: sourceFormat,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    cards.add(card);
    return card;
  }

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async {
    final book = Worldbook(
      bookId: 'book-${books.length}',
      name: name,
      rawJson: rawJson,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    books.add(book);
    return book;
  }

  @override
  Future<void> updateCharacterCard({
    required String cardId,
    required String name,
    required String rawJson,
  }) async {
    final i = cards.indexWhere((c) => c.cardId == cardId);
    if (i >= 0) {
      cards[i] = CharacterCard(
        cardId: cardId,
        name: name,
        rawJson: rawJson,
        sourceFormat: cards[i].sourceFormat,
        createdAt: cards[i].createdAt,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> updateWorldbook({
    required String bookId,
    required String name,
    required String rawJson,
  }) async {
    final i = books.indexWhere((b) => b.bookId == bookId);
    if (i >= 0) {
      books[i] = Worldbook(
        bookId: bookId,
        name: name,
        rawJson: rawJson,
        createdAt: books[i].createdAt,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<void> deleteCharacterCard(String cardId) async {}

  @override
  Future<void> deleteWorldbook(String bookId) async {}

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => cards;

  @override
  Future<List<Worldbook>> getAllWorldbooks() async => books;

  @override
  Future<CharacterCard?> getCharacterCard(String cardId) async => null;

  @override
  Future<Worldbook?> getWorldbook(String bookId) async => null;
}

/// 构造最小 PNG（签名 + tEXt chunk + IEND），CRC 占位
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
