# 私人顾问团 · Private Advisor

> 本地优先的 AI 专家桌面应用。**聊天是入口，Expert Runtime 是核心。**
> 方案基线：`私人顾问团_V1.3_开发方案.md` / `私人顾问团_V1.3_系统架构与数据模型设计.md`

---

## 仓库结构

```
私人顾问团/
├── advisor_core/          # 纯 Dart 核心包（Domain + Application）★可独立验证
│   ├── lib/domain/        #   领域模型：expert / conversation / generation / knowledge / market / provider
│   ├── lib/application/   #   应用服务 + 仓储端口
│   ├── lib/testing/       #   内存替身（测试与验证用）
│   └── tool/verify.dart   #   核心链路验证脚本（dart run）
├── advisor_storage/       # 纯 Dart 存储包：SQLite 仓储实现 + schema（不依赖 Flutter）★可独立验证
│   ├── lib/src/database/  #   schema.sql（canonical DDL）+ 10 个 SQLite 仓储 + 组装函数
│   └── tool/verify_storage.dart  # 存储层端到端验证脚本（dart run）
├── app/                   # Flutter 桌面应用
│   └── lib/
│       ├── main.dart              # 入口 + Bootstrap 装配 + 三栏主界面 + 设置
│       ├── features/knowledge/    #   知识库管理页面（建库 / 关联文件夹 / 重扫 / 列表 / 删除）
│       ├── infrastructure/
│       │   ├── llm/               #   OpenAI 兼容适配（DeepSeek SSE 流式）
│       │   └── secure_storage/    #   API Key 只进 OS 凭据库
│       └── ...
├── market/                # 人才市场公开仓库（GitHub 后端）
│   ├── catalog/index.json #   市场索引（CI 生成）
│   ├── packages-src/      #   专家包源码（贡献者只改这里）
│   ├── schemas/           #   JSON Schema
│   └── scripts/           #   seal / validate / build_index
├── docs/                  # 四份工程契约（V1.3 §38）
└── *.md                   # 产品与架构方案
```

---

## 快速开始

### 1. 验证核心逻辑（不需要 Flutter，最快）

```bash
cd advisor_core
dart pub get
dart run tool/verify.dart
```
预期输出：`结果：通过 111 ／ 失败 0` + `全部通过 ✅`

### 2. 验证存储层（不需要 Flutter）

```bash
cd advisor_storage
dart pub get                        # 纯 Dart 依赖（advisor_core + sqlite3），不含 Flutter
dart run tool/gen_schema.dart       # 由 schema.sql 生成 schema.g.dart
dart run tool/verify_storage.dart   # 端到端持久化验证
```
预期输出：`结果：通过 49 ／ 失败 0` + `全部通过 ✅`

### 3. 运行桌面应用（需要 Flutter + Visual Studio）

```bash
# 前置：Flutter SDK、Visual Studio 2022（含「使用 C++ 的桌面开发」工作负载）
cd app
flutter create --platforms=windows,macos .   # 首次：生成 windows/ macos/ 平台目录
flutter pub get                              # 会一并解析 advisor_core / advisor_storage 路径依赖
flutter run -d windows
```

> ⚠️ **前置条件**：Windows 桌面端编译需要 Visual Studio（MSVC）与 Windows SDK。
> 本项目当前开发机**未安装** VS / MSVC / Windows SDK，因此 **Windows 桌面端无法在本机编译**
> （`flutter run -d windows` 需在装有完整工具链的机器上执行）。
> 另：**知识库管理页面尚未在任何环境实际运行过**，需在用户机器 `flutter run` 走查。

首次启动后：
1. 点左下角 **设置** → 填入 DeepSeek API Key（默认模型 `deepseek-chat`）。
2. 去 **人才市场** → 招募专家（种子专家都在市场里，`我的专家` 初始为空）。
3. 单聊，或把多位专家拉进群聊。

---

## 核心设计要点

| 要点 | 说明 |
|---|---|
| **三层身份拆分** | `MarketPackage → InstalledPackage → ExpertInstance`，市场更新**不覆盖**用户修改 |
| **三层配置拆分** | `Provider / Model / Credential`，API Key 只存 `secret_ref`，明文进 OS 凭据库 |
| **运行可追踪** | 每次 AI 运行都有 `GenerationRun → GenerationStep → GenerationEvent`，可取消、可重试 |
| **知识可溯源** | `KnowledgeBase → Document → Chunk → Embedding` + `Citation`，回答可定位到文件名与章节 |
| **Grounding Policy** | `off / preferred / strict / local_only`；`strict` 无命中**不调用 LLM**，直接回"未找到" |
| **包即数据** | `.expert` 是纯数据包，10 步安全链校验，**禁止任何可执行代码** |
| **本地优先** | 一期无服务器；知识库文件与向量索引不出本机 |
| **分层可测** | 存储实现独立为纯 Dart 包 `advisor_storage`（`schema` + 10 个 SQLite 仓储），**可在无 Flutter 环境** `dart run` 独立验证 |

---

## 当前进度（M0–M6）

| 里程碑 | 状态 | 说明 |
|---|---|---|
| **M0 技术 Spike** | ✅ 核心部分 | 核心逻辑已用 `dart run tool/verify.dart` 真实跑通 111 项断言；Flutter/Windows 打包需在你的机器上验证 |
| **M1 单聊 Vertical Slice** | ✅ 核心完成 | Expert→Provider→Credential→Streaming→Run→Message→SQLite→重启恢复，全部实现并验证 |
| **M2 Knowledge Runtime** | ✅ 核心完成 | 解析→分块→检索→引用→Grounding；知识库 / 市场仓储已 **SQLite 化**（迁入 `advisor_storage`，`verify_storage` **71／0**）；**第 2 轮**中文检索改为 **FTS5 + 应用层中文 bigram 的纯 Dart 方案**（新增 `Retriever` 端口；`VectorStore`/`EmbeddingModel` 端口保留，将来可插拔换回）；**ONNX `bge-small-zh` 与 `sqlite-vec` 已放弃接入**（原因见「第 2 轮验证证据」）；知识库管理页 + **检索测试页**已实现（**待用户机器 `flutter run` 走查**） |
| **M3 Group Runtime** | ✅ 核心完成 | 4 种策略 + ContextManager + 去重 + 跑题检测 + 总结者 + Token 预算 + Fail Soft |
| **M4 Expert Package** | ✅ 完成 | 包规范 + 10 步安全链 + 市场仓库 + 5 个投标专家包（已封包校验通过） |
| **M5 Market Runtime** | ⏳ 待做 | 索引解析 / 版本比对已就绪；HTTP 拉取与下载待接入 |
| **M6 Eval + Hardening + Release** | ⏳ 待做 | 专家评测集 / 安全验收 / 安装包与发布 |

### 待办清单（唯一事实来源）

> 本清单同步维护于三处：**`README.md`（本表）**、`私人顾问团_V1.3_系统架构与数据模型设计.md` §51.8、`私人顾问团_V1.3_开发方案.md` §38.2。
> **修改任一处必须同步另外两处。**

| # | 事项 | 归属 |
|---|---|---|
| 1 | 知识库 / 市场仓储 SQLite 化 + 中文检索链路：✅ 已完成——纯 Dart 包 `advisor_storage` 承载全部 10 个 SQLite 仓储（第 1 轮）+ FTS5 中文检索（第 2 轮）；当前证据：`verify_storage` 71/0、`verify_retrieval` 32/0、`qa_verify` 123/2（仅余 TD-1 与症状记录探针 [BF6]）、`qa_verify_retrieval` 50/0、`advisor_core` 111/0 | M2 / M5 |
| 2 | ~~接入真实 ONNX `bge-small-zh`（约 100MB，本地推理，内容不出机）~~ 已用 **FTS5 + 应用层中文 bigram 的纯 Dart 方案**替代；`VectorStore`/`EmbeddingModel` 端口保留，将来可插拔换回 | M2 |
| 3 | ~~接入 `sqlite-vec` 向量检索~~ 已用 **FTS5 + 应用层中文 bigram 的纯 Dart 方案**替代；`VectorStore`/`EmbeddingModel` 端口保留，将来可插拔换回 | M2 |
| 4 | ~~市场 HTTP 客户端~~ ✅ 已完成（第 4 轮）：网络端口 `MarketHttpClient` 定义在 `advisor_core`（**core 零网络依赖**），`HttpMarketClient` 实现在 app（releaseUrl 直连 + `api.github.com` asset API 回退，通道实测结论见契约 04 §5.1）；拉取 `catalog/index.json` → 包列表实装（分类筛选 / 关键词搜索 / 刷新，282 个包）；下载 → **10 步安全链校验**（`MarketInstallFlow`：索引 sha256 对照 + `PackageVerifier` 步骤 2–9，校验失败逐条展示原因、**绝不安装、绝不落盘**）→ `MarketService.installPackage` 落库 → 专家自动进通讯录；证据：`verify_market` 63/0（含真实市场包 `tech-spec-expert-1.0.0.expert` 全链回归）；HTTP 真实拉取待用户机器走查 | M5 |
| 5 | ~~文档解析器扩展：PDF / DOCX / XLSX（当前只有 TXT / MD）~~ ✅ 已完成（第 3 轮）：纯 Dart 解析器集 TXT / MD / Markdown / CSV、DOCX、XLSX、PPTX、PDF（尽力而为，不可解析时明确报错不静默）+ 老版 DOC / XLS / PPT（`OfficeConverter` 端口 + `PowerShellOfficeConverter`（Windows COM）预转换，Office 缺失/超时给明确错误）；证据：`verify_parsers` 26/0 | M2 |
| 6 | Worker Runtime：解析 / Embedding / 下载 / 安装 / 生成全部异步化 | M5 |
| 7 | feature 页面：✅ 已完成（第 3 轮 T05，沙箱外待走查）——专家设置（大模型下拉、Grounding 策略、专家风格 7 预设单选 +「不指定」、提示词多行、知识库多选绑定含 topK / similarity_threshold）；通讯录三页签（好友 / 分组 / 群聊，首字母排序 + `#` 置顶 + 内联【⚙设置｜💬对话】）；群成员管理（组长恰好 0/1 名、设新组长旧组长自动降级、至少保留 1 名成员）；会话列表（置顶优先 + 时间倒序 + 点开续聊）与对话界面（单聊 / 群聊流式渲染，**不显示思考过程**）；知识库批量导入（多文件夹多选 + 进度 UI；**第 4 轮已移除导入入口**，由关联文件夹 + 重新扫描取代）。市场浏览页已实装（第 4 轮，待走查） | M5 |
| 8 | 277 个种子专家批量转换并上架（`agency-agents-zh` → 本方案格式） | M6 |
| 9 | 专家评测集（§32）与安全验收（§33） | M6 |
| 10 | Windows / macOS 安装包与发布 | M6 |
| 11 | 知识库「文件夹关联」模式：✅ 已完成（第 4 轮，沙箱外待走查）——可关联多个本地文件夹（路径比较键去重 + `COLLATE NOCASE` 防大小写变体直写）；「重新扫描」**两阶段**（`planRescan` dry-run → 三防线交互 → `executeRescan`）：新增走导入链 / 内容变化删旧重建（mtime+size 预筛 + sha256 确认，**mtime 漂移不算更新**）/ 源文件删除同步清文档；**三防线**：失联 → 显著提示“找不到文件夹”且**零删除**、大比例删除（≥50% 或 ≥20）→ 弹窗逐项删除清单确认后重入、删除铁律 → 只许逐个 `deleteDocument`（`folder_sync.dart` 批删入口零命中）；断开**二选一**（默认「仅解除关联」保留内容可检索 / 「解除并删除」精确计数 + 不可恢复警告）；旧文档「补绑」（前缀 + 文件在位双条件，只增不删）；孤儿文档（未关联）任何同步路径不触碰；导入入口已移除（`importDocument` / `ImportBatch` 底层保留供重扫复用）。证据：`verify_round4` core 121/0 + storage 43/0（三防线逐条 + unlink 双路径 + 孤儿保护 + path_canon） | M5 |
| 12 | 群聊体验改造：✅ 已完成（第 6 轮，沙箱外待走查）——① 发言质量三层：新 `LeaderLedStrategy`（id `leader_led`）= 强制入选（用户 `@成员` ∪ 组长正文 `@提名` ∪ 组长先行）＞ 相关性粗筛（`MemberRelevanceScorer`，**复用 `ExpertiseTokenizer` 同口径**，超 `minRelevance`=0.01 入选）＞ 全不命中仅组长兜底；`max_speakers_per_round` 默认 3 上限；新 `GroupDirectiveResolver` 正则解析发言范围（"让组长一个人发言"等，**用户指令 ＞ 持久策略**，不做 LLM 意图分类）；新 `GroupPromptComposer` 注入角色声明 + 群公告（**硬契约：每位发言者含总结者**）+ 发言范围 + 简洁规则；**静默契约**（成员回 `【不参与】` → step partial + 消息 cancelled 清空 + **UI 不渲染气泡**）。② 群卡片 + 群管理：中栏内联 `GroupSummaryCard`（「群成员｜群管理」两页签）+ `GroupSettingsView`（改群名 / 组长 / 策略 / 上限 / 公告）+ **单一展开原则**（父级 `_expandedId`；A 群卡片与 C 好友卡同源）。③ 总裁助理市场包（slug `executive-assistant`）+ 群管理「任命总裁助理为组长」一键流程。④ 头像拟人化（`AvatarResolver` 约定 `<data>/avatars/<expertId>.png` + `ExpertAvatar` 缺图回退；7 位已添加专家批处理生成 PNG；市场列表维持 emoji）。证据：`verify_round6` 70/0 + `verify_round6_group` 41/0（均 core）；schema v5 迁移（`group_configs` +3 列，纯加性）`verify_storage` 88/0 + storage `verify_round3` 51/0 + storage `verify_round4` 43/0 | M5 |
| 13 | app 静态门禁（appcheck）：✅ 已建立（第 6 轮收口）——`flutter analyze` / `dart analyze` 本机不可用（管道错误 231），改用 `过程文件/appcheck/`（进程内 analyzer）作 `app/` 类型门禁，**判据 `ERROR = 0`**；第 6 轮实测 `28 文件 / ERROR 0 / WARNING 0 / INFO 11`。**遗留待办**：11 条 `deprecated_member_use`（`expert_settings_panel.dart` 7 + `folder_section.dart` 4；`Radio.groupValue/onChanged`、`FormField.value`，Flutter 3.32/3.33 起需 `RadioGroup` 祖先 + `initialValue`） | M5 |
| 14 | 第 7 轮 T01 基建落地（可验证层）：✅ 已完成（沙箱外待走查）——① 头像确定性色板哈希下沉 core：`AvatarPaletteIndex`（`size=8`；`hash` = **FNV-1a 32 位 over UTF-8 code units**（自实现，严禁 `hashCode`）+ `of = hash % 8`）；`app/ui/theme/avatar_palette.dart` 只做 `index → Color`（8 色，白字对比度 5.13–10.00:1 全 ≥4.5）；② 知识库层级树纯逻辑下沉 core：`KbTreeNode` + `KnowledgeTreeBuilder.build/filter/relativePath/defaultExpandedIds`（§1.1.2 六边界：跨根 / 根外 / 大小写 / 分隔符 / rename 降级 / 空目录不显示；**relPath 只进 UI，不参与增删同步**）；③ `app/ui/widgets/app_card.dart`（规格 4.5 通用卡：悬停阴影 `0 1px 2px`→`0 2px 8px`）+ `AppColors`/`AppDims` 补卡片阴影 token；④ `ExpertAvatar` 增 `seed`/`skipImage`（向后兼容，调用点 4→4）。证据：新增 `verify_round7` **57/0**（core）；**验证基线 11 → 12 条（core 7 → 8）**，其余 11 条零回归 | M5 |
| 15 | 市场 emoji 数据链（第 7 轮 T06，用户选定 emoji 方案）：✅ 已完成（沙箱外待走查、远端待发布）——① `market/scripts/package_utils.dart` 的 `buildIndexEntry` 透传包内 `expert.json` 的 `emoji`/`color`（**纯 additive、仅非空才写、`schemaVersion` 保持 1**）；重生成 `catalog/index.json`：283 条 **emoji 278 / color 278**，与备份索引**逐字零漂移**（自检 `过程文件/emoji-index-drift-check.py` PASS）；② `advisor_core/domain/market.dart` 的 `MarketPackage` 加可选 `emoji`/`color`（`fromJson` 仅非空字符串才取，脏值→null 不抛）；③ app `market_page.dart` 卡片头像：有 emoji → 圆形底 = 包 `color`（安全解析，非法回退 `AvatarPalette.colorFor`）+ emoji；无 emoji → 首字 + `AvatarPalette.colorFor(packageId)` + 白字（头像处原微信绿裸色值 `0xFFE8F6EE`/`0xFF07C160` 已清除）。证据：`verify_market` 78→**84/0**（+6 emoji/color 断言）、12 条基线全绿、appcheck `ERROR 0 / WARNING 0 / INFO 11`。**pending**：推送（本机无 `GH_TOKEN`）+ 远端 CI 重建 + 实机走查。红线：`packages-src/**` 一字未改 | M5 |
| 16 | 用户走查三件（第 7 轮 · 纯 app 层，schema/core/storage 零改动；沙箱外待走查）——**E-1 会话输入框改微信逻辑**：`conversation_view.dart` `_onInputKeyEvent`（挂在**输入框自身 `FocusNode.onKeyEvent`**，按 SDK `focus_manager.dart` L2263-2268 分发顺序保证在默认换行前拦截）实现 **Enter 发送 / Shift(Ctrl|Alt|Meta)+Enter 换行**；换行由 `_insertNewline()` 手动重组 `TextEditingValue`（**已删 `textInputAction: newline`**）；**空输入不发送且不吞键**、`_running`/`_sending` 期间 `enabled: true` **允许继续输入**；发送后 `clear()` + `requestFocus()` 支持连续发；顺手清扫裸色值 `0xFFEDEDED`/`0xFF95EC69` → `AppColors.bgTertiary`/`userBubble`、`circular(8)` → `AppDims.radiusM`。**E-2 群聊 @成员选择器**（新增 `mention_picker.dart`，仅群聊）：光标处 `@词` 触发面板（词边界扫描、**@ 必须词首**），候选 = 群成员（`conversation_members` 只含专家 → **天然不含用户自己**）+ **按显示名去重** + 角色徽标；`↑↓` 移动 / `Enter`或`Tab` 选中 / `Esc` 关闭 / 鼠标点选；**面板开时 Enter = 选中，绝不落到 `_send()`**（无候选时只 Esc 可关，不发半截 @ 消息）；选中把 `@半截词` 换成 `@<显示名> `（**尾随空格**，与 core `GroupDirectiveResolver` 的 `text.contains('@$name')` 口径对齐）；关闭覆盖「选中 / Esc / 删掉 @ / **失焦**（帧末延迟判定，规避焦点转移期回调乱序误关）/ 切换会话」；候选用既有 `AppCard`。**E-3 人才市场三栏拆分**（第 7 轮 §1.2.1 / §5 T03）：新增 `market_card.dart`（中栏紧凑卡 + 共享 helpers `kMarketCategoryNames`/`marketCategoryLabel`/`parseHexColor`/`marketPackageAvatar`）与 `market_detail_pane.dart`（右栏：emoji 头像 + 专家名 + **擅长业务** + 描述 + 标签 + 分类/版本 + **[添加]** + **10 步校验结果区内联**（失败逐条））；`market_page.dart` **原整页改为中栏 `MarketListPane`**（搜索框 + **分类 chip 横排** + 紧凑卡列表）；`main.dart` case 2 改为「中栏 `MarketListPane`（`_listWidth(context)`）+ `VerticalDivider` + 右栏 `MarketDetailPane`」，数据经 **`MarketState` 快照单向流**（中栏是唯一持有者）；`_showDetail`/`_showVerificationReport` **由弹窗迁为 pane 内容**，**安装链路 + 10 步校验编排零改动**（冻结项）；保留 `onInstalled → _contactsTick++` 刷新链、已添加徽标、`kMarketCategoryNames` 中文筛选。证据：**appcheck ERROR 0 / WARNING 0 / INFO 11**（扫整个 `app` 34 文件同样 0/0）、**13 条基线全绿零回归**（core 9 `111/87/121/84/26/22/70/56/57` + storage 4 `88/51/43/32`）、`qa_verify*.dart` 只跑不改。**pending：app 未真实编译（本机无 flutter）→ 键位/面板/三栏布局均待用户实机走查** | M5 |

| 17 | 会话附件上传（第 8 轮，沙箱外待走查）——① **领域纯逻辑**：新增 `domain/attachment.dart`（`Attachment` 实体 / `AttachmentKind` / `ImageFit`（二期预留）/ `PendingAttachmentStatus` 四态 / `PendingAttachment`）+ `AttachmentPolicy`（**16 项白名单** 图片6+文档/zip10、**20MB 上限**（`kMaxAttachmentBytes`，边界含等号）、文件名**安全化**（分隔符/冒号/控制字符/`..` / **Windows 保留名** / 尾点空格 / 超长截断80 保留扩展名 / 空回退 `file`）、`storedRelPath` 内容寻址（sha 强制校验）、`isInsideRoot` 二次断言防逃逸（`<root>-evil` 前缀陷阱正确拒绝）、`validate`）+ `AttachmentStore` **端口（零 IO）**；② **存储层 v6**：`schema.sql` 新增 `message_attachments` 表（FK→`messages(id)` **ON DELETE CASCADE**）+ `idx_attachments_msg` / `idx_attachments_sha` 两索引，`kSchemaVersion` 5→6，`schema.g.dart` 重生成（逐字一致），守卫链加 **no-op 空分支**；`SqliteAttachmentRepository`（7 方法，**`listAttachmentsByMessages` 批量查防 N+1**、`countByStoredPath` **DB 登记计数绝不扫盘**）；`MessageRepository` + **`deleteMessage`**；`Repositories` + `attachments`；③ **应用层**：`application/attachment_store.dart` 的 `LocalAttachmentStore`（**内容寻址、同内容跳过复制、写 `.part` 再原子改名**、删前断言在 root 内）+ `AttachmentService` **两阶段**（`draft` 纯校验**不落盘不落库** → `send` 读文件算 sha256 → save → insert，**失败隔离不抛异常**，落库失败立即清物理文件防孤儿）；`ConversationService.deleteMessage`（**三级 fail-closed**：消息存在 / 属于该会话 / **仅 `senderType==user`**（主理人铁律：专家消息一律不可删）+ **双清**：`messages.deleteMessage` DDL 级联 → `attachments.deleteByMessage` 显式删 → **按 DB 引用计数清物理文件**）+ `listMessagesWithAttachments` 批量预载；④ **UI**：`attachment_pick.dart`（FilePicker + 纯校验，**零 File 操作**）、`attachment_bar.dart`（pending 四态条：ready / uploading / failed / rejected）、`message_attachment_card.dart`（图片缩略 **120px** 圆角 8 `Wrap` + `errorBuilder` 回退 + 文件卡严格照规格 §4.3.3）、`image_viewer.dart`（全屏 `InteractiveViewer` 0.8–8 + 双击复位 + Esc/按钮关闭）、`conversation_view.dart`（**36px 工具栏**：[📎] 固定左1 + [@提及] 仅群聊左2（复用同一 `MentionPicker`） + 弹性 + [发送]；pending 条挂工具栏下方；用户气泡挂附件卡；**长按/右键仅用户消息**出菜单（复制/删除）+ **二次确认**「删除后不可恢复；该消息的知识库引用记录将保留」 + `_reload()`；「打开文件」`explorer /select,<path>`，**非 Windows / 失败降级 Clipboard + SnackBar**）；⑤ **归属红线 / 不预复制**：附件归属只认 `message_id`，物理 GC 只用 `countByStoredPath`，`attachment_store.dart` 源码**零 `.listSync(` 调用**（脚本断言）；选择阶段零 IO ⇒ 选了又取消零孤儿。证据：`verify_round8.dart` **195/0**（含**红队用例表 20 条逐条精确期望 + 全表不变量复检 + 幂等**、真实临时目录沙箱、同 sha256 二次 save **mtime/长度/内容三重不变**证明未复制、同内容两消息**同 storedPath 且物理文件只 1 份**、**删专家消息被拒且消息/附件/物理全不受影响**、同消息同内容只删一次）、`verify_storage` **133/0**（**0→6 与 5→6 两路径**、连跑 + 回退5 + 回退1 幂等、**FK cascade 直查子表实测 + FK OFF 反证**、`PRAGMA foreign_keys` 实测 = 1）、13 条基线零回归、**appcheck（app/lib 37 文件 / 整个 app 38 文件）ERROR 0 / WARNING 0 / INFO 11（均为既有 deprecation）**、`qa_verify*.dart` 只跑不改（`qa_verify` 150/1 仅剩既有 [6.11]）。**两处偏离已报备**：`AttachmentService` 由设计所列的 `services.dart` 移至 `attachment_store.dart`（它要读文件算 sha256，属 IO；`services.dart` 保持**零 `dart:io`**）；设计 §1.2「删前计数 `AND id != ?`」改为**先删行再计数**（原写法在同消息重复同内容时两行互判「仍有引用」→ 泄漏孤儿物理文件）。**pending：app 未真实编译（本机无 flutter）→ 全部 UI 待用户实机走查** | M5 |
| 18 | 知识库子文件夹层级显示 + 人才市场三栏（第 7 轮 T02 / T03，用户 2026-10-02 认可三栏方向）——**知识库**：新增 `app/lib/features/knowledge/knowledge_tree_pane.dart`（中栏：知识库 chip 切换 + 搜索 + 树）与 `knowledge_detail_pane.dart`（右栏：库设置 + 按选中节点过滤的文档详情 + 检索测试），`knowledge_page.dart` 重写为中栏/右栏两栏；树构建用第 7 轮 T01 已落地的 `KnowledgeTreeBuilder`（core 纯逻辑，`verify_round7` 57/0）；**展示层相对路径推导，不引入 rel_path 列、不碰归属判定**（归属 100% 由 `doc.folderId` 决定；路径推导失败落「其他」桶、优雅降级）；空目录不显示；默认展开「库根 + 关联文件夹 + 一级子文件夹」，用户显式开/合状态本会话内保持；搜索命中祖先自动展开子树。**人才市场**：`market_page.dart` 拆为 `MarketListPane` + 新增 `market_card.dart` / `market_detail_pane.dart`（emoji 头像优先 + 擅长业务 + 10 步校验区内联）。appcheck `app/lib`(39) 与整个 `app`(40) 均 **ERROR 0 / WARNING 0**；13 条基线零回归。**待用户实机走查** | M3/M5 |
| 19 | 走查第三批：市场三连修（卡片高度 / 弹窗空白 / emoji 未显示）——① **卡片太高留空白**：`childAspectRatio 0.78→1.18`（右栏 4 列卡高 ≈260px→≈172px）、头像 52→44px、「已添加」由独占一行改右上角小标，并按用户要求**扩充介绍信息**（描述 2 行 + 标签 1 行）；② **弹窗空白（真 bug）**：`MarketDetailDialog` 原先不接收 `package`、完全依赖 `stateListenable`，`listenable==null || state.selected==null` 时返回 `SizedBox.shrink()` → 弹出空白框；修为 **`package` 必填直传作主数据源** + `stateListenable` 降级为可选实时通道（null 退化静态详情）+ `_Detail.state` 可空化全 `?.` 兜底，**结构上杜绝空白弹窗**；③ **emoji 未显示（真 bug，根因在持久化）**：实机查用户 DB 发现 `market_packages` **无 emoji/color 列**（库里已有 284 行、远端索引带 emoji，是仓储丢字段）→ schema **v6→v7** 加两列（additive + `_addColumnIfMissing` 双保险）+ 重生成 schema.g.dart + 仓储 INSERT/读回映射（**null→NULL 不写空串**）。断言 `verify_market` 84→**101/0**、`verify_storage` 133→**197/0**；13 条基线零回归；appcheck `app/lib`(44) 与整个 `app`(45) 均 ERROR 0 / WARNING 0。**用户需两动作生效**：重启 app（触发 v6→v7 补列）+ 再点「刷新索引」（写入远端 emoji） | M5 |
| 20 | 走查第四批：市场三连 + 扫描中断 + 粘贴降级 + 图标标题——① 点「添加」没反应 = 两个独立根因：(a) app/lib/main.dart 声明 _marketListKey 却从未作为 key: 传给 MarketListPane → currentState 恒 null → ?.install(p) 静默无操作（这也正是此前弹窗空白的真凶）；(b) sqlite_market_repository.dart 的 _package() 原 slug:''（注释错称 slug 非消费字段），而 install() 用 pkg.slug 拼安装目录 → 所有包装进同一个 packages/-1.0.0（实机 DB 8 行 install_path 全同）。修为 key: 挂载 + **schema v7→v8 加 slug 列**（additive + 守卫）+ INSERT 13 列 + rowString(r['slug']) ?? ''；断言 verify_market 101→112/0、verify_storage 197→250/0（含升级后存量 slug 空串 → 刷新索引才写入 → 安装目录恢复 slug-version 的关键路径）。② 缩小窗口卡片 BOTTOM OVERFLOWED BY 47 PIXELS：根因是 childAspectRatio 让卡片高度随右栏宽度同比缩放；修为 **mainAxisExtent: 176（固定高度）** + 列数 <420→2 / <640→3 / 否则4。③ 知识库 35 篇只进 11 篇：根因是重扫循环 if (!mounted) return; 切页签即静默中断；修为 lastScanAt==null 时行内显示上次扫描未完成提示。④ 粘贴图片：grep 本机 Flutter SDK 3.44.6 证实 Clipboard 无图片 API（仅 kTextPlain），按纪律不假装实现，降级为有文本照常粘贴 / 无文本时 SnackBar 引导用 📎 选图。⑤ 图标 + 名称：生成 7 尺寸 app_icon.ico(372KB) 覆盖原文件（RC 引用不变），窗口标题用 \u79C1\u4EBA\u987E\u95EE\u56E2（.cpp 保持纯 ASCII 防 GBK 乱码）。13 条基线全绿、appcheck 44 文件 ERROR 0 / WARNING 0 / INFO 0 | M3/M5 |
> 表中 `§` 引用均指《私人顾问团_V1.3_系统架构与数据模型设计.md》。

---

## 技术债台账（TD）

> 登记自第 1、2 轮 QA 独立验证；镜像维护于《私人顾问团_V1.3_系统架构与数据模型设计.md》§51.10 与《私人顾问团_V1.3_开发方案.md》§39.8。
> 第 2 轮 QA 提出 3 项观察：**O-2 → 登记为本表 TD-4**；**O-3 即既有 TD-1**；**O-1（FTS 索引被清空后启动不回填）已按裁定修复**（`ensureSchema` 现在「FTS 为空且有分块」时幂等回填），**不登记**。

| 编号 | 等级 | 内容 | 处置 |
|---|---|---|---|
| **TD-1** | ~~中危~~ **✅ 已修复** | 存量 8 仓储未做错误归一化（`advisor_storage/lib/src/database/sqlite_repositories.dart`），抛裸 `SqliteException` 而非 `StorageError`；仅新增的 Knowledge / Market 两仓储有防护 | ✅ **2026-10-03 修复**：文件级私有泛型 `_guard<T>`（`if (e is AppError) rethrow; throw normalizeStorageError(code, e)`）包裹 **8 仓储 55/55 公开方法**（漏网 0），错误码约定 `storage.<area>.<method>`。证据：`verify_error_normalization` **38/0**、QA 独立 `qa_verify_error_normalization` **39/0**（55/55 覆盖核对 + 只归一化一次 + 成功路径逐列零变更 + 码稳定且互不重复）、`qa_verify` **151/0**（原持续红的 `[6.11]` 转绿，`[6.12]` 已由 QA 由反证改为正向断言）、全量回归零失败 |
| **TD-2** | 低危 | `market_packages.sha256/signature` 恒为 NULL（`sqlite_market_repository.dart:82`），sha256 仅存于 `market_versions` | 待 M5 接入市场 HTTP 客户端时一并处理 |
| **TD-3** | 观察 | `deleteDocument` 不清 `message_citations`（该表无 FK 指向 documents/chunks），引用快照保留 | **已决策保留**：历史回答的引用是不可变快照，不应被追溯篡改 |
| **TD-4** | 观察 | 单字中文查询返回空（`ChineseBigram` 仅产出相邻 bigram，单字 `bigram=0`） | **已决策保留**（第 2 轮 QA 观察 **O-2**）：单字召回噪声过大、不构成有效检索意图；检索测试页对不足 2 字的查询**显式提示**「查询词过短，请输入至少 2 个字」，**不静默返回空** |
| **TD-5** | 观察 | `_guard` 会把**非 `AppError` 的一切**异常（含 Dart 自身 `TypeError` / `RangeError` 等**编程错误**）归一化为 `StorageError`，改写异常类型并丢失原始堆栈 | **已决策保留**（2026-10-03 TD-1 验收中 QA 提出，非阻断）：与既有 market / knowledge 仓储同口径、`cause` 保留原异常（非静默吞掉）；若要保留编程错误原样，需**全局**收窄为仅包 `SqliteException`，会与现有两仓储不一致 → 留作后续统一整改 |

---

## app 静态门禁（appcheck）—— `flutter analyze` 的本机替代

> 本机 `flutter analyze` / `dart analyze` / `dart test` **均不可用**：启动 analysis_server 时必然
> `CreateFile failed 231（所有的管道范例都在使用中）`，为沙箱/环境层面对子进程管道创建的限制
> （`dart format` 只能查语法、查不了类型）。`app/` 包因此从第 5 轮起长期未被类型检查。
>
> 替代手段：`过程文件/appcheck/`（进程内 analyzer，直接 `package:analyzer` 的 `AnalysisContextCollection`，
> **不启动 analysis server**）。

**命令**：

```bash
cd "E:/APP/私人顾问团/过程文件/appcheck" && \
"/path/to/flutter/bin/cache/dart-sdk/bin/dart.exe" run bin/check.dart "<repo>/app/lib"
```

**判据（硬）**：**`ERROR` 必须为 0**（有 ERROR 时退出码 1 → 视为门禁失败）。
`WARNING` 逐条判性质（真缺陷→修 / 死代码→删）后清零或登记；`deprecated_member_use`（INFO）暂不阻断，见待办。

**第 6 轮收口实测**：`Dart 文件 28 ｜ ERROR 0 ｜ WARNING 0 ｜ INFO 11`。
（INFO 11 条分布：`expert_settings_panel.dart` 7 条 + `folder_section.dart` 4 条，均为 `Radio.groupValue/onChanged`、`FormField.value` 废弃——Flutter 3.32/3.33 起，需改用 `RadioGroup` 祖先 + `initialValue`；**本轮不改**，记待办。）

---

## 第 1 轮验证证据（QA 已通过）

| 脚本 | 命令 | 结果 |
|---|---|---|
| 存储层（工程师） | `cd advisor_storage && dart run tool/verify_storage.dart` | **通过 49 ／ 失败 0** |
| 存储层（QA 独立） | `cd advisor_storage && dart run tool/qa_verify.dart` | **通过 100 ／ 失败 1**（唯一失败 = TD-1） |
| 核心层回归 | `cd advisor_core && dart run tool/verify.dart` | **通过 111 ／ 失败 0** |

两轮验证共发现并修复 **2 个存量缺陷 + 2 项本轮偏差**：

1. `SqliteGenerationRepository.listRuns` 原用 `List.then()` —— **根本编译不过**（存量）
2. `applySchema` 分节注释导致整段 `CREATE TABLE` 被跳过，`generation_runs` 等表实际不会创建（存量）
3. `recoverInterrupted` 返回全表 `cancelled` 总数而非"本次恢复数"（本轮）
4. FK 开关依赖调用方，`ensureSchema` 路径下 `foreign_keys=0` 导致级联删除静默失效（本轮）

> ⚠️ **未验证项**：`app/` 的 Flutter UI 渲染与交互**仍未在任何环境验证过** —— 需用户安装 VS Build Tools（含「使用 C++ 的桌面开发」）后 `flutter create --platforms=windows,macos .` → `flutter run -d windows` 走查。**不得视为已验证。**

---

## 第 2 轮验证证据（QA 已通过）

本轮核心变更：**中文检索改用「FTS5 + 应用层中文 bigram」的纯 Dart 方案**（新增端口 `Retriever`，`Fts5Retriever` 实现；`InMemoryRetriever` 供测试）。五个脚本的真实输出：

| 脚本 | 命令 | 结果 |
|---|---|---|
| 存储层（工程师） | `cd advisor_storage && dart run tool/verify_storage.dart` | **通过 71 ／ 失败 0** |
| 检索链路（工程师，新增） | `cd advisor_storage && dart run tool/verify_retrieval.dart` | **通过 32 ／ 失败 0** |
| 存储层（QA 独立） | `cd advisor_storage && dart run tool/qa_verify.dart` | **通过 123 ／ 失败 2** |
| 检索链路（QA 独立，新增） | `cd advisor_storage && dart run tool/qa_verify_retrieval.dart` | **通过 50 ／ 失败 0** |
| 核心层回归 | `cd advisor_core && dart run tool/verify.dart` | **通过 111 ／ 失败 0** |

`qa_verify` 的 2 项失败**均为预期**：

- `[6.11]` = 已登记技术债 **TD-1**（存量 8 仓储未做错误归一化），持续红属预期；**（2026-10-03 现状：TD-1 已修复，该断言已由 QA 改为正向断言，`qa_verify` = 151/0；另 `[6.12]` 同期由反证改为「错误码合规 + cause 保留」正向断言）**
- `[BF6]` = 一条**症状记录式**探针，其"期望"记录的是 O-1 修复**前**的旧行为（v2 库人为清空 FTS 后 `ensureSchema` **不**回填=0 行）。本轮按裁定修复 O-1 后，`ensureSchema` 在"FTS 为空且有分块"时**总是幂等回填**，该探针实际值变为 2、断言必然翻转——**属预期，已交 QA 更新该用例**（工程师不得修改 QA 脚本）。

**根因修复（本轮）**：旧 `bigram()` 会**追加尾单字**，查询侧用 `AND` 连接 → `MATCH "举高" AND "高"`，而索引中**从不存独立单字** "高" → **批量检索恒返回 0**。本轮改为：**只产出相邻 bigram** + 查询侧 `OR` 召回 + 覆盖率过滤。

**阈值语义变更（重要）**：原 `similarity_threshold`（余弦相似度，默认 0.75）→ 新语义为**查询 bigram 命中覆盖率** `|Q ∩ C| / |Q|`（默认 **0.5**；`schema.sql` 列默认值同步由 0.75 改为 0.5）。用**真实中文文档**标定（语料：5 份专家 `main.md`，15 个分块）：

| 阈值 | 工程师样本（17 条有效查询） | QA 样本（6 条有效查询） |
|---|---|---|
| ≥0.50 | 15/17 有命中 | 6/6 有命中 |
| ≥0.75 | 14/17 有命中 | 5/6 有命中 |
| ≥1.00 | 13/17 有命中 | 4/6 有命中 |

> 结论：**0.5** 在"长多概念查询不塌成 0"与"噪声不过多"之间取得平衡；0.75 会使部分有效多概念查询（如「技术参数负偏离」「投标保证金递交开标时间节点」）丢结果。标定脚本：`advisor_storage/tool/calibrate_threshold.dart`。

**为何放弃 ONNX `bge-small-zh` + `sqlite-vec`**：

1. `onnxruntime` 是 **Flutter 原生插件**，无法安装进纯 Dart 包（`advisor_core` / `advisor_storage` 必须保持**不依赖 Flutter**、可独立 `dart run` 验证）；
2. 本机系统库 `winsqlite3.dll` **未编译扩展加载支持**，且 Dart `sqlite3` 包未暴露加载 `sqlite-vec` 扩展的 API；
3. Dart 无法派生子进程（命名管道 `ERROR_PIPE_BUSY`）→ `flutter` 命令在本环境不可用，无法打通插件链路。

FTS5 为 SQLite **内建**能力：**零额外原生依赖**、内容不出本机（本地优先）、在纯 Dart 环境可独立验证——故选此方案。**`VectorStore` / `EmbeddingModel` 端口保留**，将来若环境允许可插拔换回。

**`app/` 首次编译缺陷（已修）**：`lib/main.dart` 原整包 `import 'package:sqlite3/sqlite3.dart'` 会把 sqlite3 的 `Row`/`ResultSet` 等符号注入，与 Flutter 布局的 `Row` **撞名**（`main.dart(233,13)` 报 `'Row' is imported from both flutter/widgets/basic.dart and sqlite3/result_set.dart`）。已改为**只导入实际用到的符号** `import 'package:sqlite3/sqlite3.dart' show Database;`，并顺带**审计 `app/` 全部 import**（无其它 advisor-vs-Flutter 撞名、无未用 import、引用符号均存在）。

> ⚠️ **本轮未验证项**：`app/` 的 **检索测试页**（入口：知识库页顶部「文档 / 检索测试」切换）与 Flutter UI 渲染交互**仍未在任何环境验证过**——需用户安装 VS Build Tools（含「使用 C++ 的桌面开发」）后 `flutter create --platforms=windows,macos .` → `flutter run -d windows` 走查。**不得视为已验证。**

---

## 第 7 轮验证证据（T01 基建落地）

本轮 T01 交付：`advisor_core/lib/domain/avatar_palette.dart` + `knowledge_tree.dart` +
`advisor_core/tool/verify_round7.dart`（新）+ `app/lib/ui/theme/avatar_palette.dart` +
`app/lib/ui/widgets/app_card.dart` + `ExpertAvatar` 增 `seed`/`skipImage`。

**验证基线 11 → 12 条（core 7 → 8）**，全量真实输出如下（`dart run`）：

| 层 | 脚本 | 结果 |
|---|---|---|
| core | `verify.dart` | 通过 111 ／ 失败 0 |
| core | `verify_market.dart` | 通过 78 ／ 失败 0 |
| core | `verify_parsers.dart` | 通过 26 ／ 失败 0 |
| core | `verify_round3.dart` | 通过 87 ／ 失败 0 |
| core | `verify_round4.dart` | 通过 121 ／ 失败 0 |
| core | `verify_round6.dart` | 通过 70 ／ 失败 0 |
| core | `verify_round6_group.dart` | 通过 41 ／ 失败 0 |
| core | **`verify_round7.dart`（新）** | **通过 57 ／ 失败 0** |
| storage | `verify_storage.dart` | 通过 88 ／ 失败 0 |
| storage | `verify_round3.dart` | 通过 51 ／ 失败 0 |
| storage | `verify_round4.dart` | 通过 43 ／ 失败 0 |
| storage | `verify_retrieval.dart` | 通过 32 ／ 失败 0 |

- `qa_verify*.dart` **未改动**。
- app 静态门禁（appcheck）：`Dart 文件 30 ｜ ERROR 0 ｜ WARNING 0 ｜ INFO 11`。
- `dart format --output=none lib`：`Formatted 30 files (0 changed)`。
- **未验证项（pending）**：`app/` 仍无法真实编译；本轮 6 个交付物仅经 appcheck 静态担保，
  悬停阴影 / 同 id 恒同色 / 树降级行为需用户实机 `flutter run` 走查。

### 第 7 轮补丁：失败分支占位消息终态（task #42 / 契约 §2.4–§2.6）

- **缺陷**：单聊 / 群聊生成失败时，占位专家消息停留 `streaming`（与 `run=failed` / `step=failed` 不一致）；
  `Message.isFinal` 仅认 `{completed, partial}`，`cancelled` / `failed` 被误判为「仍在变化」。
- **修复**（`advisor_core` + `app`，`qa_verify*.dart` 未改动）：
  1. `Message.isFinal` 纳入 4 终态 `{completed, partial, cancelled, failed}`（`domain/conversation.dart`）；
  2. 失败路径把占位消息置 `MessageStatus.failed`（**正文保留已累积内容，为空则空串**），**不留 `streaming`**——
     单聊 `runSingleChat` catch + 群聊 per-member catch（`application/services.dart`）；
  3. app `conversation_view` 渲染顺序（契约 §2.6）：**先判 `failed`**（明确失败提示，**绝不空白气泡**）→
     再判 `cancelled && 正文空`（第 6 轮静默契约，不渲染）→ 其余正常气泡。
- **三件核对**：`grep "MessageStatus.failed" advisor_core/lib/` = **3 处代码命中（≥1）**；
  `isFinal` 已含 `failed`/`cancelled`；失败态在 app 侧为**明确失败提示**（非空白）。
- **验证**：`qa_verify_single_chat.dart` **95/0**；`qa_verify_group_failure.dart` **24/1** ——
  `H1.6 / H1.7 / H2.3`（C5.9 群聊版「占位消息终态 / = failed」）**由红转绿**；
  剩余 1 红 = `H2.9`（QA 独立发现：群聊全员失败 `run=failed` 时 `run.errorCode` 为空，**待裁定**，本补丁未涉及）。
- 其余 core 基线零回归：`verify_round3 87/0`、`verify_parsers 26/0`、`verify_round4 121/0`、
  `verify_market 84/0`、`verify_round6 70/0`、`verify_round6_group 41/0`；storage 4 条不变（`88 / 51 / 43 / 32` 全 0 失败）。
- **未验证项**：app 侧失败气泡渲染仅静态担保（无实机 `flutter run`）。

---

## 把市场推送到 GitHub

市场仓库目标：`https://github.com/TZW1982/private-advisor-market`（公开）

```bash
cd market
git init
git add .
git commit -m "feat: 初始市场（5 个投标专家包 + 校验工具链）"
git branch -M main
git remote add origin https://github.com/TZW1982/private-advisor-market.git
git push -u origin main
```

> ⚠️ **请使用 Personal Access Token（PAT）或 SSH key 认证，不要用账号密码。**
> 生成 PAT：GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens，
> 权限只需 `Contents: Read and write`。推送时用户名填 GitHub 用户名，密码填 PAT。

---

## 许可

- `advisor_core` / `app` / `market` 工具链：MIT
- 市场收录的专家包：版权归各自作者；来自 `agency-agents-zh`（MIT）的保留原始署名
