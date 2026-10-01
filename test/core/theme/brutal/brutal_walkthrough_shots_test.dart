import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_factories.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_materials.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_radii.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/presentation/widgets/sidebar_session_item.dart';
import 'package:lmstory/features/settings/presentation/widgets/adaptive_setting_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../test_helpers/load_app_fonts.dart';

/// 批A 表面（会话列表行 / 设置入口卡）在棱角结构下的走查连拍 +
/// 结构特征断言（的机器证明：批A 呈现结构语言，无 classic 残留）。
///
/// 结构断言（默认常跑）：
/// - 会话项选中态：ink frameInline 描边 + 直角容器（classic/glass 下无描边）；
/// - 设置卡：[BrutalCard]（frameCard 描边 + 静止零阴影 + 直角）。
///
/// 截图产出（人眼走查素材）：`--dart-define=LM_SHOTS=true` 时落图
/// `test_screenshots/brutal-walkthrough/`（gitignore 覆盖），对照
/// `q2_baseline_shots_test.dart` 的连拍范式；真机 `flutter devices`
/// 在本机被安全策略禁用，桌面走查以此替代（环境限制在案）。
const bool kShotsEnabled = bool.fromEnvironment('LM_SHOTS');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
  });

  for (final paletteId in ['classic', 'bordeaux']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'brutal+$paletteId ${brightness.name} 批A 表面呈现结构语言',
        (tester) async {
          tester.view.physicalSize = const Size(900, 760);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final theme = ThemeCatalog.assemble(
            LmAppearance(structureId: 'brutal', paletteId: paletteId),
            brightness,
          );

          final selected = ChatSession(
            sessionId: 's1',
            title: '被选中的会话',
            mode: 'chat',
            createdAt: DateTime(2026),
            lastActiveAt: DateTime(2026),
            messageCount: 3,
          );
          final plain = ChatSession(
            sessionId: 's2',
            title: '普通会话',
            mode: 'intermediate',
            createdAt: DateTime(2026),
            lastActiveAt: DateTime(2026),
            messageCount: 1,
          );

          await tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(
                theme: theme,
                home: RepaintBoundary(
                  child: Scaffold(
                    body: ListView(
                      children: [
                        SidebarSessionItem(
                          session: selected,
                          index: 0,
                          isSelected: true,
                          onTap: () {},
                          onDelete: () {},
                          onRename: () {},
                          onToggleStar: () {},
                          onCopy: () {},
                        ),
                        SidebarSessionItem(
                          session: plain,
                          index: 1,
                          isSelected: false,
                          onTap: () {},
                          onDelete: () {},
                          onRename: () {},
                          onToggleStar: () {},
                          onCopy: () {},
                        ),
                        const SizedBox(height: 12),
                        AdaptiveSettingCard(
                          icon: Icons.palette,
                          title: '外观',
                          subtitle: '结构与配色',
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          // ──  断言①：会话项选中态 = 结构墨色描边 + 直角 ────────
          final palette = Theme.of(tester.element(find.byType(Scaffold)))
              .extension<LmTokens>()!
              .palette;
          final selectedContainer = tester.widget<Container>(
            find
                .ancestor(
                  of: find.text('被选中的会话'),
                  matching: find.byType(Container),
                )
                .first,
          );
          final selectedDecoration =
              selectedContainer.decoration! as BoxDecoration;
          expect(
            selectedDecoration.border?.top.width,
            BrutalRadii.frameInline,
            reason: '选中会话项应有 frameInline 描边',
          );
          expect(
            selectedDecoration.border?.top.color,
            BrutalMaterials.frameOf(palette),
            reason: '选中会话项描边应取当前结构墨色',
          );
          expect(
            selectedDecoration.borderRadius,
            BorderRadius.circular(BrutalRadii.cornerNone),
            reason: '会话项应为直角',
          );

          // ──  断言②：设置卡 = BrutalCard（描边卡 + 静止零阴影）───
          expect(
            find.descendant(
              of: find.byType(AdaptiveSettingCard),
              matching: find.byType(BrutalCard),
            ),
            findsOneWidget,
            reason: '棱角下设置入口应渲染 BrutalCard 而非 classic 卡',
          );
          final cardBox = tester.widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(BrutalCard),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          final cardDecoration = cardBox.decoration as BoxDecoration;
          expect(
            cardDecoration.border?.top.width,
            BrutalRadii.frameCard,
            reason: '设置卡应有 frameCard 描边',
          );
          expect(
            cardDecoration.boxShadow,
            isNull,
            reason: '卡片静止零阴影（阴影只在可按压元素）',
          );

          // ── 走查截图（LM_SHOTS 开关）──────────────────────────────
          if (kShotsEnabled) {
            await _writeShot(
              tester,
              'brutal_$paletteId'
              '__${brightness.name}'
              '__batchA',
            );
          }
        },
      );
    }
  }
}

/// 落图到 test_screenshots/brutal-walkthrough/（q2 连拍同款实现）。
///
/// 两条环境铁律（q2 实战教训，此处照搬）：
/// - `ImageByteFormat.png` 在本测试环境引擎侧不返回，必须取
///   rawStraightRgba 由 Dart 侧拼 PNG；
/// - 文件 IO 必须留在 `runAsync` 内——测试主体在 fake-async zone，
///   真实 dart:io Future 拿不到事件循环会永久挂起。
Future<void> _writeShot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.binding.runAsync<void>(() async {
    final image = await boundary.toImage();
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final rgba = data!.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    image.dispose();

    const outDir = 'test_screenshots/brutal-walkthrough';
    final dir = Directory(outDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    File('$outDir/$name.png').writeAsBytesSync(_encodePng(width, height, rgba));
  });
}

// ── 最小 PNG 编码器（q2 同款）──────────────────────────────────────

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) == 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _u32(int value) => <int>[
      (value >>> 24) & 0xFF,
      (value >>> 16) & 0xFF,
      (value >>> 8) & 0xFF,
      value & 0xFF,
    ];

void _addChunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  out
    ..add(_u32(data.length))
    ..add(typeBytes)
    ..add(data)
    ..add(_u32(_crc32(typeBytes + data)));
}

Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder();
  final stride = width * 4;
  for (var y = 0; y < height; y++) {
    raw
      ..addByte(0) // scanline filter = None
      ..add(Uint8List.sublistView(rgba, y * stride, (y + 1) * stride));
  }
  final idat = ZLibCodec().encoder.convert(raw.takeBytes());

  final ihdr = BytesBuilder()
    ..add(_u32(width))
    ..add(_u32(height))
    ..addByte(8) // bit depth
    ..addByte(6) // colour type: truecolour + alpha
    ..addByte(0) // compression
    ..addByte(0) // filter method
    ..addByte(0); // interlace

  final out = BytesBuilder()..add(const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  _addChunk(out, 'IHDR', ihdr.takeBytes());
  _addChunk(out, 'IDAT', idat);
  _addChunk(out, 'IEND', const <int>[]);
  return out.takeBytes();
}
