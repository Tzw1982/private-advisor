// 本文件由 tool/gen_schema.dart 自动生成，请勿手工修改。
// 源文件：lib/src/database/schema.sql
// 重新生成：cd advisor_storage && dart run tool/gen_schema.dart
library;

/// canonical DDL（与 schema.sql 逐字一致）。
const String kAdvisorSchemaSql = r'''
-- 私人顾问团 · 本地数据库 Schema（canonical DDL）
-- 对应契约 docs/02-database-er-migration.md
-- 存储分工：SQLite = 业务关系数据；OS Secure Storage = Secret；检索 = FTS5 + 应用层中文 bigram（第 2 轮；sqlite-vec 未启用）
--
-- 迁移原则：只允许 additive migration；禁止启动时 DROP/CREATE 重建。
--
-- ⚠️ 约束（applySchema 依赖）：本文件**不得**出现引号内部的分号，
--    因为 support.dart 的 applySchema 使用分号切分语句。
--    verify_storage.dart 有一条回归断言守护该约束。

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ===========================================================================
-- Expert
-- ===========================================================================

CREATE TABLE IF NOT EXISTS experts (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    profession      TEXT,
    avatar_path     TEXT,
    avatar_emoji    TEXT,
    avatar_color    TEXT,
    system_prompt   TEXT NOT NULL,
    welcome_message TEXT,
    quick_prompts_json TEXT,
    category_id     TEXT,
    package_id      TEXT,
    package_version TEXT,
    source          TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS expert_runtime_configs (
    expert_id               TEXT PRIMARY KEY,
    model_profile_id        TEXT,
    credential_profile_id   TEXT,
    temperature             REAL,
    top_p                   REAL,
    max_tokens              INTEGER,
    grounding_policy        TEXT NOT NULL DEFAULT 'off',
    enabled                 INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS expert_user_states (
    expert_id           TEXT PRIMARY KEY,
    remark              TEXT,
    group_id            TEXT,
    pinned              INTEGER NOT NULL DEFAULT 0,
    custom_prompt       TEXT,
    style_id            TEXT,
    is_locked           INTEGER NOT NULL DEFAULT 0,
    local_modified_at   INTEGER,
    FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE
);

-- 通讯录分组主表（第 3 轮 v3 新增）。
-- expert_user_states.group_id 为**逻辑外键**指向本表（SQLite 无法事后 ADD FK，
-- 且禁重建表）→ 删除分组时由服务层清空成员 group_id（无 DB 级 FK）。
CREATE TABLE IF NOT EXISTS expert_groups (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tags (
    id      TEXT PRIMARY KEY,
    name    TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS expert_tag_relations (
    expert_id   TEXT NOT NULL,
    tag_id      TEXT NOT NULL,
    PRIMARY KEY (expert_id, tag_id),
    FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE,
    FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
);

-- ===========================================================================
-- Conversation
-- ===========================================================================

CREATE TABLE IF NOT EXISTS conversations (
    id              TEXT PRIMARY KEY,
    type            TEXT NOT NULL,
    title           TEXT,
    pinned          INTEGER NOT NULL DEFAULT 0,
    last_message_at INTEGER,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS conversation_members (
    conversation_id TEXT NOT NULL,
    expert_id       TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'member',
    weight          REAL NOT NULL DEFAULT 1.0,
    enabled         INTEGER NOT NULL DEFAULT 1,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (conversation_id, expert_id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
    FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE
);

-- 群聊配置表。
-- 第 6 轮 v5 新增三列（announcement / announcement_updated_at / max_speakers_per_round）
-- **同时**写进本 canonical DDL（与第 3 轮 style_id 同模式：DDL 内置 + 迁移守卫双保险）；
-- 与第 4 轮 folder_id / source_mtime **只走迁移**不同——两种模式在此明文区分，消除同文件自相矛盾。
-- （新库：建表即含三列 → v5 守卫 _addColumnIfMissing 判存后 no-op；老库：守卫照常补列。）
CREATE TABLE IF NOT EXISTS group_configs (
    conversation_id         TEXT PRIMARY KEY,
    speak_strategy          TEXT NOT NULL DEFAULT 'auto',
    summarizer_expert_id    TEXT,
    context_window          INTEGER,
    max_rounds              INTEGER DEFAULT 1,
    token_budget            INTEGER,
    duplicate_threshold     REAL DEFAULT 0.82,
    topic_threshold         REAL DEFAULT 0.02,
    announcement            TEXT,
    announcement_updated_at INTEGER,
    max_speakers_per_round  INTEGER,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS messages (
    id                  TEXT PRIMARY KEY,
    conversation_id     TEXT NOT NULL,
    sender_type         TEXT NOT NULL,
    sender_id           TEXT,
    parent_message_id   TEXT,
    content             TEXT NOT NULL,
    status              TEXT NOT NULL,
    prompt_tokens       INTEGER,
    completion_tokens   INTEGER,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, created_at);

-- ===========================================================================
-- Generation Runtime
-- ===========================================================================

CREATE TABLE IF NOT EXISTS generation_runs (
    id                  TEXT PRIMARY KEY,
    conversation_id     TEXT NOT NULL,
    trigger_message_id  TEXT,
    run_type            TEXT NOT NULL,
    status              TEXT NOT NULL,
    model_profile_id    TEXT,
    token_budget        INTEGER,
    prompt_tokens       INTEGER DEFAULT 0,
    completion_tokens   INTEGER DEFAULT 0,
    estimated_cost      REAL DEFAULT 0,
    started_at          INTEGER,
    ended_at            INTEGER,
    error_code          TEXT,
    error_message       TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_conv ON generation_runs(conversation_id, started_at);

CREATE TABLE IF NOT EXISTS generation_steps (
    id                  TEXT PRIMARY KEY,
    run_id              TEXT NOT NULL,
    expert_id           TEXT,
    stage               TEXT NOT NULL,
    sequence            INTEGER NOT NULL,
    status              TEXT NOT NULL,
    started_at          INTEGER,
    ended_at            INTEGER,
    retrieval_count     INTEGER DEFAULT 0,
    prompt_tokens       INTEGER DEFAULT 0,
    completion_tokens   INTEGER DEFAULT 0,
    latency_ms          INTEGER,
    output_message_id   TEXT,
    error_code          TEXT,
    error_message       TEXT,
    FOREIGN KEY (run_id) REFERENCES generation_runs(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_steps_run ON generation_steps(run_id, sequence);

CREATE TABLE IF NOT EXISTS generation_events (
    id          TEXT PRIMARY KEY,
    step_id     TEXT NOT NULL,
    sequence    INTEGER NOT NULL,
    event_type  TEXT NOT NULL,
    delta       TEXT,
    created_at  INTEGER NOT NULL,
    FOREIGN KEY (step_id) REFERENCES generation_steps(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_events_step ON generation_events(step_id, sequence);

-- ===========================================================================
-- Provider / Model / Credential
-- ===========================================================================

CREATE TABLE IF NOT EXISTS provider_profiles (
    id              TEXT PRIMARY KEY,
    provider_id     TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    base_url        TEXT NOT NULL,
    protocol        TEXT NOT NULL DEFAULT 'openai_compatible',
    enabled         INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS model_profiles (
    id                      TEXT PRIMARY KEY,
    provider_profile_id     TEXT NOT NULL,
    model_id                TEXT NOT NULL,
    context_window          INTEGER,
    supports_streaming      INTEGER NOT NULL DEFAULT 1,
    supports_vision         INTEGER NOT NULL DEFAULT 0,
    supports_tools          INTEGER NOT NULL DEFAULT 0,
    supports_json           INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (provider_profile_id) REFERENCES provider_profiles(id) ON DELETE CASCADE
);

-- 只存 secret_ref，绝不存明文 Key
CREATE TABLE IF NOT EXISTS credential_profiles (
    id                      TEXT PRIMARY KEY,
    provider_profile_id     TEXT NOT NULL,
    name                    TEXT NOT NULL,
    secret_ref              TEXT NOT NULL,
    created_at              INTEGER NOT NULL,
    updated_at              INTEGER NOT NULL,
    FOREIGN KEY (provider_profile_id) REFERENCES provider_profiles(id) ON DELETE CASCADE
);

-- ===========================================================================
-- Knowledge
-- ===========================================================================

CREATE TABLE IF NOT EXISTS knowledge_bases (
    id                  TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    description         TEXT,
    type                TEXT NOT NULL DEFAULT 'local_folder',
    embedding_model_id  TEXT,
    index_path          TEXT,
    status              TEXT NOT NULL DEFAULT 'idle',
    file_count          INTEGER DEFAULT 0,
    chunk_count         INTEGER DEFAULT 0,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS knowledge_documents (
    id                  TEXT PRIMARY KEY,
    knowledge_base_id   TEXT NOT NULL,
    file_name           TEXT NOT NULL,
    file_path           TEXT NOT NULL,
    file_hash           TEXT NOT NULL,
    file_size           INTEGER NOT NULL,
    mime_type           TEXT,
    parser              TEXT,
    parser_version      TEXT,
    status              TEXT NOT NULL,
    page_count          INTEGER,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    UNIQUE (knowledge_base_id, file_hash),
    FOREIGN KEY (knowledge_base_id) REFERENCES knowledge_bases(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS knowledge_chunks (
    id                  TEXT PRIMARY KEY,
    document_id         TEXT NOT NULL,
    parent_chunk_id     TEXT,
    text                TEXT NOT NULL,
    heading_path        TEXT,
    page                INTEGER,
    sheet               TEXT,
    cell_range          TEXT,
    sequence            INTEGER NOT NULL,
    token_count         INTEGER,
    chunk_hash          TEXT NOT NULL,
    FOREIGN KEY (document_id) REFERENCES knowledge_documents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_chunks_doc ON knowledge_chunks(document_id, sequence);

-- 中文检索：应用层 bigram + FTS5（索引 token 由 Dart 侧 ChineseBigram.tokenize 生成）
-- 设计（第 2 轮 §3.2）：
--   bg 列只放**空格连接的 bigram tokens**（unicode61 按空格切分为独立 token）；
--   其余列 UNINDEXED —— 存储但不建索引，用于 WHERE 过滤 / 回连 / 删除；
--   正文**不**进 FTS（命中后按 chunk_id 回连 knowledge_chunks.text，避免重复存储）；
--   排序用 bm25(knowledge_chunks_fts)（越小越相关）。
CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_chunks_fts USING fts5(
    bg,
    chunk_id          UNINDEXED,
    document_id       UNINDEXED,
    knowledge_base_id UNINDEXED,
    tokenize = 'unicode61'
);

CREATE TABLE IF NOT EXISTS embedding_models (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    version     TEXT,
    dimension   INTEGER NOT NULL,
    runtime     TEXT NOT NULL,
    model_path  TEXT,
    checksum    TEXT
);

CREATE TABLE IF NOT EXISTS chunk_embeddings (
    chunk_id            TEXT NOT NULL,
    embedding_model_id  TEXT NOT NULL,
    dimension           INTEGER NOT NULL,
    vector_ref          TEXT NOT NULL,
    created_at          INTEGER NOT NULL,
    PRIMARY KEY (chunk_id, embedding_model_id),
    FOREIGN KEY (chunk_id) REFERENCES knowledge_chunks(id) ON DELETE CASCADE,
    FOREIGN KEY (embedding_model_id) REFERENCES embedding_models(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS expert_knowledge_bindings (
    expert_id           TEXT NOT NULL,
    knowledge_base_id   TEXT NOT NULL,
    priority            INTEGER NOT NULL DEFAULT 0,
    enabled             INTEGER NOT NULL DEFAULT 1,
    top_k               INTEGER NOT NULL DEFAULT 5,
    -- 语义：查询 bigram 的最低命中比例（coverage），默认 0.5（第 2 轮标定；见 kDefaultCoverageThreshold）
    similarity_threshold REAL NOT NULL DEFAULT 0.5,
    PRIMARY KEY (expert_id, knowledge_base_id),
    FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE,
    FOREIGN KEY (knowledge_base_id) REFERENCES knowledge_bases(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS message_citations (
    id              TEXT PRIMARY KEY,
    message_id      TEXT NOT NULL,
    document_id     TEXT,
    chunk_id        TEXT,
    file_name       TEXT,
    page            INTEGER,
    heading_path    TEXT,
    sheet           TEXT,
    cell_range      TEXT,
    quote_text      TEXT,
    score           REAL,
    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_citations_msg ON message_citations(message_id);

-- ===========================================================================
-- Market
-- ===========================================================================

CREATE TABLE IF NOT EXISTS market_sources (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    base_url        TEXT NOT NULL,
    enabled         INTEGER NOT NULL DEFAULT 1,
    last_refresh_at INTEGER
);

-- 市场包索引表。
-- 第 #58 轮 v7 新增 emoji / color 两列（**additive**）：远端索引自第 7 轮 T06
-- 起携带包自带 emoji 与主色（`MarketPackage.emoji`/`color` 域模型早已支持），
-- 但本表缺列 → 仓储丢字段 → 市场卡片回退「首字 + 确定性色」（用户走查反馈）。
-- 模式与第 3 轮 style_id / 第 6 轮 group_configs 三列相同：「**DDL 内置 +
-- ensureSchema v7 守卫 _addColumnIfMissing 双保险**」——新库建表即含两列
-- （守卫判存后 no-op）；老库（user_version ≤ 6，market_packages 有存量行）
-- 由守卫 ALTER 补列，既有行默认 NULL，**数据不丢、不重写**。
-- 第 #59 轮 v8 新增 slug 列（**additive**，同一模式）：slug 是安装目录
-- （`packages/<slug>-<version>`，market_page.dart 的 install()）与卡片标识的
-- 组成部分，**必须持久化**——v7 及之前本表未存该列，仓储 _package() 只能以空串
-- 还原 → 所有包的安装目录坍缩为同一个 `packages/-1.0.0`，每装一个专家就覆盖
-- 上一个的文件（用户走查「人才市场点添加没反应」根因之二；根因之一是 main.dart
-- 的 GlobalKey 未挂载致 currentState 恒 null，已由主理人修复）。新库建表即含
-- 该列（守卫判存后 no-op）；老库（user_version ≤ 7）由守卫 ALTER 补列，既有行
-- 默认 NULL、**数据不丢**——存量行 slug 由用户下次「刷新索引」经 replacePackages
-- 写入（verify_storage.dart 的 v7→v8 迁移节实证：升级后既有行 slug 为空串 →
-- refreshIndex 后写入真实值；迁移本身**不回填**业务字段，远端索引才是唯一事实源）。
CREATE TABLE IF NOT EXISTS market_packages (
    package_id      TEXT PRIMARY KEY,
    source_id       TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    profession      TEXT,
    description     TEXT,
    category_id     TEXT,
    tags_json       TEXT,
    latest_version  TEXT,
    sha256          TEXT,
    signature       TEXT,
    emoji           TEXT,
    color           TEXT,
    slug            TEXT,
    FOREIGN KEY (source_id) REFERENCES market_sources(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_market_cat ON market_packages(category_id);

CREATE TABLE IF NOT EXISTS market_versions (
    package_id      TEXT NOT NULL,
    version         TEXT NOT NULL,
    release_url     TEXT,
    sha256          TEXT NOT NULL,
    signature       TEXT,
    size_bytes      INTEGER,
    published_at    INTEGER,
    PRIMARY KEY (package_id, version),
    FOREIGN KEY (package_id) REFERENCES market_packages(package_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS installed_packages (
    installation_id TEXT PRIMARY KEY,
    package_id      TEXT NOT NULL,
    version         TEXT NOT NULL,
    install_path    TEXT NOT NULL,
    installed_at    INTEGER NOT NULL,
    local_modified  INTEGER NOT NULL DEFAULT 0,
    source          TEXT NOT NULL
);

-- ===========================================================================
-- Runtime
-- ===========================================================================

CREATE TABLE IF NOT EXISTS jobs (
    id              TEXT PRIMARY KEY,
    type            TEXT NOT NULL,
    status          TEXT NOT NULL,
    progress        REAL DEFAULT 0,
    retry_count     INTEGER DEFAULT 0,
    payload_json    TEXT,
    error_code      TEXT,
    error_message   TEXT,
    created_at      INTEGER NOT NULL,
    started_at      INTEGER,
    finished_at     INTEGER
);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status, type);

CREATE TABLE IF NOT EXISTS settings (
    key     TEXT PRIMARY KEY,
    value   TEXT NOT NULL
);

-- ===========================================================================
-- v4 新增（第 4 轮）：知识库「文件夹关联」
-- ===========================================================================

-- 关联文件夹登记表。folder_path 存第 4 轮设计 §2.1 定义的比较键（小写），
-- 并声明 COLLATE NOCASE：即使调用方绕过服务层直接写入未规约的原始路径，
-- UNIQUE 也在 DB 层拦截大小写变体重复关联（防御纵深）；
-- display_path 存用户选择时的原样路径，仅供 UI 展示与文件系统 IO（存储原样、
-- 比较用键——路径三律）。
-- knowledge_documents.folder_id 为**逻辑外键**指向本表（SQLite 无法事后 ADD FK
-- 且禁重建表，与第 3 轮 group_id 同一处理）；folder 行删除时的文档处理由
-- 服务层 FolderSyncService 保证（unlink 二选一语义），不依赖 DB 级联。
CREATE TABLE IF NOT EXISTS knowledge_base_folders (
    id                TEXT PRIMARY KEY,
    knowledge_base_id TEXT NOT NULL,
    folder_path       TEXT NOT NULL COLLATE NOCASE,
    display_path      TEXT NOT NULL,
    recursive         INTEGER NOT NULL DEFAULT 1,
    last_scan_at      INTEGER,
    created_at        INTEGER NOT NULL,
    UNIQUE (knowledge_base_id, folder_path),
    FOREIGN KEY (knowledge_base_id) REFERENCES knowledge_bases(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_kb_folders_base ON knowledge_base_folders(knowledge_base_id);

-- knowledge_documents.folder_id（TEXT）/ source_mtime（INTEGER）两列**只走迁移**：
-- 由 ensureSchema 的 v4 守卫以 _addColumnIfMissing 补齐（ALTER 无 IF NOT EXISTS），
-- **不写进本 schema.sql 正文**（与第 3 轮 style_id、第 6 轮 group_configs 三列的
-- 「**DDL 内置 + 守卫双保险**」模式不同——两种模式并存，均幂等，按各列的历史选择为准）。

-- ===========================================================================
-- v6 新增（第 8 轮）：会话附件（文件 / 图片）
-- ===========================================================================
-- 归属判定：message_id 外键（ON DELETE CASCADE）→ 附件只随消息生死。
-- 双保险：DDL 级联 + 服务层显式 deleteByMessage + 物理文件按 DB 引用计数清理
--         （countByStoredPath；绝不扫盘——归属红线）。
-- stored_path 为内容寻址绝对路径 <data>/attachments/<sha256[0:2]>/<sha256>.<ext>：
-- 同内容复用同一物理文件，不复制两份。
-- sent_to_model_at / width / height / page_count 为二期 vision 预留，本期恒 NULL。
CREATE TABLE IF NOT EXISTS message_attachments (
    id                TEXT PRIMARY KEY,
    message_id        TEXT NOT NULL,
    kind              TEXT NOT NULL DEFAULT 'file',
    file_name         TEXT NOT NULL,
    stored_path       TEXT NOT NULL,
    sha256            TEXT NOT NULL,
    size_bytes        INTEGER NOT NULL,
    mime_type         TEXT,
    width             INTEGER,
    height            INTEGER,
    page_count        INTEGER,
    sent_to_model_at  INTEGER,
    created_at        INTEGER NOT NULL,
    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_attachments_msg ON message_attachments(message_id, created_at);
CREATE INDEX IF NOT EXISTS idx_attachments_sha ON message_attachments(sha256);

-- ===========================================================================
-- sqlite-vec 向量表（加载扩展后创建；未加载时跳过）
-- ===========================================================================
-- CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
--     chunk_id TEXT PRIMARY KEY,
--     embedding FLOAT[512]
-- );
''';
