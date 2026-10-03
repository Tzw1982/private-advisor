/// 持久化端口（Repository Ports）。
///
/// Domain / Application 只依赖这些抽象；具体实现由 infrastructure 层
/// （Drift / SQLite / Secure Storage / GitHub）提供。
library;

import '../domain/attachment.dart';
import '../domain/conversation.dart';
import '../domain/expert.dart';
import '../domain/expert_group.dart';
import '../domain/generation.dart';
import '../domain/knowledge.dart';
import '../domain/market.dart';
import '../domain/provider.dart';

/// 专家仓储。
abstract interface class ExpertRepository {
  Future<void> upsertExpert(Expert expert);
  Future<Expert?> getExpert(String id);
  Future<List<Expert>> listExperts();
  Future<void> deleteExpert(String id);

  Future<void> upsertRuntimeConfig(ExpertRuntimeConfig config);
  Future<ExpertRuntimeConfig?> getRuntimeConfig(String expertId);

  Future<void> upsertUserState(ExpertUserState state);
  Future<ExpertUserState?> getUserState(String expertId);

  Future<void> setTags(String expertId, List<String> tagNames);
  Future<List<String>> getTags(String expertId);

  Future<void> upsertKnowledgeBinding(ExpertKnowledgeBinding binding);
  Future<void> removeKnowledgeBinding(String expertId, String knowledgeBaseId);
  Future<List<ExpertKnowledgeBinding>> listKnowledgeBindings(String expertId);
}

/// 分组仓储（通讯录分组主表；第 3 轮新增）。
abstract interface class GroupRepository {
  Future<void> upsertGroup(ExpertGroup group);
  Future<ExpertGroup?> getGroup(String id);
  Future<List<ExpertGroup>> listGroups();

  /// 删除分组。成员 `group_id` 由 `ExpertService` 清理（**无 DB 级 FK**）。
  Future<void> deleteGroup(String id);
}

/// 会话仓储。
abstract interface class ConversationRepository {
  Future<void> upsertConversation(Conversation conversation);
  Future<Conversation?> getConversation(String id);
  Future<List<Conversation>> listConversations();

  /// 删除会话。
  ///
  /// **级联由 DB 外键负责**（`conversation_members` / `group_configs` /
  /// `messages` 均声明 `ON DELETE CASCADE`，后者再级联
  /// `message_attachments` / `message_citations`）——实现方**只删
  /// `conversations` 主表一行，绝不手删子表**。
  ///
  /// 已知边界（既定事实，非本标准缺陷）：`generation_runs` 对
  /// `conversation_id` **无 FK**，删除会话不会带走其生成运行记录。
  Future<void> deleteConversation(String id);

  /// 置顶 / 取消置顶（写 `conversations.pinned`；幂等）。
  ///
  /// 会话不存在时**静默 no-op**（UPDATE 影响 0 行）——存在性校验由服务层
  /// （`ConversationService.setPinned`）负责。
  Future<void> setConversationPinned(String conversationId, bool pinned);

  /// 清空该会话全部消息（**会话本身保留**）。
  ///
  /// 消息的附件 / 引用子表由 DB 外键 `ON DELETE CASCADE` 负责，
  /// 实现方**只删 `messages` 行，绝不手删子表**。
  /// 会话不存在时静默 no-op（存在性校验同 [setConversationPinned]）。
  Future<void> clearMessages(String conversationId);

  Future<void> upsertMember(ConversationMember member);
  Future<void> removeMember(String conversationId, String expertId);
  Future<List<ConversationMember>> listMembers(String conversationId);

  Future<void> upsertGroupConfig(GroupConfig config);
  Future<GroupConfig?> getGroupConfig(String conversationId);
}

/// 群配置（对应 `group_configs` 表）。
///
/// 第 6 轮新增三字段（schema v4 → v5，additive）：
/// - [announcement]：群公告 / 共识（"建立本群共识"的载体；空 = 无）；
/// - [announcementUpdatedAt]：公告更新时间（UI 展示"最后更新"）；
/// - [maxSpeakersPerRound]：单轮发言者上限（防刷屏；null 由服务层兜底为 3）。
class GroupConfig {
  const GroupConfig({
    required this.conversationId,
    this.speakStrategy = 'auto',
    this.summarizerExpertId,
    this.contextWindow,
    this.maxRounds = 1,
    this.tokenBudget,
    this.duplicateThreshold = 0.82,
    this.topicThreshold = 0.02,
    this.announcement,
    this.announcementUpdatedAt,
    this.maxSpeakersPerRound,
  });

  final String conversationId;
  final String speakStrategy;
  final String? summarizerExpertId;
  final int? contextWindow;
  final int maxRounds;
  final int? tokenBudget;
  final double duplicateThreshold;
  final double topicThreshold;
  final String? announcement;
  final int? announcementUpdatedAt;
  final int? maxSpeakersPerRound;

  GroupConfig copyWith({
    String? speakStrategy,
    String? summarizerExpertId,
    int? maxRounds,
    int? tokenBudget,
    double? duplicateThreshold,
    double? topicThreshold,
    String? announcement,
    int? announcementUpdatedAt,
    int? maxSpeakersPerRound,
  }) =>
      GroupConfig(
        conversationId: conversationId,
        speakStrategy: speakStrategy ?? this.speakStrategy,
        summarizerExpertId: summarizerExpertId ?? this.summarizerExpertId,
        contextWindow: contextWindow,
        maxRounds: maxRounds ?? this.maxRounds,
        tokenBudget: tokenBudget ?? this.tokenBudget,
        duplicateThreshold: duplicateThreshold ?? this.duplicateThreshold,
        topicThreshold: topicThreshold ?? this.topicThreshold,
        announcement: announcement ?? this.announcement,
        announcementUpdatedAt: announcementUpdatedAt ?? this.announcementUpdatedAt,
        maxSpeakersPerRound: maxSpeakersPerRound ?? this.maxSpeakersPerRound,
      );
}

/// 消息仓储。
abstract interface class MessageRepository {
  Future<void> insertMessage(Message message);
  Future<void> updateMessage(Message message);
  Future<Message?> getMessage(String id);
  Future<List<Message>> listMessages(String conversationId, {int? limit, int? before});
  Future<void> insertCitation(String messageId, Citation citation);
  Future<List<Citation>> listCitations(String messageId);

  /// 删除消息（第 8 轮）。
  ///
  /// **服务层负责前置校验**（主理人铁律：仅 `senderType == user` 的消息可删，
  /// 专家消息一律不可删——否则 `generation_steps.output_message_id` 悬空）；
  /// 本方法为**数据层原语**：`DELETE FROM messages WHERE id = ?`。
  ///
  /// DB 层 `message_attachments` 与 `message_citations` 均声明
  /// `ON DELETE CASCADE`（schema v6）——但服务层仍会**显式**删附件行与物理文件
  /// （双保险，不依赖单一 FK；第 2 轮 FK 脆弱性教训）。
  Future<void> deleteMessage(String messageId);
}

/// 附件仓储（第 8 轮）。
///
/// **归属红线（架构 §4 / 共享约定 1）**：附件归属**只认 `message_id`**；
/// 物理文件是否删除由 [countByStoredPath]（**DB 登记计数**）决定，
/// **绝不扫盘**——任何文件系统扫描不得参与归属判定。
abstract interface class AttachmentRepository {
  /// 插入一条附件记录。
  Future<void> insertAttachment(Attachment a);

  /// 批量插入（发送阶段一次落库）。
  Future<void> insertAttachments(List<Attachment> list);

  /// 列出某消息的全部附件（按创建序）。
  Future<List<Attachment>> listAttachmentsByMessage(String messageId);

  /// **批量**列出多条消息的附件（**防 N+1**；消息流一次查全）。
  Future<List<Attachment>> listAttachmentsByMessages(List<String> messageIds);

  /// 按内容 sha256 查找既有附件（内容寻址去重：复用已存路径）。
  Future<Attachment?> findBySha256(String sha256);

  /// 该存储路径被 DB 登记引用的次数（排除 [excludeId] 自身）——物理文件 GC 依据。
  Future<int> countByStoredPath(String storedPath, {String? excludeId});

  /// 删除某消息的全部附件行（FK 级联之外的显式删；服务层调用）。
  Future<void> deleteByMessage(String messageId);
}

/// 生成运行仓储。
abstract interface class GenerationRepository {
  Future<void> upsertRun(GenerationRun run);
  Future<GenerationRun?> getRun(String id);
  Future<List<GenerationRun>> listRuns(String conversationId);

  Future<void> upsertStep(GenerationStep step);
  Future<List<GenerationStep>> listSteps(String runId);

  Future<void> appendEvent(GenerationEvent event);
  Future<List<GenerationEvent>> listEvents(String stepId);

  /// 启动恢复：把中断的 run/step 标记为 cancelled。
  Future<int> recoverInterrupted();
}

/// 知识库仓储。
abstract interface class KnowledgeRepository {
  Future<void> upsertBase(KnowledgeBase base);
  Future<KnowledgeBase?> getBase(String id);
  Future<List<KnowledgeBase>> listBases();
  Future<void> deleteBase(String id);

  Future<void> upsertDocument(KnowledgeDocument doc);
  Future<List<KnowledgeDocument>> listDocuments(String knowledgeBaseId);
  Future<KnowledgeDocument?> findDocumentByHash(String knowledgeBaseId, String fileHash);
  Future<void> deleteDocument(String id);

  Future<void> insertChunks(List<KnowledgeChunk> chunks);
  Future<List<KnowledgeChunk>> listChunks(String documentId);
  Future<KnowledgeChunk?> getChunk(String id);
  Future<void> deleteChunksByDocument(String documentId);

  Future<void> upsertEmbedding(ChunkEmbedding embedding);
  Future<List<ChunkEmbedding>> listEmbeddings(List<String> chunkIds);

  Future<void> upsertEmbeddingModel(EmbeddingModelProfile model);
  Future<List<EmbeddingModelProfile>> listEmbeddingModels();

  // —— 文件夹关联（第 4 轮新增；folder_id 为逻辑外键，无 DB 级约束）——

  /// 新增 / 更新关联文件夹登记行。
  Future<void> upsertFolder(KnowledgeBaseFolder folder);

  /// 按 id 读取单个关联文件夹（`planRescan` / `unlinkFolder` 入口）。
  Future<KnowledgeBaseFolder?> getFolder(String id);

  /// 列出某知识库的全部关联文件夹。
  Future<List<KnowledgeBaseFolder>> listFolders(String knowledgeBaseId);

  /// 删除关联登记行（**只删行**；文档的两种处置由 `FolderSyncService.unlinkFolder`
  /// 二选一语义负责，本方法绝不级联文档）。
  Future<void> deleteFolder(String id);

  /// 列出某关联文件夹名下的全部文档（`WHERE folder_id = ?`——归属判定的唯一依据）。
  Future<List<KnowledgeDocument>> listDocumentsByFolder(String folderId);

  /// 批量设置 / 清空文档的 folder_id（补绑回填填值；unlink keep 路径置 null）。
  /// **只 UPDATE folder_id，绝不删除任何行**（补绑"只增不删"铁律）。
  Future<void> assignDocumentsFolder(List<String> documentIds, String? folderId);

  /// 更新单个文档的 source_mtime（重扫后回填快速路径依据；逐个调用，批量由上层循环）。
  Future<void> updateSourceMtime(String documentId, int sourceMtime);
}

/// Provider 仓储。
abstract interface class ProviderRepository {
  Future<void> upsertProvider(ProviderProfile profile);
  Future<List<ProviderProfile>> listProviders();
  Future<ProviderProfile?> getProvider(String id);

  Future<void> upsertModel(ModelProfile profile);
  Future<List<ModelProfile>> listModels({String? providerProfileId});
  Future<ModelProfile?> getModel(String id);
}

/// 凭据仓储（只存 secretRef，**不存明文**）。
abstract interface class CredentialRepository {
  Future<void> upsert(CredentialProfile profile);
  Future<List<CredentialProfile>> list();
  Future<CredentialProfile?> get(String id);
  Future<void> delete(String id);
}

/// Secret 存储端口（OS Secure Storage 实现）。
abstract interface class SecretStore {
  Future<void> write(String ref, String secret);
  Future<String?> read(String ref);
  Future<void> delete(String ref);
  Future<bool> contains(String ref);
}

/// 市场仓储。
abstract interface class MarketRepository {
  Future<void> upsertSource(MarketSource source);
  Future<List<MarketSource>> listSources();

  Future<void> replacePackages(String sourceId, List<MarketPackage> packages);
  Future<List<MarketPackage>> listPackages({String? sourceId, String? categoryId});
  Future<MarketPackage?> getPackage(String packageId);

  Future<void> upsertInstalled(InstalledPackage pkg);
  Future<List<InstalledPackage>> listInstalled();
  Future<InstalledPackage?> getInstalledByPackageId(String packageId);
  Future<void> deleteInstalled(String installationId);

  /// 按 `packageId` 删除**全部**已安装记录（第 #80 轮新增，**additive**）。
  ///
  /// 用途有二：
  /// 1. **卸载语义**：删除市场来源专家、且已无其他专家引用该包时，`ExpertService.delete`
  ///    调用本方法清掉 `installed_packages`——否则市场页永久显示「已添加」且无法重装；
  /// 2. **安装幂等**：`installFromPackage` 写 `InstalledPackage` 前先调本方法，保证同一
  ///    `package_id` 在 `installed_packages` 中**最多 1 行**（走应用层去重，**不加 UNIQUE
  ///    索引**——存量库可能已有重复行，加索引会失败）。
  ///
  /// 无匹配行时**静默 no-op**（幂等）。
  Future<void> deleteInstalledByPackageId(String packageId);

  Future<void> setIndexEtag(String sourceId, String? etag, int refreshedAt);
  Future<({String? etag, int? refreshedAt})?> getIndexEtag(String sourceId);
}

/// 设置仓储（键值）。
abstract interface class SettingsRepository {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// Job 仓储。
abstract interface class JobRepository {
  Future<void> upsert(JobRecord job);
  Future<JobRecord?> get(String id);
  Future<List<JobRecord>> list({String? type, String? status});
}

/// Job 记录。
class JobRecord {
  const JobRecord({
    required this.id,
    required this.type,
    this.status = 'queued',
    this.progress = 0,
    this.retryCount = 0,
    this.payloadJson,
    this.errorCode,
    this.errorMessage,
    required this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String type;
  final String status;
  final double progress;
  final int retryCount;
  final String? payloadJson;
  final String? errorCode;
  final String? errorMessage;
  final int createdAt;
  final int? startedAt;
  final int? finishedAt;
}

/// 仓储聚合（应用服务统一依赖它，便于注入内存实现做测试）。
class Repositories {
  const Repositories({
    required this.experts,
    required this.groups,
    required this.conversations,
    required this.messages,
    required this.generations,
    required this.knowledge,
    required this.providers,
    required this.credentials,
    required this.secrets,
    required this.market,
    required this.settings,
    required this.jobs,
    required this.attachments,
  });

  final ExpertRepository experts;

  /// 通讯录分组（第 3 轮新增）。
  final GroupRepository groups;

  final ConversationRepository conversations;
  final MessageRepository messages;
  final GenerationRepository generations;
  final KnowledgeRepository knowledge;
  final ProviderRepository providers;
  final CredentialRepository credentials;
  final SecretStore secrets;
  final MarketRepository market;
  final SettingsRepository settings;
  final JobRepository jobs;

  /// 会话附件（第 8 轮新增）。
  final AttachmentRepository attachments;
}

/// 设置键常量。
abstract final class SettingKeys {
  static const defaultModelProfileId = 'default.modelProfileId';
  static const defaultCredentialProfileId = 'default.credentialProfileId';
  static const defaultGroundingPolicy = 'default.groundingPolicy';
  static const activeProviderProfileId = 'active.providerProfileId';
  static const embeddingModelId = 'knowledge.embeddingModelId';
  static const appVersion = 'app.version';
}
