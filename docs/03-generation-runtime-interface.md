# 工程契约 03 · Generation Runtime Interface

> 版本：1.0.0 ｜ 对应 V1.3 §8 / §9 / §24 / §25 / §26
> 核心承诺：**每一次 AI 运行都有 Run / Step / Event，可取消、可重试、可追踪、可落库。**

---

## 1. 三层运行模型

```
GenerationRun    一次用户提问触发的完整运行（单聊=1 run；群聊=1 run 多 step）
   └─ GenerationStep   每个发言者 / 每个阶段一步
        └─ GenerationEvent  流式增量事件
```

---

## 2. 领域类型

### 2.1 GenerationRun
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | run 标识 |
| `conversationId` | string | |
| `triggerMessageId` | string? | 触发它的用户消息 |
| `runType` | enum | `single_chat` / `group_chat` / `summarization` / `retrieval` |
| `status` | enum | `queued` / `running` / `completed` / `cancelled` / `failed` / `partial` |
| `modelProfileId` | string? | |
| `tokenBudget` | int? | |
| `promptTokens` / `completionTokens` | int | 累计 |
| `estimatedCost` | double | |
| `startedAt` / `endedAt` | int(ms)? | |
| `errorCode` / `errorMessage` | string? | |

### 2.2 GenerationStep
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` / `runId` | string | |
| `expertId` | string? | 发言者（synthesis 阶段可为 null） |
| `stage` | enum | `planning` `routing` `retrieval` `generation` `dedup` `critic` `synthesis` `validation` |
| `sequence` | int | 顺序 |
| `status` | enum | 同 Run |
| `retrievalCount` | int | 命中知识片段数 |
| `promptTokens` / `completionTokens` | int | |
| `latencyMs` | int? | |
| `outputMessageId` | string? | 产出的消息 |
| `errorCode` / `errorMessage` | string? | **单步失败不影响其它步**（Fail Soft） |

### 2.3 GenerationEvent
| 字段 | 类型 |
|---|---|
| `id` / `stepId` / `sequence` | string / string / int |
| `eventType` | `run_started` `step_started` `token_delta` `reasoning_delta`（第 3 轮新增）`step_completed` `step_failed` `run_completed` `run_failed` |
| `delta` | string? |
| `createdAt` | int(ms) |

### 2.4 Message 状态机（**第 7 轮补齐**）

> **背景（契约遗漏的定性）**：原契约（§2.1–2.3、§5）只定义了 **Run / Step** 状态机与 Fail Soft，**从未定义 Message 状态机、也未定义"失败路径的消息终态"**。QA 独立脚本 `advisor_core/tool/qa_verify_single_chat.dart` 抓到的"**失败留永久空白气泡**"（占位消息永远停在 `streaming`）即该遗漏的直接后果——**属契约遗漏，非单纯实现遗漏**。

| `status` | 语义 | 谁写入（as-built 位置） | 何时 | 终态 |
|---|---|---|---|---|
| `queued` | 已入队待生成（**保留**，当前消息级无写入者） | — | — | 否 |
| `streaming` | **占位 / 流式生成中** | `Message.expert(...)` 默认（`conversation.dart:212`）；单聊 / 群聊生成前插入占位 | 生成前 | 否 |
| `completed` | 正常完成（正文经 `ReasoningStripper` 剥离 + `clampOutput` 裁剪后落库） | 单聊成功 `services.dart:1155-1157`；群聊成功 `:1680-1685`；`appendExpertMessage` 默认 `:646`（no-answer / 总结 / 系统类） | 流结束 + 剥离后 | **是** |
| `cancelled` | **已结束**但被中止或静默 | ① 用户取消：单聊 `:1155-1157`（cancelled 分支）；② **第 6 轮静默契约**：群聊 `:1656-1678`（成员自判无关 → **正文清空**） | 取消 / 自判无关 | **是** |
| `failed` | 生成失败 | **目标（第 7 轮修复）：单聊 catch `:1196-1215` + 群聊 Fail-Soft 单成员 catch `:1760-1772`**；**当前缺失**（全库 `MessageStatus.failed` 零写入者 = 缺陷指纹） | run / step 失败时 | **是** |
| `partial` | 部分完成（**保留**；当前消息级无写入者，仅 step 用 `RunStatus.partial` 表达去重/跑题/静默） | — | — | **是** |

**终态集合 = `{completed, cancelled, failed, partial}`；非终态 = `{queued, streaming}`。**

### 2.5 失败路径消息终态契约（**硬契约**）

1. **一致性铁律**：run 进入终态（`completed/cancelled/failed/partial`）时，**该 run 名下所有占位消息必须与 run 状态一致地进入终态**——**不得留任何 `streaming`**。
2. **单聊失败**：`catch` 中除 `step` / `run` 置 `failed` 外，**必须** `updateMessage(占位消息.copyWith(status: failed, ...))`（保留已累积正文或为空），并保证 UI 给出失败提示（见 §2.6）。
3. **群聊 Fail-Soft 单成员失败**：该成员占位消息**必须**置 `failed`（其余成员不受影响）——"单步失败不影响其它步"（§5）**不等于**"失败消息可以悬空在 `streaming`"。
4. **QA 可测断言**：① run 结束后，该 run 产出的消息中 `status='streaming'` 计数**必须为 0**；② 全库 `grep -rn "MessageStatus.failed" advisor_core/lib/` **应 ≥ 1**（修复前为 0，即缺陷指纹）；③ 单聊失败用例：断言存在 `status=failed` 的专家消息且**非空 UI 提示**。

### 2.6 `isFinal` 语义与 app 渲染契约（**第 7 轮裁定**）

**裁定**：`bool get isFinal => status ∈ {completed, partial, cancelled, failed}` —— **`failed` 与 `cancelled` 均纳入**。

**理由**：`isFinal` 的语义应是"**该消息是否已停止变化（不可能再产生新内容）**"。`failed`（出错）与 `cancelled`（中止/静默）都不会再有内容 → **必须算终态**；当前 `isFinal` 只认 `completed/partial`，一旦将来有人用它判断"是否仍在生成中"，会把失败/取消消息**误判为"仍在进行"**（该 getter 当前是死代码，但语义必须现在就补正）。

**`cancelled` 与 `failed` 的差异（务必区分，勿混为一谈）**：

| 维度 | `cancelled` | `failed` |
|---|---|---|
| 语义 | **已结束**（用户取消 / 第 6 轮静默契约"未参与"） | **出错**（未配模型 / Key 无效 / 网络断 / 限流×） |
| 正文 | 用户取消：保留已累积；**静默契约：清空** | 保留已累积（或空） |
| UI 渲染 | 取消：灰/斜体（`conversation_view.dart:540-543`）；**静默契约：不出气泡**（`:506` 过滤 `cancelled && content.trim().isEmpty`） | **必须给出明确失败提示**（不得空白气泡），建议关联重试入口 |
| 归属 | 第 6 轮静默契约 / 取消语义 | **第 5/7 轮 UI 规格（失败态）** |

**app 侧 `failed` 渲染规格（硬要求，归入第 5/7 轮 UI 规格）**：
- `failed` 消息**必须**渲染为**明确失败提示**（示意："生成失败：<原因>（可重试）"），**禁止**渲染为空白气泡；
- 与静默契约的 `cancelled` **严格区分**：同样"空内容"，**`failed` 要出提示、`cancelled` 才静默**；
- 建议判定顺序：先判 `failed` → 出失败提示；再判 `cancelled && content.trim().isEmpty` → 不渲染；其余按正常气泡渲染。

### 2.7 run 级失败字段契约（`errorCode` / `errorMessage`，**第 7 轮补**）

> **背景（同 §2.4，属契约遗漏）**：原契约 §2.1 只把 `errorCode`/`errorMessage` 列为 `string?`，**从未规定"失败时必须回填"**。后果：单聊失败回填（参考实现 `services.dart:1221-1226`，且 `yield RunFailedUpdate`），**群聊终态不回填**（`:1875-1885` 无 `errorCode`）→ **全员失败时 `run.errorCode = null` 而 step 有码（两族口径不一）**。

**硬契约（单聊 / 群聊两族口径一致）**：

| run 终态 | `errorCode` / `errorMessage` | 判据 / 取值 |
|---|---|---|
| `failed` | **必须回填** | 取该 run 内**首个失败 step** 的 `(errorCode, errorMessage)`（群聊 = 首个失败成员；单聊 = 该次生成）。run 码与 step 码**一致** |
| `partial` | **不得回填（保持 `null`）** | run **未失败**；成员级失败细节只存在于其 step（`status=failed` + `errorCode`）与该消息（§2.4 Message = `failed`） |
| `completed` / `cancelled` | 不回填 | — |

- **语义铁律**：`run.errorCode` = "**run 整体失败的原因**"，**不是**"run 内任一 step 失败的原因"。据此——只要 run 未进入 `failed`，`errorCode` 必须为 `null`（避免把"某成员失败"误报为"整轮失败"）。
- **谁写 / 何时写**：单聊 `runSingleChat` 的 `catch`；群聊 `runGroupChat` 的**终态计算处**（`upsertRun` 之前）。
- **可测断言**：① 群聊**全员失败** → `run.status==failed && run.errorCode != null`（且 == 首个失败成员 step 的码）；② 群聊**单成员失败**（其余成功）→ `run.status==partial && run.errorCode == null`；③ 单聊失败 → `run.errorCode != null`（现有行为，保持不回归）。

### 2.8 总结者失败契约（状态一致性 + 可观测，**第 7 轮补**）

> **背景（静默失败，比错误更糟）**：总结者 `catch`（`services.dart:1865-1872`）只置 `sStep=failed`，**不置任何失败标志** → 成员全成功 + 仅总结者失败时，run 落 `completed`（`:1875-1877`），**无总结、无任何失败提示**；且**群聊从不产出 `RunFailedUpdate`**（全库仅单聊 `:1228` 有）→ "总结失败"当前**在 UI 上完全不可见**。

**A. 状态一致性（硬要求）**：总结者失败**必须**使 run 落 **`partial`**（非 `completed`、非 `failed`）。

- **依据**：§5"全部失败 → run = `failed`"的**反面**——主产物（成员发言）已产出、期望的总结缺失 = "**部分完成**"，正是 `partial` 语义。落 `completed` = **谎报成功**；落 `failed` = **抹杀已产出的成员发言**。
- **实现规约**：总结 `catch` 置**独立标志** `summarizerFailed = true`（**不要复用 `anyFailed`**，避免"成员失败"与"总结失败"语义混淆），并回填 `sStep.errorCode`（承接 §2.7 的 step 级口径）。终态按真值表计算：

| `accepted`（非跳过成员输出数） | `anyFailed`（成员） | `summarizerFailed` | run 终态 |
|---|---|---|---|
| 0 | 是 | —（未触发） | `failed` |
| 0 | 否 | — | `completed` |
| ≥1 | 是 | 任意 | `partial` |
| ≥1 | 否 | **是** | **`partial`** ← 本契约修复点 |
| ≥1 | 否 | 否 | `completed` |

**B. 可观测性（硬要求：必须可见）**：静默失败不可接受——用户会误以为"本轮没有小结是因为无需总结"。

1. **新增 `SummaryFailedUpdate`（`GenerationUpdate` 第 8 类，定义在 `application/services.dart`）**：携带 `expertId`（总结者）与 `error(AppError)`；群聊总结 `catch` 中 `yield`。UI 的**穷尽 `switch` 必须新增分支**（不处理则编译失败，**强制不漏**）。
2. **群聊 `run === failed` 时 `yield RunFailedUpdate`**（与单聊一致）——一并修复"群聊从不产出失败事件"，使**两族可观测性一致**。
3. **app 渲染规格（归属第 5/7 轮 UI 规格）**：
   - **位置**：会话**消息流末尾**（本轮已渲染消息之后、输入框之上）；
   - **形态**：**居中提示条**，复用现有 `_errorBanner` 视觉语言（`conversation_view.dart:448-470`：淡红底 + 错误色文字 + "重试"按钮）——**不得**渲染为专家空白气泡、**不得静默**；
   - **文案**：**"本轮未产出会议纪要（总结失败：<原因>）。可重试。"**
   - **历史重载**：`RunFinishedUpdate` 后重载时，若**最近一次 group run 的 synthesis step == `failed`** → 同样补提示（用 `GenerationRepository.listRuns/listSteps` 判定，**纯接线，core/storage 零改动**）；
   - **与 §2.6 的 `failed` 消息提示区分**：§2.6 是"**某成员气泡**失败"，本处是"**整轮纪要缺失**"——两者可同现，各自独立渲染。
4. **可测断言**：① "成员全成功 + 总结抛错" → `run.status==partial` 且流中出现 `SummaryFailedUpdate`、且 `run.errorCode == null`（承接 §2.7）；② 群聊全员失败 → 流中出现 `RunFailedUpdate`；③ UI 走查：纪要缺失时有可见提示条。

---

## 3. Provider 适配接口（V1.3 §26）

```dart
abstract interface class LlmProvider {
  String get providerId;
  Future<List<ModelDescriptor>> listModels();
  Future<ChatResponse> chat(ChatRequest request);
  Stream<StreamEvent> stream(ChatRequest request);
  Future<ProviderHealth> healthCheck();
  AppError mapError(Object raw);
}
```

- `ChatRequest`: `model, messages[], temperature?, topP?, maxTokens?, stream, responseFormat?`
- `StreamEvent`: `token(text)` / `reasoning(text)`（第 3 轮新增：模型思考通道，如 DeepSeek `reasoning_content`） / `usage(promptTokens, completionTokens)` / `error(AppError)` / `done()`
- **取消**：`stream()` 返回的 Stream 被 `cancel()` 时必须中止底层 HTTP 连接。
- **思考三分法（第 3 轮）**：
  - **A① 思考通道隔离**：`reasoning_content` → `StreamEvent.reasoning` → `GenerationEvent(reasoning_delta)` 落库**仅供排查**，**绝不进 `messages.content`**，UI 对话界面不显示思考过程；
  - **A② 正文保守剥离**（`ReasoningStripper`）：对模型把思考混进正文的情况，仅剥离**显式围栏**（`【思考】…【/思考】` / `[思考]…[/思考]` / `<!--thinking-->` / ` ```thinking `）与**段首元叙述短句**（opener+verb、长度 ≤30 字符）；**正文中间不剥离**、整段疑似元叙述时回退原文（宁可漏剥、不可误剥）。

---

## 4. 群聊编排接口（V1.3 §24）

```dart
abstract interface class SpeakingStrategy {
  String get id;                        // manual | round_robin | weighted | auto
  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx);
}

class GroupContext {
  final String conversationId;
  final Message userMessage;
  final List<Message> recentMessages;
  final List<GroupMember> members;      // 含 weight / enabled
  final List<Citation> knowledgeEvidence;
  final TokenBudget budget;
  final List<ExpertOutput> previousSpeakerOutputs;
  final int round;                      // 当前轮次（默认 0）
  final String? lastSpeakerId;          // 上一轮发言者（轮流策略使用）
}

class SpeakerPlan {
  final List<String> primarySpeakers;   // 有序
  final List<String> fallbackSpeakers;
  final int maxRounds;
  final String rationale;
}
```

内置 4 种策略：`ManualStrategy`（@指定）、`RoundRobinStrategy`、`WeightedStrategy`、`AutoStrategy`（默认）。
**第 6 轮新增第 5 种**：`LeaderLedStrategy`（id `leader_led`，label「组长主持（推荐）」）——见 §12.1。

---

## 5. 群聊流水线（V1.3 §25）

```
用户问题
  → createRun(group_chat)
  → buildGroupContext()
  → strategy.selectNextSpeakers() → SpeakerPlan
  → for speaker in plan:
        step = createStep(stage: generation)
        evidence = knowledge.retrieveForExpert(speaker)      // stage: retrieval
        if grounding==strict && evidence.isEmpty:
             markStepNoAnswer(); continue                    // 不调用 LLM
        generate(step, speaker, evidence)                    // 流式 → events
        if dedup.isDuplicate(output): markDuplicate(); continue       // 去重：无条件丢弃
        if offTopic.isOffTopic(output)
             && offTopic.skipEnabled
             && output.length > 40:
             markOffTopic(); continue                        // 跑题：默认**不**丢弃（见下）
  → synthesis = summarizer.summarize(acceptedOutputs)         // stage: synthesis
  → citationValidator.validate(synthesis)                     // stage: validation
  → persist(run)                                              // 一个事务
```

**Fail Soft**：任何 step 抛错 → 该 step 标 `failed`，run 继续；全部失败 → run = `failed`。

> **去重 vs 跑题（二者行为不同，务必区分，勿混淆）**：
> - **去重 `DuplicateDetector`**：命中即**无条件丢弃**该输出（`markDuplicate(); continue`）。
> - **跑题 `OffTopicDetector`**：**默认只记录信号、不丢弃输出** —— `skipEnabled` 默认 `false`；仅当显式 `OffTopicDetector(skipEnabled: true)` **且** 输出长度 > 40 时才丢弃。此为 §51.4 行为决策：实测短指令（"继续""开始"）会被词面重合度启发式误判为跑题，整段丢弃属不可接受的内容损失。
> - **如需强约束**：显式构造 `OffTopicDetector(skipEnabled: true)`。

---

## 6. 上下文管理（V1.3 §10）

```dart
abstract final class ContextManager {
  static List<ChatMessage> build({
    required String systemPrompt,
    String styleDirective = '',              // 第 3 轮新增：风格指令（v3）
    required String userTask,
    List<Message> recentMessages = const [],
    List<Citation> evidence = const [],
    TokenBudget budget = TokenBudget.defaults,
    bool strictGrounding = false,
  });
}
```
预算参数：`maxContextTokens` / `maxGroupHistory` / `maxExpertOutput` / `maxTotalGroupBudget`。
构成：`RecentMessages` + `SummaryMemory` + `CurrentUserTask` + `ExpertRelevantMessages` + `KnowledgeEvidence`。
> **禁止**把全部历史直接拼给所有专家。
>
> **风格注入顺序（第 3 轮，写死）**：system 段 = `风格指令 → 有效提示词 → 严格规则 → 知识库证据`；
> `styleDirective` 由 `StyleLibrary.directiveFor(eff.styleId)` 产出（前缀 `【风格要求·<标签>】`），`styleId` 为 null 时为空串（不注入）。

---

## 7. 去重 / 跑题 / 总结（V1.3 §11）

- `DuplicateDetector.check(String output, List<ExpertOutput> recentOutputs, {String? currentExpertId}) -> {similarity, isDuplicate}`
- `OffTopicDetector.check(String output, String userTask) -> {isOffTopic, reason}`（**仅 2 个参数，无 `role`**）
- `Summarizer.summarize(...) -> SummaryResult{consensus[], disagreements[], recommendations[], openQuestions[], citations[]}`

---

## 8. Grounding 运行规则（V1.3 §14 / §15 / §21）

| policy | 行为 |
|---|---|
| `off` | 普通对话，不检索 |
| `preferred` | 先检索，有证据则注入；无证据照常回答 |
| `strict` | **无有效证据 → 不调用 LLM，直接返回 no-answer** |
| `local_only` | 检索 + Embedding + LLM **全本地**，敏感内容不出机 |

> `strict` 是**应用层策略**，不是 prompt 里的一句话。

---

## 9. 状态模型（V1.3 §24 / §35）

三维分离，UI 不直接依赖 HTTP 错误码：

| 维度 | 取值 |
|---|---|
| Availability | `available` `unavailable` `misconfigured` `rate_limited` |
| Activity | `idle` `thinking` `preparing` `generating` |
| Health | `healthy` `auth_error` `network_error` `quota_error` `provider_error` |

UI 映射：`healthy+idle → 在线`；`auth_error → 灰头像 + Key 无效`；`rate_limited → 灰头像 + 限流中`；`generating → 正在输入`。

---

## 10. 错误模型（V1.3 §36）

```
AppError
├── ValidationError
├── StorageError
├── ProviderError ─ AuthenticationError / RateLimitError / NetworkError / QuotaError / ProviderServerError
├── KnowledgeError
├── PackageError ─ SignatureError / HashMismatchError / SchemaError / UnsafePackageError
└── GenerationError
```
映射规则由 `LlmProvider.mapError()` 负责：401/403 → AuthenticationError；429 → RateLimitError；5xx → ProviderServerError；SocketException → NetworkError。

---

## 11. 知识库文件夹关联接口（第 4 轮 as-built）

> 实现：`advisor_core/lib/application/folder_sync.dart`（纯 Dart，`dart run` 全量验证，
> `verify_round4`（core）121/0 +（storage）43/0）。归属判定 = `folder_id` **登记事实**
> （`WHERE folder_id = ?`），删除路径**严禁路径前缀推断**；前缀匹配只允许出现在
> 补绑回填（只增不删）与重扫对账键。

### 11.1 FolderSyncService（构造依赖：Repositories + KnowledgeService）

| 方法 | 语义 | 错误码 |
|---|---|---|
| `linkFolder(kbId, path, {recursive})` | 新建关联登记行（比较键去重 + 存在性检查） | `kb.folder.missing` / `kb.folder.duplicate` |
| `unlinkFolder(folderId, {required keepDocuments})` | **二选一**：true = 删行 + 文档 folder_id 置 NULL（保留为孤儿，可检索、可补绑）；false = 删行 + 按 folder_id 精确列表逐个 `deleteDocument`（级联 chunks → embeddings → FTS → vectorStore）。两条路径均不动既有孤儿文档 | `kb.folder.missing` |
| `backfillFolder(folderId)` | 补绑回填：只认领 `folder_id IS NULL` 且路径位于文件夹前缀下**且文件在位**的文档；**只 UPDATE folder_id 绝不删行**；不回填 source_mtime（首次重扫全量 sha 对账由设计承担） | `kb.folder.missing` |
| `planRescan(folderId)` | **阶段一（只计划不执行）**：扫描（只 stat）→ 增量对账（mtime+size 预筛 + sha256 确认；读取失败保守按 unchanged）→ 防线判定 | `kb.folder.missing`（登记行不存在） |
| `executeRescan(plan, {confirmDeletes})` | **阶段二**：`Stream<RescanProgress>`；updated = 删旧 → `importDocument` 重建；deleted = 逐个 `deleteDocument`（**删除数 == diff 列表长度**）；unchanged 回填 `source_mtime`；成功后更新 `last_scan_at` | `kb.folder.missing`（计划已中止）/ `kb.folder.abort_deletes`（需确认未确认） |
| `rescan(folderId, {confirmDeletes})` | plan + execute 便捷封装，返回 `RescanSummary` | 同上 |
| `listFolders(kbId)` / `listDocumentsByFolder(folderId)` | 只读查询（UI 只调应用服务，不触碰仓储） | — |

### 11.2 三层防线（全部在服务层，UI 只展示确认）

1. **失联检测（扫描前置）**：`Directory(displayPath).existsSync()` 失败 → `RescanPlan.abortedReason='folder_missing'`，**零删除**；执行中止计划抛 `kb.folder.missing`。
2. **大比例删除确认（dry-run 决策）**：deleted > 0 且（占比 ≥ 0.5 **或** ≥ 20）→ `needsConfirmation=true`；未携 `confirmDeletes: true` 执行则抛 `kb.folder.abort_deletes`。
3. **删除粒度铁律**：同步路径只允许对精确文档 id 逐个调用 `deleteDocument`；`deleteByKnowledgeBase` / `deleteBase` 在 `folder_sync.dart` 源码中**零出现**（QA 可 grep 验证，`verify_round4` 有同款断言）。

### 11.3 增量对账规则（§1.2，按序短路）

① 路径（比较键）不在既有集合 → **added**；② `size == fileSize && mtime == source_mtime && status == indexed` → **unchanged**（零内容读取）；③ sha256 确认：相同 → unchanged（**mtime 漂移不算更新**）、不同 → **updated**（删旧重建）；④ `status == failed` 且文件在 → 一律按 updated 重试；⑤ 既有文档路径不在文件系统 → **deleted**（精确 id 列表）。读取失败（`readHash` 返回 null）→ 保守按 unchanged（宁可漏检，绝不误删）。

---

## 12. 群聊体验改造接口（第 6 轮 as-built，任务 #32）

> 实现：`advisor_core/lib/domain/{relevance,group_directive,strategies,orchestration}.dart` +
> `advisor_core/lib/application/services.dart`（`runGroupChat` / `GroupService`），
> 纯逻辑下沉、`dart run` 可测（`verify_round6` 70/0 + `verify_round6_group` 41/0）。

### 12.1 发言选择三层（`LeaderLedStrategy`，强制优先）

`leader_led` 的发言者选择**按序**：

1. **强制入选**（优先于相关性）：① 用户消息 `@成员`（`GroupDirectiveResolver`）；② **组长上一轮正文 `@成员` 提名**（`LeaderLedStrategy` 解析上一发言者正文）；③ 组长先行（`insert(0)`，组长必在候选首位）；
2. **相关性粗筛**：`MemberRelevanceScorer.score(userText, member)` ≥ `minRelevance`（默认 `kDefaultMinRelevance = 0.01`）→ 入选；**必须复用同一分词口径 `ExpertiseTokenizer.tokenize`**（`AutoStrategy.tokenize` 亦委托之，**禁止另写分词器导致漂移**）；
3. **兜底不冷场**：相关性**全不命中** 且 **无任何强制入选者** 且 有组长 → **仅组长发言**（不退化全员）。

**严格 cap**：`group_configs.max_speakers_per_round`（默认 3）限制单轮发言者数。**优先级铁律**：`SpeakerDirective`（用户本次指令）> `group_configs.speak_strategy`（持久策略）> 策略内部兜底。

### 12.2 发言范围指令解析（`GroupDirectiveResolver`，纯函数，无 LLM）

`resolve({userText, members, leaderId}) → SpeakerDirective?`：识别高置信中文句式（正则）——"仅组长一人/单独/自己发言"、"<名>发言/@<名>"、"组长（发言|主持|来）"、"大家/所有人/各自（说说|发言）"；未命中 → `null`（回落策略）。**明确不做 LLM 意图分类**（可测、零成本、零延迟）。`SpeakerDirective{expertIds, reason, isFullGroup}` 命中则**覆盖**策略选择。

### 12.3 群级提示词组装（`GroupPromptComposer`，纯函数）

`ContextManager.build` 增可选命名参数 `groupBlocks`（**不破坏现有签名**）；system 顺序扩展为：
`风格指令 → 有效提示词 → 【群角色声明】roleBlock → 【本群共识/公告】consensusBlock → 【本轮发言范围】scopeBlock → 严格规则 → 知识库证据 → 近期历史 → 用户任务`。

- `roleBlock({selfName, role, leaderName})`：声明"你是组长/组员，组长是 X"（解决"分不清自己角色"）；
- `consensusBlock(announcement)`：**群公告硬契约**——注入**每位发言者（含总结者）** system；
- `scopeBlock(directive, names)` + `nonParticipationRule`（成员自判模板）+ `concisionRule`（简洁/不复述/专注业务）。

### 12.4 静默契约（成员自判"无关"）

成员输出 `【不参与】`（常量 `kNonParticipationToken`）→ `runGroupChat` 记为 step `RunStatus.partial` + 消息 `MessageStatus.cancelled` 且**正文清空** + `ExpertOutput.skippedBy(...)`；**UI 不渲染为气泡**（T03 `conversation_view` 仅显示极淡"X 未参与本次讨论"）。**禁止**让"不参与"成为可见消息（否则自判反成刷屏源）。

### 12.5 `GroupService` 新增方法（群管理，UI 只调应用服务）

| 方法 | 语义 | 错误码 |
|---|---|---|
| `config(convId) → GroupConfig?` | 读群配置（含公告 / 上限） | — |
| `updateAnnouncement(convId, text)` | 写 `announcement` + `announcement_updated_at` | — |
| `updateSpeakStrategy(convId, id)` | 写 `speak_strategy`（含 `leader_led`） | `group.strategy.unknown`（未注册 id） |
| `updateMaxSpeakers(convId, n)` | 写 `max_speakers_per_round` | `group.max_speakers.invalid`（越 1..20） |
| `renameGroup(convId, title)` | 改群名（`conversations.title`） | `group.title.empty`（空名） |
| （复用）`setLeader` / `leaderId` / `effectiveSummarizer` / `addMember` / `removeMember` | — | — |

> 面板设置 = **持久策略**（`group_configs.speak_strategy`）；用户消息指令 = **本次覆盖**（`SpeakerDirective`，单次有效）。

### 12.6 总裁助理市场包（第 6 轮 T04）

- 新专家包 slug **`executive-assistant`**（packageId `org.private-advisor.executive-assistant`，displayName「总裁助理」，分类 `09-OperationsHR`）——**注**：原设计拟用 slug `chief-of-staff`，但该 slug 已被既有种子包「幕僚长」占用，为避免覆盖既有分发包改用 `executive-assistant`；
- 群管理面板「任命总裁助理为组长」一键流程：按 `packageId == 'org.private-advisor.executive-assistant'` 在已安装专家中定位 → 不在群内先 `addMember` → `setLeader`；未安装则引导去市场（`Expert.id` 是本地实例 id，不稳定，**必须用 packageId 匹配**）。

### 12.7 头像拟人化（第 6 轮 T05）

- `AvatarResolver`（app，`infrastructure/avatar/`）：按 `expertId` **约定推导** `<data>/avatars/<expertId>.png`；优先级 `Expert.avatarPath`（存在）→ 约定路径 → `null`；**不写 DB、不动 schema**；
- `ExpertAvatar`（app，`ui/widgets/`）：`Image.file`（存在才显示，`errorBuilder` → 回退）→ 缺图 / 损坏**优雅回退**首字 / 图标；圆形（默认）或圆角矩形（会话列表保持 B1 规格）；**市场列表不使用**（B5 约定维持 emoji）；
- PNG 由**批处理**一次性生成到 `<data>/avatars/`（见 `app/tool/gen_avatars.md`），app 运行时无图像生成服务。
