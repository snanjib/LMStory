import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_import_service.dart';
import 'package:lmstory/features/resource_library/presentation/widgets/incoming_import_listener.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IncomingImportListener 组件测试（外部"打开方式/分享"导入）
///
/// 验证：
/// - PNG 文件事件 → 弹确认框（文件名 + 角色卡类型标签）
/// - 确认 → 调用 ResourceImportService 导入 + snackbar 成功提示
/// - 取消 → 不导入
/// - 临时文件在处理后删除
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late FakeResourceLibraryRepository repo;
  late File tempPng;

  setUp(() {
    repo = FakeResourceLibraryRepository();
    final png = _buildPng({
      'chara': '{"spec":"chara_card_v2","spec_version":"2.0",'
          '"data":{"name":"测试卡","description":"d"}}',
    });
    final dir = Directory.systemTemp.createTempSync('incoming_test');
    tempPng = File('${dir.path}/card.png')..writeAsBytesSync(png);
  });

  tearDown(() {
    if (tempPng.existsSync()) tempPng.deleteSync();
    tempPng.parent.deleteSync();
  });

  Widget wrap(Stream<IncomingFile> stream) {
    return ProviderScope(
      overrides: [
        resourceImportServiceProvider.overrideWithValue(
          ResourceImportService(repository: repo),
        ),
        incomingFileEventsProvider.overrideWith((ref) => stream),
      ],
      child: TranslationProvider(
        child: const MaterialApp(
          home: IncomingImportListener(
            child: Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );
  }

  testWidgets('PNG 事件 → 确认框 → 确认导入成功', (tester) async {
    final controller = StreamController<IncomingFile>();
    await tester.pumpWidget(wrap(controller.stream));
    await tester.pump();
    controller.add(
      IncomingFile(path: tempPng.path, fileName: 'card.png', mime: 'image/png'),
    );
    await tester.pumpAndSettle();

    // 确认框：标题 + 文件名 + 类型标签（角色卡）
    expect(find.text('导入到资源库'), findsOneWidget);
    expect(
      find.textContaining('将 "card.png" 作为角色卡导入资源库？'),
      findsOneWidget,
    );

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 导入成功：入库 + snackbar
    expect(repo.cards, hasLength(1));
    expect(repo.cards.single.name, '测试卡');
    expect(find.textContaining('已导入 "测试卡"'), findsOneWidget);

    // 临时文件已清理
    expect(tempPng.existsSync(), isFalse);
  });

  testWidgets('取消 → 不导入', (tester) async {
    final controller = StreamController<IncomingFile>();
    await tester.pumpWidget(wrap(controller.stream));
    await tester.pump();
    controller.add(
      IncomingFile(path: tempPng.path, fileName: 'card.png', mime: 'image/png'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repo.cards, isEmpty);
    expect(tempPng.existsSync(), isFalse);
  });

  testWidgets('备份 JSON → 备份确认框（非资源库导入）→ 取消不导入', (tester) async {
    final dir = Directory.systemTemp.createTempSync('incoming_test');
    final backupFile = File('${dir.path}/lmstory_backup_1.json')
      ..writeAsStringSync('{"version":3,"exportedAt":"2026-09-25T00:00:00Z",'
          '"sessions":[],"presets":[]}');
    addTearDown(() {
      if (backupFile.existsSync()) backupFile.deleteSync();
      backupFile.parent.deleteSync();
    });

    final controller = StreamController<IncomingFile>();
    await tester.pumpWidget(wrap(controller.stream));
    await tester.pump();
    controller.add(
      IncomingFile(
        path: backupFile.path,
        fileName: 'lmstory_backup_1.json',
        mime: 'application/json',
      ),
    );
    await tester.pumpAndSettle();

    // 分流到备份确认框，而不是「导入到资源库」——
    // 备份顶层结构此前会命中资源启发式被误导入
    expect(find.text('检测到应用数据备份'), findsOneWidget);
    expect(find.textContaining('lmstory_backup_1.json'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(repo.cards, isEmpty);
    // 临时文件已清理
    expect(backupFile.existsSync(), isFalse);
  });
}

/// 内存版仓储 fake（仅角色卡 create 路径需要真实行为）
class FakeResourceLibraryRepository implements ResourceLibraryRepository {
  final List<CharacterCard> cards = [];

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
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<void> deleteCharacterCard(String cardId) async {}

  @override
  Future<void> deleteWorldbook(String bookId) async {}

  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => cards;

  @override
  Future<List<Worldbook>> getAllWorldbooks() async => const [];

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
