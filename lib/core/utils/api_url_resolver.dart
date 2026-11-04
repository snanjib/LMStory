import 'package:flutter/foundation.dart' show kIsWeb;

/// API URL 智能解析工具
///
/// 对标 ChatBox 的 `normalizeOpenAIApiHostAndPath`（src/shared/utils/llm_utils.ts），
/// 采用"版本号归入 baseUrl + 后缀纯路径"策略：
///
/// 核心原则（与 ChatBox 一致）：
/// 1. **版本号属于 baseUrl，不属于 path**--path 只含端点后缀（/chat/completions、
///    /models、/embeddings），不含 /v1 等版本前缀
/// 2. 如果 baseUrl 末尾没有版本号（/v1、/v3、/v4 等），自动补 /v1（对标 ChatBox
///    第 59-61 行：`!apiHost.endsWith('/v1') && !apiPath` 时自动补 /v1）
/// 3. 如果 baseUrl 已含版本号（如火山引擎 /api/v3），原样保留，不补 /v1
/// 4. 自动补 https:// 协议头
/// 5. 剥离用户误填的完整端点后缀（/chat/completions、/models、/embeddings）
///
/// 这样所有端点（chat/models/embeddings）都基于同一个规范化后的 baseUrl，
/// 避免了"版本号去重"的脆弱正则匹配，同时天然支持 /v1、/v3、/v4 等所有版本号。
///
/// 手动模式（raw 前缀）：
/// 当 baseUrl 以 `raw:` 前缀开头时，去掉前缀后原样返回，不做任何补全。
/// 用于供应商端点完全非标准的情况。注意：raw 模式下所有端点都会用同一个 URL，
/// list models 可能 404，仅适用于用户明确知道自己在做什么的场景。
///
/// Web 平台 CORS 代理（v0.2 dev-0.2-web）：
/// 浏览器环境下，直接调用第三方 API 会触发 CORS 限制。Web 平台时，所有
/// 外部 API 请求通过部署服务器上的 `/api-proxy` 端点转发，规避 CORS。
/// 详见 DOC-02 §6.6.6。
class ApiUrlResolver {
  ApiUrlResolver._();

  /// 手动模式前缀
  static const rawPrefix = 'raw:';

  /// Web 平台 CORS 代理路径前缀
  ///
  /// 服务器端由 `tool/serve_web.py` 的 CORS 代理处理器处理，
  /// 接收格式：`/api-proxy?url=<编码后的完整目标URL>`
  static const webProxyPrefix = '/api-proxy?url=';

  /// 已知端点路径后缀（用于从 baseUrl 中剥离）
  ///
  /// 对标 ChatBox 第 36-39 行：如果 apiHost 以 `/chat/completions` 结尾，
  /// 把它拆出来。LMStory 扩展到 4 个端点。
  static const _endpointSuffixes = <String>[
    '/chat/completions',
    '/responses',
    '/models',
    '/embeddings',
  ];

  /// 版本号检测正则：匹配末尾的 /v1、/v3、/v4 等
  ///
  /// 用于判断 baseUrl 是否已含版本号，决定是否自动补 /v1。
  /// 对标 ChatBox 第 59 行 `!apiHost.endsWith('/v1')` 的检测，
  /// LMStory 扩展为检测任意版本号（/v\d+），支持火山引擎 /api/v3 等场景。
  static final _versionSuffixRegex = RegExp(r'/v\d+$');

  /// 带版本号的 Anthropic Messages 全端点后缀（`/v1/messages`）。
  static final _versionedMessagesSuffixRegex = RegExp(r'/v\d+/messages$');

  /// 解析 API URL
  ///
  /// [baseUrl] 用户配置的 baseUrl（可含版本号，如 /v1、/api/v3）
  /// [path] 要拼接的端点后缀，如 `/chat/completions` 或 `/models`（不含版本号）
  static String resolve(String baseUrl, String path) {
    // 手动模式：原样返回，不做任何补全
    if (baseUrl.startsWith(rawPrefix)) {
      final rawUrl = baseUrl.substring(rawPrefix.length);
      return _wrapWithProxyIfNeeded(rawUrl);
    }

    // 规范化 baseUrl（对标 ChatBox normalizeOpenAIApiHostAndPath）
    final normalized = _normalize(baseUrl);

    // 如果规范化后的 baseUrl 末尾没有版本号，自动补 /v1
    // 对标 ChatBox 第 59-61 行：host 不以 /v1 结尾时自动补 /v1
    // LMStory 扩展：检测任意版本号（/v1、/v3、/v4），已有版本号则不补
    final hasVersion = _versionSuffixRegex.hasMatch(normalized);
    final finalBase = hasVersion ? normalized : '$normalized/v1';

    return _wrapWithProxyIfNeeded('$finalBase$path');
  }

  /// 规范化 baseUrl（对标 ChatBox normalizeOpenAIApiHostAndPath）
  ///
  /// 步骤：
  /// 1. trim 空格
  /// 2. 去掉末尾斜杠
  /// 3. 自动补 https:// 协议头
  /// 4. 去掉端点路径后缀（/chat/completions、/models、/embeddings）
  ///
  /// 保留用户填写的版本号（/v1、/v3 等），由 [resolve] 决定是否自动补 /v1。
  /// 规范化后的 baseUrl 形如：
  /// - `https://api.openai.com`（无版本号，resolve 会补 /v1）
  /// - `https://api.openai.com/v1`（保留 /v1）
  /// - `https://ark.cn-beijing.volces.com/api/v3`（保留 /v3）
  /// - `https://openrouter.ai/api/v1`（保留 /v1）
  static String _normalize(String baseUrl) {
    var clean = baseUrl.trim();

    // 去末尾斜杠（对标 ChatBox 第 23-25 行）
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }

    // 自动补 https:// 协议头（对标 ChatBox 第 30-32 行）
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      clean = 'https://$clean';
    }

    // 去掉端点路径后缀（对标 ChatBox 第 36-39 行，扩展到 3 个端点）
    // 保留版本号：火山引擎 /api/v3/chat/completions -> /api/v3
    for (final endpoint in _endpointSuffixes) {
      if (clean.endsWith(endpoint)) {
        clean = clean.substring(0, clean.length - endpoint.length);
        break;
      }
    }

    // Anthropic 全端点粘贴：仅剥离带版本号的 /vN/messages，保留 /vN；
    // 无版本号的 /messages 可能是自定义路径，交给 raw: 模式处理。
    if (_versionedMessagesSuffixRegex.hasMatch(clean)) {
      clean = clean.substring(0, clean.length - '/messages'.length);
    }

    return clean;
  }

  /// Web 平台时把完整 API URL 包装为通过部署服务器转发的代理 URL
  ///
  /// 代理服务由 `tool/serve_web.py` 提供，路径 `/api-proxy?url=xxx`。
  /// 原生平台（Android/iOS/桌面）不经过代理，直接请求目标 URL。
  ///
  /// 平台检测通过 Flutter foundation 的 web 编译期常量判断，
  /// dart2js 会做 tree-shaking，原生平台编译时此分支被完全移除。
  static String _wrapWithProxyIfNeeded(String targetUrl) {
    if (!kIsWeb) return targetUrl;
    // 只代理 https/http 开头的外部 URL；同源的相对路径不包装
    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
      return targetUrl;
    }
    return '$webProxyPrefix${Uri.encodeComponent(targetUrl)}';
  }

  /// 判断 baseUrl 是否处于手动模式
  static bool isRawMode(String baseUrl) => baseUrl.startsWith(rawPrefix);

  /// 获取用于显示的 baseUrl（去掉 raw: 前缀）
  static String displayName(String baseUrl) {
    if (baseUrl.startsWith(rawPrefix)) {
      return baseUrl.substring(rawPrefix.length);
    }
    return baseUrl;
  }
}
