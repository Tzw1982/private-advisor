# 工程契约 02 · Database ER + Migration

> 版本：1.0.0 ｜ 对应 V1.3 §26 / §27 / §39 / §40
> 存储分工：**SQLite(raw SQL) = 业务关系数据** ｜ **OS Secure Storage = Secret** ｜ **向量检索：当前为 FTS5 中文检索（第 2 轮）**
>
> ⚠️ **as-built 提示（第 1、2 轮实现后回填）**：本文档为 V1.3 原始设计契约，**部分内容已随实现变更**，与实现冲突处以《私人顾问团_V1.3_系统架构与数据模型设计.md》的偏差记录为准：
> - **§51.2 偏差一**：数据库驱动由 **Drift → `sqlite3` raw SQL**（本文档下文凡提 Drift 均已过时）；
> - **§51.9 偏差三**：SQLite 实现迁出为独立纯 Dart 包 `advisor_storage`，**canonical DDL = `advisor_storage/lib/src/database/schema.sql`**（原 `app/lib/infrastructure/database/` 随迁移**已整体删除**）；
> - **§51.11 偏差四**：中文检索由 **ONNX `bge-small-zh` + `sqlite-vec` → FTS5 + 应用层中文 bigram 的纯 Dart 方案**（`VectorStore` / `EmbeddingModel` 端口保留可插拔）。

---

## 1. ER 总览

```
provider_profiles ──1:N── model_profiles
        │
        └──1:N── credential_profiles            (SQLite 只存 secret_ref)

experts ──1:1── expert_runtime_configs
        ├─1:1── expert_user_states
        ├─N:M── tags (via expert_tag_relations)
        ├─N:M── knowledge_bases (via expert_knowledge_bindings)
        └─1:N── conversation_members ──N:1── conversations ──1:N── messages
                                                         └─1:1── group_configs (群聊配置，仅 type=group)
                                                                  │
generation_runs ──1:N── generation_steps ──1:N── generation_events
                     └── messages.output_message_id

knowledge_bases ──1:N── knowledge_documents ──1:N── knowledge_chunks ──1:N── chunk_embeddings
                                                          └── message_citations

market_sources ──1:N── market_packages ──1:N── market_versions
                                   └── installed_packages (installation_id)

jobs
settings
```

---

## 2. 表清单（31 张）

| 分组 | 表 |
|---|---|
| Expert | `experts` `expert_runtime_configs` `expert_user_states` `tags` `expert_tag_relations` |
| Conversation | `conversations` `conversation_members` `group_configs` `messages` `message_attachments` |
| Generation | `generation_runs` `generation_steps` `generation_events` |
| Knowledge | `knowledge_bases` `knowledge_documents` `knowledge_chunks` `embedding_models` `chunk_embeddings` `expert_knowledge_bindings` `message_citations` |
| Provider | `provider_profiles` `model_profiles` `credential_profiles` |
| Market | `market_sources` `market_packages` `market_versions` `installed_packages` |
| Runtime | `jobs` `settings` |
| 分组（第 3 轮 v3 新增） | `expert_groups` |
| 关联文件夹（第 4 轮 v4 新增） | `knowledge_base_folders` |

> 上述 31 张为**业务表**（`schema.sql` 中 `CREATE TABLE` 计数；第 3 轮 v3 由 28 → 29，第 4 轮 v4 由 29 → 30，**第 8 轮 v6 由 30 → 31（新增 `message_attachments`）**；第 6 轮 v5 / 第 #58 轮 v7 / 第 #59 轮 v8 / 第 #66 轮 v9 均为**纯加列、无新表**——表数不变，仍 31）；另有 **1 张 FTS5 虚表** `knowledge_chunks_fts`（第 2 轮新增，中文检索用）——运行期 `sqlite_master` 计 **37 张**（含 5 张 FTS5 影子表）。

> DDL 以 **`advisor_storage/lib/src/database/schema.sql`**（canonical）为**唯一事实来源**；本文档只做约束说明。
> （原 `app/lib/infrastructure/database/tables/` 下的 Drift 定义已随第 1 轮迁移**整体删除**，勿再引用。）

---

## 3. 关键约束

### 3.1 禁止存明文 Secret
- `credential_profiles.secret_ref` 仅存引用键（如 `cred_<uuid>`）。
- 真值只存在于 OS Secure Storage（`flutter_secure_storage`）。
- **任何表都不得出现 api_key / token 明文列。**

### 3.2 向量存储（as-built）
- `chunk_embeddings` 只存 `vector_ref`（**对向量索引的引用键**，不含向量本体）。
- **当前状态（第 2 轮）**：中文检索**不走向量**，改用 **FTS5 + 应用层中文 bigram**（见 §51.11）；`sqlite-vec` **未加载**，`vec_chunks` 虚表在 `schema.sql:446` 为**注释态**（未创建）。
- 上层**只经 `VectorStore` / `EmbeddingModel` 端口**访问，不直接依赖任何具体向量实现（V1.3 §13）——**端口保留**，将来环境允许可插拔换回。

### 3.3 级联与事务边界（V1.3 §40）

| 操作 | 必须同一事务完成 |
|---|---|
| 安装专家 | `installed_packages` + `experts` + `expert_runtime_configs` + `expert_user_states` |
| 删除专家 | `experts` + `expert_runtime_configs` + `expert_user_states` + `expert_tag_relations` + `expert_knowledge_bindings` + `conversation_members` |
| 删除知识库 | `expert_knowledge_bindings` + `message_citations` + `chunk_embeddings` + `knowledge_chunks` + `knowledge_documents` + `knowledge_bases` + FTS5 索引 `knowledge_chunks_fts` |

### 3.4 外键
- 全部外键开启 `PRAGMA foreign_keys = ON`。
- `knowledge_documents` 对 `(knowledge_base_id, file_hash)` 建唯一索引（去重）。
- `expert_user_states.group_id` → `expert_groups.id` 为**逻辑外键**（**无 DB 级 FK**，第 3 轮 v3 裁定）：删分组时由服务层（`ExpertService.deleteGroup`）**先清空成员 `group_id` 再删分组**，保证无悬挂引用。
- `knowledge_documents.folder_id` → `knowledge_base_folders.id` 为**逻辑外键**（**无 DB 级 FK**，第 4 轮 v4 裁定，同 `group_id` 处理）：`folder_id` 是文档归属的**登记事实**（归属判定 = `WHERE folder_id = ?`，**严禁路径前缀推断**）。`knowledge_base_folders.folder_path` 存路径**比较键**（canonicalize + 小写）并声明 `COLLATE NOCASE`——`UNIQUE(knowledge_base_id, folder_path)` 在 DB 层拦截大小写变体重复关联；folder 行删除时文档处置由服务层（`FolderSyncService.unlinkFolder`）二选一语义负责（仅解除关联 → 文档 `folder_id` 置 NULL 变孤儿 / 解除并删除 → 精确列表逐个 `deleteDocument`），`folder_id IS NULL` 的孤儿文档任何同步路径不触碰。

---

## 4. Migration 原则（V1.3 §39）

```
禁止：启动时 DROP / CREATE 重建
要求：v1 → v2 → v3 …，每步
      ├─ 幂等（可重复执行）
      ├─ 失败可恢复
      ├─ 执行前备份 advisor.sqlite
      └─ 写升级日志 logs/migration.log
```

- 采用 **`PRAGMA user_version`** 顺序迁移（当前 **v9**），由 `advisor_storage` 的 `applySchema` / `ensureSchema` 执行；迁移脚本纯加性、可重复执行。
- **v2 → v3（第 3 轮，纯加性）**：
  1. 新建表 `expert_groups`（好友分组，见 §2）；
  2. `expert_user_states` 加可空列 `style_id TEXT`（专家风格，见契约 01 §4）。
  实现：`ensureSchema` 以 `user_version` 为守卫，`ALTER TABLE ADD COLUMN` 前用 `PRAGMA table_info` 判存**双保险**（版本号被手动回退也不会重复加列或崩溃）；列已存在时跳过，可重复执行。
- **v3 → v4（第 4 轮，纯加性）**：
  1. 新建表 `knowledge_base_folders`（关联文件夹登记，见 §2；`folder_path` 存比较键 + `COLLATE NOCASE`）；
  2. `knowledge_documents` 加可空列 `folder_id TEXT`（来源关联，逻辑外键见 §3.4）与 `source_mtime INTEGER`（重扫增量快速路径依据：mtime+size 命中则零内容读取，未命中再 sha256 确认）。
  实现：与 v3 同一 `_addColumnIfMissing` 双保险模式；存量文档两列为 NULL（等待补绑回填 / 首次重扫建立）。
- **v4 → v5（第 6 轮，纯加性，无新表）**：`group_configs` 加 3 个可空列（群聊体验改造，见任务 #32）：
  1. `announcement TEXT` —— **群公告 / 共识**（"建立本群共识"的载体）；空 / 未设 = 无。经 `GroupPromptComposer.consensusBlock` 注入**每位发言者（含总结者）**的 system（硬契约）；
  2. `announcement_updated_at INTEGER` —— 公告更新时间（UI 展示"最后更新"）；
  3. `max_speakers_per_round INTEGER` —— 单轮发言者上限（防刷屏）；**NULL 视为默认 3**（服务层兜底）。
  实现：`kSchemaVersion = 5`；`ensureSchema` 增 `if (current < 5) { 三个 _addColumnIfMissing }`（版本守卫 + `PRAGMA table_info` 判存双保险）；存量 `group_configs` 三列为 NULL（等待用户首次编辑）。**无新表、无 schema.sql 正文新增段**（纯加列，`applySchema` 分号约束不受影响）。
- **v5 → v6（第 8 轮，additive，有 1 张新表）**：会话附件上传（任务 #45 / 待办 #17）。
  1. **新建表** `message_attachments`（会话附件；`message_id` 外键指向 `messages(id)` **ON DELETE CASCADE**——删消息即级联删登记）；
  2. **新建 2 索引** `idx_attachments_msg(message_id, created_at)` 与 `idx_attachments_sha(sha256)`（按消息批量查、按内容寻址计数）。
  - **是否 additive**：**是**。**只有新增表 / 索引，无任何 `ALTER TABLE`、无 `DROP`、无列类型变更**。
  - **对存量数据的影响**：既有表与既有行**零改动**；新表初始为空。`kSchemaVersion` 5 → 6。`ensureSchema` 守卫内为 **no-op 空分支**——新表 / 新索引全部由 `schema.sql` 的 `CREATE TABLE/INDEX IF NOT EXISTS` 经 `applySchema` 一次性建好，无需 `ALTER`；守卫分支仍显式保留只为**链式可读性**（防后人误以为漏迁移）。`schema.g.dart` 由 `schema.sql` 重生成（逐字一致）。
- **v6 → v7（第 #58 轮，additive，无新表）**：修复「专家 emoji 不显示」（根因：`market_packages` 缺 `emoji`/`color` 列，仓储丢字段）。
  1. `market_packages` 加 2 个可空列：`emoji TEXT`、`color TEXT`（市场包自带头像 emoji / 底色）。
  - **是否 additive**：**是**。仅加可空列，**无新表、无 `DROP`**；`emoji`/`color` **同时**写进 `schema.sql` 的 canonical DDL（与第 3 轮 `style_id` / 第 6 轮 `group_configs` 三列同模式），并保留 `PRAGMA user_version < 7` 守卫 + `_addColumnIfMissing` 判存**双保险**。
  - **对存量数据的影响**：老库由守卫补列，既有行默认 **NULL**（既有 284 行索引数据不丢）；新库建表即含两列（守卫判存后 no-op）。存量行 emoji/color **不在迁移中回填**——远端索引才是唯一事实源，由用户下次「刷新索引」经 `replacePackages` 写入（`verify_storage` v6→v7 迁移节实证）。`kSchemaVersion` 6 → 7。
- **v7 → v8（第 #59 轮，additive，无新表）**：修复「点击添加没反应」根因之二（`MarketPackage.slug` 从未持久化 → 安装目录全部坍缩为 `packages/-1.0.0`）。
  1. `market_packages` 加 1 个可空列：`slug TEXT`（安装目录拼接依据：`packages/<slug>-<version>`）。
  - **是否 additive**：**是**。仅加可空列，**无新表、无 `DROP`**；同样「DDL 内置 + 守卫双保险」（`PRAGMA user_version < 8` + `_addColumnIfMissing`）。
  - **对存量数据的影响**：老库由守卫补列，既有行默认 **NULL / 空串**；存量行 `slug` **不在迁移中回填**（远端索引才是唯一事实源），由用户下次「刷新索引」经 `replacePackages` 写入；在写入前，存量包安装仍走旧路径（`verify_storage` 含该关键路径断言）。`kSchemaVersion` 7 → 8。
- **v8 → v9（第 #66 轮，additive，无新表）**：修复「添加到通讯录后 emoji 头像回退首字」。
  1. `experts` 加 2 个可空列：`avatar_emoji TEXT`（市场包 emoji，如 `🤖`）、`avatar_color TEXT`（emoji 底色，`#RRGGBB` 或色名）。
  - **是否 additive**：**是**。仅加可空列，**无新表、无 `DROP`**；与第 #58 轮 `market_packages.emoji`/`color` 同模式「DDL 内置 + 守卫双保险」（`PRAGMA user_version < 9` + `_addColumnIfMissing`）。
  - **对存量数据的影响**：老库由守卫补列，既有专家行默认 **NULL** → UI 回退「首字 + 确定性色」，**零行为回归**；存量行 **不在迁移中回填**；新安装的专家由 `MarketService.installPackage` 从市场索引读出 emoji/color 一并落库；存量**市场来源**专家由**启动期** `MarketService.backfillExpertAvatars()` 按 `packageId` 从本地索引**幂等回填**（不回写 `expert_user_states` 业务字段）。`kSchemaVersion` 8 → 9。
  - 字段语义与回填行为详见《私人顾问团_V1.3_系统架构与数据模型设计.md》§6.1。
- M3 之后**只允许 additive migration**（加表 / 加可空列），禁止改列类型或删列；**禁止 `DROP` / `CREATE` 重建**。
- 每次升级前把 `database/advisor.sqlite` 复制到 `database/backup/advisor.v<n>.sqlite`。

---

## 5. 本地文件布局（V1.3 §38）

```
%APPDATA%/PrivateAdvisor/
├── database/  advisor.sqlite (+ backup/)
├── market/    cache/  packages/
├── experts/   instances/<expertId>/
├── knowledge/ sources/  indexes/  models/
├── avatars/   <expertId>.png          （第 6 轮 T05 头像拟人化；约定路径，不写 DB / 不动 schema）
├── logs/      app.log generation.log market.log knowledge.log error.log
└── temp/
```
> Secret **不在此目录**（由 OS 凭据库托管）。
> **头像约定（第 6 轮 T05）**：`<data>/avatars/<expertId>.png` 由 `AvatarResolver` 按 `expertId` **约定推导**（`Image.file` 存在才显示，缺失 / 损坏 → 回退首字 / emoji）；PNG 由**批处理**一次性生成（见 `app/tool/gen_avatars.md`），app 运行时**无图像生成服务**，不做 DB 写入、不新增 schema。

---

## 6. 索引建议

| 表 | 索引 |
|---|---|
| `messages` | `(conversation_id, created_at)` |
| `conversation_members` | `(expert_id)` |
| `generation_steps` | `(run_id, sequence)` |
| `knowledge_chunks` | `(document_id, sequence)` |
| `expert_knowledge_bindings` | `(knowledge_base_id)` |
| `market_packages` | `(category_id)`、`(display_name)` |

> **as-built 实际已建索引**（`schema.sql`，共 **11 个**）：`messages(conversation_id, created_at)`、`generation_runs(conversation_id, started_at)`、`generation_steps(run_id, sequence)`、`generation_events(step_id, sequence)`、`knowledge_chunks(document_id, sequence)`、`message_citations(message_id)`、`market_packages(category_id)`、`jobs(status, type)`、`knowledge_base_folders(knowledge_base_id)`（第 4 轮 v4 新增 `idx_kb_folders_base`）、`message_attachments(message_id, created_at)` 与 `message_attachments(sha256)`（第 8 轮 v6 新增 `idx_attachments_msg` / `idx_attachments_sha`）。
> 上表中**尚未建**的项（保留为建议，未建不影响功能）：`conversation_members(expert_id)`、`expert_knowledge_bindings(knowledge_base_id)`、`market_packages(display_name)`。
