// 枚举已下沉 core/llm——
// core 的网关配置与网络适配层共用，不得反向依赖 feature。
// 本文件 re-export 维持既有消费面零改动。
export 'package:lmstory/core/llm/reasoning_effort.dart';
