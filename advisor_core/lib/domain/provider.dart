/// Provider 领域：Provider / Model / Credential 三层拆分（V1.3 §7 / §15 / §16 / §35）。
///
/// 关键约束：
/// - API Key **不直接挂 Expert**，只经 `CredentialProfile.secretRef` 间接引用。
/// - 本层只描述数据与端口，不做 HTTP；HTTP 由 infrastructure 层实现 [LlmProvider]。
library;

import 'common.dart';

// ---------------------------------------------------------------------------
// 状态三维模型（V1.3 §24 / §35）
// ---------------------------------------------------------------------------

/// 可用性：能否发起请求。
enum Availability {
  available('可用'),
  unavailable('不可用'),
  misconfigured('未配置'),
  rateLimited('限流中');

  const Availability(this.label);
  final String label;
}

/// 活动态：当前在做什么。
enum Activity {
  idle('空闲'),
  thinking('思考中'),
  preparing('准备发言'),
  generating('正在输入');

  const Activity(this.label);
  final String label;
}

/// 健康度：最近一次交互的结果。
enum Health {
  healthy('正常'),
  authError('Key 无效'),
  networkError('网络异常'),
  quotaError('配额不足'),
  providerError('服务异常');

  const Health(this.label);
  final String label;
}

/// 专家头像在 UI 上应呈现的聚合状态。
///
/// UI **只依赖**该映射结果，不直接读 HTTP 错误码（V1.3 §35）。
class ExpertStatus {
  const ExpertStatus({
    required this.availability,
    required this.activity,
    required this.health,
  });

  final Availability availability;
  final Activity activity;
  final Health health;

  static const idle = ExpertStatus(
    availability: Availability.available,
    activity: Activity.idle,
    health: Health.healthy,
  );

  /// 头像是否灰显（离线 / 限流 / 鉴权失败 / 未配置）。
  bool get isDimmed =>
      health != Health.healthy ||
      availability == Availability.unavailable ||
      availability == Availability.misconfigured ||
      availability == Availability.rateLimited;

  /// 头像旁的文字标签；在线且空闲时返回 null（不显示）。
  String? get badge {
    switch (health) {
      case Health.authError:
        return '（离线）';
      case Health.networkError:
        return '（离线）';
      case Health.quotaError:
        return '（离线）';
      case Health.providerError:
        return '（异常）';
      case Health.healthy:
        break;
    }
    switch (availability) {
      case Availability.rateLimited:
        return '（限流中）';
      case Availability.misconfigured:
        return '（未配置）';
      case Availability.unavailable:
        return '（离线）';
      case Availability.available:
        break;
    }
    switch (activity) {
      case Activity.idle:
        return null;
      case Activity.thinking:
        return '思考中…';
      case Activity.preparing:
        return '准备发言…';
      case Activity.generating:
        return '正在输入…';
    }
  }

  ExpertStatus copyWith({
    Availability? availability,
    Activity? activity,
    Health? health,
  }) =>
      ExpertStatus(
        availability: availability ?? this.availability,
        activity: activity ?? this.activity,
        health: health ?? this.health,
      );

  /// 由 Provider 错误映射健康度。
  static Health healthFromError(AppError error) => switch (error) {
        AuthenticationError() => Health.authError,
        NetworkError() => Health.networkError,
        QuotaError() => Health.quotaError,
        RateLimitError() => Health.healthy,
        ProviderServerError() => Health.providerError,
        _ => Health.providerError,
      };
}

// ---------------------------------------------------------------------------
// 三层数据模型
// ---------------------------------------------------------------------------

/// Provider 档案（DeepSeek / OpenRouter / Ollama / 自定义 OpenAI 兼容）。
class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.providerId,
    required this.displayName,
    required this.baseUrl,
    this.protocol = 'openai_compatible',
    this.enabled = true,
  });

  final String id;

  /// 内置 provider 标识：deepseek / openrouter / ollama / custom。
  final String providerId;
  final String displayName;
  final String baseUrl;
  final String protocol;
  final bool enabled;

  ProviderProfile copyWith({
    String? displayName,
    String? baseUrl,
    bool? enabled,
  }) =>
      ProviderProfile(
        id: id,
        providerId: providerId,
        displayName: displayName ?? this.displayName,
        baseUrl: baseUrl ?? this.baseUrl,
        protocol: protocol,
        enabled: enabled ?? this.enabled,
      );
}

/// 模型档案。
class ModelProfile {
  const ModelProfile({
    required this.id,
    required this.providerProfileId,
    required this.modelId,
    this.contextWindow,
    this.supportsStreaming = true,
    this.supportsVision = false,
    this.supportsTools = false,
    this.supportsJson = false,
  });

  final String id;
  final String providerProfileId;
  final String modelId;
  final int? contextWindow;
  final bool supportsStreaming;
  final bool supportsVision;
  final bool supportsTools;
  final bool supportsJson;

  ModelProfile copyWith({
    String? modelId,
    int? contextWindow,
    bool? supportsStreaming,
    bool? supportsVision,
    bool? supportsTools,
    bool? supportsJson,
  }) =>
      ModelProfile(
        id: id,
        providerProfileId: providerProfileId,
        modelId: modelId ?? this.modelId,
        contextWindow: contextWindow ?? this.contextWindow,
        supportsStreaming: supportsStreaming ?? this.supportsStreaming,
        supportsVision: supportsVision ?? this.supportsVision,
        supportsTools: supportsTools ?? this.supportsTools,
        supportsJson: supportsJson ?? this.supportsJson,
      );

  /// DeepSeek 官方直连的默认模型档案。
  ///
  /// `contextWindow` 取 100 万（用户实配口径，2026-10-02）：此前写 65536 会让
  /// 预算按 64K 时代的尺子推导，长文档一注入历史就被吃光、群聊被过早掐断
  /// （用户反馈 #61）。该值仅用于 `TokenBudget.forContext` 推导，**不参与**请求体。
  static ModelProfile deepseekChat({String providerProfileId = 'pp_deepseek'}) =>
      ModelProfile(
        id: 'mp_deepseek_chat',
        providerProfileId: providerProfileId,
        modelId: 'deepseek-chat',
        contextWindow: 1000000,
        supportsStreaming: true,
        supportsJson: true,
      );

  /// DeepSeek 推理模型。
  ///
  /// `contextWindow` 与 [deepseekChat] **同口径**（用户实配 1M，走查反馈
  /// 「reasoner 上下文显示不对」修正）：此前写 65536 会让预算按 64K 时代的
  /// 尺子推导，长推理链路被过早掐断。该值仅用于 `TokenBudget.forContext`
  /// 推导，**不参与**请求体。
  static ModelProfile deepseekReasoner({String providerProfileId = 'pp_deepseek'}) =>
      ModelProfile(
        id: 'mp_deepseek_reasoner',
        providerProfileId: providerProfileId,
        modelId: 'deepseek-reasoner',
        contextWindow: 1000000,
        supportsStreaming: true,
      );
}

/// 凭据档案。SQLite 只存 [secretRef]，明文由 OS Secure Storage 托管。
class CredentialProfile {
  const CredentialProfile({
    required this.id,
    required this.providerProfileId,
    required this.name,
    required this.secretRef,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String providerProfileId;
  final String name;

  /// 指向 Secure Storage 的键，**不是** Key 明文。
  final String secretRef;
  final int createdAt;
  final int updatedAt;

  static String secretRefFor(String credentialId) => 'pa.secret.$credentialId';
}

// ---------------------------------------------------------------------------
// LLM 端口（infrastructure 实现）
// ---------------------------------------------------------------------------

/// 对话角色。
enum ChatRole { system, user, assistant }

/// 单条对话消息（发给模型的最小单元）。
class ChatMessage {
  const ChatMessage(this.role, this.content, {this.imageUrls = const []});

  final ChatRole role;
  final String content;

  /// 随消息发送的图片 data URL 列表（`data:image/png;base64,...`）。
  ///
  /// 第 9 轮图片多模态：默认空 → **旧调用方零破坏**（payload 的 `content`
  /// 保持原字符串形态）。非空时由 infrastructure 层
  /// （`OpenAiCompatibleProvider`）映射为 OpenAI content-parts 数组，
  /// 并受模型 `supports_vision` 门控（未开启 → 明确报错，不静默丢图）。
  final List<String> imageUrls;
}

/// 模型请求。
class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.messages,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stream = true,
    this.jsonMode = false,
  });

  final String model;
  final List<ChatMessage> messages;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final bool stream;
  final bool jsonMode;
}

/// 流式事件。
sealed class StreamEvent {
  const StreamEvent();
}

/// 增量 token。
class TokenDelta extends StreamEvent {
  const TokenDelta(this.text);
  final String text;
}

/// 模型思考通道增量（`reasoning_content`）。
///
/// **绝不写入 `messages.content`**；由生成服务落 `generation_events(type=reasoning_delta)`，
/// 用户不可见（第 3 轮 Q9 / 架构设计 §3.5 A①）。
class ReasoningDelta extends StreamEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// 用量统计。
class UsageEvent extends StreamEvent {
  const UsageEvent(this.promptTokens, this.completionTokens);
  final int promptTokens;
  final int completionTokens;
}

/// 流内错误。
class StreamErrorEvent extends StreamEvent {
  const StreamErrorEvent(this.error);
  final AppError error;
}

/// 正常结束。
class StreamDone extends StreamEvent {
  const StreamDone();
}

/// 非流式响应。
class ChatResponse {
  const ChatResponse({
    required this.content,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final String content;
  final int promptTokens;
  final int completionTokens;
}

/// 模型能力描述（listModels 返回）。
class ModelDescriptor {
  const ModelDescriptor({
    required this.modelId,
    this.contextWindow,
    this.supportsStreaming = true,
  });

  final String modelId;
  final int? contextWindow;
  final bool supportsStreaming;
}

/// Provider 健康检查结果。
class ProviderHealth {
  const ProviderHealth({required this.health, this.latencyMs, this.detail});

  final Health health;
  final int? latencyMs;
  final String? detail;

  static const unknown =
      ProviderHealth(health: Health.providerError, detail: '尚未探测');
}

/// 模型服务适配端口（V1.3 §26）。
///
/// 任何 provider（DeepSeek / OpenRouter / Ollama / 自定义）都实现本接口；
/// 上层只依赖此抽象，便于替换（Replaceable Infra 原则）。
abstract interface class LlmProvider {
  String get providerId;

  Future<List<ModelDescriptor>> listModels();

  Future<ChatResponse> chat(ChatRequest request);

  /// 流式请求。[cancel] 时必须中止底层连接。
  Stream<StreamEvent> stream(ChatRequest request);

  Future<ProviderHealth> healthCheck();

  /// 把底层异常归一化为 [AppError]。
  AppError mapError(Object raw);
}

/// HTTP 状态码 → 统一错误（供各 provider 复用）。
AppError mapHttpStatus(int statusCode, [String? body]) {
  final detail = (body == null || body.isEmpty) ? null : body;
  if (statusCode == 401 || statusCode == 403) {
    return AuthenticationError(detail ?? 'API Key 无效或已失效');
  }
  if (statusCode == 429) return RateLimitError(detail ?? '请求过于频繁，已被限流');
  if (statusCode == 402) return QuotaError(detail ?? '账户配额不足');
  if (statusCode >= 500) return ProviderServerError(detail ?? '模型服务端错误');
  return ProviderServerError('HTTP $statusCode${detail == null ? '' : ': $detail'}');
}
