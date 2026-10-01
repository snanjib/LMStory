/// 供应商 ID → models.dev provider ID 映射
///
/// 对标 ChatBox 的 `provider-mapping.ts`。我们的内置供应商有固定 presetId
/// （`builtin-openai` 等），自定义供应商通过 baseUrl 域名匹配。
class ProviderMapping {
  ProviderMapping._();

  /// 内置 presetId → models.dev providerId
  static const Map<String, String> builtinMapping = {
    'builtin-openai': 'openai',
    'builtin-deepseek': 'deepseek',
    'builtin-openrouter': 'openrouter',
    'builtin-anthropic': 'anthropic',
    'builtin-gemini': 'google',
    'builtin-qwen': 'alibaba',
    'builtin-zhipu': 'zhipuai',
  };

  /// baseUrl 域名 → models.dev providerId（用于自定义供应商匹配）
  static const Map<String, String> domainMapping = {
    'api.openai.com': 'openai',
    'api.deepseek.com': 'deepseek',
    'openrouter.ai': 'openrouter',
    'api.anthropic.com': 'anthropic',
    'generativelanguage.googleapis.com': 'google',
    'dashscope.aliyuncs.com': 'alibaba',
    'open.bigmodel.cn': 'zhipuai',
  };

  /// 根据 presetId 和 baseUrl 解析 models.dev providerId
  ///
  /// 优先匹配内置 presetId；否则用 baseUrl 域名匹配。返回 null 表示无映射
  /// （该供应商不享受 models.dev 富化）。
  static String? resolve({required String presetId, required String baseUrl}) {
    if (builtinMapping.containsKey(presetId)) {
      return builtinMapping[presetId]!;
    }
    final domain = _extractDomain(baseUrl);
    if (domain != null && domainMapping.containsKey(domain)) {
      return domainMapping[domain]!;
    }
    return null;
  }

  /// 从 baseUrl 提取域名（小写，去掉协议和端口）
  static String? _extractDomain(String baseUrl) {
    var url = baseUrl.trim().toLowerCase();
    if (url.isEmpty) return null;
    // 去掉协议
    if (url.startsWith('https://')) {
      url = url.substring(8);
    } else if (url.startsWith('http://')) {
      url = url.substring(7);
    }
    // 去掉路径和端口
    final slashIndex = url.indexOf('/');
    if (slashIndex != -1) {
      url = url.substring(0, slashIndex);
    }
    final colonIndex = url.indexOf(':');
    if (colonIndex != -1) {
      url = url.substring(0, colonIndex);
    }
    return url.isEmpty ? null : url;
  }
}
