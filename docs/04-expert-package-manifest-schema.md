# 工程契约 04 · Expert Package / Manifest Schema

> 版本：1.0.0 ｜ 对应 V1.3 §19 / §20 / §21 / §22 / §30 / §31 / §32
> 核心承诺：**`.expert` 是纯数据包，不执行任何代码。**

---

## 1. 包目录结构

```
<expert-slug>/
├── manifest.json          # 包清单（机器校验用）
├── expert.json            # 专家定义（人可读，市场展示）
├── agents/
│   └── main.md            # 系统提示词（YAML frontmatter 可选）
├── avatars/
│   └── expert.png         # 512×512 PNG，≤500KB
└── README.md
```

打包：整个目录 → `<slug>-<version>.expert`（ZIP，扩展名 `.expert`）。

---

## 2. manifest.json（唯一校验入口）

```json
{
  "schemaVersion": 1,
  "packageId": "org.private-advisor.bid-tender",
  "slug": "bid-tender-expert",
  "version": "1.0.0",
  "appVersion": ">=1.3.0",
  "displayName": "投标文件解读专家",
  "categoryId": "12-IndustryConsultant",
  "entry": "agents/main.md",
  "sha256": "<包内容哈希，见 §4>",
  "signature": "<可选，ed25519 对 sha256 的签名>",
  "signerKeyId": "pa-market-2026",
  "capabilities": {
    "network": false,
    "filesystem": false,
    "shell": false,
    "tools": false
  },
  "files": [
    { "path": "expert.json", "sha256": "..." },
    { "path": "agents/main.md", "sha256": "..." },
    { "path": "avatars/expert.png", "sha256": "..." },
    { "path": "README.md", "sha256": "..." }
  ],
  "publishedAt": 1790757000000
}
```

### 字段约束
| 字段 | 必填 | 说明 |
|---|---|---|
| `schemaVersion` | ✅ | 当前固定 `1` |
| `packageId` | ✅ | 反向域名，**全局唯一** |
| `slug` | ✅ | 小写字母+连字符 |
| `version` | ✅ | 语义化版本 |
| `appVersion` | ✅ | 最低 App 版本（如 `>=1.3.0`） |
| `categoryId` | ✅ | WorkBuddy 15 类之一 |
| `entry` | ✅ | 提示词文件相对路径 |
| `sha256` | ✅ | 包整体哈希 |
| `signature` | ○ | 一期可空（市场 CI 签发后填） |
| `capabilities` | ✅ | **一期全部必须为 `false`** |
| `files[]` | ✅ | 逐文件哈希 |

---

## 3. expert.json

```json
{
  "displayName": "投标文件解读专家",
  "profession": "政府采购与招投标顾问",
  "description": "拆解招标文件，提取资格条件、评分办法与废标条款，输出结构化风险清单。",
  "tags": ["招标文件", "资格条件", "评分办法"],
  "quickPrompts": ["拆解这份招标文件", "提取评分办法", "列出废标条款"],
  "welcomeMessage": "把招标文件发我，我帮你拆资格条件和废标条款。",
  "recommendedModel": "deepseek-chat",
  "temperature": 0.3,
  "knowledgeHint": "技术规格书 / 历史标书"
}
```

> **风格不入包**（第 3 轮裁定）：专家风格是**用户侧数据**（`expert_user_states.style_id`，7 个代码内置预设），由用户在客户端按专家单独设置；`expert.json` / `manifest.json` **不含**任何风格字段，市场更新不覆盖。

---

## 4. 哈希与签名口径（必须一致，否则验签失败）

1. 设包内文件集合 `F`（**不含 manifest.json 自身**），按 `path` 字典序排列。
2. 对每个文件算 `sha256(fileBytes)`，写入 `files[]`。
3. 包整体 `sha256` = `sha256( concat( path + "\0" + sha256hex + "\n" for each file in F ) )`。
4. `signature` = `ed25519_sign(sha256, marketPrivateKey)`；客户端用内置公钥（`signerKeyId` 索引）验证。

> 一期若未启用签名，客户端**只校验 sha256 + schema + 路径安全**，并在 UI 标注"未签名"。

> **两种哈希口径，绝不可互比（任务 #27 裁定，2024 走查 BugFix）**：
> - **seal 内容口径**（本节定义）：索引 `versions[].sha256` 与 `manifest.sha256` 声明的就是这个口径——对**解包后**的文件**内容字节**逐个哈希再拼装整包哈希（服务端 `package_utils.computePackageHash`）。
> - **ZIP 字节口径**：对 `.expert`（ZIP 文件）的**传输字节**整体 `sha256`。同一包两种口径哈希**必然不同**（实证：`ecr.expert` 内容口径 `81d3b107…` vs 字节口径 `038490c9…`）。
> - 客户端安装校验**只用 seal 内容口径**：解包 → 按 seal 同口径重算 → 对照索引声明；ZIP 传输完整性由 HTTPS + 20MB 尺寸预检承担。历史上客户端曾误用 ZIP 字节口径对照内容口径声明 → 全部包「下载完整性校验失败」。

---

## 5. 安装安全链（V1.3 §22 / §31，顺序不可调换）

```
1. HTTPS              强制 TLS
2. Manifest Parse     解析 manifest.json
3. Signature Verify   有签名则验签
4. SHA256 Verify      逐文件 + 整体
5. Schema Validate    manifest / expert schema
6. Size Validate      单文件 ≤5MB，整包 ≤20MB
7. Path Safety Verify 拒绝绝对路径、..、盘符、符号链接
8. Capability Verify  四项 capability 必须 false
9. No-Executable Scan 禁止 .exe .dll .bat .ps1 .sh .py .js .jar .msi .scr .com .vbs
10. Install           解包到 market/packages/<installationId>/
```

任何一步失败 → `PackageError`，**不得安装**，并保留失败原因。

### 5.1 客户端实现（第 4 轮 as-built）

- **分层**：网络端口 `MarketHttpClient`（`fetchText` / `fetchBytes`）定义在 `advisor_core`（**core 零网络依赖**），`package:http` 实现 `HttpMarketClient` 在 app 层注入；校验编排 `MarketInstallFlow`（`advisor_core/lib/application/market_client.dart`）为**纯逻辑**（解包 → 校验 → 提示词提取 → 落盘），写库由 `MarketService.installPackage`（二次防线：`verification.ok == false` 直接拒装）。
- **步骤归属**：步骤 1 由传输层（HTTPS，尺寸预检 ≤20MB）+ **索引 sha256 对照**兜底——对照在**解包后**按 **seal 内容口径**重算（`PackageManifest.contentHashFromPayload(payload.dataEntries)`，与 `manifest.sha256` 封包口径逐字同口径，见 §4 口径裁定），失败报 `market.hash：下载完整性校验失败`；ZIP 字节哈希**不用于**安装校验（任务 #27）。步骤 2–9 由 `PackageVerifier.verify` 纯逻辑执行；步骤 10（appVersion）需调用方传当前版本，安装流默认不启用。
- **下载通道（沙箱 `curl` 实测结论，写死）**：`raw.githubusercontent.com`（index）可达；`github.com/.../releases/download/...` 302 → `release-assets.githubusercontent.com` 在受限网络下**完整下载常被重置**；**`api.github.com` asset API（`Accept: application/octet-stream` + 跟随重定向）为可靠兜底通道**。`HttpMarketClient` 实现为「releaseUrl 直连 → 失败回退 api.github.com（按 `releases/tags/<tag>` 找同名资产）」。
- **落盘前二次路径校验**：即使步骤 7 已过，逐 entry 落盘前再跑 `ZipPathSafety.reject` + `staysInside`（纵深防御）；落盘根目录 `market/packages/<slug>-<version>/`。
- **验证证据**：`advisor_core` `dart run tool/verify_market.dart`（78 项：索引解析/仓储、成功路径落盘落库、13 个失败分支逐一拒绝（含「旧口径 ZIP 字节哈希作期望必被拒」防回退回归）、真实市场包 `tech-spec-expert-1.0.0.expert` 全链回归、真实资产 `ecr.expert` seal 内容口径重算 == 线上声明 `81d3b107…` 且端到端安装成功）。

---

## 6. ZIP 路径安全（防 Zip Slip）

- 解包前对每个 entry 的 `name` 做规范化，必须满足：
  - 不以 `/` 或 `\` 开头；不含盘符（`^[A-Za-z]:`）
  - 规范化后不含 `..` 段
  - 解析出的绝对路径必须仍位于目标目录内（`targetDir` 前缀校验）
- 拒绝符号链接 / 硬链接 entry。
- 解包采用**流式写入 + 大小上限**，防 zip bomb。

---

## 7. 安装状态机（V1.3 §30）

```
discovered → downloading → verifying → validating → installing → installed
                              ↓            ↓            ↓
                    verification_failed  validation_failed  install_failed
```

---

## 8. 版本与更新（V1.3 §32）

```
marketVersion > installedVersion
   ↓
local_modified?
   ├─ false → 可自动更新（覆盖包文件，不动 expert_user_states）
   └─ true  → 生成 Diff 候选，用户选择迁移
```

**一期默认**：不自动覆盖用户的 `customPrompt` / 备注 / 分组 / 知识库绑定。

---

## 9. 市场索引 index.json

```json
{
  "schemaVersion": 1,
  "generatedAt": 1790757000000,
  "packages": [
    {
      "packageId": "org.private-advisor.bid-tender",
      "slug": "bid-tender-expert",
      "displayName": "投标文件解读专家",
      "profession": "政府采购与招投标顾问",
      "description": "……",
      "categoryId": "12-IndustryConsultant",
      "tags": ["招标文件", "资格条件"],
      "latestVersion": "1.0.0",
      "versions": [
        {
          "version": "1.0.0",
          "releaseUrl": "https://github.com/<org>/private-advisor-market/releases/download/<pkg>/<slug>-1.0.0.expert",
          "sha256": "...",
          "signature": "...",
          "sizeBytes": 184320,
          "publishedAt": 1790757000000
        }
      ]
    }
  ]
}
```
> 客户端优先从 `releaseUrl`（GitHub Release Asset）下载；索引本身从 `catalog/index.json` 拉取并缓存（ETag）。

---

## 10. 市场仓库结构

```
private-advisor-market/
├── catalog/
│   └── index.json                 # 由 CI 从 packages-src 生成
├── schemas/
│   ├── manifest.schema.json
│   ├── expert.schema.json
│   └── index.schema.json
├── packages-src/
│   └── <slug>/
│       ├── manifest.json
│       ├── expert.json
│       ├── agents/main.md
│       ├── avatars/expert.png
│       └── README.md
├── releases/                      # 本地构建产物（.gitignore）
├── scripts/
│   ├── package_utils.dart         # 共享校验 / 索引逻辑（与客户端 PackageVerifier 同口径）
│   ├── seal.dart                  # 回填 manifest.json 的 files[] 与整体 sha256
│   ├── validate.dart              # 校验 packages-src 下所有包（CI 每个 PR 运行）
│   └── build_index.dart           # 由 packages-src 生成 catalog/index.json
├── LICENSE
└── .github/workflows/validate.yml # PR 校验 + 自动重建 index
```

---

## 11. 知识库「关联文件夹」UI 契约（第 4 轮 as-built）

> 实现：`app/lib/features/knowledge/folder_section.dart`（`FolderSection` 组件）+
> `knowledge_page.dart`（详情区挂载 + 「未关联」徽标）。导入入口**已移除**（裁定 #5）：
> 内容一律经「关联文件夹 + 重新扫描」增量同步；`ImportBatch` / `importDocument`
> 底层链路保留（重扫复用）。

### 11.1 关联文件夹卡片

- 标题「关联文件夹（N）」+ 说明「原文件永不复制、移动、修改」+ **「关联文件夹」按钮**（`FilePicker.getDirectoryPath`，无需扩展名过滤）；
- 每行：`display_path`（原样路径）+ `最近扫描 <时间> · 含子文件夹` + **「重新扫描」**按钮 + 行菜单（**补绑未关联文档…** / **断开关联…**）。

### 11.2 重新扫描（两阶段，交互由核心层防线驱动）

1. `planRescan`（dry-run）→ 无确认需求则直接 `executeRescan`；
2. **防线 1（失联）**：红色图标弹窗「找不到关联文件夹」——说明可能原因（移动/重命名/拔盘/断网），明确**「没有删除任何内容」**；
3. **防线 2（大比例删除）**：橙色警示弹窗展示**逐项删除清单**（最多 8 项 + 总数）与占比，按钮「确认删除 N 篇」；取消则提示「未执行任何删除」；
4. **执行**：不可关闭进度弹窗（已处理 x/y + 当前文件 + 五项计数），随 `Stream<RescanProgress>` 逐帧刷新；
5. **完成**：摘要弹窗「新增 X 篇 ｜ 更新 Y 篇 ｜ 删除 Z 篇 ｜ 跳过（内容重复）W 篇 ｜ 失败 F 篇」。

### 11.3 断开关联（二选一弹窗，默认仅解除）

- **仅解除关联（推荐，默认选中）**：文案「保留 N 篇文档及其分块，仍可检索；变为『未关联』，不再被重扫管理，可随时通过『补绑』重新认领」；
- **解除并删除已索引内容（N 篇）**：N 为**精确计数**（`listDocumentsByFolder`，与核心层同一判定来源）；选中时显示红色警告条「将删除 N 篇文档及其全部分块与索引，此操作不可恢复」，确认按钮变红。

### 11.4 未关联文档（孤儿）

- 文档列表中 `folder_id IS NULL` 的文档带橙色**「未关联」徽标** + 副标题「来源：未关联（重扫不管理）」；
- 列表上方橙色提示条：「有 N 篇『未关联』文档……可在关联文件夹行菜单『补绑未关联文档』认领」；
- 补绑结果弹窗：「匹配回填 N 篇」+（有未匹配时）「未匹配 M 篇（文件已移走或不在该文件夹内），保持『未关联』：内容保留、仍可检索，任何重扫都不会删除它们」。

---

## 12. 群聊体验改造 UI 契约（第 6 轮 as-built，任务 #32）

> 实现：`app/lib/features/contacts/{group_summary_card,group_settings_view,group_member_list,group_members_panel}.dart`
> + `app/lib/ui/widgets/expert_avatar.dart` + `app/lib/infrastructure/avatar/avatar_resolver.dart`。
> 硬约束：**不得破坏第 5 轮 B1**（theme / NavRail / 栅格数值零改动）；`conversation_list_pane` 只加挂点与展开，不改会话项视觉规格（B2 重样式须保留下方群卡片挂点）。

### 12.1 中栏内联群卡片（`GroupSummaryCard`）

- 在**会话列表**（会话页签）与**群聊页签**（通讯录页签）的群项**下方展开**；
- 顶部两导航「群成员 ｜ 群管理」（默认**群成员**）+「进入群聊」图标（→ 右栏打开会话）；
- 「群成员」复用共享组件 `GroupMemberList`；「群管理」复用 `GroupSettingsView`；
- 切页签即换 `KeyedSubtree(key: ValueKey('group-card-$_tab'))` → 内容区重载（保证两页签数据一致）。

### 12.2 群管理表单（`GroupSettingsView`）

群名称（保存）/ 组长（下拉任命，复用 `setLeader`）/ **发言策略**（下拉 4 策略 + `leader_led`，写 `group_configs.speak_strategy`）/ 单轮发言上限（1..8，写 `max_speakers_per_round`）/ **群公告**（保存 + 「最后更新」时间）/ **「任命总裁助理为组长」**（一键：定位 `executive-assistant` 包 → 未入群先加入 → `setLeader`；未安装则引导去市场）。
防御：`DropdownButton.value` 越界（异常数据）一律回退 `null` + hint，避免断言崩溃。

### 12.3 单一展开原则（A 群卡片 与 C 好友卡同源）

任何"列表项内联展开"一律**父级持 `String? _expandedId`、子组件受控**：
- `ContactNameRow` 由 StatefulWidget 改 **StatelessWidget 受控**（`expanded` + `onToggle`，移除内部 `_expanded`）；`FriendsTab` / `GroupsTab` 提升 `_expandedId`；
- 群项：`conversation_list_pane` / `group_chats_tab` 父级持 `_expandedId`；点群项 → 右栏续聊 + 展开卡片（再点收起）；**点另一好友/另一群 → 前一张卡片自动收回**。

### 12.4 静默契约 UI（`conversation_view`）

成员自判「无关」（`【不参与】`，T02 已把消息置 `cancelled` + 正文清空）→ **不渲染气泡**，仅居中极淡（`Colors.black26` / 11px）系统行「X 未参与本次讨论」。**禁止**让"不参与"成为可见消息。

### 12.5 头像拟人化（`ExpertAvatar` + `AvatarResolver`）

- 约定路径 `<data>/avatars/<expertId>.png`（`AvatarResolver` 按 id 推导，**不写 DB / 不动 schema**）；优先级 `Expert.avatarPath` → 约定路径 → `null`；
- `ExpertAvatar`：图片存在则 `Image.file`（`errorBuilder` 兜底），**缺图 / 损坏 → 回退首字（或指定图标）**，禁止崩溃 / 留白；
- 形状：默认圆形（通讯录行 / 群成员）；**会话列表保持 B1 规格 36×36 圆角 12**（传 `borderRadius`）；
- 替换点：`contact_name_row` / `group_member_list`（对话框 + 群卡片共用）/ `conversation_list_pane`；**群聊行**（无对端专家）维持群组图标；**市场列表不使用**（B5 约定维持 emoji）。

### 12.6 总裁助理市场包（第 6 轮 T04）

- 新包 slug **`executive-assistant`**（displayName「总裁助理」，`categoryId: 09-OperationsHR`）；目录 `market/packages-src/executive-assistant/`（`manifest.json` / `expert.json` / `agents/main.md` / `README.md`），产物 `market/dist/executive-assistant-1.0.0.expert`，索引已含该条目；
- **注**：原设计拟用 slug `chief-of-staff`，但该 slug 已被既有种子包「幕僚长」占用 → 为避免覆盖既有分发包改用 `executive-assistant`；
- 添加渠道与其余包一致（市场 → 下载校验 → 安装），发布后客户端可见。

---

## 13. 会话附件 UI 契约（第 8 轮 as-built，任务 #45）

> 实现：`app/lib/features/conversation/{attachment_pick,attachment_bar,message_attachment_card,image_viewer,conversation_view}.dart`
> + `app/lib/main.dart`（Bootstrap：建 `<data>/attachments/` + 装配 `LocalAttachmentStore` / `AttachmentService`）。
> 核心契约见契约 03 §12；本文只约定 **UI 侧**坐标、四态、删除入口与平台降级。

### 13.1 输入区坐标（架构 §1.6，写死）

```
输入框（规格 §4.4：最小 120px 可拖高）
 ├─ 顶部工具栏 36px：[📎 附件]（左1，本轮实现）[@ 提及]（左2，仅群聊，复用第 7 轮同一 MentionPicker）
 │                       弹性空间                        [发送按钮 §4.4]
 ├─ pending 附件条（仅本轮：有 pending 时出现于工具栏下方；四态见 §13.2）
 └─ 输入区（Enter 发送 / Shift+Enter 换行 —— 第 7 轮 E-1 逻辑不动）
```

- **📎 固定左 1、@ 固定左 2**（`if (_isGroup)` 才渲染）→ 不得占用 / 交换二者位置；
- 顶部工具栏高度取 `AppDims.toolbarHeight`(36)；图标 18（`iconNav`）、间距用 `AppDims` 刻度；**发送按钮沿用既有 `FilledButton` 视觉**（`AppColors.primary` / 禁用 `sendDisabled` /「发送中」文案）。

### 13.2 pending 四态（`PendingAttachmentStatus`）

| 态 | 触发 | 表现 |
|---|---|---|
| `ready` | 通过 `AttachmentPolicy.validate` | 文件名 + 大小·类别 + ✕ 可移除 |
| `uploading` | **契约预留**：异步发送进行中 | spinner 替代图标；`canRemove = false`（禁移除半路文件） |
| `failed` | 发送阶段 IO / 落库失败（`AttachmentService.send` 返回 `error != null`） | 红字原因 + **重试**（复位为 `ready`）+ ✕ |
| `rejected` | 选择阶段即被拒（超限 / 类型不符 / 无本地路径） | 红字原因，**不进重试**，只可移除 |

- **失败隔离**：单个附件失败**不影响消息已发出**——消息照发，失败项留在 pending 条标红（SnackBar 汇总「有 N 个附件未发送成功」）；
- 「取消」= 从列表移除（**不预复制** → 移除即零痕迹，无孤儿、无需扫盘）。

### 13.3 消息流附件卡

- **图片缩略卡**：`ClipRRect` 圆角 8、边长 **120px**（规格区间 96–160 内定值）、`Image.file(fit: cover)` + **`errorBuilder` → 回退文件图标**（禁止崩溃 / 留白）、点击 → 全屏放大；多图 `Wrap`（间距 `AppDims.space2`）；
- **文件卡片严格照规格 §4.3.3**：`#F7F8FA`(`bgSecondary`) 背景 + 1px `#E5E7EB`(`divider`) 边框 + 圆角 8 + 内边距 12 + 标题 **13/500 一行** + 元信息 **12/`#9CA3AF`(`textTertiary`) 两行** + 左侧图标 **24×24**；按扩展名映射图标（pdf / doc / xls / ppt / txt·md / zip / 默认）；
- 用户气泡由 `SelectableText` 改为 `Column[MessageAttachmentCards, 正文]`（正文为空时只出附件卡）。

### 13.4 全屏放大（`ImageViewer`）

`Dialog`（`insetPadding: space6`，黑底）+ `InteractiveViewer`（`minScale 0.8` / `maxScale 8`）+ `TransformationController` + **双击复位**；关闭 = 右上角按钮或 **`Esc`**（`KeyboardListener`）；左上角文件名；图片缺失/损坏 →「图片无法显示」。

### 13.5 删除消息入口（铁律 + UI 隐藏只是第一道）

- **手势只挂在「用户消息」分支**（`_messageBubble` 的 `if (m.isFromUser)` 内的 `GestureDetector.onLongPress` / `onSecondaryTap`）→ **专家气泡无任何删除入口**；
- 菜单项：`复制消息` / `删除消息`；
- **二次确认**（文案逐字固定）：标题「删除消息」+「删除后不可恢复；该消息的知识库引用记录将保留（历史不可变）。」；
- 执行 → `ConversationService.deleteMessage(conversationId, messageId)`（**服务层三级 fail-closed**，含 `message.not_deletable`）→ 成功 → `_reload()`；被拒 → SnackBar 明示原因；
- `_deleting` 期间禁用入口（防重复点击）。

### 13.6 「打开文件」平台降级（共享约定 10）

`AttachmentActions.locateFile`：
1. 文件不存在 → SnackBar「文件不在原位置，可能已被移动或删除」+ 回调宿主刷新；
2. **非 Windows → 直接降级**（不尝试）；
3. Windows → `Process.run('explorer', ['/select,<反斜杠归一化路径>'])`；`exitCode != 0` 或抛异常 → 降级；
4. 降级动作 = `Clipboard.setData(ClipboardData(text: 原路径))` + SnackBar「定位失败，路径已复制：…」。
**禁止跨平台硬调 `explorer`**。

### 13.7 合规要点（QA 可 grep 验证）

- `attachment_pick.dart` **零 `File(` / 零 `copySync`**（选择阶段零 IO）；
- `attachment_store.dart`（core）**零 `.listSync(` 调用**（绝不扫盘）；
- 附件归属判定只出现 `message_id` 外键 + `countByStoredPath`，**无路径前缀推断**；
- `app/lib/features/market/**` **不出现** `ExpertAvatar`（市场列表维持 emoji）。
