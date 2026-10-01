import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/domain/services/character_card_parser.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';

/// 资源应用服务（DOC-15 §9.3 导入/应用流程编排）
///
/// 串联「读资源表 → 解析 rawJson → 投影到会话事实层」三步，供 UI 入口调用。
class ResourceApplyService {
  ResourceApplyService({
    required ResourceLibraryRepository resourceRepository,
    required ResourceProjectionService projectionService,
  })  : _resourceRepository = resourceRepository,
        _projectionService = projectionService;

  final ResourceLibraryRepository _resourceRepository;
  final ResourceProjectionService _projectionService;

  /// 批 J-b：应用前预览——解析但**不投影**，让用户
  /// 在确认前知道这个资源会带来什么。世界书列词条标题样例（含常驻数）；
  /// 角色卡列将写入的关键字段样例。
  ///
  /// 预览口径对齐真实投影——enabled=false 的词条
  /// 投影时被跳过（resource_projection_service），因此也不进样例行与
  /// 常驻计数，保证「预览说的 = 实际投的」。
  Future<SeedApplyPreview> previewCharacterCard({
    required String cardId,
  }) async {
    final card = await _resourceRepository.getCharacterCard(cardId);
    if (card == null) {
      throw ModelNotFoundException(cardId);
    }
    final parsed = CharacterCardParser.parse(card.rawJson);
    final activeEntries =
        parsed.embeddedEntries.where((e) => e.enabled).toList();
    final lines = <SeedApplyPreviewLine>[
      if (parsed.description.trim().isNotEmpty)
        SeedApplyPreviewLine(
          SeedPreviewLineKind.cardBackground,
          text: _truncate(parsed.description, 60),
        ),
      if (parsed.personality.trim().isNotEmpty)
        SeedApplyPreviewLine(
          SeedPreviewLineKind.cardPersonality,
          text: _truncate(parsed.personality, 60),
        ),
      // 域层只产出语义键 + 数据，用户可见文案由 presentation
      // 按 slang 映射（「domain 不拼接用户文案」）
      for (final e in activeEntries.take(3))
        SeedApplyPreviewLine(
          SeedPreviewLineKind.cardEmbeddedEntry,
          text:
              _truncate(e.comment.isEmpty ? e.keys.join(', ') : e.comment, 40),
        ),
      // 对齐 previewWorldbook 的截断
      // 尾行——卡内嵌词条 >3 时此前静默省略，用户无从知道还有多少
      if (activeEntries.length > 3)
        SeedApplyPreviewLine(
          SeedPreviewLineKind.moreCount,
          count: activeEntries.length,
        ),
    ];
    return SeedApplyPreview(
      // 空名兜底与投影侧一致（resource_projection_service
      // 「未命名角色」），预览不再出现空白标题
      title: parsed.name.trim().isNotEmpty ? parsed.name : '未命名角色',
      lines: lines,
      constantCount: activeEntries.where((e) => e.constant).length,
      // （只读语义 2.0）：启用内置词条总数——预览弹窗「注入方式」段的
      // 按关键词触发条数 = enabledEntryCount - constantCount（同源口径）
      enabledEntryCount: activeEntries.length,
    );
  }

  Future<SeedApplyPreview> previewWorldbook({required String bookId}) async {
    final book = await _resourceRepository.getWorldbook(bookId);
    if (book == null) {
      throw ModelNotFoundException(bookId);
    }
    // 先剔除停用词条再取样/计数，与投影的 `if (!entry.enabled) continue`
    // 同口径——常驻计数不再把停用词条计入
    final entries =
        WorldbookParser.parse(book.rawJson).where((e) => e.enabled).toList();
    final lines = <SeedApplyPreviewLine>[
      for (final e in entries.take(6))
        SeedApplyPreviewLine(
          SeedPreviewLineKind.worldbookEntry,
          text: e.comment.isNotEmpty ? e.comment : e.keys.join(', '),
          isConstant: e.constant,
        ),
      if (entries.length > 6)
        SeedApplyPreviewLine(
          SeedPreviewLineKind.moreCount,
          count: entries.length,
        ),
    ];
    return SeedApplyPreview(
      title: book.name,
      lines: lines,
      constantCount: entries.where((e) => e.constant).length,
      // 启用词条总数（与 constantCount 同口径剔除停用行）
      enabledEntryCount: entries.length,
    );
  }

  /// 按 Unicode 码点（runes）截断——`substring`
  /// 按 UTF-16 码元切割会把 emoji 等代理对截成半个字符（孤立代理项）。
  /// 行为保持「超长才截 + 尾缀省略号」。
  static String _truncate(String text, int max) {
    final runes = text.runes;
    if (runes.length <= max) return text;
    return '${String.fromCharCodes(runes.take(max))}…';
  }

  /// 应用角色卡到会话（读 + 解析 + 投影）。返回投影实体数。
  Future<int> applyCharacterCard({
    required String sessionId,
    required String cardId,
  }) async {
    final card = await _resourceRepository.getCharacterCard(cardId);
    if (card == null) {
      throw ModelNotFoundException(cardId);
    }
    final parsed = CharacterCardParser.parse(card.rawJson);
    return _projectionService.applyCharacterCard(
      sessionId: sessionId,
      cardId: cardId,
      card: parsed,
    );
  }

  /// 应用世界书到会话（读 + 解析 + 投影）。返回投影实体数。
  Future<int> applyWorldbook({
    required String sessionId,
    required String bookId,
  }) async {
    final book = await _resourceRepository.getWorldbook(bookId);
    if (book == null) {
      throw ModelNotFoundException(bookId);
    }
    final entries = WorldbookParser.parse(book.rawJson);
    return _projectionService.applyWorldbook(
      sessionId: sessionId,
      bookId: bookId,
      entries: entries,
    );
  }

  /// 取消应用：按投影来源成组移除种子实体（F1 修复 2026-08-23）。
  /// 返回删除的实体数；0 = 该来源在会话内无实体。
  Future<int> unapplyResource({
    required String sessionId,
    required String sourceRef,
  }) {
    return _projectionService.unapply(
      sessionId: sessionId,
      sourceRef: sourceRef,
    );
  }
}

/// 预览样例行类型（：域层仅产出语义键，用户可见文案由
/// presentation 按 slang 映射，见 seed_resource_section 的行渲染）
enum SeedPreviewLineKind {
  /// 角色卡背景（description → attrKey background）样例行
  cardBackground,

  /// 角色卡性格（personality → attrKey personality）样例行
  cardPersonality,

  /// 角色卡内置世界书词条样例行
  cardEmbeddedEntry,

  /// 世界书词条样例行（[SeedApplyPreviewLine.isConstant] 标记常驻）
  worldbookEntry,

  /// 样例截断尾行（[SeedApplyPreviewLine.count] 携带启用词条总数）
  moreCount,
}

/// 单条预览样例行（语义键 + 数据，不含任何用户可见文案）
class SeedApplyPreviewLine {
  const SeedApplyPreviewLine(
    this.kind, {
    this.text = '',
    this.count,
    this.isConstant = false,
  });

  /// 行类型（presentation 据此映射文案）
  final SeedPreviewLineKind kind;

  /// 样例文本（词条名/字段内容，域层已截断）
  final String text;

  /// [SeedPreviewLineKind.moreCount] 行的启用词条总数
  final int? count;

  /// 世界书词条是否常驻（constant，每轮必进上下文）
  final bool isConstant;
}

/// 批 J-b：应用前预览数据（解析产物，未投影）
class SeedApplyPreview {
  const SeedApplyPreview({
    required this.title,
    required this.lines,
    required this.constantCount,
    this.enabledEntryCount,
  });

  /// 资源主名（角色名/书名）
  final String title;

  /// 将写入内容的样例行（最多 6 行 + 截断尾行）
  final List<SeedApplyPreviewLine> lines;

  /// 启用词条中的常驻（constant）条数——「每轮必进上下文」的量级提示
  /// （：停用词条不计入，与真实投影同口径）
  final int constantCount;

  /// 启用词条总数（只读语义 2.0）：卡路径 = 内置词条启用数，
  /// 书路径 = 词条启用数。与 [constantCount] 同源口径（剔除停用行）；
  /// 「按关键词触发」条数 = enabledEntryCount - constantCount。
  /// 可空为兼容旧构造调用；两条预览路径均会填充。
  final int? enabledEntryCount;
}
