/// 视觉（图片）多模态门控与 OpenAI content 映射（第 9 轮 · 图片多模态）。
///
/// 边界（重要）：
/// - 本文件只提供**纯函数**：门控判定 + payload `content` 字段构造；
/// - HTTP 请求体拼装仍在 infrastructure 层（`app` 的
///   `OpenAiCompatibleProvider`），由它 **1:1 委托** [openAiContentFor]，
///   **不另造请求体**（原请求体其余字段一字不动）；
/// - `supports_vision` 门控口径：model profile `supports_vision == false`
///   而消息带图 → **明确抛 [VisionUnsupportedError]**，绝不静默丢图。
library;

import '../domain/common.dart';
import '../domain/provider.dart';

/// 模型不支持视觉输入时的标准错误消息（[modelId] 填入当前位置）。
String visionUnsupportedMessage(String modelId) =>
    '当前模型（$modelId）不支持图片；请换用支持视觉的模型，'
    '或在「设置 → 模型」中为该模型开启「支持视觉」';

/// 视觉门控：任一带图消息 + 模型未开启 `supports_vision` →
/// 抛 [VisionUnsupportedError]（`provider.vision_unsupported`）。
///
/// 无图 / 已开启 → 静默返回（正常路径零开销）。
void assertVisionSupported({
  required bool supportsVision,
  required String modelId,
  required List<ChatMessage> messages,
}) {
  if (supportsVision) return;
  final hasImage = messages.any((m) => m.imageUrls.isNotEmpty);
  if (!hasImage) return;
  throw VisionUnsupportedError(visionUnsupportedMessage(modelId));
}

/// 把 [ChatMessage] 映射为 OpenAI 兼容 payload 的 `content` 字段值。
///
/// - **无图片 → 原字符串**（请求体与第 9 轮之前逐字一致，回归防护）；
/// - **有图片 → content-parts 数组**：
///   `[{'type':'text','text':<原文>}, {'type':'image_url','image_url':{'url':<dataUrl>}}, ...]`，
///   顺序恒为 **text → image**（可多张，按 [ChatMessage.imageUrls] 顺序）。
Object openAiContentFor(ChatMessage message) {
  if (message.imageUrls.isEmpty) return message.content;
  return <Map<String, Object?>>[
    {'type': 'text', 'text': message.content},
    for (final url in message.imageUrls)
      {'type': 'image_url', 'image_url': {'url': url}},
  ];
}
