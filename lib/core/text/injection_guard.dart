///  注入面加固（spotlighting）：不可信内容的统一包裹标签与消毒器。
///
/// 威胁模型：世界书/角色卡是活跃注入载体（SillyTavern 生态），其字段
/// 值经 coreBlocks/query_facts 裸拼进模型上下文；内容里若携带 harness
/// 专用标签（workbench-reminder / round-work / 导入资料），可越权伪装
/// 成工作台指令或逃逸资料包裹。
///
/// 本文件是**单一事实源**：包裹开/闭标签常量与消毒剥离规则同源，
/// 契约测试（injection_guard_test）锁定「消毒器必剥离包裹标签」。
library;

/// 导入资料块的开标签（值本体的承载容器，向模型声明「这是数据」）
const String kImportedDataOpen = '〈导入资料〉';

/// 导入资料块的闭标签
const String kImportedDataClose = '〈/导入资料〉';

/// 把消毒后的不可信内容包成导入资料块
String wrapImportedData(String content) =>
    '$kImportedDataOpen$content$kImportedDataClose';

/// harness 专用标签名（消毒剥离对象；导入内容携带这些标签即为伪装攻击）
const List<String> _sentinelTagNames = [
  '导入资料',
  'workbench-reminder',
  'round-work',
];

final RegExp _sentinelTagPattern = RegExp(
  '〈\\s*/?\\s*(?:${_sentinelTagNames.join('|')})[^〉]*〉',
);

/// 零宽字符与格式控制符（词 joiner/bidi 控制等，用于隐藏指令或扰动匹配）
final RegExp _invisibleCharsPattern = RegExp(
  '[\u200b\u200c\u200d\u2060\u2061-\u2064\ufeff\u202a-\u202e]',
);

/// 控制字符（除 \n \t；来源包括粘贴富文本残留的 \u0000-\u001f）
final RegExp _controlCharsPattern =
    RegExp('[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]');

/// 截断提示后缀（超长字段截断后追加，向模型如实标注数据不完整）
const String kTruncatedSuffix = '…（超长截断）';

/// 消毒不可信文本（导入/注入前清洗）：
///
/// 1. 去除零宽字符与 bidi 控制符（先于标签剥离——零宽字符拆写标签是
///    常见逃逸手法）
/// 2. 去除控制字符（保留换行与制表）
/// 3. 剥离 harness 专用包裹标签（防伪装指令与逃逸资料包裹）
/// 4. 超长截断（[maxLength]，含 [kTruncatedSuffix] 提示）
String sanitizeUntrusted(String input, {int maxLength = 2000}) {
  var text = input.replaceAll(_invisibleCharsPattern, '');
  text = text.replaceAll(_controlCharsPattern, '');
  text = text.replaceAll(_sentinelTagPattern, '');

  final truncationCut = maxLength - kTruncatedSuffix.length;
  if (text.length > maxLength) {
    text = text.substring(0, truncationCut < 0 ? 0 : truncationCut) +
        kTruncatedSuffix;
  }
  return text;
}
