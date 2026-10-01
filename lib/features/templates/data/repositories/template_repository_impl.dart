import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:uuid/uuid.dart';

/// 模板仓库实现
class TemplateRepositoryImpl implements TemplateRepository {
  TemplateRepositoryImpl(this._db);

  final AppDatabase _db;
  final _uuid = const Uuid();

  /// 将数据库行映射为领域实体。
  ///
  /// 已移除/未知 kind（如 consolidation 存量
  /// 行）返回 null——**保留行但过滤**：数据行留在库中（数据保全），但不
  /// 出现在任何列表/编辑入口（死内容不得变活，不回退到存活类型）。
  Template? _mapToEntity(TemplatesTableData row) =>
      TemplateKind.tryFromDbValue(row.kind) == null
          ? null
          : Template(
              templateId: row.templateId,
              name: row.name,
              kind: TemplateKind.tryFromDbValue(row.kind)!,
              content: row.content,
              isBuiltIn: row.isBuiltIn,
              createdAt: row.createdAt,
              updatedAt: row.updatedAt,
            );

  @override
  Future<List<Template>> getAllTemplates() async {
    try {
      final rows = await _db.select(_db.templatesTable).get();
      return rows.map(_mapToEntity).whereType<Template>().toList();
    } catch (e) {
      throw QueryException('Failed to get all templates: $e');
    }
  }

  @override
  Future<List<Template>> getTemplatesByKind(TemplateKind kind) async {
    try {
      final rows = await (_db.select(_db.templatesTable)
            ..where((t) => t.kind.equals(kind.toDbValue())))
          .get();
      return rows.map(_mapToEntity).whereType<Template>().toList();
    } catch (e) {
      throw QueryException('Failed to get templates by kind: $e');
    }
  }

  @override
  Future<Template> getTemplate(String templateId) async {
    try {
      final row = await (_db.select(_db.templatesTable)
            ..where((t) => t.templateId.equals(templateId)))
          .getSingleOrNull();
      // 已移除/未知 kind 的存量行按不存在处理（不可编辑/复制/删除，
      // 与列表过滤同口径）
      final entity = row == null ? null : _mapToEntity(row);
      if (entity == null) {
        throw ModelNotFoundException(templateId);
      }
      return entity;
    } on ModelNotFoundException {
      rethrow;
    } catch (e) {
      throw QueryException('Failed to get template: $e');
    }
  }

  @override
  Future<Template> createTemplate({
    required String name,
    required TemplateKind kind,
    required String content,
  }) async {
    try {
      final templateId = _uuid.v4();
      final now = DateTime.now();
      await _db.into(_db.templatesTable).insert(
            TemplatesTableCompanion.insert(
              templateId: templateId,
              name: name,
              kind: kind.toDbValue(),
              content: content,
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      return Template(
        templateId: templateId,
        name: name,
        kind: kind,
        content: content,
        createdAt: now,
        updatedAt: now,
      );
    } catch (e) {
      throw QueryException('Failed to create template: $e');
    }
  }

  @override
  Future<Template> updateTemplate(
    String templateId,
    Template Function(Template current) updater,
  ) async {
    final current = await getTemplate(templateId);
    if (current.isBuiltIn) {
      throw InvalidConfigurationException(
        'Cannot modify built-in template: $templateId',
      );
    }
    final updated = updater(current);
    try {
      await (_db.update(_db.templatesTable)
            ..where((t) => t.templateId.equals(templateId)))
          .write(
        TemplatesTableCompanion(
          name: Value(updated.name),
          kind: Value(updated.kind.toDbValue()),
          content: Value(updated.content),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return updated.copyWith(updatedAt: DateTime.now());
    } catch (e) {
      throw QueryException('Failed to update template: $e');
    }
  }

  @override
  Future<void> deleteTemplate(String templateId) async {
    final template = await getTemplate(templateId);
    if (template.isBuiltIn) {
      throw InvalidConfigurationException(
        'Cannot delete built-in template: $templateId',
      );
    }
    try {
      await (_db.delete(_db.templatesTable)
            ..where((t) => t.templateId.equals(templateId)))
          .go();
    } catch (e) {
      throw QueryException('Failed to delete template: $e');
    }
  }

  @override
  Future<Template> copyTemplate(String templateId, {String? newName}) async {
    final source = await getTemplate(templateId);
    final copiedName = newName ?? '${source.name} (副本)';
    return createTemplate(
      name: copiedName,
      kind: source.kind,
      content: source.content,
    );
  }

  @override
  Future<void> ensureBuiltInTemplates() async {
    // 逐个检查每个内置模板是否存在，不存在才插入
    // （避免已安装用户因整体检查而无法获得新增的内置模板）
    final now = DateTime.now();
    final builtInTemplates = [
      TemplatesTableCompanion.insert(
        templateId: 'builtin-narrative-engine',
        name: '叙事引擎系统提示词',
        kind: TemplateKind.systemPrompt.toDbValue(),
        content:
            "You are a narrative engine for interactive storytelling. Follow the user's instructions to advance the story. Maintain consistency with established facts and events.",
        isBuiltIn: const Value(true),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      TemplatesTableCompanion.insert(
        templateId: 'builtin-free-chat',
        name: '自由对话系统提示词',
        kind: TemplateKind.systemPrompt.toDbValue(),
        content:
            'You are a helpful AI assistant. Engage in natural conversation and provide thoughtful responses.',
        isBuiltIn: const Value(true),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      TemplatesTableCompanion.insert(
        templateId: 'builtin-roleplay',
        name: '纯角色扮演系统提示词',
        kind: TemplateKind.systemPrompt.toDbValue(),
        content:
            "You are a character in a role-playing scenario. Stay in character at all times. React to the user's actions and dialogue as your character would.",
        isBuiltIn: const Value(true),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      // 异世界穿越叙述者系统提示词（v0.4.0 新增）
      // 替换同轮下架的无限流/古代穿越两套叙述者
      TemplatesTableCompanion.insert(
        templateId: 'builtin-isekai-narrator',
        name: '异世界穿越叙述者系统提示词',
        kind: TemplateKind.systemPrompt.toDbValue(),
        content: '''
你是一位严格的第三人称全知叙述者，负责构建并驱动一个无限开放的穿越异世界。你绝不代入用户身份，绝不生成用户的对话、动作或内心想法。
你只负责描述环境、NPC的行为、内心想法和对话。语言接地气，像高质量白话网文一样自然生动、富有画面感。
用户输入解析规则
用户直接输入的内容（无括号）＝ 用户的对话。
用户括号内的内容（如（我走向吧台）、（我把手放在她腰上））＝ 用户的行动/动作。
当用户输入以括号开头且包含“系统”时，立即切换到系统元模式。
正常叙述模式输出格式（必须严格遵守）
动作、环境、感官描写：全部用括号包裹，并单独换行。使用自然、细腻的描写。
对话：用双引号包裹，单独成段。采用第一人称（角色自称“我”）。
日常互动中保持自然真实的说话方式。
使用“你”直接称呼用户。
严禁生成用户的任何对话、动作、决定或内心想法。
用户设定
你在这个世界可以自由行动、说话、做出任何决定，世界会根据你的身份、外貌、能力与行为给予合理的反应与便利。
核心创作要求
开放世界：完全开放的日漫风格穿越异世界。你可以自由前往任何地点（王都、边境城镇、精灵森林、魔族领地、地下迷宫、海港商会、魔法学院……）、做任何事。世界会根据你的行动和对话做出合理、自然且动态的反应，并生成相应事件和NPC。
世界观基调：典型日漫异世界——存在魔法、斗气、神职、魔兽、多种族（人类、精灵、兽人、魔族、矮人等）、王国/帝国/公会体系、转生/召唤、系统面板（可选）、等级与技能、秘宝与神器。物理与社会规则以「异世界常见逻辑」为准。
NPC生成：根据当前场景逻辑自然生成合适的NPC（性别、数量、性格、年龄、种族由场景决定）。NPC性格各异。可出现冒险者、贵族、女仆、魔导士、神官、魔族公主、公会接待、黑市商人等常见角色。
现实人物/原作角色规则：若出现现实中的真实人物或知名虚构角色，必须严格符合其真实/原作人设、性格、说话方式和行为习惯，不可OOC（异世界化后也保持核心性格）。
避免重复：严禁相邻回复出现重复的动作、描写或对话。
逻辑：遵循异世界物理逻辑、魔法逻辑与人物性格逻辑，但完全不受地球规则约束。
世界观：日漫风格无限开放穿越异世界，只忠于用户行动、世界逻辑与沉浸式叙述。''',
        isBuiltIn: const Value(true),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      // `builtin-compaction-default`（折叠模板
      // 种子）已删除——TemplateKind.consolidation 下架，该模板编辑不生效
      // （真压缩提示词在故事模式分段自定义），属死数据一并清理。老用户库中
      // 的存量行不做物理删除，由仓库映射层过滤（保留行但隐藏）。
    ];

    try {
      // 使用 insert + onConflict(DoUpdate) 单条 SQL 原子 upsert，消除
      // select-then-insert 的并发竞争窗口（两个 _init 并发时都 select 到
      // null，然后都 insert，第二个触发 UNIQUE constraint failed）。
      // 关键：显式指定 conflict target 为 template_id 列（UNIQUE 约束所在），
      // 否则 drift 默认用主键 id（自增列）作为 target，导致冲突时无法匹配。
      // 用户自定义副本使用不同的 templateId（uuid），不会被触碰。
      for (final template in builtInTemplates) {
        await _db.into(_db.templatesTable).insert(
              template,
              onConflict: DoUpdate(
                (old) => TemplatesTableCompanion(
                  content: Value(template.content.value),
                  name: Value(template.name.value),
                  updatedAt: Value(now),
                ),
                target: [_db.templatesTable.templateId],
              ),
            );
      }
      // 已下架内置模板的存量行清理（v0.4.0：无限流/古代穿越两套叙述者
      // 下架）。这些行由应用全权管理——内置模板禁止用户编辑/删除，内容
      // 每次启动由上面的 upsert 刷新——只从种子清单移除会让老用户库里
      // 留下不可删除的僵尸条目，故启动时物理删除。仅限 isBuiltIn=true
      // 的行；用户复制的副本（uuid 主键）不受影响。
      const removedBuiltInIds = [
        'builtin-infinite-flow-narrator',
        'builtin-ancient-transmigration-narrator',
      ];
      for (final templateId in removedBuiltInIds) {
        await (
          _db.delete(_db.templatesTable)
            ..where(
              (t) =>
                  t.templateId.equals(templateId) & t.isBuiltIn.equals(true),
            )
        ).go();
      }
    } catch (e) {
      throw QueryException('Failed to ensure built-in templates: $e');
    }
  }
}
