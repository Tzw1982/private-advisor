/// Generation 领域：Run / Step / Event 三层运行模型（V1.3 §8 / §9 / §24）。
///
/// 核心承诺：**每一次 AI 运行都可取消、可重试、可追踪、可落库。**
library;

import 'common.dart';
import 'conversation.dart';
import 'knowledge.dart';

// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------

/// 运行类型。
enum RunType {
  singleChat('单聊'),
  groupChat('群聊'),
  summarization('总结'),
  retrieval('检索');

  const RunType(this.label);
  final String label;
}

/// 运行 / 步骤状态。
enum RunStatus {
  queued('排队中'),
  running('进行中'),
  completed('完成'),
  cancelled('已取消'),
  failed('失败'),
  partial('部分完成');

  const RunStatus(this.label);
  final String label;

  static RunStatus parse(String? v) => RunStatus.values
      .firstWhere((e) => e.name == v, orElse: () => RunStatus.queued);
}

/// 步骤阶段。
enum StepStage {
  planning('规划'),
  routing('路由'),
  retrieval('检索'),
  generation('生成'),
  dedup('去重'),
  critic('评审'),
  synthesis('综合'),
  validation('校验');

  const StepStage(this.label);
  final String label;
}

/// 流式事件类型。
enum GenerationEventType {
  runStarted('run_started'),
  stepStarted('step_started'),
  tokenDelta('token_delta'),

  /// 模型思考通道增量（`reasoning_content`）；**用户不可见**，仅用于排查（第 3 轮新增）。
  reasoningDelta('reasoning_delta'),
  stepCompleted('step_completed'),
  stepFailed('step_failed'),
  runCompleted('run_completed'),
  runFailed('run_failed');

  const GenerationEventType(this.wire);
  final String wire;
}

// ---------------------------------------------------------------------------
// Run / Step / Event
// ---------------------------------------------------------------------------

/// 一次用户提问触发的完整运行。
class GenerationRun {
  const GenerationRun({
    required this.id,
    required this.conversationId,
    this.triggerMessageId,
    required this.runType,
    this.status = RunStatus.queued,
    this.modelProfileId,
    this.tokenBudget,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.estimatedCost = 0,
    this.startedAt,
    this.endedAt,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String conversationId;
  final String? triggerMessageId;
  final RunType runType;
  final RunStatus status;
  final String? modelProfileId;
  final int? tokenBudget;
  final int promptTokens;
  final int completionTokens;
  final double estimatedCost;
  final int? startedAt;
  final int? endedAt;
  final String? errorCode;
  final String? errorMessage;

  int get totalTokens => promptTokens + completionTokens;

  /// 是否已超出预算（群聊 Token 爆炸防护，V1.3 §34）。
  bool get isOverBudget => tokenBudget != null && totalTokens >= tokenBudget!;

  static GenerationRun create({
    required String conversationId,
    required RunType runType,
    String? triggerMessageId,
    String? modelProfileId,
    int? tokenBudget,
  }) =>
      GenerationRun(
        id: Ids.next('run'),
        conversationId: conversationId,
        triggerMessageId: triggerMessageId,
        runType: runType,
        modelProfileId: modelProfileId,
        tokenBudget: tokenBudget,
      );

  GenerationRun copyWith({
    RunStatus? status,
    int? promptTokens,
    int? completionTokens,
    double? estimatedCost,
    int? startedAt,
    int? endedAt,
    String? errorCode,
    String? errorMessage,
  }) =>
      GenerationRun(
        id: id,
        conversationId: conversationId,
        triggerMessageId: triggerMessageId,
        runType: runType,
        status: status ?? this.status,
        modelProfileId: modelProfileId,
        tokenBudget: tokenBudget,
        promptTokens: promptTokens ?? this.promptTokens,
        completionTokens: completionTokens ?? this.completionTokens,
        estimatedCost: estimatedCost ?? this.estimatedCost,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        errorCode: errorCode ?? this.errorCode,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

/// 单个发言者 / 单个阶段的一步。
class GenerationStep {
  const GenerationStep({
    required this.id,
    required this.runId,
    this.expertId,
    required this.stage,
    required this.sequence,
    this.status = RunStatus.queued,
    this.startedAt,
    this.endedAt,
    this.retrievalCount = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.latencyMs,
    this.outputMessageId,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String runId;
  final String? expertId;
  final StepStage stage;
  final int sequence;
  final RunStatus status;
  final int? startedAt;
  final int? endedAt;
  final int retrievalCount;
  final int promptTokens;
  final int completionTokens;
  final int? latencyMs;
  final String? outputMessageId;
  final String? errorCode;
  final String? errorMessage;

  static GenerationStep create({
    required String runId,
    required StepStage stage,
    required int sequence,
    String? expertId,
  }) =>
      GenerationStep(
        id: Ids.next('step'),
        runId: runId,
        expertId: expertId,
        stage: stage,
        sequence: sequence,
      );

  GenerationStep copyWith({
    RunStatus? status,
    int? startedAt,
    int? endedAt,
    int? retrievalCount,
    int? promptTokens,
    int? completionTokens,
    int? latencyMs,
    String? outputMessageId,
    String? errorCode,
    String? errorMessage,
  }) =>
      GenerationStep(
        id: id,
        runId: runId,
        expertId: expertId,
        stage: stage,
        sequence: sequence,
        status: status ?? this.status,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        retrievalCount: retrievalCount ?? this.retrievalCount,
        promptTokens: promptTokens ?? this.promptTokens,
        completionTokens: completionTokens ?? this.completionTokens,
        latencyMs: latencyMs ?? this.latencyMs,
        outputMessageId: outputMessageId ?? this.outputMessageId,
        errorCode: errorCode ?? this.errorCode,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

/// 流式增量事件。最终 Message 只保存最终内容，事件表用于回放与调试。
class GenerationEvent {
  const GenerationEvent({
    required this.id,
    required this.stepId,
    required this.sequence,
    required this.eventType,
    this.delta,
    required this.createdAt,
  });

  final String id;
  final String stepId;
  final int sequence;
  final GenerationEventType eventType;
  final String? delta;
  final int createdAt;

  static GenerationEvent create({
    required String stepId,
    required int sequence,
    required GenerationEventType eventType,
    String? delta,
  }) =>
      GenerationEvent(
        id: Ids.next('evt'),
        stepId: stepId,
        sequence: sequence,
        eventType: eventType,
        delta: delta,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
}

// ---------------------------------------------------------------------------
// 群聊编排上下文与计划（V1.3 §24）
// ---------------------------------------------------------------------------

/// Token 预算。
class TokenBudget {
  const TokenBudget({
    this.maxContextTokens = 8000,
    this.maxGroupHistory = 30,
    this.maxExpertOutput = 1200,
    this.maxTotalGroupBudget = 40000,
  });

  final int maxContextTokens;
  final int maxGroupHistory;
  final int maxExpertOutput;
  final int maxTotalGroupBudget;

  static const defaults = TokenBudget();

  /// 单次专家输出上限的钳制区间（tokens）。
  ///
  /// 下限 2000：短于这个连一份结构化纪要都写不下；
  /// 上限 16000：约 1.6 万汉字，足够一次「五类清单」式长答复，
  /// 同时仍是**失控护栏**——不设上限时一次异常/提示注入就可能产出整本书。
  static const int minExpertOutput = 2000;
  static const int maxExpertOutputCeiling = 16000;

  /// 由**模型上下文窗口**推导预算（替代写死常量）。
  ///
  /// 背景（2026-10-02 用户反馈）：原写死值（历史 8000 / 单次输出 1200 /
  /// 群总量 40000）按 64K 模型预留，而实际模型已有百万级上下文，导致
  /// ① 招标文件这类长输入一注入就把历史预算吃光（模型看得见附件、
  ///    看不见任何聊天记录）；② 群聊在第 1 位专家后即被 `isOverBudget` 掐断。
  ///
  /// 推导规则：
  /// - [maxContextTokens] / [maxTotalGroupBudget] = 上下文的 3/4——给 system、
  ///   附件、证据、输出留足余量，且仍保留"超预算即停"的护栏（**不取消**，
  ///   只是不再按 64K 时代的尺子裁）；
  /// - [maxExpertOutput] = 上下文 / 8，钳制在 [minExpertOutput]…[maxExpertOutputCeiling]。
  ///
  /// [contextWindow] 为 null（模型档案未填）时退回 [defaults]，行为与旧版一致。
  factory TokenBudget.forContext(int? contextWindow) {
    if (contextWindow == null || contextWindow <= 0) return defaults;
    final usable = contextWindow * 3 ~/ 4;
    final out = (contextWindow ~/ 8).clamp(minExpertOutput, maxExpertOutputCeiling);
    return TokenBudget(
      maxContextTokens: usable,
      maxGroupHistory: 30,
      maxExpertOutput: out,
      maxTotalGroupBudget: usable,
    );
  }
}

/// 群聊成员（含发言权重与专家能力标签）。
class GroupMember {
  const GroupMember({
    required this.expertId,
    required this.name,
    this.weight = 1.0,
    this.expertise = const [],
    this.enabled = true,
    this.sortOrder = 0,
    this.role = MemberRole.member,
  });

  final String expertId;
  final String name;
  final double weight;
  final List<String> expertise;
  final bool enabled;
  final int sortOrder;
  final MemberRole role;

  bool get isSummarizer => role == MemberRole.summarizer;
}

/// 已完成的专家输出（供去重 / 总结使用）。
class ExpertOutput {
  const ExpertOutput({
    required this.expertId,
    required this.expertName,
    required this.content,
    this.messageId,
    this.citations = const [],
    this.skipped = false,
    this.skipReason,
  });

  final String expertId;
  final String expertName;
  final String content;
  final String? messageId;
  final List<Citation> citations;

  /// 因 strict 无命中 / 重复 / 跑题而被跳过。
  final bool skipped;
  final String? skipReason;

  static ExpertOutput skippedBy(String expertId, String name, String reason) =>
      ExpertOutput(
        expertId: expertId,
        expertName: name,
        content: '',
        skipped: true,
        skipReason: reason,
      );
}

/// 群聊上下文。
class GroupContext {
  const GroupContext({
    required this.conversationId,
    required this.userMessage,
    this.recentMessages = const [],
    this.members = const [],
    this.knowledgeEvidence = const [],
    this.budget = TokenBudget.defaults,
    this.previousSpeakerOutputs = const [],
    this.round = 0,
    this.lastSpeakerId,
  });

  final String conversationId;
  final Message userMessage;
  final List<Message> recentMessages;
  final List<GroupMember> members;
  final List<Citation> knowledgeEvidence;
  final TokenBudget budget;
  final List<ExpertOutput> previousSpeakerOutputs;
  final int round;

  /// 上一轮发言者（轮流策略使用）。
  final String? lastSpeakerId;

  List<GroupMember> get activeMembers =>
      members.where((m) => m.enabled).toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  GroupContext copyWith({
    List<ExpertOutput>? previousSpeakerOutputs,
    int? round,
    String? lastSpeakerId,
  }) =>
      GroupContext(
        conversationId: conversationId,
        userMessage: userMessage,
        recentMessages: recentMessages,
        members: members,
        knowledgeEvidence: knowledgeEvidence,
        budget: budget,
        previousSpeakerOutputs: previousSpeakerOutputs ?? this.previousSpeakerOutputs,
        round: round ?? this.round,
        lastSpeakerId: lastSpeakerId ?? this.lastSpeakerId,
      );
}

/// 发言计划。
class SpeakerPlan {
  const SpeakerPlan({
    required this.primarySpeakers,
    this.fallbackSpeakers = const [],
    this.maxRounds = 1,
    this.rationale = '',
  });

  final List<String> primarySpeakers;
  final List<String> fallbackSpeakers;
  final int maxRounds;
  final String rationale;

  bool get isEmpty => primarySpeakers.isEmpty;

  static const none = SpeakerPlan(primarySpeakers: [], rationale: '无可用发言者');
}
