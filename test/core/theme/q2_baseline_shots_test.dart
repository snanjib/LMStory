import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_surface.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_empty_view.dart';
import 'package:lmstory/features/chat/presentation/pages/home_page.dart';
import 'package:lmstory/features/onboarding/presentation/pages/onboarding_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/load_app_fonts.dart';
import '../../test_helpers/stub_settings_notifier.dart';

/// 四组合 × 明暗 视觉基线连拍（地基）。
///
/// **默认不产出任何文件**——需显式开启：
/// ```bash
/// flutter test test/core/theme/q2_baseline_shots_test.dart \
///   --dart-define=LM_SHOTS=true
/// ```
/// 可选 `--dart-define=LM_SHOT_VIEWS=appearance,sink` 只跑部分视图。
///
/// 为什么默认关闭：常规回归不该往磁盘写几 MB 截图。
/// 为什么要它： 已证明「过渡 scrim / 兜底底色」这类缺陷只有看真实像素才能发现，
/// 而本机 `flutter devices` 被安全策略禁用（`reg.EXE` 进黑名单），
/// 真机截图路线不可用。本用例退而求其次：渲染**真实 widget 树 + 真实 ThemeData**，
/// 落图到 `test_screenshots/night-2026-09-21/`（该目录已被 .gitignore 覆盖）。
///
/// 这与 golden 的区别：golden 是「锁死回归」，本用例是「供人眼评审的素材产出」，
/// 不写断言、不做比对，只看。
const bool kShotsEnabled = bool.fromEnvironment('LM_SHOTS');
const String kViewsFilter = String.fromEnvironment('LM_SHOT_VIEWS');

const String _outDir = 'test_screenshots/night-2026-09-21';
const List<String> _allViews = <String>[
  'appearance',
  'settings',
  'sink',
  'drawer',
  'dialog',
  'sheet',
  'states',
  //  复评新增：第一印象面（真实首屏 / 真实空态）。
  // 之前七轮的出图素材全是「料理台 / 设置页」，从未渲染过真实首屏，
  // 于是「首屏在琉璃模式下是否真的有场地」「空态是否仍是图标+居中堆叠」
  // 这类整体面判断没有任何证据。这三张补齐。
  'firstrun',
  'home',
  'empty',
];

/// 设置主页的最小替身：只读依赖走空实现，未用到的方法显式报错，
/// 避免「静默成功但页面其实是空的」这种假信号。
class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  Future<int> getCustomPresetCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 首页空态替身返回空列表，走真实空态组件。
/// 其余方法显式报错，避免「静默成功但页面其实是空的」。
class _StubChatRepository implements ChatRepository {
  @override
  Future<HomeSessions> getHomeSessions() async =>
      (recent: const <ChatSession>[], latestStory: null);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

const List<String> _structures = <String>['classic', 'glass'];
const List<String> _palettes = <String>['classic', 'bordeaux'];

void main() {
  if (!kShotsEnabled) {
    // 未开启：留一个空 passing 用例，避免空文件让 flutter test 报错。
    test('baseline shots disabled (pass --dart-define=LM_SHOTS=true)', () {});
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await _loadRealFonts();
  });

  final views = kViewsFilter.isEmpty
      ? _allViews
      : kViewsFilter.split(',').map((e) => e.trim()).toList();

  for (final structure in _structures) {
    for (final paletteId in _palettes) {
      for (final brightness in Brightness.values) {
        for (final view in views) {
          testWidgets(
            '${structure}_$paletteId __ ${brightness.name} __ $view',
            (tester) async {
              await _shootOne(
                tester,
                structureId: structure,
                paletteId: paletteId,
                brightness: brightness,
                view: view,
              );
            },
          );
        }
      }
    }
  }
}

Future<void> _shootOne(
  WidgetTester tester, {
  required String structureId,
  required String paletteId,
  required Brightness brightness,
  required String view,
}) async {
  tester.view.physicalSize = const Size(1100, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _log('physicalSize set');

  SharedPreferences.setMockInitialValues({});
  final prefs = Preferences(prefs: await SharedPreferences.getInstance());
  _log('prefs ok');

  final theme = ThemeCatalog.assemble(
    LmAppearance(structureId: structureId, paletteId: paletteId),
    brightness,
  ).withCjkFallbackForShots();
  _log('theme ok');

  // 真实设置页需要 ProviderScope 及其依赖替身（沿用仓库现有稳定搭法）；
  // 料理台视图不需要，但统一走同一层开销无妨。
  GlobalKey<_StateMatrixRootState>? matrixKey;
  final Widget root;
  if (view == 'states') {
    //  五态矩阵：玻璃工厂 / 经典对应件同构渲染，由 structureId 分流。
    matrixKey = GlobalKey<_StateMatrixRootState>();
    root = _StateMatrixRoot(
      key: matrixKey,
      glass: structureId == 'glass',
    );
  } else if (view == 'appearance') {
    root = const GeneralAppearanceSettingsPage();
  } else if (view == 'settings') {
    root = const GeneralSettingsPage();
  } else if (view == 'firstrun') {
    // 真实首次启动引导页（首屏）。
    root = const OnboardingPage();
  } else if (view == 'home') {
    // 真实首页（会话列表）；stub 返回空会话 → 真实空态。
    root = const HomePage(
      onNewChat: _noopTap,
      onNewStory: _noopTap,
      onSessionSelected: _noopSession,
    );
  } else if (view == 'empty') {
    root = const _EmptyRoot();
  } else {
    root = _ShotRoot(view: view);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        apiPresetRepositoryProvider
            .overrideWithValue(_StubApiPresetRepository()),
        chatRepositoryProvider.overrideWithValue(_StubChatRepository()),
        settingsNotifierProvider.overrideWith((ref) => StubSettingsNotifier()),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
        ),
        preferencesProvider.overrideWithValue(prefs),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: theme,
          builder: (context, child) =>
              // 根级中文回退：widget 里显式构造的 TextStyle（inherit=true）会
              // 与 DefaultTextStyle 合并，未设置的 fontFamilyFallback 由此补上。
              DefaultTextStyle(
            style: TextStyle(
              // 同理：family 必须非 null，否则占位 Roboto 抢字形。
              fontFamily: kHasSystemCjkForShots ? 'Inter' : null,
              fontFamilyFallback: kHasSystemCjkForShots
                  ? const ['Microsoft YaHei', 'LMSerifSC']
                  : null,
            ),
            child: RepaintBoundary(
              key: const ValueKey('shot'),
              // 复刻 main.dart 的根场地壳：琉璃下一切都在 GlassBackdrop 之上。
              // 截图边界必须包住场地——它在 Navigator 之下，若只包 home，
              // 琉璃透明 Scaffold 的整帧捕获会 alpha=0（场地不在子树内）。
              child: context.glassVenue(child ?? const SizedBox.shrink()),
            ),
          ),
          home: root,
        ),
      ),
    ),
  );
  _log('pumpWidget done');
  await _settle(tester);
  _log('settled');

  if (view == 'states') {
    await _shootStates(
      tester,
      matrixKey!,
      structureId: structureId,
      paletteId: paletteId,
      brightness: brightness,
    );
    return;
  }

  switch (view) {
    case 'drawer':
      await tester.tap(find.byKey(const ValueKey('open_drawer')));
      await _settle(tester);
      _log('drawer opened');
    case 'dialog':
      // 料理台加料后按钮可能被推出视口：tap 前先滚入，否则落空
      // （实锤：dialog 截图与 sink 逐像素相同 = 弹窗未开）。
      await tester.ensureVisible(find.byKey(const ValueKey('open_dialog')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('open_dialog')));
      await _settle(tester);
      _log('dialog opened');
    case 'sheet':
      await tester.ensureVisible(find.byKey(const ValueKey('open_sheet')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('open_sheet')));
      await _settle(tester);
      _log('sheet opened');
    default:
      break;
  }

  final name = '${structureId}_$paletteId'
      '__${brightness.name}'
      '__$view';
  _log('writing $name');
  await _writeShot(tester, name);
  _log('wrote $name');
}

/// 定帧 settle，替代 `pumpAndSettle`。
///
/// 为什么不用 pumpAndSettle：个别页面存在常驻动效，它会拖到 **10 分钟默认超时**
/// 才抛，连拍 8 组合时表现为「卡死」。本用例只做像素采集，推进到稳定态即可，
/// 不等绝对静止。
Future<void> _settle(WidgetTester tester) async {
  _log('settle enter');
  await tester.pump();
  _log('settle pump1');
  for (final ms in const [100, 300, 600, 900]) {
    await tester.pump(Duration(milliseconds: ms));
  }
  _log('settle done');
}

/// 加载真实字体（共享 helper：打包字体 + Windows 系统中文兜底），
/// 让截图有真实字形而不是占位方块，「文字发虚 / 可读性」评审才成立。
/// 详见 `test/test_helpers/load_app_fonts.dart` 顶部注释的三级坑记录。
Future<void> _loadRealFonts() async {
  kHasSystemCjkForShots = await loadAppFonts(withSystemCjkFallback: true);
  _log('fonts loaded, systemCjk=$kHasSystemCjkForShots');
}

/// 是否成功加载了系统级中文字体（供下方的 ThemeData 回退扩展判断）。
bool kHasSystemCjkForShots = false;

/// flutter_tester 没有平台字体管理器，引擎**不会**对注册族做逐字自动回退——
/// 缺字只会渲染成测试占位字形。给文本主题显式加 `fontFamilyFallback`
/// 才能让中文落到上面注册的系统中文字体。仅截图夹具使用，不进生产代码。
extension ShotThemeCjkFallback on ThemeData {
  ThemeData withCjkFallbackForShots() {
    if (!kHasSystemCjkForShots) return this;
    const fallback = <String>['Microsoft YaHei', 'LMSerifSC'];
    TextStyle? fix(TextStyle? style) => style?.copyWith(
          // family 为 null 的样式（如 LmUiTextStyles.caption）会落到引擎默认
          // Roboto——测试占位字体自称拥有全部字形，familyFallback 永远轮不到。
          // 显式给 Inter（UI 文字的真实族），缺字才走下面的回退链。
          fontFamily: style.fontFamily ?? 'Inter',
          fontFamilyFallback: fallback,
        );

    // 按钮标签走组件主题里的显式 textStyle（inherit 链被按钮内部
    // DefaultTextStyle 接管，根级回退够不到），必须逐个补。
    // 注意：这里同样要钉 fontFamily（与上面 fix 同理）——只给
    // fontFamilyFallback 而 family 为 null 时，标签会落到引擎默认占位字体，
    // 缺字直接渲染成实心方块（实测经典侧 FilledButton 的「确」字变白方块）。
    ButtonStyle fixButton(ButtonStyle? style) {
      final base = style ?? const ButtonStyle();
      final label =
          base.textStyle?.resolve(const <WidgetState>{}) ?? const TextStyle();
      return base.copyWith(
        textStyle: WidgetStatePropertyAll(
          label.copyWith(
            fontFamily: label.fontFamily ?? 'Inter',
            fontFamilyFallback: fallback,
          ),
        ),
      );
    }

    return copyWith(
      textTheme: textTheme.apply(fontFamilyFallback: fallback),
      primaryTextTheme: primaryTextTheme.apply(fontFamilyFallback: fallback),
      appBarTheme: appBarTheme.copyWith(
        titleTextStyle: (appBarTheme.titleTextStyle ?? textTheme.titleLarge)
            ?.copyWith(fontFamilyFallback: fallback),
        toolbarTextStyle: (appBarTheme.toolbarTextStyle ?? textTheme.bodyMedium)
            ?.copyWith(fontFamilyFallback: fallback),
      ),
      elevatedButtonTheme:
          ElevatedButtonThemeData(style: fixButton(elevatedButtonTheme.style)),
      filledButtonTheme:
          FilledButtonThemeData(style: fixButton(filledButtonTheme.style)),
      outlinedButtonTheme:
          OutlinedButtonThemeData(style: fixButton(outlinedButtonTheme.style)),
      textButtonTheme:
          TextButtonThemeData(style: fixButton(textButtonTheme.style)),
      chipTheme: chipTheme.copyWith(
        labelStyle: fix(chipTheme.labelStyle),
        secondaryLabelStyle: fix(chipTheme.secondaryLabelStyle),
      ),
      dialogTheme: dialogTheme.copyWith(
        titleTextStyle: fix(dialogTheme.titleTextStyle),
        contentTextStyle: fix(dialogTheme.contentTextStyle),
      ),
    );
  }
}

/// 同步写下每行并 flush：卡住时 stdout 里能看到最后走到哪一步。
void _log(String msg) {
  // ignore: avoid_print
  print('[Q2] $msg');
}

Future<void> _writeShot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject(find.byKey(const ValueKey('shot')))
      as RenderRepaintBoundary;
  await tester.binding.runAsync<void>(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    // 关键一：不能用 ImageByteFormat.png —— 本测试环境该调用不返回
    // （现象：到 toImage 全部正常随后永久挂住，连 --timeout 都不触发，
    // 说明是引擎侧编码器卡死而非 Dart 侧超时）。取原始 RGBA，
    // PNG 由 [_encodePng] 在 Dart 侧自行拼装。
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final rgba = data!.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    image.dispose();

    // 关键二：文件 IO 必须留在 runAsync 内。测试主体跑在 fake-async zone，
    // 真实 dart:io Future 拿不到事件循环调度会永久挂起（本用例最初就是
    // 卡在 `Directory.create` 上，现象同样是无输出 + timeout 不触发）。
    // 这里直接用同步 IO，彻底绕开调度问题。
    final dir = Directory(_outDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    File('$_outDir/$name.png')
        .writeAsBytesSync(_encodePng(width, height, rgba));
  });
  _log('wrote $name');
}

// ── 最小 PNG 编码器 ─────────────────────────────────────────────────
// 只需要「把 rawStraightRgba 变成能打开的 PNG」：8-bit / RGBA / 无交错 /
// filter=0，压缩交给 dart:io 的 ZLibCodec。

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

/// 聚焦态演示：聚焦的玻璃药丸（环+辉光）+ 静息玻璃输入框。
/// 聚焦环与辉光取运行时 palette.accent（派生），四组合 × 明暗
/// 出图即可肉眼核对「辉光随配色轴」。显式 postFrame requestFocus：
/// autofocus 在夹具（抽屉+正文双 _KitchenSink 实例）里不可靠。
class _FocusedGlassRow extends StatefulWidget {
  const _FocusedGlassRow();

  @override
  State<_FocusedGlassRow> createState() => _FocusedGlassRowState();
}

class _FocusedGlassRowState extends State<_FocusedGlassRow> {
  final _focus = FocusNode(debugLabel: 'q2-focused-pill');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GlassPillButton(
          label: '聚焦药丸',
          onPressed: () {},
          focusNode: _focus,
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: SizedBox(
            height: 48,
            child: GlassInput(child: TextField()),
          ),
        ),
      ],
    );
  }
}

void _noopTap() {}

void _noopSession(ChatSession session) {}

/// 真实对话空态（`ChatEmptyView` → `SimpleEmptyState`）单独成屏，
/// 与首页空态（`home_page._buildEmptyState`）形成对照——
/// 首轮 P2「空状态是 AI 模板」的收口范围是否有遗漏，靠这两张并排看。
class _EmptyRoot extends StatelessWidget {
  const _EmptyRoot();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(title: const Text('对话')),
      body: const ChatEmptyView(onStart: _noopTap),
    );
  }
}

/// 评审用容器：把「要看的东西」集中到一屏。
class _ShotRoot extends StatelessWidget {
  const _ShotRoot({required this.view});
  final String view;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: Text(view == 'settings' ? '通用设置' : '外观'),
        leading: Builder(
          builder: (inner) => IconButton(
            key: const ValueKey('open_drawer'),
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(inner).openDrawer(),
          ),
        ),
      ),
      // 抽屉宽 304，料理台内容高于视口，必须可滚动，否则 RenderFlex 溢出报错。
      // 抽屉面板自带场地（与 main_layout 真实抽屉同构：GlassBackdrop +
      //  浮起，非裸 Drawer）——裸抽屉在琉璃下会与页面内容叠印，
      // 那是夹具简化伪影而非产品缺陷。
      drawer: context.glassVenue(
        const Drawer(
          child: SingleChildScrollView(child: _KitchenSink(inDrawer: true)),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _KitchenSink(inDrawer: view == 'drawer'),
        ),
      ),
    );
  }
}

/// 评审料理台：怀疑 Visual Debt 的要素全部平铺，逐组合对比。
class _KitchenSink extends StatelessWidget {
  const _KitchenSink({this.inDrawer = false});
  final bool inDrawer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: inDrawer ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        Text('标题层级 Heading', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '正文段落：聚焦-button/分隔线/选中态/空态/加载态是否都还在，'
          '以及琉璃层下这段文字是否发虚。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        SimpleSettingCard(
          icon: Icons.auto_awesome,
          title: '对话',
          subtitle: '设置与资源',
          onTap: () {},
        ),
        const SizedBox(height: 8),
        IntermediateSettingCard(
          icon: Icons.auto_stories,
          title: '故事',
          subtitle: '阅读偏好',
          onTap: () {},
        ),
        const SizedBox(height: 16),
        const SimpleMarkdownBody(
          data: '## 会话\n这是一段 **强调** [链接](https://example.com)。\n\n> 安静的引用块。',
        ),
        const SizedBox(height: 8),
        const IntermediateMarkdownBody(
          data: '叙事侧：**故事**文本与 *斜体* —— 检查可读性。',
          isUser: true,
        ),
        const SizedBox(height: 16),
        // ── 聚焦态（：聚焦环+辉光随本族 accent）─────────────────
        // 放在内容上部保证整件入镜；显式 requestFocus（autofocus 在
        // 夹具多组件树里不可靠——浅色档实测未聚焦，环/辉光缺失）。
        const _FocusedGlassRow(),
        const SizedBox(height: 16),
        const TextField(decoration: InputDecoration(hintText: '写点什么')),
        const SizedBox(height: 16),
        // ── 单选选项行（：选中行底色 + 行内左置指示）────────────
        Container(
          decoration: BoxDecoration(
            color: context.lm.palette.surfaceVariant,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Column(
            children: [
              SimpleSelectionOption(
                label: '选项行 · 已选中',
                isSelected: true,
                onTap: _noopTap,
              ),
              SimpleSelectionOption(
                label: '选项行 · 未选中',
                isSelected: false,
                onTap: _noopTap,
              ),
              SimpleSelectionOption(
                label: '选项行 · 禁用',
                isSelected: false,
                isEnabled: false,
                onTap: _noopTap,
                disabledLabel: '(v0.2)',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          children: <Widget>[
            ElevatedButton(onPressed: () {}, child: const Text('继续')),
            OutlinedButton(onPressed: () {}, child: const Text('详情')),
            TextButton(onPressed: () {}, child: const Text('取消')),
            const ElevatedButton(onPressed: null, child: Text('不可用')),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          children: <Widget>[
            const Chip(label: Text('未选中')),
            Chip(
              label: const Text('已选中'),
              onDeleted: () {},
              backgroundColor: theme.colorScheme.secondaryContainer,
            ),
          ],
        ),
        const SizedBox(height: 16),
        // ── 加载态 / 空态 ──────────────────────────────────────────
        const Row(
          children: <Widget>[
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('加载中'),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '空态：暂无会话',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        const Divider(),
        const LinearProgressIndicator(value: 0.4),
        const Divider(),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: ElevatedButton(
                key: const ValueKey('open_dialog'),
                onPressed: () => showLmDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(
                    title: Text('对话框'),
                    content: Text('弹窗底色与边框是否可见？'),
                  ),
                ),
                child: const Text('开弹窗'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                key: const ValueKey('open_sheet'),
                onPressed: () => showLmSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 180,
                    child: Center(child: Text('底部浮层')),
                  ),
                ),
                child: const Text('开浮层'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── ：交互五态矩阵（玻璃工厂 / 经典对应件）────────────────────────
//
// 为什么需要它：五态是「结构性」属性，单看某一张页面截图看不出全貌；
// 把「组件 × 状态」铺成一屏，四组合 × 明暗各一张，肉眼逐格评审。
//
// 状态如何被「逼出来」（真实交互，不做假样式）：
// - 静息    ：默认参数；
// - 悬停    ：多个鼠标指针同时停在各悬停格（多指并存，各自独立）；
// - 按压    ：多个触摸指针同时按在各按压格（不松手，按下即态）；
// - 禁用    ：`enabled:false` / `onPressed:null`（真禁用，非 Opacity 假装）；
// - 载入    ：药丸 `loading:true`（其余工厂无载入态语义，标 `—`）；
// - 焦点    ：primary focus 全局唯一，故焦点态不铺成一行，改为底部
//             「焦点条」给出被聚焦的样本；`_input` 变体再单独出输入件聚焦。
//
// 另出 `..._states_input.png`：同一矩阵、焦点改落在输入件（焦点唯一性所限，
// 两次快门各取一个焦点样本）。

const List<String> _mxComponents = <String>[
  'pill',
  'ghost',
  'chip',
  'card',
  'input',
  'row',
];
const List<String> _mxStates = <String>[
  'rest',
  'hover',
  'press',
  'disabled',
  'loading',
];
const Map<String, String> _mxComponentLabel = <String, String>{
  'pill': '药丸',
  'ghost': '幽灵',
  'chip': '标签',
  'card': '卡片',
  'input': '输入',
  'row': '列表行',
};
const Map<String, String> _mxStateLabel = <String, String>{
  'rest': '静息',
  'hover': '悬停',
  'press': '按压',
  'disabled': '禁用',
  'loading': '载入',
};

Future<void> _shootStates(
  WidgetTester tester,
  GlobalKey<_StateMatrixRootState> matrixKey, {
  required String structureId,
  required String paletteId,
  required Brightness brightness,
}) async {
  // 键盘焦点环要在「非触摸推断」下才亮（见  守卫②同一坑）。
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  final release = await _driveStateGestures(tester);

  matrixKey.currentState?.focusPrimary();
  await _settle(tester);

  final name = '${structureId}_$paletteId'
      '__${brightness.name}'
      '__states';
  await _writeShot(tester, name);
  _log('wrote $name');

  matrixKey.currentState?.focusInput();
  await _settle(tester);
  await _writeShot(tester, '${name}_input');
  _log('wrote ${name}_input');

  await release();
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
}

/// 逼出悬停 / 按压态；返回释放闭包（截图后再松手，避免结束时留下活跃指针）。
///
/// 悬停为何自造事件：`TestPointer` 对 `PointerDeviceKind.mouse`
/// **恒把 device 置 1**（见 flutter_test/src/test_pointer.dart 构造器），
/// 于是多个 `tester.createGesture(kind: mouse)` 会共用同一 device，
/// 第二个 `addPointer` 即为「Added 接 Added」→ 撞 MouseTracker 的
/// Added/Removed 配对断言。这里改为手工派发、各给独立 device id。
Future<Future<void> Function()> _driveStateGestures(
  WidgetTester tester,
) async {
  final hoverDevices = <int>[];
  for (final component in _mxComponents) {
    final finder = find.byKey(ValueKey<String>('hover-$component'));
    if (finder.evaluate().isEmpty) continue;
    final center = tester.getCenter(finder);
    final device = 900 + hoverDevices.length;
    hoverDevices.add(device);
    await tester.sendEventToBinding(
      PointerAddedEvent(
        device: device,
        kind: PointerDeviceKind.mouse,
        position: center,
      ),
    );
    await tester.sendEventToBinding(
      PointerHoverEvent(
        device: device,
        kind: PointerDeviceKind.mouse,
        position: center,
      ),
    );
  }
  await tester.pump();

  final presses = <TestGesture>[];
  for (final component in _mxComponents) {
    final finder = find.byKey(ValueKey<String>('press-$component'));
    if (finder.evaluate().isEmpty) continue;
    presses.add(await tester.startGesture(tester.getCenter(finder)));
  }
  await tester.pump();

  return () async {
    for (final gesture in presses) {
      await gesture.up();
    }
    for (final device in hoverDevices) {
      await tester.sendEventToBinding(PointerRemovedEvent(device: device));
    }
  };
}

class _StateMatrixRoot extends StatefulWidget {
  const _StateMatrixRoot({required this.glass, super.key});

  /// true = 琉璃工厂；false = 经典对应件（Material / Simple* 系列）。
  final bool glass;

  @override
  State<_StateMatrixRoot> createState() => _StateMatrixRootState();
}

class _StateMatrixRootState extends State<_StateMatrixRoot> {
  final FocusNode _focusPrimary = FocusNode(debugLabel: 't06-mx-primary');
  final FocusNode _focusInput = FocusNode(debugLabel: 't06-mx-input');

  void focusPrimary() {
    if (mounted) _focusPrimary.requestFocus();
  }

  void focusInput() {
    if (mounted) _focusInput.requestFocus();
  }

  @override
  void dispose() {
    _focusPrimary.dispose();
    _focusInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: context.scaffoldBgOf(theme.scaffoldBackgroundColor),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${widget.glass ? '琉璃工厂' : '经典对应件'} · 交互五态矩阵',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(
              '静息 / 悬停 / 按压 / 禁用 / 载入（悬停与按压为真实指针驱动）；焦点态见底部条',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            _matrix(theme),
            const SizedBox(height: 14),
            Text(
              '焦点态 focus-visible（环 + 辉光取本族 accent · 线宽 2）',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                if (widget.glass)
                  GlassPillButton(
                    key: const ValueKey<String>('focus-primary'),
                    label: '聚焦药丸',
                    onPressed: () {},
                    focusNode: _focusPrimary,
                  )
                else
                  FilledButton(
                    key: const ValueKey<String>('focus-primary'),
                    onPressed: () {},
                    focusNode: _focusPrimary,
                    child: const Text('聚焦按钮'),
                  ),
                const SizedBox(width: 28),
                if (widget.glass)
                  SizedBox(
                    width: 220,
                    child: GlassInput(
                      key: const ValueKey<String>('focus-input'),
                      focusNode: _focusInput,
                      child: const Text('输入'),
                    ),
                  )
                else
                  SizedBox(
                    width: 220,
                    child: TextField(
                      key: const ValueKey<String>('focus-input'),
                      focusNode: _focusInput,
                      decoration: const InputDecoration(hintText: '输入'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _matrix(ThemeData theme) {
    return Table(
      // 组件列等宽：列宽由「最宽单元格」决定时，Material 侧的 FilledButton
      // 会被挤到 label 截断（实测经典侧药丸只剩一个方块），等宽铺开更稳。
      columnWidths: <int, TableColumnWidth>{
        0: const FixedColumnWidth(52),
        for (var i = 1; i <= _mxComponents.length; i++)
          i: const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: theme.dividerColor, width: 0.6),
      children: <TableRow>[
        TableRow(
          children: <Widget>[
            _header('状态', theme),
            ..._mxComponents.map((c) => _header(_mxComponentLabel[c]!, theme)),
          ],
        ),
        ..._mxStates.map(
          (state) => TableRow(
            children: <Widget>[
              _header(_mxStateLabel[state]!, theme),
              ..._mxComponents.map(
                (component) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  child: Center(child: _cell(component, state, theme)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(String text, ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium,
        ),
      );

  Widget _cell(String component, String state, ThemeData theme) {
    final disabled = state == 'disabled';
    final loading = state == 'loading';
    final key = ValueKey<String>('$state-$component');

    // 载入态只有药丸有语义，其余标 —（不假装）。
    if (loading && component != 'pill') {
      return Text('—', style: theme.textTheme.bodySmall);
    }

    if (widget.glass) {
      switch (component) {
        case 'pill':
          return GlassPillButton(
            key: key,
            label: '确认',
            onPressed: disabled ? null : () {},
            loading: loading,
          );
        case 'ghost':
          return GlassPillButton(
            key: key,
            label: '取消',
            variant: GlassPillVariant.ghost,
            onPressed: disabled ? null : () {},
          );
        case 'chip':
          return GlassChip(
            key: key,
            label: '标签',
            onTap: () {},
            enabled: !disabled,
          );
        case 'card':
          return GlassCard(
            key: key,
            onTap: () {},
            enabled: !disabled,
            child: const Text('卡片'),
          );
        case 'input':
          // 不放真 TextField：指针按住会触发长按放大镜、聚焦下划线等
          // 「文本编辑」行为，污染状态截图本身。 评审的是容器状态
          // （填充/描边/焦点环），静态文本即可等价呈现。
          return SizedBox(
            width: 132,
            child: GlassInput(
              key: key,
              enabled: !disabled,
              child: const Text('输入'),
            ),
          );
        case 'row':
        default:
          return GlassListRow(
            key: key,
            onTap: () {},
            enabled: !disabled,
            child: const Text('列表行'),
          );
      }
    }

    switch (component) {
      case 'pill':
        return FilledButton(
          key: key,
          onPressed: disabled ? null : () {},
          child: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认'),
        );
      case 'ghost':
        return OutlinedButton(
          key: key,
          onPressed: disabled ? null : () {},
          child: const Text('取消'),
        );
      case 'chip':
        return FilterChip(
          key: key,
          label: const Text('标签'),
          onSelected: disabled ? null : (_) {},
        );
      case 'card':
        return Card(
          key: key,
          margin: EdgeInsets.zero,
          child: ListTile(
            dense: true,
            title: const Text('卡片'),
            onTap: disabled ? null : () {},
          ),
        );
      case 'input':
        // 经典输入件用 InputDecorator（输入框外壳本体），非可编辑控件：
        // 与琉璃侧同理，避免文本编辑行为污染状态截图。
        return SizedBox(
          width: 132,
          child: InputDecorator(
            key: key,
            decoration: InputDecoration(
              hintText: '输入',
              isDense: true,
              enabled: !disabled,
              border: const OutlineInputBorder(),
            ),
            child: const Text(' '),
          ),
        );
      case 'row':
      default:
        return SimpleSelectionOption(
          key: key,
          label: '列表行',
          isSelected: false,
          isEnabled: !disabled,
          onTap: _noopTap,
        );
    }
  }
}
