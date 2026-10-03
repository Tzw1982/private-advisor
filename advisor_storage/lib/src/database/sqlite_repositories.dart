/// SQLite 仓储实现（raw SQL，无代码生成）——存量 8 个仓储。
///
/// 迁移自 `app/lib/infrastructure/database/sqlite_repositories.dart`（逻辑不变，
/// 仅把文件"搬家"到纯 Dart 存储包，并复用 `support.dart` 的通用工具与类型转换）。
///
/// DDL 见同目录 `schema.sql`（canonical）。V1.3 §26 推荐 Drift；本项目改用
/// `sqlite3` + 手写映射，原因是避免 build_runner 代码生成，让"克隆即可编译"，
/// DDL 与契约文档逐字对应。
///
/// **错误归一化（TD-1）**：本文件所有公开方法经文件内 [_guard] 包裹，把底层
/// `SqliteException` 归一化为 [StorageError]（`storage.<area>.<method>`），
/// 与 `sqlite_market_repository.dart` / `sqlite_knowledge_repository.dart`
/// 的既有写法一致——**不向 UI 泄漏裸 `SqliteException`**。已是 [AppError]
/// （含 [StorageError]）的异常**原样透传**，保证"只归一化一次"。
library;

import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

/// 执行 [body]，把任何异常归一化为 [StorageError]（不泄漏 `SqliteException`）。
///
/// - 已是 [AppError]（含 [StorageError]）的异常**原样透传**——避免把上层已归一化
///   的错误重复包裹（"只归一化一次"）。
/// - 其余异常（如底层 `SqliteException`）统一包成
///   [normalizeStorageError]`(code, e)`，`message` 走默认文案，**不透出 SQL 明文**。
///
/// 与 `sqlite_market_repository.dart` 的实例方法 `_guard` **同构，但透传判据更宽**：
/// 那里是 `if (e is StorageError) rethrow`，此处是 `if (e is AppError) rethrow`——
/// 任何已知 AppError（含 `ValidationError` 等业务错误）都**原样透传**，避免把上层
/// 语义错误二次包装成存储错误。此处提为文件级私有函数，供本文件 8 个仓储复用
/// （减少重复，保持类型安全）。
/// 注意：helper 为**同步**泛型；仓储方法均为 `async`，此处在方法体内调用（`db.select`
/// /`db.execute` 均为同步调用），成功路径返回值/异常原样穿过。
T _guard<T>(String code, T Function() body) {
  try {
    return body();
  } catch (e) {
    if (e is AppError) rethrow;
    throw normalizeStorageError(code, e);
  }
}

// ---------------------------------------------------------------------------
// Expert
// ---------------------------------------------------------------------------

class SqliteExpertRepository implements ExpertRepository {
  SqliteExpertRepository(this.db);
  final Database db;

  @override
  Future<void> upsertExpert(Expert e) async {
    _guard('storage.expert.upsert_expert', () {
      db.execute('''
        INSERT INTO experts (id,name,profession,avatar_path,avatar_emoji,avatar_color,
          system_prompt,welcome_message,
          quick_prompts_json,category_id,package_id,package_version,source,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, profession=excluded.profession, avatar_path=excluded.avatar_path,
          avatar_emoji=excluded.avatar_emoji, avatar_color=excluded.avatar_color,
          system_prompt=excluded.system_prompt, welcome_message=excluded.welcome_message,
          quick_prompts_json=excluded.quick_prompts_json, category_id=excluded.category_id,
          package_id=excluded.package_id, package_version=excluded.package_version,
          source=excluded.source, updated_at=excluded.updated_at
      ''', [
        e.id, e.name, e.profession, e.avatarPath,
        // 第 #66 轮（v9）：emoji 头像落库（null 如实写 NULL，禁止写空串——
        // 空串会被 UI 误判为"有 emoji 但渲染不出"，且污染旧库升级后的默认语义）。
        e.avatarEmoji, e.avatarColor,
        e.systemPrompt, e.welcomeMessage,
        jsonEncode(e.quickPrompts), e.categoryId, e.packageId, e.packageVersion,
        e.source.name, e.createdAt, e.updatedAt,
      ]);
    });
  }

  @override
  Future<Expert?> getExpert(String id) async => _guard('storage.expert.get_expert', () {
        final rs = db.select('SELECT * FROM experts WHERE id = ?', [id]);
        return rs.isEmpty ? null : _expert(rs.first);
      });

  @override
  Future<List<Expert>> listExperts() async => _guard(
        'storage.expert.list_experts',
        () => db.select('SELECT * FROM experts ORDER BY created_at DESC').map(_expert).toList(),
      );

  @override
  Future<void> deleteExpert(String id) async {
    _guard('storage.expert.delete_expert', () {
      db.execute('DELETE FROM experts WHERE id = ?', [id]);
    });
  }

  Expert _expert(Row r) => Expert(
        id: r['id'] as String,
        name: r['name'] as String,
        profession: rowString(r['profession']),
        avatarPath: rowString(r['avatar_path']),
        // 第 #66 轮（v9）：emoji 头像读回（NULL 透传为 null；v8 及更早的存量
        // 行升级后同样为 null → UI 走"首字 + 确定性色"回退，行为不变）。
        avatarEmoji: rowString(r['avatar_emoji']),
        avatarColor: rowString(r['avatar_color']),
        systemPrompt: r['system_prompt'] as String,
        welcomeMessage: rowString(r['welcome_message']),
        quickPrompts: rowJsonList(r['quick_prompts_json']),
        categoryId: rowString(r['category_id']),
        packageId: rowString(r['package_id']),
        packageVersion: rowString(r['package_version']),
        source: ExpertSource.parse(r['source'] as String?),
        createdAt: rowInt(r['created_at'])!,
        updatedAt: rowInt(r['updated_at'])!,
      );

  @override
  Future<void> upsertRuntimeConfig(ExpertRuntimeConfig c) async {
    _guard('storage.expert.upsert_runtime_config', () {
      db.execute('''
        INSERT INTO expert_runtime_configs
          (expert_id,model_profile_id,credential_profile_id,temperature,top_p,max_tokens,grounding_policy,enabled)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(expert_id) DO UPDATE SET
          model_profile_id=excluded.model_profile_id,
          credential_profile_id=excluded.credential_profile_id,
          temperature=excluded.temperature, top_p=excluded.top_p, max_tokens=excluded.max_tokens,
          grounding_policy=excluded.grounding_policy, enabled=excluded.enabled
      ''', [
        c.expertId, c.modelProfileId, c.credentialProfileId, c.temperature, c.topP,
        c.maxTokens, c.groundingPolicy.name, boolToInt(c.enabled),
      ]);
    });
  }

  @override
  Future<ExpertRuntimeConfig?> getRuntimeConfig(String expertId) async =>
      _guard('storage.expert.get_runtime_config', () {
        final rs = db.select('SELECT * FROM expert_runtime_configs WHERE expert_id = ?', [expertId]);
        if (rs.isEmpty) return null;
        final r = rs.first;
        return ExpertRuntimeConfig(
          expertId: expertId,
          modelProfileId: rowString(r['model_profile_id']),
          credentialProfileId: rowString(r['credential_profile_id']),
          temperature: rowDouble(r['temperature']),
          topP: rowDouble(r['top_p']),
          maxTokens: rowInt(r['max_tokens']),
          groundingPolicy: GroundingPolicy.parse(r['grounding_policy'] as String?),
          enabled: rowBool(r['enabled']),
        );
      });

  @override
  Future<void> upsertUserState(ExpertUserState s) async {
    _guard('storage.expert.upsert_user_state', () {
      db.execute('''
        INSERT INTO expert_user_states
          (expert_id,remark,group_id,pinned,custom_prompt,style_id,is_locked,local_modified_at)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(expert_id) DO UPDATE SET
          remark=excluded.remark, group_id=excluded.group_id, pinned=excluded.pinned,
          custom_prompt=excluded.custom_prompt, style_id=excluded.style_id,
          is_locked=excluded.is_locked,
          local_modified_at=excluded.local_modified_at
      ''', [
        s.expertId, s.remark, s.groupId, boolToInt(s.pinned), s.customPrompt,
        s.styleId, boolToInt(s.isLocked), s.localModifiedAt,
      ]);
    });
  }

  @override
  Future<ExpertUserState?> getUserState(String expertId) async =>
      _guard('storage.expert.get_user_state', () {
        final rs = db.select('SELECT * FROM expert_user_states WHERE expert_id = ?', [expertId]);
        if (rs.isEmpty) return null;
        final r = rs.first;
        return ExpertUserState(
          expertId: expertId,
          remark: rowString(r['remark']),
          groupId: rowString(r['group_id']),
          pinned: rowBool(r['pinned']),
          customPrompt: rowString(r['custom_prompt']),
          styleId: rowString(r['style_id']),
          isLocked: rowBool(r['is_locked']),
          localModifiedAt: rowInt(r['local_modified_at']),
        );
      });

  @override
  Future<void> setTags(String expertId, List<String> tagNames) async {
    _guard('storage.expert.set_tags', () {
      db.execute('DELETE FROM expert_tag_relations WHERE expert_id = ?', [expertId]);
      for (final name in tagNames) {
        final trimmed = name.trim();
        if (trimmed.isEmpty) continue;
        final existing = db.select('SELECT id FROM tags WHERE name = ?', [trimmed]);
        final tagId = existing.isEmpty ? Ids.next('tag') : existing.first['id'] as String;
        if (existing.isEmpty) {
          db.execute('INSERT INTO tags (id,name) VALUES (?,?)', [tagId, trimmed]);
        }
        db.execute(
          'INSERT OR IGNORE INTO expert_tag_relations (expert_id,tag_id) VALUES (?,?)',
          [expertId, tagId],
        );
      }
    });
  }

  @override
  Future<List<String>> getTags(String expertId) async => _guard('storage.expert.get_tags', () => db
      .select('''
        SELECT t.name AS name FROM tags t
        JOIN expert_tag_relations r ON r.tag_id = t.id
        WHERE r.expert_id = ? ORDER BY t.name
      ''', [expertId])
      .map((r) => r['name'] as String)
      .toList());

  @override
  Future<void> upsertKnowledgeBinding(ExpertKnowledgeBinding b) async {
    _guard('storage.expert.upsert_knowledge_binding', () {
      db.execute('''
        INSERT INTO expert_knowledge_bindings
          (expert_id,knowledge_base_id,priority,enabled,top_k,similarity_threshold)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(expert_id,knowledge_base_id) DO UPDATE SET
          priority=excluded.priority, enabled=excluded.enabled,
          top_k=excluded.top_k, similarity_threshold=excluded.similarity_threshold
      ''', [b.expertId, b.knowledgeBaseId, b.priority, boolToInt(b.enabled), b.topK, b.similarityThreshold]);
    });
  }

  @override
  Future<void> removeKnowledgeBinding(String expertId, String knowledgeBaseId) async {
    _guard('storage.expert.remove_knowledge_binding', () {
      db.execute(
        'DELETE FROM expert_knowledge_bindings WHERE expert_id = ? AND knowledge_base_id = ?',
        [expertId, knowledgeBaseId],
      );
    });
  }

  @override
  Future<List<ExpertKnowledgeBinding>> listKnowledgeBindings(String expertId) async =>
      _guard('storage.expert.list_knowledge_bindings', () => db
          .select('SELECT * FROM expert_knowledge_bindings WHERE expert_id = ? ORDER BY priority',
              [expertId])
          .map((r) => ExpertKnowledgeBinding(
                expertId: expertId,
                knowledgeBaseId: r['knowledge_base_id'] as String,
                priority: rowInt(r['priority']) ?? 0,
                enabled: rowBool(r['enabled']),
                topK: rowInt(r['top_k']) ?? 5,
                similarityThreshold: rowDouble(r['similarity_threshold']) ?? 0.75,
              ))
          .toList());
}

// ---------------------------------------------------------------------------
// Conversation / Message
// ---------------------------------------------------------------------------

class SqliteConversationRepository implements ConversationRepository {
  SqliteConversationRepository(this.db);
  final Database db;

  @override
  Future<void> upsertConversation(Conversation c) async {
    _guard('storage.conversation.upsert_conversation', () {
      db.execute('''
        INSERT INTO conversations (id,type,title,pinned,last_message_at,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          title=excluded.title, pinned=excluded.pinned,
          last_message_at=excluded.last_message_at, updated_at=excluded.updated_at
      ''', [c.id, c.type.name, c.title, boolToInt(c.pinned), c.lastMessageAt, c.createdAt, c.updatedAt]);
    });
  }

  @override
  Future<Conversation?> getConversation(String id) async =>
      _guard('storage.conversation.get_conversation', () {
        final rs = db.select('SELECT * FROM conversations WHERE id = ?', [id]);
        return rs.isEmpty ? null : _conv(rs.first);
      });

  @override
  Future<List<Conversation>> listConversations() async => _guard(
        'storage.conversation.list_conversations',
        () => db
            .select('SELECT * FROM conversations ORDER BY pinned DESC, last_message_at DESC')
            .map(_conv)
            .toList(),
      );

  Conversation _conv(Row r) => Conversation(
        id: r['id'] as String,
        type: ConversationType.parse(r['type'] as String?),
        title: rowString(r['title']),
        pinned: rowBool(r['pinned']),
        lastMessageAt: rowInt(r['last_message_at']),
        createdAt: rowInt(r['created_at'])!,
        updatedAt: rowInt(r['updated_at'])!,
      );

  @override
  Future<void> deleteConversation(String id) async {
    // 只删主表一行：conversation_members / group_configs / messages 由 DDL
    // ON DELETE CASCADE 清除，messages 再级联 message_attachments /
    // message_citations（前提：连接 PRAGMA foreign_keys = ON，见 support.dart）。
    // **绝不手删子表**（双保险与显式删由服务层按场景另行编排）。
    _guard('storage.conversation.delete_conversation', () {
      db.execute('DELETE FROM conversations WHERE id = ?', [id]);
    });
  }

  @override
  Future<void> setConversationPinned(String conversationId, bool pinned) async {
    // 只改 pinned 一列（置顶不是内容变更，不动 updated_at）。
    // 会话不存在 → 影响 0 行，静默 no-op（存在性校验在服务层）。
    _guard('storage.conversation.set_pinned', () {
      db.execute(
        'UPDATE conversations SET pinned = ? WHERE id = ?',
        [boolToInt(pinned), conversationId],
      );
    });
  }

  @override
  Future<void> clearMessages(String conversationId) async {
    // 只删 messages 行（会话本身保留）：message_attachments /
    // message_citations 由 DDL ON DELETE CASCADE 自动清除。
    // **绝不手删子表**——与 deleteConversation 同口径。
    _guard('storage.conversation.clear_messages', () {
      db.execute('DELETE FROM messages WHERE conversation_id = ?', [conversationId]);
    });
  }

  @override
  Future<void> upsertMember(ConversationMember m) async {
    _guard('storage.conversation.upsert_member', () {
      db.execute('''
        INSERT INTO conversation_members
          (conversation_id,expert_id,role,weight,enabled,sort_order)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(conversation_id,expert_id) DO UPDATE SET
          role=excluded.role, weight=excluded.weight,
          enabled=excluded.enabled, sort_order=excluded.sort_order
      ''', [m.conversationId, m.expertId, m.role.name, m.weight, boolToInt(m.enabled), m.sortOrder]);
    });
  }

  @override
  Future<void> removeMember(String conversationId, String expertId) async {
    _guard('storage.conversation.remove_member', () {
      db.execute(
        'DELETE FROM conversation_members WHERE conversation_id = ? AND expert_id = ?',
        [conversationId, expertId],
      );
    });
  }

  @override
  Future<List<ConversationMember>> listMembers(String conversationId) async =>
      _guard('storage.conversation.list_members', () => db
          .select('SELECT * FROM conversation_members WHERE conversation_id = ? ORDER BY sort_order',
              [conversationId])
          .map((r) => ConversationMember(
                conversationId: conversationId,
                expertId: r['expert_id'] as String,
                role: MemberRole.parse(r['role'] as String?),
                weight: rowDouble(r['weight']) ?? 1.0,
                enabled: rowBool(r['enabled']),
                sortOrder: rowInt(r['sort_order']) ?? 0,
              ))
          .toList());

  @override
  Future<void> upsertGroupConfig(GroupConfig c) async {
    _guard('storage.conversation.upsert_group_config', () {
      db.execute('''
        INSERT INTO group_configs
          (conversation_id,speak_strategy,summarizer_expert_id,context_window,max_rounds,
           token_budget,duplicate_threshold,topic_threshold,
           announcement,announcement_updated_at,max_speakers_per_round)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(conversation_id) DO UPDATE SET
          speak_strategy=excluded.speak_strategy, summarizer_expert_id=excluded.summarizer_expert_id,
          context_window=excluded.context_window, max_rounds=excluded.max_rounds,
          token_budget=excluded.token_budget, duplicate_threshold=excluded.duplicate_threshold,
          topic_threshold=excluded.topic_threshold,
          announcement=excluded.announcement,
          announcement_updated_at=excluded.announcement_updated_at,
          max_speakers_per_round=excluded.max_speakers_per_round
      ''', [
        c.conversationId, c.speakStrategy, c.summarizerExpertId, c.contextWindow,
        c.maxRounds, c.tokenBudget, c.duplicateThreshold, c.topicThreshold,
        c.announcement, c.announcementUpdatedAt, c.maxSpeakersPerRound,
      ]);
    });
  }

  @override
  Future<GroupConfig?> getGroupConfig(String conversationId) async =>
      _guard('storage.conversation.get_group_config', () {
        final rs = db.select('SELECT * FROM group_configs WHERE conversation_id = ?', [conversationId]);
        if (rs.isEmpty) return null;
        final r = rs.first;
        return GroupConfig(
          conversationId: conversationId,
          speakStrategy: r['speak_strategy'] as String? ?? 'auto',
          summarizerExpertId: rowString(r['summarizer_expert_id']),
          contextWindow: rowInt(r['context_window']),
          maxRounds: rowInt(r['max_rounds']) ?? 1,
          tokenBudget: rowInt(r['token_budget']),
          duplicateThreshold: rowDouble(r['duplicate_threshold']) ?? 0.82,
          topicThreshold: rowDouble(r['topic_threshold']) ?? 0.02,
          announcement: rowString(r['announcement']),
          announcementUpdatedAt: rowInt(r['announcement_updated_at']),
          maxSpeakersPerRound: rowInt(r['max_speakers_per_round']),
        );
      });
}

class SqliteMessageRepository implements MessageRepository {
  SqliteMessageRepository(this.db);
  final Database db;

  @override
  Future<void> insertMessage(Message m) async {
    _guard('storage.message.insert_message', () => _insertMessage(m));
  }

  @override
  Future<void> updateMessage(Message m) async {
    // 与 insertMessage 同一条 upsert SQL（仅错误码区分：update 语义）。
    // 抽到 [_insertMessage] 以在保持"仅归一化一次"的同时给出稳定、可断言的错误码。
    _guard('storage.message.update_message', () => _insertMessage(m));
  }

  /// 消息 upsert 的共享实现（成功路径与原 `insertMessage` 逐字一致）。
  void _insertMessage(Message m) {
    db.execute('''
      INSERT INTO messages
        (id,conversation_id,sender_type,sender_id,parent_message_id,content,status,
         prompt_tokens,completion_tokens,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        content=excluded.content, status=excluded.status,
        prompt_tokens=excluded.prompt_tokens, completion_tokens=excluded.completion_tokens,
        updated_at=excluded.updated_at
    ''', [
      m.id, m.conversationId, m.senderType.name, m.senderId, m.parentMessageId, m.content,
      m.status.name, m.promptTokens, m.completionTokens, m.createdAt, m.updatedAt,
    ]);
  }

  @override
  Future<Message?> getMessage(String id) async => _guard('storage.message.get_message', () {
        final rs = db.select('SELECT * FROM messages WHERE id = ?', [id]);
        return rs.isEmpty ? null : _msg(rs.first);
      });

  @override
  Future<List<Message>> listMessages(String conversationId, {int? limit, int? before}) async =>
      _guard('storage.message.list_messages', () {
        final params = <Object?>[conversationId];
        var sql = 'SELECT * FROM messages WHERE conversation_id = ?';
        if (before != null) {
          sql += ' AND created_at < ?';
          params.add(before);
        }
        sql += ' ORDER BY created_at ASC, rowid ASC';
        final rows = db.select(sql, params).toList();
        if (limit != null && rows.length > limit) {
          return rows.sublist(rows.length - limit).map(_msg).toList();
        }
        return rows.map(_msg).toList();
      });

  Message _msg(Row r) => Message(
        id: r['id'] as String,
        conversationId: r['conversation_id'] as String,
        senderType: MessageSenderType.parse(r['sender_type'] as String?),
        senderId: rowString(r['sender_id']),
        parentMessageId: rowString(r['parent_message_id']),
        content: r['content'] as String,
        status: MessageStatus.parse(r['status'] as String?),
        promptTokens: rowInt(r['prompt_tokens']),
        completionTokens: rowInt(r['completion_tokens']),
        createdAt: rowInt(r['created_at'])!,
        updatedAt: rowInt(r['updated_at'])!,
      );

  @override
  Future<void> insertCitation(String messageId, Citation c) async {
    _guard('storage.message.insert_citation', () {
      db.execute('''
        INSERT INTO message_citations
          (id,message_id,document_id,chunk_id,file_name,page,heading_path,sheet,cell_range,quote_text,score)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
      ''', [
        Ids.next('cit'), messageId, c.documentId, c.chunkId, c.fileName, c.page,
        c.headingPath, c.sheet, c.cellRange, c.text, c.score,
      ]);
    });
  }

  @override
  Future<List<Citation>> listCitations(String messageId) async =>
      _guard('storage.message.list_citations', () => db
          .select('SELECT * FROM message_citations WHERE message_id = ? ORDER BY score DESC',
              [messageId])
          .map((r) => Citation(
                chunkId: rowString(r['chunk_id']) ?? '',
                documentId: rowString(r['document_id']) ?? '',
                fileName: rowString(r['file_name']) ?? '未知文件',
                text: rowString(r['quote_text']) ?? '',
                score: rowDouble(r['score']) ?? 0,
                page: rowInt(r['page']),
                headingPath: rowString(r['heading_path']),
                sheet: rowString(r['sheet']),
                cellRange: rowString(r['cell_range']),
              ))
          .toList());

  @override
  Future<void> deleteMessage(String messageId) async {
    // 数据层原语：只删消息行本身。
    // · `message_attachments` / `message_citations` 行由 DDL 的
    //   `ON DELETE CASCADE` 自动清除（前提连接 FK = ON）。
    // · 显式删附件行与物理文件 GC 由服务层（ConversationService.deleteMessage）
    //   按引用计数编排——**双保险，不依赖单一 FK**。
    _guard('storage.message.delete_message', () {
      db.execute('DELETE FROM messages WHERE id = ?', [messageId]);
    });
  }
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

class SqliteGenerationRepository implements GenerationRepository {
  SqliteGenerationRepository(this.db);
  final Database db;

  @override
  Future<void> upsertRun(GenerationRun r) async {
    _guard('storage.generation.upsert_run', () {
      db.execute('''
        INSERT INTO generation_runs
          (id,conversation_id,trigger_message_id,run_type,status,model_profile_id,token_budget,
           prompt_tokens,completion_tokens,estimated_cost,started_at,ended_at,error_code,error_message)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          status=excluded.status, prompt_tokens=excluded.prompt_tokens,
          completion_tokens=excluded.completion_tokens, estimated_cost=excluded.estimated_cost,
          started_at=excluded.started_at, ended_at=excluded.ended_at,
          error_code=excluded.error_code, error_message=excluded.error_message
      ''', [
        r.id, r.conversationId, r.triggerMessageId, r.runType.name, r.status.name,
        r.modelProfileId, r.tokenBudget, r.promptTokens, r.completionTokens, r.estimatedCost,
        r.startedAt, r.endedAt, r.errorCode, r.errorMessage,
      ]);
    });
  }

  @override
  Future<GenerationRun?> getRun(String id) async => _guard('storage.generation.get_run', () {
        final rs = db.select('SELECT * FROM generation_runs WHERE id = ?', [id]);
        if (rs.isEmpty) return null;
        final r = rs.first;
        return GenerationRun(
          id: r['id'] as String,
          conversationId: r['conversation_id'] as String,
          triggerMessageId: rowString(r['trigger_message_id']),
          runType: RunType.values.firstWhere((e) => e.name == r['run_type'],
              orElse: () => RunType.singleChat),
          status: RunStatus.parse(r['status'] as String?),
          modelProfileId: rowString(r['model_profile_id']),
          tokenBudget: rowInt(r['token_budget']),
          promptTokens: rowInt(r['prompt_tokens']) ?? 0,
          completionTokens: rowInt(r['completion_tokens']) ?? 0,
          estimatedCost: rowDouble(r['estimated_cost']) ?? 0,
          startedAt: rowInt(r['started_at']),
          endedAt: rowInt(r['ended_at']),
          errorCode: rowString(r['error_code']),
          errorMessage: rowString(r['error_message']),
        );
      });

  @override
  Future<List<GenerationRun>> listRuns(String conversationId) async {
    // 修复原实现中 `.toList().then(...)` 的编译错误（List 无 then）；语义不变：
    // 按 started_at 倒序取 id，再逐条读回，过滤掉读不到的记录。
    // id 查询经 _guard 归一化；逐条 getRun 自身已归一化，无需再包。
    final ids = _guard(
      'storage.generation.list_runs',
      () => db
          .select(
              'SELECT id FROM generation_runs WHERE conversation_id = ? ORDER BY started_at DESC',
              [conversationId])
          .map((r) => r['id'] as String)
          .toList(),
    );
    final runs = <GenerationRun>[];
    for (final id in ids) {
      final run = await getRun(id);
      if (run != null) runs.add(run);
    }
    return runs;
  }

  @override
  Future<void> upsertStep(GenerationStep s) async {
    _guard('storage.generation.upsert_step', () {
      db.execute('''
        INSERT INTO generation_steps
          (id,run_id,expert_id,stage,sequence,status,started_at,ended_at,retrieval_count,
           prompt_tokens,completion_tokens,latency_ms,output_message_id,error_code,error_message)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          status=excluded.status, started_at=excluded.started_at, ended_at=excluded.ended_at,
          retrieval_count=excluded.retrieval_count, prompt_tokens=excluded.prompt_tokens,
          completion_tokens=excluded.completion_tokens, latency_ms=excluded.latency_ms,
          output_message_id=excluded.output_message_id,
          error_code=excluded.error_code, error_message=excluded.error_message
      ''', [
        s.id, s.runId, s.expertId, s.stage.name, s.sequence, s.status.name, s.startedAt, s.endedAt,
        s.retrievalCount, s.promptTokens, s.completionTokens, s.latencyMs, s.outputMessageId,
        s.errorCode, s.errorMessage,
      ]);
    });
  }

  @override
  Future<List<GenerationStep>> listSteps(String runId) async =>
      _guard('storage.generation.list_steps', () => db
          .select('SELECT * FROM generation_steps WHERE run_id = ? ORDER BY sequence', [runId])
          .map((r) => GenerationStep(
                id: r['id'] as String,
                runId: runId,
                expertId: rowString(r['expert_id']),
                stage: StepStage.values.firstWhere((e) => e.name == r['stage'],
                    orElse: () => StepStage.generation),
                sequence: rowInt(r['sequence'])!,
                status: RunStatus.parse(r['status'] as String?),
                startedAt: rowInt(r['started_at']),
                endedAt: rowInt(r['ended_at']),
                retrievalCount: rowInt(r['retrieval_count']) ?? 0,
                promptTokens: rowInt(r['prompt_tokens']) ?? 0,
                completionTokens: rowInt(r['completion_tokens']) ?? 0,
                latencyMs: rowInt(r['latency_ms']),
                outputMessageId: rowString(r['output_message_id']),
                errorCode: rowString(r['error_code']),
                errorMessage: rowString(r['error_message']),
              ))
          .toList());

  @override
  Future<void> appendEvent(GenerationEvent e) async {
    _guard('storage.generation.append_event', () {
      db.execute('''
        INSERT INTO generation_events (id,step_id,sequence,event_type,delta,created_at)
        VALUES (?,?,?,?,?,?)
      ''', [e.id, e.stepId, e.sequence, e.eventType.wire, e.delta, e.createdAt]);
    });
  }

  @override
  Future<List<GenerationEvent>> listEvents(String stepId) async =>
      _guard('storage.generation.list_events', () => db
          .select('SELECT * FROM generation_events WHERE step_id = ? ORDER BY sequence', [stepId])
          .map((r) => GenerationEvent(
                id: r['id'] as String,
                stepId: stepId,
                sequence: rowInt(r['sequence'])!,
                eventType: GenerationEventType.values.firstWhere(
                  (e) => e.wire == r['event_type'],
                  orElse: () => GenerationEventType.tokenDelta,
                ),
                delta: rowString(r['delta']),
                createdAt: rowInt(r['created_at'])!,
              ))
          .toList());

  @override
  Future<int> recoverInterrupted() async {
    return _guard('storage.generation.recover_interrupted', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      db.execute(
        "UPDATE generation_runs SET status='cancelled', ended_at=? WHERE status='running'",
        [now],
      );
      // 本次真正恢复的 run 数 = 该 UPDATE 影响的行数。
      // 必须在执行后续语句前立即读取（updatedRows 会被下一条语句覆盖）。
      final recovered = db.updatedRows;
      db.execute(
        "UPDATE generation_steps SET status='cancelled', ended_at=? WHERE status='running'",
        [now],
      );
      return recovered;
    });
  }
}

// ---------------------------------------------------------------------------
// Provider / Credential
// ---------------------------------------------------------------------------

class SqliteProviderRepository implements ProviderRepository {
  SqliteProviderRepository(this.db);
  final Database db;

  @override
  Future<void> upsertProvider(ProviderProfile p) async {
    _guard('storage.provider.upsert_provider', () {
      db.execute('''
        INSERT INTO provider_profiles (id,provider_id,display_name,base_url,protocol,enabled)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          provider_id=excluded.provider_id, display_name=excluded.display_name,
          base_url=excluded.base_url, protocol=excluded.protocol, enabled=excluded.enabled
      ''', [p.id, p.providerId, p.displayName, p.baseUrl, p.protocol, boolToInt(p.enabled)]);
    });
  }

  @override
  Future<List<ProviderProfile>> listProviders() async => _guard(
        'storage.provider.list_providers',
        () => db
            .select('SELECT * FROM provider_profiles ORDER BY display_name')
            .map((r) => ProviderProfile(
                  id: r['id'] as String,
                  providerId: r['provider_id'] as String,
                  displayName: r['display_name'] as String,
                  baseUrl: r['base_url'] as String,
                  protocol: r['protocol'] as String? ?? 'openai_compatible',
                  enabled: rowBool(r['enabled']),
                ))
            .toList(),
      );

  @override
  Future<ProviderProfile?> getProvider(String id) async =>
      _guard('storage.provider.get_provider', () {
        final rs = db.select('SELECT * FROM provider_profiles WHERE id = ?', [id]);
        if (rs.isEmpty) return null;
        final r = rs.first;
        return ProviderProfile(
          id: r['id'] as String,
          providerId: r['provider_id'] as String,
          displayName: r['display_name'] as String,
          baseUrl: r['base_url'] as String,
          protocol: r['protocol'] as String? ?? 'openai_compatible',
          enabled: rowBool(r['enabled']),
        );
      });

  @override
  Future<void> upsertModel(ModelProfile m) async {
    _guard('storage.provider.upsert_model', () {
      db.execute('''
        INSERT INTO model_profiles
          (id,provider_profile_id,model_id,context_window,supports_streaming,supports_vision,supports_tools,supports_json)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          provider_profile_id=excluded.provider_profile_id, model_id=excluded.model_id,
          context_window=excluded.context_window, supports_streaming=excluded.supports_streaming,
          supports_vision=excluded.supports_vision, supports_tools=excluded.supports_tools,
          supports_json=excluded.supports_json
      ''', [
        m.id, m.providerProfileId, m.modelId, m.contextWindow, boolToInt(m.supportsStreaming),
        boolToInt(m.supportsVision), boolToInt(m.supportsTools), boolToInt(m.supportsJson),
      ]);
    });
  }

  @override
  Future<List<ModelProfile>> listModels({String? providerProfileId}) async =>
      _guard('storage.provider.list_models', () {
        final rows = providerProfileId == null
            ? db.select('SELECT * FROM model_profiles ORDER BY model_id')
            : db.select('SELECT * FROM model_profiles WHERE provider_profile_id = ? ORDER BY model_id',
                [providerProfileId]);
        return rows.map(_model).toList();
      });

  @override
  Future<ModelProfile?> getModel(String id) async => _guard('storage.provider.get_model', () {
        final rs = db.select('SELECT * FROM model_profiles WHERE id = ?', [id]);
        return rs.isEmpty ? null : _model(rs.first);
      });

  ModelProfile _model(Row r) => ModelProfile(
        id: r['id'] as String,
        providerProfileId: r['provider_profile_id'] as String,
        modelId: r['model_id'] as String,
        contextWindow: rowInt(r['context_window']),
        supportsStreaming: rowBool(r['supports_streaming']),
        supportsVision: rowBool(r['supports_vision']),
        supportsTools: rowBool(r['supports_tools']),
        supportsJson: rowBool(r['supports_json']),
      );
}

class SqliteCredentialRepository implements CredentialRepository {
  SqliteCredentialRepository(this.db);
  final Database db;

  @override
  Future<void> upsert(CredentialProfile p) async {
    _guard('storage.credential.upsert', () {
      db.execute('''
        INSERT INTO credential_profiles (id,provider_profile_id,name,secret_ref,created_at,updated_at)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          provider_profile_id=excluded.provider_profile_id, name=excluded.name,
          secret_ref=excluded.secret_ref, updated_at=excluded.updated_at
      ''', [p.id, p.providerProfileId, p.name, p.secretRef, p.createdAt, p.updatedAt]);
    });
  }

  @override
  Future<List<CredentialProfile>> list() async => _guard(
        'storage.credential.list',
        () => db
            .select('SELECT * FROM credential_profiles ORDER BY created_at')
            .map((r) => CredentialProfile(
                  id: r['id'] as String,
                  providerProfileId: r['provider_profile_id'] as String,
                  name: r['name'] as String,
                  secretRef: r['secret_ref'] as String,
                  createdAt: rowInt(r['created_at'])!,
                  updatedAt: rowInt(r['updated_at'])!,
                ))
            .toList(),
      );

  @override
  Future<CredentialProfile?> get(String id) async => _guard('storage.credential.get', () {
        final rs = db.select('SELECT * FROM credential_profiles WHERE id = ?', [id]);
        if (rs.isEmpty) return null;
        final r = rs.first;
        return CredentialProfile(
          id: r['id'] as String,
          providerProfileId: r['provider_profile_id'] as String,
          name: r['name'] as String,
          secretRef: r['secret_ref'] as String,
          createdAt: rowInt(r['created_at'])!,
          updatedAt: rowInt(r['updated_at'])!,
        );
      });

  @override
  Future<void> delete(String id) async {
    _guard('storage.credential.delete', () {
      db.execute('DELETE FROM credential_profiles WHERE id = ?', [id]);
    });
  }
}

// ---------------------------------------------------------------------------
// Settings / Job
// ---------------------------------------------------------------------------

class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(this.db);
  final Database db;

  @override
  Future<String?> get(String key) async => _guard('storage.settings.get', () {
        final rs = db.select('SELECT value FROM settings WHERE key = ?', [key]);
        return rs.isEmpty ? null : rs.first['value'] as String;
      });

  @override
  Future<void> set(String key, String value) async {
    _guard('storage.settings.set', () {
      db.execute('''
        INSERT INTO settings (key,value) VALUES (?,?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value
      ''', [key, value]);
    });
  }

  @override
  Future<void> remove(String key) async {
    _guard('storage.settings.remove', () {
      db.execute('DELETE FROM settings WHERE key = ?', [key]);
    });
  }
}

class SqliteJobRepository implements JobRepository {
  SqliteJobRepository(this.db);
  final Database db;

  @override
  Future<void> upsert(JobRecord j) async {
    _guard('storage.job.upsert', () {
      db.execute('''
        INSERT INTO jobs (id,type,status,progress,retry_count,payload_json,error_code,error_message,
          created_at,started_at,finished_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          status=excluded.status, progress=excluded.progress, retry_count=excluded.retry_count,
          payload_json=excluded.payload_json, error_code=excluded.error_code,
          error_message=excluded.error_message, started_at=excluded.started_at,
          finished_at=excluded.finished_at
      ''', [
        j.id, j.type, j.status, j.progress, j.retryCount, j.payloadJson, j.errorCode,
        j.errorMessage, j.createdAt, j.startedAt, j.finishedAt,
      ]);
    });
  }

  @override
  Future<JobRecord?> get(String id) async => _guard('storage.job.get', () {
        final rs = db.select('SELECT * FROM jobs WHERE id = ?', [id]);
        return rs.isEmpty ? null : _job(rs.first);
      });

  @override
  Future<List<JobRecord>> list({String? type, String? status}) async =>
      _guard('storage.job.list', () {
        final rows = db.select('''
          SELECT * FROM jobs
          WHERE (? IS NULL OR type = ?) AND (? IS NULL OR status = ?)
          ORDER BY created_at DESC
        ''', [type, type, status, status]);
        return rows.map(_job).toList();
      });

  JobRecord _job(Row r) => JobRecord(
        id: r['id'] as String,
        type: r['type'] as String,
        status: r['status'] as String,
        progress: rowDouble(r['progress']) ?? 0,
        retryCount: rowInt(r['retry_count']) ?? 0,
        payloadJson: rowString(r['payload_json']),
        errorCode: rowString(r['error_code']),
        errorMessage: rowString(r['error_message']),
        createdAt: rowInt(r['created_at'])!,
        startedAt: rowInt(r['started_at']),
        finishedAt: rowInt(r['finished_at']),
      );
}
