import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';

/// 剧情节奏轮指令（surface 尾部每轮注入；设计文档 §5.4）。
///
/// 措辞硬约束（设计文档 §3，修改前必读）：
/// 1. 零题材名词——尾部指令每轮重复注入，具体题材词（枪/酒馆等）会反复
///    污染当轮生成（示例泄漏/priming，§3-③）；
/// 2. 零否定祈使句式——粉红大象效应（§3-②），规则正向化；
/// 3. 每档给正向的、动作化的收束动作——对冲训练分布的叙事惯性（§3-④）。
/// agent_pacing_test 对 1/2 有断言，违例会测试失败。
///
/// （尾部指令保缓存）：公共头追加 [kPriorityObedienceClause]——位置无关
/// 的服从强化，补偿协议实现把 system 上提到顶部后的位置损失（轮尾内容
///  起走 user 通道不上提，此句为双保险；见设计文档 §5.5 协议差异声明）。
///
/// 篇幅策略：仅激进档要求正文写满
/// 写足；保守/平衡档篇幅随叙事节奏自定，只要求把要表达的内容交代完整。
/// 两式头部均守上述硬约束（零题材名词、零否定祈使句式）。
const String _kPacingHeaderAggressive = '【节奏指令·本轮】正文照常写满写足；'
    '本指令规定叙事的景别——覆盖多大一段故事时间，以及可以替主角做出哪些'
    '决定。$kPriorityObedienceClause';

const String _kPacingHeaderAdaptive = '【节奏指令·本轮】正文以把当轮要表达的内容'
    '交代完整为准，篇幅随叙事节奏自然伸缩；本指令规定叙事的景别——覆盖多大'
    '一段故事时间，以及可以替主角做出哪些决定。$kPriorityObedienceClause';

const String _kPacingConservative = '主角的行动只执行用户输入中已声明的部分，'
    '把它写实写透；世界的反应可以有力、可以不利，但只作为对已发生之事的回应。'
    '正文以未决的事态收束，把下一步的选择交还给主角。'
    '没有选择余地的衔接动作可以代写，一笔带过。';

const String _kPacingBalanced = '用户输入中强暗示的直接延续，可以替主角执行完毕'
    '并交代结果。判据：用户读完自己写下的输入后会自然预期的下一步，在许可范围'
    '内；需要权衡取舍后才能定的新选择，留给用户。世界侧的发展保持在当前惯性'
    '之内，承接已有事件线自然延续。';

const String _kPacingAggressive = '可以引入用户输入之外的进展：新事件、意外、'
    '转折，世界的主动性放开；一切进展必须承接已确立的事实、人设与因果。';

/// 发言口径尾句：档位细则的简写许可（保守档「一笔带过」、平衡档「执行完毕
/// 并交代结果」）会被泛化到角色开口的应答上，产出「嗯/可以」式敷衍短发言。
/// 本句三档统一拼接在档位细则之后、收束整条指令（recency 最优位，紧跟
/// 简写许可形成顺序消歧）。措辞同守 §3 三条硬约束，另守两条纪律：
/// 1. 来源参照次序用三源链式（用户近期输入 > 上下文正文 > 子代理与工具
///    带回的信息），作用域覆盖发言的内容与口吻全体——拆开只约束一部分
///    或写成一主一次都会让模型在其余部分回退到旧惯性；
/// 2. 发言落笔不带量词口径（写满/写实写透/完整类）——量词会诱发把应答
///    撑满，与简写许可同病。
const String _kSpeechClause = '替角色写发言——尤其替主角补写用户输入点到、'
    '原话留白的应答——贴着当下场景、双方关系与他此刻的处境与心情，写出贴合'
    '其身份、像他亲口说出的发言；写什么、怎么说，参照次序：用户近期输入、'
    '上下文正文、子代理与工具带回的信息，越靠前越作准。';

/// 三档指令全文（档位头部 + 档位细则 + 发言口径尾句；抽成函数便于测试与
/// 复用）。头部按篇幅策略分两式：激进=写满写足，保守/平衡=篇幅自定。
String pacingDirectiveFor(NarrativePacing tier) => switch (tier) {
      NarrativePacing.conservative =>
        '$_kPacingHeaderAdaptive$_kPacingConservative$_kSpeechClause',
      NarrativePacing.balanced =>
        '$_kPacingHeaderAdaptive$_kPacingBalanced$_kSpeechClause',
      NarrativePacing.aggressive =>
        '$_kPacingHeaderAggressive$_kPacingAggressive$_kSpeechClause',
    };

/// 轮 surface 尾部指令消息（设计文档 §5.5 + 长会话退化治理）：
/// turn1 开篇角色/能力提示在前，工作契约/文风铁律每轮注入，节奏指令收尾
/// （recency 最优位）。节奏指令每轮注入且只放尾部——档位可中途换，
/// 冻结前缀必须保持档位无关以保前缀缓存（设计文档 §4.2/§6.1）。
///
///  角色约定：全部为 role=user 合成消息，内容以 workbench-reminder
/// 标记包裹（见 [wrapWorkbenchReminder]）——绕开 Anthropic 适配器把
/// system 上提到顶层字段架空 recency 位的问题（R6），适配器不改。
///
/// [characterInitHint] = turn1 开篇角色一次性提示（向导「初始化你的角色」
/// 自由描述路径，runner 用 firstTurnCharacterInitHint 预构建；
/// null = 未启用，整条省略）。
/// [maintenanceGapLine] = 轻量维护缺口提示（由 runner 用
/// maintenanceGapReminderText 预构建；大周期轮不注入）。
/// [isMajorReviewRound] = 本轮是否进入大周期双任务接力（true 时抑制小提示，
/// 并在工作契约内温和告知交付正文后进入周期审查与维护）。
/// [foreshadowSweepLine] = 兼容旧调用点的伏笔清点行。
List<AgentMessage> surfaceTailMessages({
  required NarrativePacing pacing,
  required bool isFirstTurn,
  required Set<String> toolNames,
  bool importedDataPresent = false,
  String? characterInitHint,
  String? maintenanceGapLine,
  bool isMajorReviewRound = false,
  String? foreshadowSweepLine,
}) {
  final hint = firstTurnCapabilityHint(toolNames);
  final effectiveGapLine =
      isMajorReviewRound ? null : (maintenanceGapLine ?? foreshadowSweepLine);
  return [
    // 开篇角色一次性提示（turn1 且启用才有；内容性指令置首）
    if (isFirstTurn && characterInitHint != null)
      AgentMessage.user(wrapWorkbenchReminder(characterInitHint)),
    //  deny 感知：spawn 未注册时能力提示整条省略（不空许诺）
    if (isFirstTurn && hint != null)
      AgentMessage.user(wrapWorkbenchReminder(hint)),
    AgentMessage.user(
      wrapWorkbenchReminder(
        workbenchContractText(
          toolNames,
          isMajorReviewRound: isMajorReviewRound,
        ),
      ),
    ),
    // 维护缺口提示（非大周期轮且触发时才有；紧随工作契约，任务簿记类相邻）
    if (effectiveGapLine != null)
      AgentMessage.user(wrapWorkbenchReminder(effectiveGapLine)),
    AgentMessage.user(wrapWorkbenchReminder(kStyleIronRuleLine)),
    AgentMessage.user(wrapWorkbenchReminder(pacingDirectiveFor(pacing))),
    // 世界状态含导入资料时的尾部边界重申（recency 位补偿）
    if (importedDataPresent)
      AgentMessage.user(wrapWorkbenchReminder(kDataBoundaryReassert)),
  ];
}
