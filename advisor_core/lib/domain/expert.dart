/// Expert 领域：三层身份模型（V1.3 §6 / §17 / §18 / §23）。
///
/// ```
/// MarketPackage → InstalledPackage → ExpertInstance
/// ```
/// 硬规则：`Expert.id`（本地实例）**不等于**市场 `packageId`。
library;

import 'common.dart';
import 'provider.dart';

// ---------------------------------------------------------------------------
// Grounding Policy（V1.3 §14 / §21）
// ---------------------------------------------------------------------------

/// 知识接地策略。取代 V1.2 的布尔 `strict_mode`。
enum GroundingPolicy {
  /// 普通模型对话，不检索。
  off('关闭', '不检索知识库，普通对话'),

  /// 优先使用知识库，无证据照常回答。
  preferred('优先', '优先用知识库，没有也照常回答'),

  /// 必须有知识库证据才回答，无命中**不调用 LLM**。
  strict('严格', '只依据知识库作答，没有命中就明确说"未找到"'),

  /// 检索 + Embedding + LLM 全本地，敏感内容不出机。
  localOnly('全本地', '知识库与模型都在本机，内容不出机');

  const GroundingPolicy(this.label, this.description);
  final String label;
  final String description;

  static GroundingPolicy parse(String? value) => GroundingPolicy.values
      .firstWhere((e) => e.name == value, orElse: () => GroundingPolicy.off);

  /// 是否需要先做知识检索。
  bool get needsRetrieval => this != GroundingPolicy.off;

  /// 是否在无证据时禁止调用 LLM。
  bool get forbidsLlmWithoutEvidence => this == GroundingPolicy.strict;

  /// 是否强制本地模型（不允许远程 LLM）。
  bool get requiresLocalModel => this == GroundingPolicy.localOnly;
}

// ---------------------------------------------------------------------------
// Expert 本体
// ---------------------------------------------------------------------------

/// 专家来源。
enum ExpertSource {
  market('市场'),
  local('自建'),
  imported('导入');

  const ExpertSource(this.label);
  final String label;

  static ExpertSource parse(String? v) => ExpertSource.values
      .firstWhere((e) => e.name == v, orElse: () => ExpertSource.local);
}

/// 专家本体（市场原始定义 + 本地实例 ID）。
class Expert {
  const Expert({
    required this.id,
    required this.name,
    required this.systemPrompt,
    this.profession,
    this.avatarPath,
    this.avatarEmoji,
    this.avatarColor,
    this.welcomeMessage,
    this.quickPrompts = const [],
    this.packageId,
    this.packageVersion,
    this.categoryId,
    this.source = ExpertSource.local,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? profession;
  final String? avatarPath;

  /// 市场包自带 emoji 头像（如 `🤖`）；本地自建 / 老库升级行为 null。
  ///
  /// 第 #66 轮新增（**additive**）：市场页卡片走"包自带 emoji + color"档，
  /// 而 `Expert` 此前**只有** [avatarPath]，安装落库时 emoji/color 直接丢失
  /// → 专家进了通讯录就回退成首字（用户走查反馈：头像没了）。
  /// 显示优先级（app 层 [ExpertAvatar]）：本地图片 > emoji > 首字。
  final String? avatarEmoji;

  /// emoji 头像底色（市场包 `color`，`#RRGGBB` 或色名；可为 null）。
  ///
  /// null / 非法色值 → UI 回退 `AvatarPalette.colorFor(expertId)`（确定性色）。
  final String? avatarColor;
  final String systemPrompt;
  final String? welcomeMessage;
  final List<String> quickPrompts;

  /// 来源市场包 ID（`org.private-advisor.xxx`）；本地自建为 null。
  final String? packageId;
  final String? packageVersion;

  /// WorkBuddy 15 类分类 ID（如 `12-IndustryConsultant`）。
  final String? categoryId;

  final ExpertSource source;
  final int createdAt;
  final int updatedAt;

  Expert copyWith({
    String? name,
    String? profession,
    String? avatarPath,
    String? avatarEmoji,
    String? avatarColor,
    String? systemPrompt,
    String? welcomeMessage,
    List<String>? quickPrompts,
    String? packageId,
    String? packageVersion,
    String? categoryId,
    ExpertSource? source,
    int? updatedAt,
    bool clearAvatarEmoji = false,
    bool clearAvatarColor = false,
  }) =>
      Expert(
        id: id,
        name: name ?? this.name,
        profession: profession ?? this.profession,
        avatarPath: avatarPath ?? this.avatarPath,
        avatarEmoji: clearAvatarEmoji ? null : (avatarEmoji ?? this.avatarEmoji),
        avatarColor: clearAvatarColor ? null : (avatarColor ?? this.avatarColor),
        systemPrompt: systemPrompt ?? this.systemPrompt,
        welcomeMessage: welcomeMessage ?? this.welcomeMessage,
        quickPrompts: quickPrompts ?? this.quickPrompts,
        packageId: packageId ?? this.packageId,
        packageVersion: packageVersion ?? this.packageVersion,
        categoryId: categoryId ?? this.categoryId,
        source: source ?? this.source,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 专家运行配置（与 Expert 一对一）。
class ExpertRuntimeConfig {
  const ExpertRuntimeConfig({
    required this.expertId,
    this.modelProfileId,
    this.credentialProfileId,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.groundingPolicy = GroundingPolicy.off,
    this.enabled = true,
  });

  final String expertId;

  /// 为空 → 使用全局默认模型。
  final String? modelProfileId;

  /// 为空 → 使用全局默认凭据。
  final String? credentialProfileId;

  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final GroundingPolicy groundingPolicy;
  final bool enabled;

  ExpertRuntimeConfig copyWith({
    String? modelProfileId,
    String? credentialProfileId,
    double? temperature,
    double? topP,
    int? maxTokens,
    GroundingPolicy? groundingPolicy,
    bool? enabled,
    bool clearModel = false,
    bool clearCredential = false,
  }) =>
      ExpertRuntimeConfig(
        expertId: expertId,
        modelProfileId: clearModel ? null : (modelProfileId ?? this.modelProfileId),
        credentialProfileId:
            clearCredential ? null : (credentialProfileId ?? this.credentialProfileId),
        temperature: temperature ?? this.temperature,
        topP: topP ?? this.topP,
        maxTokens: maxTokens ?? this.maxTokens,
        groundingPolicy: groundingPolicy ?? this.groundingPolicy,
        enabled: enabled ?? this.enabled,
      );
}

/// 专家用户侧状态（市场更新**不覆盖**本表）。
class ExpertUserState {
  const ExpertUserState({
    required this.expertId,
    this.remark,
    this.groupId,
    this.pinned = false,
    this.customPrompt,
    this.styleId,
    this.isLocked = false,
    this.localModifiedAt,
  });

  final String expertId;
  final String? remark;
  final String? groupId;
  final bool pinned;

  /// 用户自定义提示词；非空时**覆盖** `Expert.systemPrompt`。
  final String? customPrompt;

  /// 专家级风格（`ExpertStyle.name`，0 或 1 个预设；第 3 轮 v3 新增）。
  ///
  /// 与 [customPrompt] 同级：市场更新**不覆盖**；null → 不注入风格。
  final String? styleId;

  final bool isLocked;

  /// 一旦非空，市场更新需走 diff 迁移，不自动覆盖。
  final int? localModifiedAt;

  bool get isLocallyModified => localModifiedAt != null;

  ExpertUserState copyWith({
    String? remark,
    String? groupId,
    bool? pinned,
    String? customPrompt,
    String? styleId,
    bool? isLocked,
    int? localModifiedAt,
    bool clearCustomPrompt = false,
    bool clearStyle = false,
  }) =>
      ExpertUserState(
        expertId: expertId,
        remark: remark ?? this.remark,
        groupId: groupId ?? this.groupId,
        pinned: pinned ?? this.pinned,
        customPrompt: clearCustomPrompt ? null : (customPrompt ?? this.customPrompt),
        styleId: clearStyle ? null : (styleId ?? this.styleId),
        isLocked: isLocked ?? this.isLocked,
        localModifiedAt: localModifiedAt ?? this.localModifiedAt,
      );
}

/// 标签（独立表，不用 `tags[]` 直存）。
class ExpertTag {
  const ExpertTag({required this.id, required this.name});
  final String id;
  final String name;

  static ExpertTag create(String name) =>
      ExpertTag(id: Ids.next('tag'), name: name.trim());
}

// ---------------------------------------------------------------------------
// 知识库绑定（N:M，V1.3 §18 / §20）
// ---------------------------------------------------------------------------

/// 专家 ↔ 知识库绑定。同一知识库可服务多个专家；一个专家可绑定多个知识库（多选）。
class ExpertKnowledgeBinding {
  const ExpertKnowledgeBinding({
    required this.expertId,
    required this.knowledgeBaseId,
    this.priority = 0,
    this.enabled = true,
    this.topK = 5,
    this.similarityThreshold = 0.75,
  });

  final String expertId;
  final String knowledgeBaseId;
  final int priority;
  final bool enabled;
  final int topK;
  final double similarityThreshold;

  ExpertKnowledgeBinding copyWith({
    int? priority,
    bool? enabled,
    int? topK,
    double? similarityThreshold,
  }) =>
      ExpertKnowledgeBinding(
        expertId: expertId,
        knowledgeBaseId: knowledgeBaseId,
        priority: priority ?? this.priority,
        enabled: enabled ?? this.enabled,
        topK: topK ?? this.topK,
        similarityThreshold: similarityThreshold ?? this.similarityThreshold,
      );
}

// ---------------------------------------------------------------------------
// 生效配置解析（契约 01 §5）
// ---------------------------------------------------------------------------

/// 专家在一次生成中实际生效的配置。
class EffectiveExpertConfig {
  const EffectiveExpertConfig({
    required this.expertId,
    required this.displayName,
    required this.prompt,
    required this.modelProfileId,
    required this.credentialProfileId,
    required this.groundingPolicy,
    this.styleId,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.knowledgeBaseIds = const [],
  });

  final String expertId;
  final String displayName;
  final String prompt;

  /// 生效风格 id（`ExpertStyle.name`）；null → 不注入（第 3 轮新增）。
  final String? styleId;

  final String? modelProfileId;
  final String? credentialProfileId;
  final GroundingPolicy groundingPolicy;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final List<String> knowledgeBaseIds;

  /// `customPrompt ?? systemPrompt`
  static String resolvePrompt(Expert expert, ExpertUserState? state) {
    final custom = state?.customPrompt;
    if (custom != null && custom.trim().isNotEmpty) return custom;
    return expert.systemPrompt;
  }

  /// 生效风格 id（来自用户状态）。
  static String? resolveStyle(ExpertUserState? state) => state?.styleId;

  /// 展示名：备注优先。
  static String resolveName(Expert expert, ExpertUserState? state) {
    final remark = state?.remark;
    if (remark != null && remark.trim().isNotEmpty) return remark;
    return expert.name;
  }
}
