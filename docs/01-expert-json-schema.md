# 工程契约 01 · Expert JSON Schema

> 版本：1.0.0 ｜ 对应 V1.3 §6 / §27
> 作用：冻结 Expert 领域的三层身份模型与序列化格式，M1 起不再变更（仅允许 additive）。

---

## 1. 三层身份模型（核心约束）

```
MarketPackage       市场里的"商品"（packageId + version）
      ↓ install
InstalledPackage    本机安装记录（installationId + installPath + local_modified）
      ↓ instantiate
ExpertInstance      用户实际聊天用的专家（expertId，独立 UUID）
```

**硬规则**
1. `expertId` **不等于** `packageId`。市场 slug 只出现在 `experts.package_id`。
2. 用户修改（备注 / 分组 / 自定义 prompt / 专家风格 / 知识库绑定）记录在 `ExpertUserState`，**市场更新不覆盖**。
3. `ExpertRuntimeConfig` 与 `ExpertUserState` 与 `Expert` 一对一（同 `expert_id`）。

---

## 2. ExpertDefinition（专家本体）

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string(uuid) | ✅ | 本地专家实例 ID |
| `name` | string | ✅ | 显示名 |
| `profession` | string? | | 职业头衔 |
| `avatarPath` | string? | | 头像本地路径（`experts/instances/<id>/avatar.png`） |
| `systemPrompt` | string | ✅ | 系统提示词（市场包中的原始 prompt） |
| `welcomeMessage` | string? | | 首次进入欢迎语 |
| `quickPrompts` | string[] | | 推荐提示词（≤3） |
| `packageId` | string? | | 来源市场包 ID；本地自建为 null |
| `packageVersion` | string? | | 安装时的包版本 |
| `source` | enum | ✅ | `market` / `local` / `imported` |
| `createdAt` / `updatedAt` | int(ms) | ✅ | 时间戳 |

### JSON 示例
```json
{
  "id": "e_9f2c1a44",
  "name": "商务文件解读专家",
  "profession": "企业采购与商务合规顾问",
  "avatarPath": "experts/instances/e_9f2c1a44/avatar.png",
  "systemPrompt": "你是一名企业采购与商务合规顾问……",
  "welcomeMessage": "把长篇文档发我，我帮你拆资格条件和废标条款。",
  "quickPrompts": ["拆解这份长篇文档", "提取评分办法", "列出废标条款"],
  "packageId": "org.private-advisor.bid-tender",
  "packageVersion": "1.0.0",
  "source": "market",
  "createdAt": 1790757000000,
  "updatedAt": 1790757000000
}
```

---

## 3. ExpertRuntimeConfig（运行配置）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `expertId` | string | — | PK |
| `modelProfileId` | string? | null | 为空则用全局默认模型 |
| `credentialProfileId` | string? | null | 为空则用全局默认凭据 |
| `temperature` | double? | null | 为空用模型默认 |
| `topP` | double? | null | |
| `maxTokens` | int? | null | |
| `groundingPolicy` | enum | `off` | `off` / `preferred` / `strict` / `local_only` |
| `enabled` | bool | true | 启停（停用的专家在群聊中不参与） |

---

## 4. ExpertUserState（用户侧状态）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `expertId` | string | — | PK |
| `remark` | string? | | 备注（用户改的名） |
| `groupId` | string? | | 分组 |
| `pinned` | bool | false | 置顶 |
| `customPrompt` | string? | | 用户自定义 prompt（**覆盖** systemPrompt，市场更新不动它） |
| `styleId` | string? | null | 专家风格（第 3 轮 v3 新增列）：7 个代码内置预设之一（`professional` / `amiable` / `blunt` / `imaginative` / `efficient` / `sharp` / `heuristic`）或 null；**null = 不注入**；市场更新不覆盖；自定义风格为 P2，一期不做 |
| `isLocked` | bool | false | 锁定，防误改 |
| `localModifiedAt` | int(ms)? | null | 一旦非空 → 市场更新需走 diff 迁移 |

---

## 5. 生效值解析规则（Effective Prompt / Model）

```
effectivePrompt   = userState.customPrompt  ??  expert.systemPrompt
effectiveModel    = runtimeConfig.modelProfileId      ?? settings.defaultModelProfileId
effectiveCred     = runtimeConfig.credentialProfileId ?? settings.defaultCredentialProfileId
effectiveGrounding= runtimeConfig.groundingPolicy     ?? 'off'
effectiveStyle    = userState.styleId                                  // 第 3 轮 v3 新增；null = 不注入
```

> 该规则由 `ExpertService.resolveEffective(expertId)` 实现，UI 与 Generation 层**只允许**通过它取生效配置。
>
> **风格注入顺序（写死，第 3 轮）**：`风格指令 → 有效提示词 → 严格规则 → 知识库证据`；
> 风格指令由 `StyleLibrary.directiveFor(styleId)` 构造（前缀 `【风格要求·<标签>】`），
> 由 `ContextManager.build(styleDirective: …)` 拼进 system，生效于该专家此后每次生成（单聊 + 其参与的群聊），**不改历史消息**。

---

## 6. 知识库绑定（N:M）

`expert_knowledge_bindings`：`(expertId, knowledgeBaseId)` 主键，含 `priority` / `enabled` / `topK` / `similarityThreshold`。
- 同一知识库可服务多个专家；一个专家可绑定多个知识库（**多选**）。
- 绑定属于**用户侧数据**，随 `ExpertUserState` 一起受市场更新保护。
- **`similarityThreshold` 语义（第 2 轮变更）**：由**余弦相似度**（默认 0.75）改为**查询 bigram 命中覆盖率** `|Q ∩ C| / |Q|`（默认 **0.5**，常量 `kDefaultCoverageThreshold`）。原 ONNX + `sqlite-vec` 方案已放弃，中文检索改用 **FTS5 + 应用层中文 bigram**（详见架构文档 **§51.11**）。

---

## 7. 兼容性

- 新增字段一律可选，缺省走默认值（additive migration）。
- `source=imported` 表示来自 `.expert` 文件导入；`packageId` 可为 null。
- 未来扩展位（V1.3 §48，一期不实现）：`tools[]`、`workflows[]`、`outputSchema`、`policies`、`memory`。
