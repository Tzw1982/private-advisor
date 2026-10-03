/// 私人顾问团 · 应用入口与三栏主界面。
///
/// 架构（V1.3 §4）：
///   Flutter UI → Application Services → Domain ← Infrastructure
/// UI 只调用 application 层服务，不直接碰数据库。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// 只导入实际用到的符号（Database），避免把 sqlite3 的 Row/ResultSet 等
// 与 Flutter 的布局 Row 撞名（此前 app 从未编译过，本处即该冲突点）。
import 'package:sqlite3/sqlite3.dart' show Database;

import 'features/contacts/contacts_pane.dart';
import 'features/contacts/expert_settings_panel.dart';
import 'features/conversation/conversation_list_pane.dart';
import 'features/conversation/conversation_view.dart';
import 'features/knowledge/knowledge_page.dart';
import 'features/market/market_controller.dart';
import 'features/market/market_detail_pane.dart';
import 'features/market/market_page.dart';
import 'infrastructure/avatar/avatar_resolver.dart';
import 'infrastructure/llm/openai_compatible_provider.dart';
import 'infrastructure/market/http_market_client.dart';
import 'infrastructure/office/powershell_office_converter.dart';
import 'infrastructure/secure_storage/secure_secret_store.dart';
import 'ui/theme/app_colors.dart';
import 'ui/theme/app_dims.dart';
import 'ui/theme/app_theme.dart';

// 第 9 轮 · 图片多模态：模型「支持视觉」开关挂载点（设置对话框内入口）。
import 'features/settings/model_manager.dart';
import 'features/settings/model_vision_settings.dart';
import 'ui/widgets/app_nav_rail.dart';
import 'ui/widgets/empty_pane.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final boot = await Bootstrap.run();
  runApp(PrivateAdvisorApp(boot: boot));
}

// ---------------------------------------------------------------------------
// 启动引导
// ---------------------------------------------------------------------------

/// 启动装配结果。
class Bootstrap {
  Bootstrap({
    required this.repos,
    required this.db,
    required this.dataDir,
    required this.experts,
    required this.conversations,
    required this.knowledge,
    required this.generation,
    required this.group,
    required this.providers,
    required this.credentials,
    required this.market,
    required this.marketClient,
    required this.marketFlow,
    required this.marketController,
    required this.expertExport,
    required this.expertImport,
    required this.packagesRoot,
    required this.folderSync,
    required this.attachmentStore,
    required this.attachmentService,
    required this.recoveredRuns,
  });

  final Repositories repos;
  final Database db;
  final Directory dataDir;
  final ExpertService experts;
  final ConversationService conversations;
  final KnowledgeService knowledge;
  final GenerationService generation;
  final GroupService group;
  final ProviderService providers;
  final CredentialService credentials;
  final MarketService market;

  /// 市场网络客户端端口实现（第 4 轮：端口在 core，实现在 app）。
  final MarketHttpClient marketClient;

  /// 市场包安装编排器（下载后的校验链 + 落盘，纯逻辑）。
  final MarketInstallFlow marketFlow;

  /// 人才市场列表控制器（**进程级**：跨页签重建存活，任务 #65 缺陷①修复）。
  ///
  /// 市场数据（包列表 / 已添加 / 分类 / 搜索 / 选中）全部由它持有，
  /// 中栏 MarketListPane 销毁重建不再丢数据、也不再需要联网刷新。
  final MarketController marketController;

  /// 专家导出服务（任务 #69：通讯录「导出专家」）。
  final ExpertExportService expertExport;

  /// 专家导入服务（任务 #69：通讯录「导入专家」，复用市场安全链）。
  final ExpertImportService expertImport;

  /// 包落盘根目录（`<data>/market/packages`）。
  final String packagesRoot;

  /// 文件夹关联同步服务（第 4 轮：link / unlink / backfill / 两阶段重扫）。
  final FolderSyncService folderSync;

  /// 附件物理存储（第 8 轮：内容寻址 `<data>/attachments/<sha256[0:2]>/<sha256>.<ext>`）。
  final LocalAttachmentStore attachmentStore;

  /// 附件编排（第 8 轮：两阶段——纯校验 pending → 发送时 save + insert）。
  final AttachmentService attachmentService;

  /// 启动时恢复的中断运行数（M1 验收项）。
  final int recoveredRuns;

  static Future<Bootstrap> run() async {
    // 1. 数据目录（契约 02 §5）
    final support = await getApplicationSupportDirectory();
    final dataDir = Directory(p.join(support.path, 'PrivateAdvisor'));
    for (final sub in [
      'database',
      'market/cache',
      'market/packages',
      'experts/instances',
      'knowledge/sources',
      'knowledge/indexes',
      'knowledge/models',
      'logs',
      'temp',
      'avatars',
      'attachments'
    ]) {
      Directory(p.join(dataDir.path, sub)).createSync(recursive: true);
    }
    // 头像解析器注入数据目录（第 6 轮 T05）：约定路径 <data>/avatars/<expertId>.png。
    AvatarResolver.configure(dataDir);

    // 2. 数据库 + schema（存储层已迁至纯 Dart 包 advisor_storage）
    final db =
        openAdvisorDatabase(p.join(dataDir.path, 'database', 'advisor.sqlite'));
    ensureSchema(db); // 读/写 PRAGMA user_version，为 0 时幂等建表

    // 3. 仓储（含 SQLite 版 Knowledge / Market，不再使用内存兜底）
    final secrets = SecureSecretStore();
    final repos = sqliteRepositories(db, secrets: secrets);

    // 4. 知识运行时：关键词检索后端 Fts5Retriever（纯 Dart，随 DB 连接装配）。
    //    Retriever 独占（不做 embedding 双写）；embeddingModel 仅作向量降级路径保留
    //    （FTS5 不可用时由 KnowledgeService 自动回退，并在检索页可见提示）。
    final retriever = Fts5Retriever(db);
    final knowledge = KnowledgeService(
      repos,
      // 全格式解析器集（第 3 轮）：纯文本 + OOXML + PDF 尽力而为 + 老版 Office
      // （.doc/.xls/.ppt 经 PowerShellOfficeConverter（Windows COM）预转换；
      //  Office 缺失/超时 → 明确报错、不静默，失败隔离到单文件）。
      parsers: [
        const PlainTextParser(),
        const DocxParser(),
        const XlsxParser(),
        const PptxParser(),
        const PdfTextParser(),
        LegacyOfficeParser(converter: PowerShellOfficeConverter()),
      ],
      chunker: SimpleChunker(),
      vectorStore: InMemoryVectorStore(repos.knowledge),
      embeddingModel: HashEmbeddingModel(), // 仅降级兜底
      retriever: retriever,
    );

    // 4.5 附件（第 8 轮）：内容寻址本地存储 + 两阶段编排。
    //      attachmentsRoot = <data>/attachments；**不写 DB、不动 schema**。
    //      必须在 ConversationService 之前创建（后者注入它才能做
    //      「双清 + 引用计数物理 GC」）。
    final attachmentStore =
        LocalAttachmentStore(p.join(dataDir.path, 'attachments'), repos.attachments);
    final attachmentService = AttachmentService(repos, attachmentStore);

    // 5. 服务
    final experts = ExpertService(repos);
    // 注入附件存储：deleteMessage 才能做「双清 + 引用计数物理 GC」。
    final conversations =
        ConversationService(repos, attachmentStore: attachmentStore);
    final providers = ProviderService(repos);
    final credentials = CredentialService(repos);
    final market = MarketService(repos, experts: experts);
    final marketClient = HttpMarketClient();
    final marketFlow = MarketInstallFlow();
    final packagesRoot = p.join(dataDir.path, 'market', 'packages');
    // 任务 #69：专家导入 / 导出服务（复用市场包格式与安全链，均只依赖 Repositories）。
    final expertExport = ExpertExportService(repos);
    final expertImport = ExpertImportService(repos);
    // 任务 #65：市场列表控制器（进程级）+ **启动预热**（纯读库，不联网）。
    // 预热后首帧即有数据；切页签回来也只是静默刷新，绝不会闪成空白。
    final marketController = MarketController(
      market: market,
      client: marketClient,
      flow: marketFlow,
      packagesRoot: packagesRoot,
    );
    await marketController.load();
    // 配套：v9 之前安装的专家没有 emoji 头像（存量库升级后两列为 NULL），
    // 按 packageId 从本地索引补上（纯读库、不联网；失败不影响启动）。
    try {
      await market.backfillExpertAvatars();
    } catch (_) {
      // 回填是尽力而为的体验修复：失败只意味着这些老专家继续显示首字头像。
    }

    // 6. LLM 工厂：按 providerProfileId 组装真实 HTTP 适配器

    /// API Key 解析（用户走查反馈 #15-B）：先按 provider 单独持钥
    /// （`cred_<providerProfileId>`，添加自定义模型时写入），读不到再回退
    /// 默认凭据路径——DeepSeek 内置场景（只存默认凭据）零行为回归。
    Future<String> _resolveApiKey(String providerProfileId) async {
      final perProvider = await credentials.getForProvider(providerProfileId);
      if (perProvider != null) {
        final secret = await repos.secrets.read(perProvider.secretRef);
        if (secret != null && secret.isNotEmpty) return secret;
      }
      final credId =
          await repos.settings.get(SettingKeys.defaultCredentialProfileId);
      final cred = credId == null ? null : await repos.credentials.get(credId);
      final key = cred == null ? null : await repos.secrets.read(cred.secretRef);
      return key ?? '';
    }

    Future<LlmProvider> buildLlm(String providerProfileId) async {
      final profile = await repos.providers.getProvider(providerProfileId);
      final key = await _resolveApiKey(providerProfileId);
      return OpenAiCompatibleProvider(
        providerId: providerProfileId,
        baseUrl: profile?.baseUrl ?? ProviderService.deepseekBaseUrl,
        apiKey: key,
      );
    }

    final generation = GenerationService(
      repos,
      experts: experts,
      conversations: conversations,
      knowledge: knowledge,
      llmFactory: (id) => _SyncLlmProxy(id, buildLlm),
    );
    final group = GroupService(
      repos,
      experts: experts,
      conversations: conversations,
      knowledge: knowledge,
      llmFactory: (id) => _SyncLlmProxy(id, buildLlm),
      // 用户反馈 #61：群总预算按模型真实上下文推导（不再用写死的 40000）。
      providers: providers,
    );
    // 文件夹关联同步（第 4 轮）：复用 KnowledgeService 导入链，纯 Dart 已全量验证。
    final folderSync = FolderSyncService(repos, knowledge: knowledge);

    // 7. 内置注册 + 启动恢复
    await providers.registerBuiltins();
    await market.registerDefaultSource();
    SpeakingStrategies.registerBuiltins();
    final recovered = await generation.recoverOnStartup();

    return Bootstrap(
      repos: repos,
      db: db,
      dataDir: dataDir,
      experts: experts,
      conversations: conversations,
      knowledge: knowledge,
      generation: generation,
      group: group,
      providers: providers,
      credentials: credentials,
      market: market,
      marketClient: marketClient,
      marketFlow: marketFlow,
      marketController: marketController,
      expertExport: expertExport,
      expertImport: expertImport,
      packagesRoot: packagesRoot,
      folderSync: folderSync,
      attachmentStore: attachmentStore,
      attachmentService: attachmentService,
      recoveredRuns: recovered,
    );
  }
}

/// 把异步构建的 Provider 适配为同步工厂所需的接口。
///
/// 由于 API Key 读取是异步的，这里先用「延迟初始化」的代理包一层：
/// 首次调用时完成解析。
class _SyncLlmProxy implements LlmProvider {
  _SyncLlmProxy(this.providerProfileId, this._builder);

  final String providerProfileId;
  final Future<LlmProvider> Function(String) _builder;
  LlmProvider? _delegate;
  final List<ChatRequest> _pending = [];

  Future<LlmProvider> _ensure() async =>
      _delegate ??= await _builder(providerProfileId);

  @override
  String get providerId => providerProfileId;

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      (await _ensure()).listModels();

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    _pending.add(request);
    return (await _ensure()).chat(request);
  }

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    final llm = await _ensure();
    yield* llm.stream(request);
  }

  @override
  Future<ProviderHealth> healthCheck() async => (await _ensure()).healthCheck();

  @override
  AppError mapError(Object raw) =>
      raw is AppError ? raw : ProviderServerError('$raw');
}

// ---------------------------------------------------------------------------
// 应用
// ---------------------------------------------------------------------------

class PrivateAdvisorApp extends StatelessWidget {
  const PrivateAdvisorApp({super.key, required this.boot});

  final Bootstrap boot;

  @override
  Widget build(BuildContext context) {
    // 全 app 唯一视觉事实来源（第 5 轮 UI 改版 · AppTheme.light()）。
    return MaterialApp(
      title: '私人顾问团',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: HomeShell(boot: boot),
    );
  }
}

/// 三栏主界面（第 5 轮 UI 改版 · 骨架 B1）：
/// 左 [AppNavRail] 180px 文字导航 → 中列表栏 320px → 右自适应详情区
/// （规格 §五 整体布局栅格；窗口 <1000px 时中栏收窄至 280）。
///
/// 各页签（B1 骨架批，页面内容 B2–B5 逐页迁移视觉）：
/// - 会话：中栏 [ConversationListPane]（4.2 规格）｜ 右栏会话视图 / 空态；
/// - 通讯录：中栏 [ContactsPane]（三页签原样迁入）｜ 右栏专家设置 / 空态引导；
/// - 人才市场 / 知识库：B1 暂以整页挂右区（B4/B5 拆分中栏列表 + 右栏详情）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.boot});

  final Bootstrap boot;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0; // 0=会话 1=通讯录 2=人才市场 3=知识库

  /// 中栏当前选中的专家（通讯录页签 → 右栏专家设置面板）。
  String? _activeExpertId;

  /// 中栏当前打开的会话（会话页签 → 右栏会话视图）。
  String? _activeConversationId;

  /// 右栏会话视图重建计数：当前会话被「清空」时递增，
  /// 强制 ConversationView 重建并从 DB 重载（消息已空）。
  int _conversationViewTick = 0;

  /// 递增以强制中栏通讯录重载（市场添加成功后刷新联系人列表）。
  int _contactsTick = 0;

  /// 人才市场（中栏 [MarketListPane]）句柄：右栏「添加」需要 `context` 弹提示条，
  /// 故仍保留（快照与数据改由 [MarketController] 持有，不再经此处中转）。
  final GlobalKey<MarketListPaneState> _marketListKey =
      GlobalKey<MarketListPaneState>();

  /// 中栏宽度：窗口 <1000px 收窄至 280，否则 320（架构设计待明确 #3）。
  double _listWidth(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w < 1000 ? AppDims.listMinWidth : AppDims.listWidth;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          AppNavRail(
            items: const [
              NavRailItem(icon: Icons.chat_bubble_outline, label: '会话'),
              NavRailItem(icon: Icons.people_outline, label: '通讯录'),
              NavRailItem(icon: Icons.storefront_outlined, label: '人才市场'),
              NavRailItem(icon: Icons.menu_book_outlined, label: '知识库'),
            ],
            selectedIndex: _tab,
            onSelected: (t) => setState(() {
              _tab = t;
              // 切页签不丢选中态，返回原页签仍停留在原处。
            }),
            onSettings: _openSettings,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildPane(context)),
        ],
      ),
    );
  }

  /// 页签内容（三栏：中列表 320 ｜ 1px 分割线 ｜ 右自适应详情）。
  Widget _buildPane(BuildContext context) {
    switch (_tab) {
      case 0:
        final convId = _activeConversationId;
        return Row(
          children: [
            SizedBox(
              width: _listWidth(context),
              child: ConversationListPane(
                conversations: widget.boot.conversations,
                group: widget.boot.group,
                experts: widget.boot.experts,
                repos: widget.boot.repos,
                onOpenConversation: (id) =>
                    setState(() => _activeConversationId = id),
                selectedId: convId,
                // 走查修复 #66：删除/清空「当前正打开」的会话时，右栏跟随。
                // deleted → 关闭右栏回空态；cleared → 递增 tick 重建视图重载消息。
                onConversationMutated: (id, kind) {
                  if (_activeConversationId != id) return;
                  setState(() {
                    if (kind == ConversationMutation.deleted) {
                      _activeConversationId = null;
                    } else {
                      _conversationViewTick++;
                    }
                  });
                },
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: convId != null
                  ? ConversationView(
                      // 会话 id 变化或当前会话被清空（tick 递增）时重建 →
                      // initState 重新从 DB 加载消息，确保与数据层一致。
                      key: ValueKey('conv-$convId-$_conversationViewTick'),
                      conversationId: convId,
                      generation: widget.boot.generation,
                      group: widget.boot.group,
                      conversations: widget.boot.conversations,
                      experts: widget.boot.experts,
                      repos: widget.boot.repos,
                      attachments: widget.boot.attachmentService,
                      attachmentStore: widget.boot.attachmentStore,
                      onBack: () =>
                          setState(() => _activeConversationId = null),
                    )
                  : const EmptyPane(
                      icon: Icons.chat_bubble_outline,
                      title: '选择一个会话',
                      hint: '从中间列表选择会话即可续聊；\n'
                          '也可以在「通讯录」对专家发起对话，或在「群聊」新建群聊。',
                    ),
            ),
          ],
        );
      case 1:
        final expertId = _activeExpertId;
        return Row(
          children: [
            SizedBox(
              width: _listWidth(context),
              child: KeyedSubtree(
                // 市场添加成功后 tick 递增 → 通讯录整树重建 → 各页签重载数据。
                key: ValueKey('contacts-$_contactsTick'),
                child: ContactsPane(
                  experts: widget.boot.experts,
                  conversations: widget.boot.conversations,
                  group: widget.boot.group,
                  repos: widget.boot.repos,
                  exportService: widget.boot.expertExport,
                  importService: widget.boot.expertImport,
                  onSelectExpert: (id) => setState(() => _activeExpertId = id),
                  onSelectConversation: (id) => setState(() {
                    _activeConversationId = id;
                    _tab = 0;
                  }),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: expertId != null
                  ? ExpertSettingsPanel(
                      key: ValueKey('expert-$expertId'),
                      expertId: expertId,
                      experts: widget.boot.experts,
                      providers: widget.boot.providers,
                      knowledge: widget.boot.knowledge,
                      repos: widget.boot.repos,
                      onBack: () => setState(() {
                        // 走查修复（#62）：删除专家后仅清选中态不会重载列表，
                        // 专家要等刷新才消失。这里同时递增 tick —— 与市场「添加成功」
                         // 走同一条重建链（KeyedSubtree key 变化 → ContactsPane 重载）。
                        _activeExpertId = null;
                        _contactsTick++;
                      }),
                    )
                  // 空态引导（设计裁定 #9：默认空态，不自动猜选）。
                  : const EmptyPane(
                      icon: Icons.people_outline,
                      title: '通讯录',
                      hint: '在左侧「好友」页签点联系人，展开【⚙设置｜💬对话】；\n'
                          '「分组」页签可增删改分组、移入移出成员；\n'
                          '「群聊」页签可新建群聊，让多位专家围绕同一问题协作。\n\n'
                          '还没有好友？去「人才市场」招募，或自建一位。',
                    ),
            ),
          ],
        );
      case 2:
        // 任务 #50（第 8 轮走查新规格）：中栏「搜索 + 竖向分类列表」，
        // 右栏「四列卡片网格」（窄栏自动降三列）；点卡片弹 MarketDetailDialog
        // （详情 + 添加 + 10 步校验结果区）。
        // 任务 #65：数据唯一持有者 = **进程级 MarketController**（跨页签重建存活），
        // 中栏 / 右栏 / 弹窗各自订阅它；切回来立刻有分类与卡片，**不依赖联网刷新**。
        final marketController = widget.boot.marketController;
        return Row(
          children: [
            SizedBox(
              width: _listWidth(context),
              child: MarketListPane(
                // ⚠️ 关键：GlobalKey 必须挂到 widget 上，否则 currentState 恒 null，
                // 点卡片里的「添加」会静默无操作（走查反馈：点击添加没反应）。
                key: _marketListKey,
                controller: marketController,
                onInstalled: (_) => setState(() => _contactsTick++),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: ValueListenableBuilder<MarketState>(
                valueListenable: marketController,
                builder: (context, state, _) => MarketGridPane(
                  state: state,
                  onOpen: (pkg) {
                    // 先同步中栏选中态（清旧校验报告），再弹详情 Dialog。
                    marketController.select(pkg);
                    showDialog<void>(
                      context: context,
                      builder: (_) => MarketDetailDialog(
                        // 走查修复：package 必填直传，弹窗绝不空白（不再依赖
                        // "中栏句柄已挂载 + 选中态非空"这条脆弱链路）。
                        package: pkg,
                        stateListenable: marketController,
                        // 中栏句柄在时走中栏（可弹提示条）；否则直接走控制器，
                        // 绝不静默无操作（旧缺陷：`?.install(p)` 句柄为空即无动作）。
                        onInstall: (p) {
                          final pane = _marketListKey.currentState;
                          if (pane != null) {
                            pane.install(p);
                          } else {
                            marketController.install(p);
                          }
                        },
                        onDismissReport: marketController.dismissReport,
                      ),
                    );
                  },
                  // 中栏句柄在时走中栏（可弹提示条）；否则直接走控制器，
                  // 绝不静默无操作（旧缺陷：`?.reload()` 句柄为空即无动作）。
                  onRetry: () {
                    final pane = _marketListKey.currentState;
                    if (pane != null) {
                      pane.reload(fromNetwork: true);
                    } else {
                      marketController.load(fromNetwork: true);
                    }
                  },
                ),
              ),
            ),
          ],
        );
      case 3:
        // B1：现有整页挂右区（B4 拆分中栏列表卡 + 右栏 KnowledgeDetailPane；
        // FolderSection 后台静默扫描与三防线交互整块保留）。
        return KnowledgePage(
            knowledge: widget.boot.knowledge,
            folderSync: widget.boot.folderSync);
      default:
        return const EmptyPane(title: '私人顾问团');
    }
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(boot: widget.boot),
    );
  }
}

// ---------------------------------------------------------------------------
// 设置：配置默认 API Key
// ---------------------------------------------------------------------------

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.boot});
  final Bootstrap boot;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _keyCtrl = TextEditingController();
  String? _modelProfileId;

  /// 全部模型档案与 provider 档案（默认模型下拉运行时生成，用户走查 #15-B）。
  List<ModelProfile> _models = const [];
  List<ProviderProfile> _providers = const [];

  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    widget.boot.providers.defaultModelProfileId.then((v) {
      if (mounted) setState(() => _modelProfileId = v);
    });
    _reloadModels();
  }

  /// 重新加载模型 / provider 档案（大模型管理增删后刷新下拉）。
  Future<void> _reloadModels() async {
    try {
      final models = await widget.boot.providers.listModels();
      final providers = await widget.boot.providers.listProviders();
      if (!mounted) return;
      setState(() {
        _models = models;
        _providers = providers;
      });
    } on AppError {
      // 加载失败保持旧列表；不打断设置对话框既有功能。
    }
  }

  /// 模型所属 provider 的显示名（下拉项展示用）。
  String _providerNameOf(ModelProfile m) {
    for (final p in _providers) {
      if (p.id == m.providerProfileId) return p.displayName;
    }
    return m.providerProfileId;
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('默认 API Key',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              '所有新增专家默认使用这个 Key；每个专家可单独覆盖。\n'
              'Key 只存本机凭据库，不写入数据库、不写日志、不上传。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key（DeepSeek 官方直连）',
                hintText: 'sk-...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('默认模型：'),
                const SizedBox(width: 8),
                // 用户走查反馈 #15-B：下拉项运行时从模型档案生成（含自定义
                // 模型）；value 不在候选中时置 null 防止断言炸裂。
                DropdownButton<String>(
                  value: _models
                          .any((m) => m.id == _modelProfileId)
                      ? _modelProfileId
                      : null,
                  hint: const Text('（未选择）'),
                  items: [
                    for (final m in _models)
                      DropdownMenuItem(
                        value: m.id,
                        child: Text('${m.modelId}（${_providerNameOf(m)}）'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _modelProfileId = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 第 9 轮 · 图片多模态：模型「支持视觉」开关（仅开启后，会话里的
            // 图片附件才会随消息发给大模型；未开启时发图会被明确拦下并提示）。
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showModelVisionSettings(context,
                    repos: widget.boot.repos,
                    providers: widget.boot.providers),
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('模型视觉能力（图片识别）'),
              ),
            ),
            // 用户走查反馈 #15-B：多模型管理（注册自定义端点 / 设全局默认）。
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await showModelManager(
                    context,
                    repos: widget.boot.repos,
                    providers: widget.boot.providers,
                    credentials: widget.boot.credentials,
                  );
                  await _reloadModels();
                },
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('大模型管理'),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(_message!,
                  style:
                      const TextStyle(color: AppColors.success, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final key = _keyCtrl.text.trim();
      if (key.isEmpty) {
        setState(() => _message = '请先填入 API Key');
        return;
      }
      await widget.boot.credentials.saveDefault(
        apiKey: key,
        providerProfileId: ProviderService.deepseekProviderId,
      );
      if (_modelProfileId != null) {
        await widget.boot.providers.setDefaultModel(_modelProfileId!);
      }
      setState(() {
        _message = '已保存（明文未落库）';
        _keyCtrl.clear();
      });
    } on AppError catch (e) {
      setState(() => _message = '保存失败：${e.message}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
