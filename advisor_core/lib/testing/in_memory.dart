/// 内存实现（测试替身）。
///
/// 用途：
/// 1. `tool/verify.dart` 中真实跑通核心链路；
/// 2. 用户在自己机器上写单元测试时直接复用。
///
/// 注意：本文件不依赖 Flutter / SQLite，纯 Dart 即可运行。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../application/repositories.dart';
import '../domain/attachment.dart';
import '../domain/common.dart';
import '../domain/conversation.dart';
import '../domain/expert.dart';
import '../domain/expert_group.dart';
import '../domain/generation.dart';
import '../domain/knowledge.dart';
import '../domain/market.dart';
import '../domain/provider.dart';
import '../domain/text_index.dart';

/// `PlainTextParser` 已迁入生产代码 `parsers/plain_text_parser.dart`；
/// 此处 **re-export** 以兼容既有 `import 'package:advisor_core/testing/in_memory.dart'`
/// 的调用点（生产/验证共用同一实现）。
export '../parsers/plain_text_parser.dart' show PlainTextParser;

// ---------------------------------------------------------------------------
// 仓储
// ---------------------------------------------------------------------------

class InMemoryExpertRepository implements ExpertRepository {
  final Map<String, Expert> experts = {};
  final Map<String, ExpertRuntimeConfig> configs = {};
  final Map<String, ExpertUserState> states = {};
  final Map<String, Set<String>> tags = {};
  final Map<String, ExpertKnowledgeBinding> bindings = {};

  @override
  Future<void> upsertExpert(Expert expert) async => experts[expert.id] = expert;

  @override
  Future<Expert?> getExpert(String id) async => experts[id];

  @override
  Future<List<Expert>> listExperts() async => experts.values.toList();

  @override
  Future<void> deleteExpert(String id) async {
    experts.remove(id);
    configs.remove(id);
    states.remove(id);
    tags.remove(id);
    bindings.removeWhere((k, _) => k.startsWith('$id::'));
  }

  @override
  Future<void> upsertRuntimeConfig(ExpertRuntimeConfig config) async =>
      configs[config.expertId] = config;

  @override
  Future<ExpertRuntimeConfig?> getRuntimeConfig(String expertId) async => configs[expertId];

  @override
  Future<void> upsertUserState(ExpertUserState state) async => states[state.expertId] = state;

  @override
  Future<ExpertUserState?> getUserState(String expertId) async => states[expertId];

  @override
  Future<void> setTags(String expertId, List<String> tagNames) async =>
      tags[expertId] = tagNames.toSet();

  @override
  Future<List<String>> getTags(String expertId) async => tags[expertId]?.toList() ?? const [];

  @override
  Future<void> upsertKnowledgeBinding(ExpertKnowledgeBinding binding) async =>
      bindings['${binding.expertId}::${binding.knowledgeBaseId}'] = binding;

  @override
  Future<void> removeKnowledgeBinding(String expertId, String knowledgeBaseId) async =>
      bindings.remove('$expertId::$knowledgeBaseId');

  @override
  Future<List<ExpertKnowledgeBinding>> listKnowledgeBindings(String expertId) async =>
      bindings.values.where((b) => b.expertId == expertId).toList();
}

class InMemoryConversationRepository implements ConversationRepository {
  InMemoryConversationRepository({this.messages});

  /// 消息仓储（由 `inMemoryRepositories()` 注入）。
  ///
  /// `clearMessages` / 级联删除需要跨仓储清消息——与 SQLite 版"FK 级联"
  /// 语义对齐：内存侧用同一对象直清（**不新造第二份消息状态**）。
  final InMemoryMessageRepository? messages;

  final Map<String, Conversation> conversations = {};
  final Map<String, Map<String, ConversationMember>> members = {};
  final Map<String, GroupConfig> groupConfigs = {};

  @override
  Future<void> upsertConversation(Conversation conversation) async =>
      conversations[conversation.id] = conversation;

  @override
  Future<Conversation?> getConversation(String id) async => conversations[id];

  @override
  Future<List<Conversation>> listConversations() async {
    final list = conversations.values.toList();
    // 与 SQLite 版同口径：置顶优先 → lastMessageAt 倒序。
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return (b.lastMessageAt ?? 0).compareTo(a.lastMessageAt ?? 0);
    });
    return list;
  }

  @override
  Future<void> deleteConversation(String id) async {
    conversations.remove(id);
    members.remove(id);
    groupConfigs.remove(id);
    // 模拟 DB 外键级联：消息（及其引用行）随会话一并消失。
    messages?.removeByConversation(id);
  }

  @override
  Future<void> setConversationPinned(String conversationId, bool pinned) async {
    final conv = conversations[conversationId];
    if (conv == null) return; // 会话不存在 → 静默 no-op（存在性校验在服务层）。
    conversations[conversationId] = conv.copyWith(pinned: pinned);
  }

  @override
  Future<void> clearMessages(String conversationId) async {
    // 只清消息（会话本身保留）；子表语义 = 直清消息 map（含引用行）。
    messages?.removeByConversation(conversationId);
  }

  @override
  Future<void> upsertMember(ConversationMember member) async {
    members.putIfAbsent(member.conversationId, () => {})[member.expertId] = member;
  }

  @override
  Future<void> removeMember(String conversationId, String expertId) async =>
      members[conversationId]?.remove(expertId);

  @override
  Future<List<ConversationMember>> listMembers(String conversationId) async {
    final list = members[conversationId]?.values.toList() ?? [];
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  @override
  Future<void> upsertGroupConfig(GroupConfig config) async =>
      groupConfigs[config.conversationId] = config;

  @override
  Future<GroupConfig?> getGroupConfig(String conversationId) async =>
      groupConfigs[conversationId];
}

class InMemoryMessageRepository implements MessageRepository {
  final Map<String, Message> messages = {};
  final Map<String, List<Citation>> citations = {};

  @override
  Future<void> insertMessage(Message message) async => messages[message.id] = message;

  @override
  Future<void> updateMessage(Message message) async => messages[message.id] = message;

  @override
  Future<Message?> getMessage(String id) async => messages[id];

  @override
  Future<List<Message>> listMessages(String conversationId, {int? limit, int? before}) async {
    var list = messages.values.where((m) => m.conversationId == conversationId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (before != null) list = list.where((m) => m.createdAt < before).toList();
    if (limit != null && list.length > limit) list = list.sublist(list.length - limit);
    return list;
  }

  @override
  Future<void> insertCitation(String messageId, Citation citation) async =>
      citations.putIfAbsent(messageId, () => []).add(citation);

  @override
  Future<List<Citation>> listCitations(String messageId) async => citations[messageId] ?? const [];

  @override
  Future<void> deleteMessage(String messageId) async {
    messages.remove(messageId);
    citations.remove(messageId);
  }

  /// 清空某会话的全部消息（含引用行；模拟 DB `ON DELETE CASCADE`）。
  ///
  /// 供 [InMemoryConversationRepository.clearMessages] 与
  /// `deleteConversation` 的级联语义使用（内存侧等价于 SQL 子表直查）。
  void removeByConversation(String conversationId) {
    final ids = messages.entries
        .where((e) => e.value.conversationId == conversationId)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      messages.remove(id);
      citations.remove(id);
    }
  }
}

/// 内存附件仓储（第 8 轮）。
class InMemoryAttachmentRepository implements AttachmentRepository {
  final Map<String, Attachment> rows = {};

  @override
  Future<void> insertAttachment(Attachment a) async => rows[a.id] = a;

  @override
  Future<void> insertAttachments(List<Attachment> list) async {
    for (final a in list) {
      rows[a.id] = a;
    }
  }

  @override
  Future<List<Attachment>> listAttachmentsByMessage(String messageId) async => _sorted(
      rows.values.where((a) => a.messageId == messageId));

  @override
  Future<List<Attachment>> listAttachmentsByMessages(List<String> messageIds) async {
    final want = messageIds.toSet();
    return _sorted(rows.values.where((a) => want.contains(a.messageId)));
  }

  @override
  Future<Attachment?> findBySha256(String sha256) async {
    final hits = _sorted(rows.values.where((a) => a.sha256 == sha256));
    return hits.isEmpty ? null : hits.first;
  }

  @override
  Future<int> countByStoredPath(String storedPath, {String? excludeId}) async => rows.values
      .where((a) => a.storedPath == storedPath && a.id != excludeId)
      .length;

  @override
  Future<void> deleteByMessage(String messageId) async =>
      rows.removeWhere((_, a) => a.messageId == messageId);

  List<Attachment> _sorted(Iterable<Attachment> it) => it.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}

class InMemoryGenerationRepository implements GenerationRepository {
  final Map<String, GenerationRun> runs = {};
  final Map<String, GenerationStep> steps = {};
  final List<GenerationEvent> events = [];

  @override
  Future<void> upsertRun(GenerationRun run) async => runs[run.id] = run;

  @override
  Future<GenerationRun?> getRun(String id) async => runs[id];

  @override
  Future<List<GenerationRun>> listRuns(String conversationId) async =>
      runs.values.where((r) => r.conversationId == conversationId).toList();

  @override
  Future<void> upsertStep(GenerationStep step) async => steps[step.id] = step;

  @override
  Future<List<GenerationStep>> listSteps(String runId) async {
    final list = steps.values.where((s) => s.runId == runId).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return list;
  }

  @override
  Future<void> appendEvent(GenerationEvent event) async => events.add(event);

  @override
  Future<List<GenerationEvent>> listEvents(String stepId) async =>
      events.where((e) => e.stepId == stepId).toList();

  @override
  Future<int> recoverInterrupted() async {
    var n = 0;
    for (final entry in runs.entries.toList()) {
      if (entry.value.status == RunStatus.running) {
        runs[entry.key] = entry.value.copyWith(
          status: RunStatus.cancelled,
          endedAt: DateTime.now().millisecondsSinceEpoch,
        );
        n++;
      }
    }
    for (final entry in steps.entries.toList()) {
      if (entry.value.status == RunStatus.running) {
        steps[entry.key] = entry.value.copyWith(
          status: RunStatus.cancelled,
          endedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
    return n;
  }
}

class InMemoryKnowledgeRepository implements KnowledgeRepository {
  final Map<String, KnowledgeBase> bases = {};
  final Map<String, KnowledgeDocument> documents = {};
  final Map<String, KnowledgeChunk> chunks = {};
  final Map<String, ChunkEmbedding> embeddings = {};
  final Map<String, EmbeddingModelProfile> embeddingModels = {};

  /// 关联文件夹登记（第 4 轮）。
  final Map<String, KnowledgeBaseFolder> folders = {};

  @override
  Future<void> upsertBase(KnowledgeBase base) async => bases[base.id] = base;

  @override
  Future<KnowledgeBase?> getBase(String id) async => bases[id];

  @override
  Future<List<KnowledgeBase>> listBases() async => bases.values.toList();

  @override
  Future<void> deleteBase(String id) async => bases.remove(id);

  @override
  Future<void> upsertDocument(KnowledgeDocument doc) async => documents[doc.id] = doc;

  @override
  Future<List<KnowledgeDocument>> listDocuments(String knowledgeBaseId) async =>
      documents.values.where((d) => d.knowledgeBaseId == knowledgeBaseId).toList();

  @override
  Future<KnowledgeDocument?> findDocumentByHash(String knowledgeBaseId, String fileHash) async {
    for (final d in documents.values) {
      if (d.knowledgeBaseId == knowledgeBaseId && d.fileHash == fileHash) return d;
    }
    return null;
  }

  @override
  Future<void> deleteDocument(String id) async => documents.remove(id);

  @override
  Future<void> insertChunks(List<KnowledgeChunk> list) async {
    for (final c in list) {
      chunks[c.id] = c;
    }
  }

  @override
  Future<List<KnowledgeChunk>> listChunks(String documentId) async {
    final list = chunks.values.where((c) => c.documentId == documentId).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return list;
  }

  @override
  Future<KnowledgeChunk?> getChunk(String id) async => chunks[id];

  @override
  Future<void> deleteChunksByDocument(String documentId) async =>
      chunks.removeWhere((_, c) => c.documentId == documentId);

  @override
  Future<void> upsertEmbedding(ChunkEmbedding embedding) async =>
      embeddings['${embedding.chunkId}::${embedding.embeddingModelId}'] = embedding;

  @override
  Future<List<ChunkEmbedding>> listEmbeddings(List<String> chunkIds) async => embeddings.values
      .where((e) => chunkIds.contains(e.chunkId))
      .toList();

  @override
  Future<void> upsertEmbeddingModel(EmbeddingModelProfile model) async =>
      embeddingModels[model.id] = model;

  @override
  Future<List<EmbeddingModelProfile>> listEmbeddingModels() async =>
      embeddingModels.values.toList();

  // —— 文件夹关联（第 4 轮）——

  @override
  Future<void> upsertFolder(KnowledgeBaseFolder folder) async => folders[folder.id] = folder;

  @override
  Future<KnowledgeBaseFolder?> getFolder(String id) async => folders[id];

  @override
  Future<List<KnowledgeBaseFolder>> listFolders(String knowledgeBaseId) async {
    final list = folders.values.where((f) => f.knowledgeBaseId == knowledgeBaseId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<void> deleteFolder(String id) async => folders.remove(id);

  @override
  Future<List<KnowledgeDocument>> listDocumentsByFolder(String folderId) async =>
      documents.values.where((d) => d.folderId == folderId).toList();

  @override
  Future<void> assignDocumentsFolder(List<String> documentIds, String? folderId) async {
    for (final id in documentIds) {
      final doc = documents[id];
      if (doc == null) continue;
      documents[id] = KnowledgeDocument(
        id: doc.id,
        knowledgeBaseId: doc.knowledgeBaseId,
        fileName: doc.fileName,
        filePath: doc.filePath,
        fileHash: doc.fileHash,
        fileSize: doc.fileSize,
        mimeType: doc.mimeType,
        parser: doc.parser,
        parserVersion: doc.parserVersion,
        status: doc.status,
        pageCount: doc.pageCount,
        folderId: folderId,
        sourceMtime: doc.sourceMtime,
        createdAt: doc.createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  @override
  Future<void> updateSourceMtime(String documentId, int sourceMtime) async {
    final doc = documents[documentId];
    if (doc == null) return;
    documents[documentId] = KnowledgeDocument(
      id: doc.id,
      knowledgeBaseId: doc.knowledgeBaseId,
      fileName: doc.fileName,
      filePath: doc.filePath,
      fileHash: doc.fileHash,
      fileSize: doc.fileSize,
      mimeType: doc.mimeType,
      parser: doc.parser,
      parserVersion: doc.parserVersion,
      status: doc.status,
      pageCount: doc.pageCount,
      folderId: doc.folderId,
      sourceMtime: sourceMtime,
      createdAt: doc.createdAt,
      updatedAt: doc.updatedAt,
    );
  }
}

class InMemoryProviderRepository implements ProviderRepository {
  final Map<String, ProviderProfile> providers = {};
  final Map<String, ModelProfile> models = {};

  @override
  Future<void> upsertProvider(ProviderProfile profile) async => providers[profile.id] = profile;

  @override
  Future<List<ProviderProfile>> listProviders() async => providers.values.toList();

  @override
  Future<ProviderProfile?> getProvider(String id) async => providers[id];

  @override
  Future<void> upsertModel(ModelProfile profile) async => models[profile.id] = profile;

  @override
  Future<List<ModelProfile>> listModels({String? providerProfileId}) async => models.values
      .where((m) => providerProfileId == null || m.providerProfileId == providerProfileId)
      .toList();

  @override
  Future<ModelProfile?> getModel(String id) async => models[id];
}

class InMemoryCredentialRepository implements CredentialRepository {
  final Map<String, CredentialProfile> profiles = {};

  @override
  Future<void> upsert(CredentialProfile profile) async => profiles[profile.id] = profile;

  @override
  Future<List<CredentialProfile>> list() async => profiles.values.toList();

  @override
  Future<CredentialProfile?> get(String id) async => profiles[id];

  @override
  Future<void> delete(String id) async => profiles.remove(id);
}

class InMemorySecretStore implements SecretStore {
  final Map<String, String> secrets = {};

  @override
  Future<void> write(String ref, String secret) async => secrets[ref] = secret;

  @override
  Future<String?> read(String ref) async => secrets[ref];

  @override
  Future<void> delete(String ref) async => secrets.remove(ref);

  @override
  Future<bool> contains(String ref) async => secrets.containsKey(ref);
}

class InMemoryMarketRepository implements MarketRepository {
  final Map<String, MarketSource> sources = {};
  final Map<String, MarketPackage> packages = {};

  /// `sourceId → 该源当前拥有的 packageId 集合`（用于按 source 作用域替换）。
  final Map<String, Set<String>> sourcePackages = {};
  final Map<String, InstalledPackage> installed = {};
  final Map<String, ({String? etag, int? refreshedAt})> etags = {};

  @override
  Future<void> upsertSource(MarketSource source) async => sources[source.id] = source;

  @override
  Future<List<MarketSource>> listSources() async => sources.values.toList();

  @override
  Future<void> replacePackages(String sourceId, List<MarketPackage> list) async {
    // 与 SQLite 版语义一致：**按 source_id 作用域**替换，不影响其他源。
    final previous = sourcePackages[sourceId] ?? const <String>{};
    for (final id in previous) {
      packages.remove(id);
    }
    final ids = <String>{};
    for (final p in list) {
      packages[p.packageId] = p;
      ids.add(p.packageId);
    }
    sourcePackages[sourceId] = ids;
  }

  @override
  Future<List<MarketPackage>> listPackages({String? sourceId, String? categoryId}) async {
    final ids = sourceId == null ? null : sourcePackages[sourceId];
    return packages.values.where((p) {
      if (sourceId != null && (ids == null || !ids.contains(p.packageId))) return false;
      if (categoryId != null && p.categoryId != categoryId) return false;
      return true;
    }).toList();
  }

  @override
  Future<MarketPackage?> getPackage(String packageId) async => packages[packageId];

  @override
  Future<void> upsertInstalled(InstalledPackage pkg) async =>
      installed[pkg.installationId] = pkg;

  @override
  Future<List<InstalledPackage>> listInstalled() async => installed.values.toList();

  @override
  Future<InstalledPackage?> getInstalledByPackageId(String packageId) async {
    for (final i in installed.values) {
      if (i.packageId == packageId) return i;
    }
    return null;
  }

  @override
  Future<void> deleteInstalled(String installationId) async => installed.remove(installationId);

  @override
  Future<void> deleteInstalledByPackageId(String packageId) async =>
      installed.removeWhere((_, i) => i.packageId == packageId);

  @override
  Future<void> setIndexEtag(String sourceId, String? etag, int refreshedAt) async =>
      etags[sourceId] = (etag: etag, refreshedAt: refreshedAt);

  @override
  Future<({String? etag, int? refreshedAt})?> getIndexEtag(String sourceId) async =>
      etags[sourceId];
}

class InMemorySettingsRepository implements SettingsRepository {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

class InMemoryJobRepository implements JobRepository {
  final Map<String, JobRecord> jobs = {};

  @override
  Future<void> upsert(JobRecord job) async => jobs[job.id] = job;

  @override
  Future<JobRecord?> get(String id) async => jobs[id];

  @override
  Future<List<JobRecord>> list({String? type, String? status}) async => jobs.values
      .where((j) => (type == null || j.type == type) && (status == null || j.status == status))
      .toList();
}

/// 分组仓储内存实现。
class InMemoryGroupRepository implements GroupRepository {
  final Map<String, ExpertGroup> groups = {};

  @override
  Future<void> upsertGroup(ExpertGroup group) async => groups[group.id] = group;

  @override
  Future<ExpertGroup?> getGroup(String id) async => groups[id];

  @override
  Future<List<ExpertGroup>> listGroups() async {
    final list = groups.values.toList()
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.createdAt.compareTo(b.createdAt);
      });
    return list;
  }

  @override
  Future<void> deleteGroup(String id) async => groups.remove(id);
}

/// 组装一套内存仓储。
///
/// `messages` 先单独构造再注入 [InMemoryConversationRepository]——内存侧
/// 没有 DB 外键，级联语义（删会话带走消息 / 清空消息）靠同一对象直清实现。
Repositories inMemoryRepositories() {
  final messages = InMemoryMessageRepository();
  return Repositories(
    experts: InMemoryExpertRepository(),
    groups: InMemoryGroupRepository(),
    conversations: InMemoryConversationRepository(messages: messages),
    messages: messages,
    generations: InMemoryGenerationRepository(),
    knowledge: InMemoryKnowledgeRepository(),
    providers: InMemoryProviderRepository(),
    credentials: InMemoryCredentialRepository(),
    secrets: InMemorySecretStore(),
    market: InMemoryMarketRepository(),
    settings: InMemorySettingsRepository(),
    jobs: InMemoryJobRepository(),
    attachments: InMemoryAttachmentRepository(),
  );
}

// ---------------------------------------------------------------------------
// 知识运行时替身
// ---------------------------------------------------------------------------

/// 简单分块器：按目标 token 合并 block，超长则二次切分。
class SimpleChunker implements Chunker {
  SimpleChunker({this.targetTokens = 320, this.overlapTokens = 40});

  @override
  String get name => 'simple-chunker';

  @override
  final int targetTokens;

  final int overlapTokens;

  @override
  List<KnowledgeChunk> chunk(String documentId, ParsedDocument doc) {
    final out = <KnowledgeChunk>[];
    var seq = 0;
    final buf = StringBuffer();
    String? currentHeading;
    int? currentPage;

    void emit() {
      final text = buf.toString().trim();
      if (text.isEmpty) return;
      out.add(KnowledgeChunk(
        id: '${documentId}_c${seq.toString().padLeft(4, '0')}',
        documentId: documentId,
        text: text,
        headingPath: currentHeading,
        page: currentPage,
        sequence: seq,
        tokenCount: KnowledgeChunk.estimateTokens(text),
        chunkHash: sha256.convert(utf8.encode(text)).toString(),
      ));
      seq++;
      buf.clear();
    }

    for (final b in doc.blocks) {
      final tokens = KnowledgeChunk.estimateTokens(b.text);
      if (tokens > targetTokens) {
        emit();
        for (final part in _splitLong(b.text, targetTokens)) {
          buf.write(part);
          currentHeading = b.headingPath;
          currentPage = b.page;
          emit();
        }
        continue;
      }
      if (KnowledgeChunk.estimateTokens(buf.toString()) + tokens > targetTokens) {
        emit();
      }
      currentHeading = b.headingPath ?? currentHeading;
      currentPage = b.page ?? currentPage;
      buf.writeln(b.text);
    }
    emit();
    return out;
  }

  Iterable<String> _splitLong(String text, int target) sync* {
    final charsPerChunk = target * 2;
    for (var i = 0; i < text.length; i += charsPerChunk) {
      yield text.substring(i, math.min(i + charsPerChunk, text.length));
    }
  }
}

/// 本地哈希 embedding（无需模型文件，确定性，适合验证与离线兜底）。
///
/// 真实实现是 ONNX bge-small-zh；此处用字符 bigram 哈希到固定维度并归一化，
/// 余弦相似度对"关键词重合"有良好区分度。
class HashEmbeddingModel implements EmbeddingModel {
  HashEmbeddingModel({this.dimension = 256});

  @override
  final int dimension;

  @override
  String get modelId => 'emb_hash_$dimension';

  @override
  Future<void> warmUp() async {}

  @override
  Future<List<List<double>>> embed(List<String> texts) async =>
      texts.map(_embedOne).toList();

  List<double> _embedOne(String text) {
    final v = List<double>.filled(dimension, 0);
    final grams = _grams(text);
    for (final g in grams) {
      final h = _fnv1a(g);
      v[h % dimension] += 1;
      v[(h >> 8) % dimension] += 0.5;
    }
    final norm = math.sqrt(v.fold<double>(0, (a, b) => a + b * b));
    if (norm > 0) {
      for (var i = 0; i < dimension; i++) {
        v[i] /= norm;
      }
    }
    return v;
  }

  Set<String> _grams(String text) {
    final out = <String>{};
    final cjk = <String>[];
    final buf = StringBuffer();
    for (final r in text.toLowerCase().runes) {
      final ch = String.fromCharCode(r);
      if (r >= 0x4E00 && r <= 0x9FFF) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        cjk.add(ch);
      } else if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
        buf.write(ch);
      } else {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    for (var i = 0; i + 1 < cjk.length; i++) {
      out.add('${cjk[i]}${cjk[i + 1]}');
    }
    out.removeWhere((e) => e.isEmpty);
    return out;
  }

  int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }
}

/// 内存向量库（余弦相似度）。
class InMemoryVectorStore implements VectorStore {
  InMemoryVectorStore(this._knowledge);

  final KnowledgeRepository _knowledge;
  final Map<String, ({List<double> vector, String kbId, String docId})> _index = {};

  @override
  Future<void> upsert(
    List<KnowledgeChunk> chunks,
    List<List<double>> vectors,
    String modelId,
  ) async {
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      final doc = await _findDoc(c.documentId);
      _index[c.id] = (
        vector: vectors[i],
        kbId: doc?.knowledgeBaseId ?? '',
        docId: c.documentId,
      );
    }
  }

  Future<KnowledgeDocument?> _findDoc(String docId) async {
    for (final kb in await _knowledge.listBases()) {
      for (final d in await _knowledge.listDocuments(kb.id)) {
        if (d.id == docId) return d;
      }
    }
    return null;
  }

  @override
  Future<List<RetrievalHit>> search(
    List<double> queryVector, {
    required List<String> knowledgeBaseIds,
    int topK = 5,
    double threshold = 0.75,
  }) async {
    final scored = <({String chunkId, double score})>[];
    for (final entry in _index.entries) {
      if (!knowledgeBaseIds.contains(entry.value.kbId)) continue;
      scored.add((chunkId: entry.key, score: _cosine(queryVector, entry.value.vector)));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final hits = <RetrievalHit>[];
    for (final s in scored.take(topK)) {
      if (s.score < threshold) continue;
      final chunk = await _knowledge.getChunk(s.chunkId);
      if (chunk == null) continue;
      final doc = await _findDoc(chunk.documentId);
      hits.add(RetrievalHit(
        chunk: chunk,
        score: s.score,
        citation: Citation(
          chunkId: chunk.id,
          documentId: chunk.documentId,
          fileName: doc?.fileName ?? '未知文件',
          text: chunk.text,
          score: s.score,
          page: chunk.page,
          headingPath: chunk.headingPath,
        ),
      ));
    }
    return hits;
  }

  static double _cosine(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  @override
  Future<void> deleteByDocument(String documentId) async =>
      _index.removeWhere((_, v) => v.docId == documentId);

  @override
  Future<void> deleteByKnowledgeBase(String knowledgeBaseId) async =>
      _index.removeWhere((_, v) => v.kbId == knowledgeBaseId);

  @override
  Future<void> rebuild(String knowledgeBaseId) async {}

  @override
  Future<bool> health() async => true;
}

// ---------------------------------------------------------------------------
// 关键词检索替身（与 Fts5Retriever 语义对齐）
// ---------------------------------------------------------------------------

/// 内存检索替身：用 [ChineseBigram] 做 bigram 召回 + coverage 过滤。
///
/// 与 `Fts5Retriever` **语义一致**（同一分词器、同一 OR 召回、同一 coverage 阈值），
/// 供 `advisor_core` 侧在无 SQLite 环境下自证 / 单测使用。
class InMemoryRetriever implements Retriever {  InMemoryRetriever(this._knowledge);

  final KnowledgeRepository _knowledge;

  /// chunkId → 索引项（所属知识库 / 文档 / 预分词集合 / 原始块）。
  final Map<
      String,
      ({String kbId, String docId, Set<String> tokens, KnowledgeChunk chunk})>
      _index = {};

  @override
  Future<void> indexChunks(
    List<KnowledgeChunk> chunks, {
    required String knowledgeBaseId,
    required String documentId,
  }) async {
    for (final c in chunks) {
      _index[c.id] = (
        kbId: knowledgeBaseId,
        docId: documentId,
        tokens: ChineseBigram.tokenize(c.text).toSet(),
        chunk: c,
      );
    }
  }

  @override
  Future<void> deleteByDocument(String documentId) async =>
      _index.removeWhere((_, v) => v.docId == documentId);

  @override
  Future<void> deleteByKnowledgeBase(String knowledgeBaseId) async =>
      _index.removeWhere((_, v) => v.kbId == knowledgeBaseId);

  @override
  Future<List<RetrievalHit>> search(
    String query, {
    required List<String> knowledgeBaseIds,
    int topK = 5,
    double threshold = 0.0,
  }) async {
    final q = ChineseBigram.tokenize(query).toSet();
    if (q.isEmpty || knowledgeBaseIds.isEmpty) return const [];

    final scored = <({String chunkId, double cov})>[];
    for (final e in _index.entries) {
      if (!knowledgeBaseIds.contains(e.value.kbId)) continue;
      final cov = ChineseBigram.coverage(q, e.value.tokens);
      if (cov <= 0) continue;
      scored.add((chunkId: e.key, cov: cov));
    }
    scored.sort((a, b) => b.cov.compareTo(a.cov));

    final out = <RetrievalHit>[];
    for (final s in scored) {
      if (s.cov + 1e-9 < threshold) continue;
      final entry = _index[s.chunkId]!;
      final doc = await _findDoc(entry.docId);
      out.add(RetrievalHit(
        chunk: entry.chunk,
        score: s.cov,
        citation: Citation(
          chunkId: entry.chunk.id,
          documentId: entry.chunk.documentId,
          fileName: doc?.fileName ?? '未知文件',
          text: entry.chunk.text,
          score: s.cov,
          page: entry.chunk.page,
          headingPath: entry.chunk.headingPath,
        ),
      ));
      if (out.length >= topK) break;
    }
    return out;
  }

  Future<KnowledgeDocument?> _findDoc(String docId) async {
    for (final kb in await _knowledge.listBases()) {
      for (final d in await _knowledge.listDocuments(kb.id)) {
        if (d.id == docId) return d;
      }
    }
    return null;
  }

  @override
  Future<void> rebuild(String knowledgeBaseId) async {
    // 内存实现无持久索引，重建为空操作。
  }

  @override
  Future<bool> health() async => true;
}

/// 脚本化 LLM：按顺序返回预设回答；可注入错误以验证错误路径。
class ScriptedLlmProvider implements LlmProvider {
  ScriptedLlmProvider({
    this.providerId = 'pp_deepseek',
    List<String>? replies,
    this.error,
    this.chunkSize = 8,
  }) : replies = replies ?? ['（脚本回答）好的，这是基于你提供信息的回答。'];

  @override
  final String providerId;

  final List<String> replies;

  /// 非空则第 [failAtCall] 次调用抛出该错误。
  final AppError? error;
  int failAtCall = -1;

  final int chunkSize;

  /// 记录每次请求，便于断言"strict 无命中时未调用 LLM"。
  final List<ChatRequest> calls = [];

  int _replyIndex = 0;

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      const [ModelDescriptor(modelId: 'deepseek-chat')];

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    calls.add(request);
    if (error != null && calls.length - 1 == failAtCall) throw error!;
    final text = replies[_replyIndex++ % replies.length];
    return ChatResponse(
      content: text,
      promptTokens: KnowledgeChunk.estimateTokens(
        request.messages.map((m) => m.content).join('\n'),
      ),
      completionTokens: KnowledgeChunk.estimateTokens(text),
    );
  }

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    calls.add(request);
    if (error != null && calls.length - 1 == failAtCall) {
      yield StreamErrorEvent(error!);
      return;
    }
    final text = replies[_replyIndex++ % replies.length];
    for (var i = 0; i < text.length; i += chunkSize) {
      yield TokenDelta(text.substring(i, math.min(i + chunkSize, text.length)));
      await Future<void>.delayed(Duration.zero);
    }
    yield UsageEvent(
      KnowledgeChunk.estimateTokens(request.messages.map((m) => m.content).join('\n')),
      KnowledgeChunk.estimateTokens(text),
    );
    yield const StreamDone();
  }

  @override
  Future<ProviderHealth> healthCheck() async =>
      const ProviderHealth(health: Health.healthy, latencyMs: 12);

  @override
  AppError mapError(Object raw) => raw is AppError ? raw : ProviderServerError('$raw');
}
