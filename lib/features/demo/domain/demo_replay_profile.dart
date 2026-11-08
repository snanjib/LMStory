import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 回放能力画像规范与身份定义（契约 §22）。
///
/// 用于在 Demo 数据包中声明回放所需受控能力，并在独立 Demo 作用域内注入。
/// 仅包含已审核的本地白名单策略，绝不暴露或注入 baseUrl、apiKey、请求头或网络端点。
class DemoReplayProfile {
  const DemoReplayProfile({
    required this.id,
    required this.version,
    required this.protocol,
    required this.capabilitiesHash,
  });

  factory DemoReplayProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const DemoPackFormatException('replayProfile.id 必须为非空字符串');
    }
    final version = json['version'];
    if (version is! int) {
      throw const DemoPackFormatException('replayProfile.version 必须为整型');
    }
    final protocol = json['protocol'];
    if (protocol is! String || protocol.isEmpty) {
      throw const DemoPackFormatException('replayProfile.protocol 必须为非空字符串');
    }
    final capabilitiesHash = json['capabilitiesHash'];
    if (capabilitiesHash is! String || capabilitiesHash.isEmpty) {
      throw const DemoPackFormatException(
        'replayProfile.capabilitiesHash 必须为非空字符串',
      );
    }
    return DemoReplayProfile(
      id: id,
      version: version,
      protocol: protocol,
      capabilitiesHash: capabilitiesHash,
    );
  }

  final String id;
  final int version;
  final String protocol;
  final String capabilitiesHash;

  static const String conservativeRelayId = 'conservativeRelay';
  static const String zhipuId = 'zhipu';
  static const String deepseekId = 'deepseek';
  static const String alibabaId = 'alibaba';
  static const int currentVersion = 1;

  /// 保守档白名单画像（v1 兼容 / 非流式工具步）
  static const DemoReplayProfile conservativeRelay = DemoReplayProfile(
    id: conservativeRelayId,
    version: currentVersion,
    protocol: 'openaiCompatible',
    capabilitiesHash: '2f54d79457ea729b',
  );

  /// 智谱 GLM 白名单画像（v2 GLM-5.3 适配 / 流式工具步）
  static const DemoReplayProfile zhipu = DemoReplayProfile(
    id: zhipuId,
    version: currentVersion,
    protocol: 'openaiCompatible',
    capabilitiesHash: 'd09527ac5c362d4f',
  );

  /// DeepSeek 白名单画像（流式工具步 / 仅串行 / required 降级 auto）
  static const DemoReplayProfile deepseek = DemoReplayProfile(
    id: deepseekId,
    version: currentVersion,
    protocol: 'openaiCompatible',
    capabilitiesHash: 'ba62b82a0ce95980',
  );

  /// Qwen 百炼白名单画像（流式工具步 / 并行默认关）
  static const DemoReplayProfile alibaba = DemoReplayProfile(
    id: alibabaId,
    version: currentVersion,
    protocol: 'openaiCompatible',
    capabilitiesHash: '4dc74aff88d7178a',
  );

  /// 当前支持的所有白名单画像
  static const Map<String, DemoReplayProfile> supportedProfiles = {
    conservativeRelayId: conservativeRelay,
    zhipuId: zhipu,
    deepseekId: deepseek,
    alibabaId: alibaba,
  };

  /// 校验画像合法性并求取对应的生产能力对象
  ProviderToolCapabilities resolveCapabilities() {
    final whitelist = supportedProfiles[id];
    if (whitelist == null) {
      throw DemoPackFormatException(
        '未知回放画像 id: "$id"（支持白名单: ${supportedProfiles.keys.toList()}）',
      );
    }
    if (version != currentVersion) {
      throw DemoPackFormatException(
        '回放画像 "$id" 版本=$version 不受支持（当前版本 $currentVersion）',
      );
    }
    if (protocol != whitelist.protocol) {
      throw DemoPackFormatException(
        '回放画像 "$id" 协议=$protocol 与白名单要求 (${whitelist.protocol}) 不符',
      );
    }
    if (capabilitiesHash != whitelist.capabilitiesHash) {
      throw DemoPackFormatException(
        '回放画像 "$id" 指纹=$capabilitiesHash 与白名单预期 (${whitelist.capabilitiesHash}) 不符',
      );
    }

    final LlmProtocol llmProtocol;
    if (protocol == 'openaiCompatible') {
      llmProtocol = LlmProtocol.openaiCompatible;
    } else {
      throw DemoPackFormatException('不支持的协议: $protocol');
    }

    final ProviderToolCapabilities caps;
    if (id == zhipuId) {
      caps = ProviderToolCapabilities.zhipu;
    } else if (id == deepseekId) {
      caps = ProviderToolCapabilities.deepseek;
    } else if (id == alibabaId) {
      caps = ProviderToolCapabilities.alibaba;
    } else {
      caps = ProviderToolCapabilities.conservativeRelay;
    }

    final calculated = computeCapabilitiesHash(
      protocol: llmProtocol,
      capabilities: caps,
    );
    if (capabilitiesHash != calculated) {
      throw DemoPackFormatException(
        '回放画像 "$id" 动态计算指纹=$calculated 与声明=$capabilitiesHash 不符',
      );
    }
    return caps;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'version': version,
        'protocol': protocol,
        'capabilitiesHash': capabilitiesHash,
      };
}

/// 纯规范化计算能力画像指纹（16 位 hex sha256）
String computeCapabilitiesHash({
  required LlmProtocol protocol,
  required ProviderToolCapabilities capabilities,
}) {
  final choices = capabilities.supportedToolChoices.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final map = <String, dynamic>{
    'idStrategy': capabilities.idStrategy.name,
    'parallelToolCalls': capabilities.parallelToolCalls,
    'preservesThoughtSignature': capabilities.preservesThoughtSignature,
    'protocol': protocol.name,
    'requiresToolStreamFlag': capabilities.requiresToolStreamFlag,
    'streamingToolCallsReliable': capabilities.streamingToolCallsReliable,
    'supportedToolChoices': [for (final c in choices) c.name],
  };
  final json = canonicalJson(map);
  return sha256.convert(utf8.encode(json)).toString().substring(0, 16);
}
