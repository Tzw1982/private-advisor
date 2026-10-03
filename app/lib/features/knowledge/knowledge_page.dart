/// 知识库管理页面（第 7 轮 T02 · D：**三栏化 + 子文件夹层级树**）。
///
/// 布局：`Column[ 页头 , Divider , Expanded(Row[ 中栏 KnowledgeTreePane(320) , 竖分割线 , 右栏 KnowledgeDetailPane ]) ]`，
/// 与「人才市场三栏」（第 7 轮 E）同构；中栏宽用既有 `AppDims.listWidth`（窄窗 280）。
///
/// 功能范围（第 4 轮后不变）：**新建知识库 / 关联文件夹（link / unlink 二选一 /
/// backfill 补绑）/ 重新扫描（两阶段：dry-run 计划 → 确认后执行，三防线交互
/// 见 [FolderSection]）/ 文档列表（状态·分块数·来源）/ 删除文档 / 删除知识库**。
///
/// **导入入口已移除**（第 4 轮裁定 #5）：内容一律通过「关联文件夹 + 重新扫描」
/// 增量同步——新增走导入链、内容变化删旧重建、源文件删除同步清文档。
///
/// 文档来源：`folder_id != null` = 由关联文件夹管理（重扫会同步）；
/// `folder_id == null` = **未关联（孤儿）**——旧导入或「仅解除关联」产物，
/// 内容保留、可检索，**任何同步路径都不会触碰**，UI 带徽标并引导「补绑」认领。
///
/// UI 只调用应用层服务（[KnowledgeService] / [FolderSyncService]），不直接触碰数据库。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'folder_section.dart';
import 'knowledge_detail_pane.dart';
import 'knowledge_tree_pane.dart';

/// 知识库管理页面（中栏树 + 右栏详情）。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({
    super.key,
    required this.knowledge,
    required this.folderSync,
  });

  /// 应用层知识库服务（由 Bootstrap 注入）。
  final KnowledgeService knowledge;

  /// 文件夹关联同步服务（由 Bootstrap 注入；第 4 轮新增）。
  final FolderSyncService folderSync;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  List<KnowledgeBase> _bases = const [];
  String? _selectedBaseId;

  List<KnowledgeDocument> _documents = const [];
  List<KnowledgeBaseFolder> _folders = const [];

  /// 每个文档的分块数（UI 展示用，按需查询）。
  final Map<String, int> _chunkCounts = {};

  bool _loading = false;
  bool _busy = false;

  /// 右侧面板模式：`false` = 文档管理，`true` = 检索测试（第 2 轮：知识库页内入口）。
  bool _showRetrieval = false;

  // —— 第 7 轮 T02（D）新增：树的交互态（**本会话内保持**）——
  /// 树搜索词（空 = 不过滤；命中祖先 → 自动展开其子树）。
  String _query = '';

  /// 中栏选中的节点 id（null = 未选中 → 右栏显示全部文档）。
  String? _selectedNodeId;

  /// 用户**显式展开**过的节点（切页签 / 重扫后仍展开）。
  final Set<String> _userExpanded = {};

  /// 用户**显式折叠**过的节点（优先于默认展开层级）。
  final Set<String> _userCollapsed = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 重新加载知识库与（若有选中项）文档、关联文件夹。
  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final bases = await widget.knowledge.listBases();
      var selected = _selectedBaseId;
      if (selected == null || !bases.any((b) => b.id == selected)) {
        selected = bases.isEmpty ? null : bases.first.id;
      }
      _bases = bases;
      _selectedBaseId = selected;
      await _loadDocuments(selected);
    } on AppError catch (e) {
      _snack('加载失败：${e.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 加载指定知识库的文档列表、各文档分块数、关联文件夹登记行。
  Future<void> _loadDocuments(String? knowledgeBaseId) async {
    if (knowledgeBaseId == null) {
      _documents = const [];
      _folders = const [];
      _chunkCounts.clear();
      return;
    }
    final docs = await widget.knowledge.listDocuments(knowledgeBaseId);
    _chunkCounts.clear();
    for (final d in docs) {
      try {
        _chunkCounts[d.id] = (await widget.knowledge.listChunks(d.id)).length;
      } on AppError {
        _chunkCounts[d.id] = 0;
      }
    }
    _documents = docs;
    try {
      _folders = await widget.folderSync.listFolders(knowledgeBaseId);
    } on AppError {
      _folders = const [];
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 统一包裹带忙标志的异步操作，异常转为 SnackBar。
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  Future<void> _createBase() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建知识库'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '知识库名称',
            hintText: '例如：消防车技术规格库',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;

    await _guard(() async {
      final base = await widget.knowledge.createBase(name: name);
      _selectedBaseId = base.id;
      _selectedNodeId = null;
      _userExpanded.clear();
      _userCollapsed.clear();
      await _reload();
      _snack('已创建知识库：${base.name}');
    });
  }

  Future<void> _deleteDocument(KnowledgeDocument doc) async {
    final ok = await _confirm('删除文档', '确定删除「${doc.fileName}」及其全部分块？');
    if (!ok) return;
    await _guard(() async {
      await widget.knowledge.deleteDocument(doc.id);
      await _reload();
      _snack('已删除：${doc.fileName}');
    });
  }

  /// 重命名知识库（用户走查反馈 #15-A）：预填当前名的输入对话框 → core
  /// `renameBase`（空名 / 不存在由应用层抛 AppError，走统一 `_guard`）。
  Future<void> _renameBase(KnowledgeBase base) async {
    final controller = TextEditingController(text: base.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名知识库'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '知识库名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null) return;

    await _guard(() async {
      final renamed = await widget.knowledge.renameBase(base.id, newName);
      await _reload();
      _snack('已改名：${renamed.name}');
    });
  }

  Future<void> _deleteBase(KnowledgeBase base) async {
    final ok = await _confirm(
        '删除知识库', '确定删除知识库「${base.name}」及其全部文档、分块？此操作不可撤销。');
    if (!ok) return;
    await _guard(() async {
      await widget.knowledge.deleteBase(base.id);
      _selectedBaseId = null;
      _selectedNodeId = null;
      _userExpanded.clear();
      _userCollapsed.clear();
      await _reload();
      _snack('已删除知识库：${base.name}');
    });
  }

  Future<bool> _confirm(String title, String message) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  /// 树节点开合：写入"用户显式"集合，使默认层级与用户操作互不打架。
  void _toggleExpanded(String id, bool open) {
    setState(() {
      if (open) {
        _userCollapsed.remove(id);
        _userExpanded.add(id);
      } else {
        _userExpanded.remove(id);
        _userCollapsed.add(id);
      }
    });
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: _listWidth(context),
                child: KnowledgeTreePane(
                  bases: _bases,
                  selectedBaseId: _selectedBaseId,
                  folders: _folders,
                  documents: _documents,
                  chunkCounts: _chunkCounts,
                  loading: _loading,
                  busy: _busy,
                  selectedNodeId: _selectedNodeId,
                  query: _query,
                  userExpanded: _userExpanded,
                  userCollapsed: _userCollapsed,
                  onSelectBase: (id) async {
                    setState(() {
                      _selectedBaseId = id;
                      _selectedNodeId = null;
                    });
                    await _guard(() async => _loadDocuments(id));
                  },
                  onCreateBase: _createBase,
                  onRenameBase: (b) => _renameBase(b),
                  onDeleteBase: (b) => _deleteBase(b),
                  onSelectNode: (id) =>
                      setState(() => _selectedNodeId = id),
                  onQueryChanged: (q) => setState(() => _query = q),
                  onToggleExpanded: _toggleExpanded,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: _selectedBaseId == null || _bases.isEmpty
                    ? const Center(
                        child: Text('请选择或新建一个知识库',
                            style: TextStyle(color: AppColors.textSecondary)),
                      )
                    : Builder(builder: (context) {
                        final base = _bases.firstWhere(
                          (b) => b.id == _selectedBaseId,
                          orElse: () => _bases.first,
                        );
                        return KnowledgeDetailPane(
                          base: base,
                          treeRoot: KnowledgeTreeBuilder.build(
                            base: base,
                            folders: _folders,
                            docs: _documents,
                            chunkCounts: _chunkCounts,
                          ),
                          documents: _documents,
                          chunkCounts: _chunkCounts,
                          folders: _folders,
                          selectedNodeId: _selectedNodeId,
                          showRetrieval: _showRetrieval,
                          busy: _busy,
                          knowledge: widget.knowledge,
                          folderSync: widget.folderSync,
                          onFolderChanged: _loadDocumentsForSelected,
                          onToggleRetrieval: (v) =>
                              setState(() => _showRetrieval = v),
                          onDeleteDocument: (d) => _deleteDocument(d),
                          onClearSelection: () =>
                              setState(() => _selectedNodeId = null),
                        );
                      }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 中栏宽度：窗口 <1000 时收窄到 280（与人才市场同款「紧凑」策略）。
  double _listWidth(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w < 1000 ? AppDims.listMinWidth : AppDims.listWidth;
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppDims.space4, 14, AppDims.space4, 14),
      child: Row(
        children: [
          const Icon(Icons.menu_book_outlined, size: 20),
          const SizedBox(width: AppDims.space2),
          const Text('知识库',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(width: AppDims.space3),
          const Expanded(
            child: Text(
              '纯本地：原文件不复制不修改，分块与索引全部留在本机，不上传。',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_busy)
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: AppDims.space2),
        ],
      ),
    );
  }

  /// FolderSection 变更后的刷新回调（只刷当前选中库的文档列表，不整页重载）。
  Future<void> _loadDocumentsForSelected() async {
    await _loadDocuments(_selectedBaseId);
    if (mounted) setState(() {});
  }
}
