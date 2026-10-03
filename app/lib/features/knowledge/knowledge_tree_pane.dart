/// 知识库**中栏**：知识库切换 + 搜索 + 子文件夹层级树（第 7 轮 T02 · D）。
///
/// 设计依据：`过程文件/第7轮-架构设计.md` §1.1（展示层相对路径推导）与 §5 T02；
/// UI 规格沿用第 5 轮 §4.5（通用卡 / 中栏 320px / 窄窗 280px）。
///
/// **归属铁律（不可逾越）**：树只做"已归属文档的分层摆放"，`relPath` 只进 UI，
/// **禁止**用于任何删除 / 同步 / 归属判定（归属 100% 由 `doc.folderId` 决定）。
/// 路径推导失败的文档落「其他」桶，**不丢弃、不错挂、不影响任何数据**。
///
/// 数据来源（全部经应用层服务，不碰数据库）：
/// [FolderSyncService.listFolders] / [KnowledgeService.listDocuments] /
/// [KnowledgeService.listChunks]（分块数）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';

/// 中栏树面板（纯展示 + 选择，不持有写操作）。
class KnowledgeTreePane extends StatelessWidget {
  const KnowledgeTreePane({
    super.key,
    required this.bases,
    required this.selectedBaseId,
    required this.folders,
    required this.documents,
    required this.chunkCounts,
    required this.loading,
    required this.busy,
    required this.selectedNodeId,
    required this.query,
    required this.userExpanded,
    required this.userCollapsed,
    required this.onSelectBase,
    required this.onCreateBase,
    required this.onRenameBase,
    required this.onDeleteBase,
    required this.onSelectNode,
    required this.onQueryChanged,
    required this.onToggleExpanded,
  });

  final List<KnowledgeBase> bases;
  final String? selectedBaseId;

  /// 当前库的关联文件夹登记行（`listFolders`）。
  final List<KnowledgeBaseFolder> folders;

  /// 当前库的文档（`listDocuments`）。
  final List<KnowledgeDocument> documents;

  /// 文档 id → 分块数。
  final Map<String, int> chunkCounts;

  final bool loading;
  final bool busy;
  final String? selectedNodeId;

  /// 搜索词（空 = 不过滤）。
  final String query;

  /// 用户**显式展开**过的节点 id（本会话内保持）。
  final Set<String> userExpanded;

  /// 用户**显式折叠**过的节点 id（本会话内保持；优先于默认展开）。
  final Set<String> userCollapsed;

  final ValueChanged<String> onSelectBase;
  final VoidCallback onCreateBase;

  /// 重命名当前选中的知识库（用户走查反馈 #15-A）。
  final ValueChanged<KnowledgeBase> onRenameBase;
  final ValueChanged<KnowledgeBase> onDeleteBase;

  /// 选中某个节点（文档叶 / 目录 / 桶；null = 取消选择）。
  final ValueChanged<String?> onSelectNode;
  final ValueChanged<String> onQueryChanged;

  /// 展开 / 折叠某个节点（内部按当前开合态决定写入哪个集合）。
  final void Function(String id, bool open) onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    if (loading && bases.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (bases.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppDims.space4),
          child: Text('还没有知识库。\n点右上角「新建知识库」开始。',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
        ),
      );
    }

    final base = bases.firstWhere(
      (b) => b.id == selectedBaseId,
      orElse: () => bases.first,
    );

    // 树：核心纯逻辑（第 7 轮 T01，57 条断言），UI 只负责摆。
    final root = KnowledgeTreeBuilder.build(
      base: base,
      folders: folders,
      docs: documents,
      chunkCounts: chunkCounts,
    );
    final filtered = KnowledgeTreeBuilder.filter(root, query);
    final tree = filtered.tree;
    // 走查修复（#63）：中栏文件夹**默认收起**。无搜索词时忽略默认展开集
    // （用户显式展开的仍生效）；有搜索词时沿用命中自动展开，方便直接看到结果。
    final autoExpanded = query.trim().isEmpty ? const <String>{} : filtered.autoExpanded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _baseSwitcher(context),
        const Divider(height: 1),
        _searchField(),
        const Divider(height: 1),
        Expanded(
          child: tree.children.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(AppDims.space4),
                    child: Text(
                      '这个库还没有内容。\n到右侧「关联文件夹」绑定本地文件夹，\n再「重新扫描」即可自动导入。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, height: 1.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: AppDims.space1),
                  children: [
                    for (final node in tree.children)
                      _nodeTile(node, 0, autoExpanded),
                  ],
                ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 知识库切换（chip 横排 + 新建 + 删除）
  // -------------------------------------------------------------------------

  Widget _baseSwitcher(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppDims.space2, AppDims.space2, AppDims.space1, AppDims.space2),
      child: Wrap(
        spacing: AppDims.space1,
        runSpacing: AppDims.space1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final b in bases)
            ChoiceChip(
              label: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: b.id == selectedBaseId,
              visualDensity: VisualDensity.compact,
              onSelected: busy ? null : (_) => onSelectBase(b.id),
            ),
          IconButton(
            tooltip: '新建知识库',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            iconSize: AppDims.iconNav,
            icon: const Icon(Icons.add_circle_outline,
                size: AppDims.iconNav, color: AppColors.textSecondary),
            onPressed: busy ? null : onCreateBase,
          ),
          if (selectedBaseId != null)
            Builder(builder: (context) {
              final base = bases.firstWhere(
                (b) => b.id == selectedBaseId,
                orElse: () => bases.first,
              );
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '重命名',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    iconSize: AppDims.iconNav,
                    icon: const Icon(Icons.drive_file_rename_outline,
                        size: AppDims.iconNav, color: AppColors.textSecondary),
                    onPressed: busy ? null : () => onRenameBase(base),
                  ),
                  IconButton(
                    tooltip: '删除知识库',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    iconSize: AppDims.iconNav,
                    icon: const Icon(Icons.delete_outline,
                        size: AppDims.iconNav, color: AppColors.textSecondary),
                    onPressed: busy ? null : () => onDeleteBase(base),
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppDims.space2, AppDims.space1, AppDims.space2, AppDims.space1),
      child: SizedBox(
        height: AppDims.searchFieldHeight,
        child: TextField(
          controller: TextEditingController(text: query),
          onChanged: onQueryChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: '搜索文档 / 文件夹名',
            hintStyle: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: AppDims.iconInline, color: AppColors.textTertiary),
            prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            filled: true,
            fillColor: AppColors.bgSecondary,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppDims.radiusM),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 树节点渲染（缩进 12px/级 + 引导线；空目录天然不出现——核心已保证）
  // -------------------------------------------------------------------------

  Widget _nodeTile(KbTreeNode node, int depth, Set<String> autoExpanded) {
    // 开合态：用户显式折叠优先；否则 = 用户显式展开 ∪ 默认展开（含搜索命中）。
    final isOpen = userCollapsed.contains(node.id)
        ? false
        : (userExpanded.contains(node.id) || autoExpanded.contains(node.id));
    final expandable = node.children.isNotEmpty;
    final selected = node.id == selectedNodeId;
    final indent = AppDims.space2 + depth * 12;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 引导线（深度 ≥1 时显示左侧 1px 竖线）
        if (depth > 0)
          Padding(
            padding: EdgeInsets.only(left: indent - 6),
            child: Container(width: 1, height: 4, color: AppColors.divider),
          ),
        InkWell(
          onTap: busy ? null : () => onSelectNode(node.id),
          child: Container(
            color: selected ? AppColors.sessionSelected : null,
            padding: EdgeInsets.only(left: indent, right: AppDims.space1),
            child: SizedBox(
              height: 34,
              child: Row(
                children: [
                  if (expandable)
                    SizedBox(
                      width: 22,
                      child: IconButton(
                        tooltip: isOpen ? '折叠' : '展开',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                        iconSize: AppDims.iconInline,
                        icon: Icon(
                          isOpen ? Icons.expand_less : Icons.expand_more,
                          size: AppDims.iconInline,
                          color: AppColors.textTertiary,
                        ),
                        onPressed: busy ? null : () => onToggleExpanded(node.id, !isOpen),
                      ),
                    )
                  else
                    const SizedBox(width: 4),
                  _leadingIcon(node),
                  const SizedBox(width: AppDims.space1),
                  Expanded(
                    child: Text(
                      node.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: node.kind == KbNodeKind.folder ? FontWeight.w600 : null,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  _trailing(node),
                ],
              ),
            ),
          ),
        ),
        if (expandable && isOpen)
          for (final child in node.children) _nodeTile(child, depth + 1, autoExpanded),
      ],
    );
  }

  Widget _leadingIcon(KbTreeNode node) {
    switch (node.kind) {
      case KbNodeKind.base:
        return const Icon(Icons.menu_book_outlined,
            size: AppDims.iconInline, color: AppColors.primary);
      case KbNodeKind.folder:
        return const Icon(Icons.folder_outlined,
            size: AppDims.iconInline, color: AppColors.primary);
      case KbNodeKind.subfolder:
        return const Icon(Icons.folder_open_outlined,
            size: AppDims.iconInline, color: AppColors.textSecondary);
      case KbNodeKind.orphanBucket:
        return const Icon(Icons.link_off,
            size: AppDims.iconInline, color: AppColors.warning);
      case KbNodeKind.document:
        final doc = node.doc;
        return Icon(
          doc == null ? Icons.insert_drive_file_outlined : _statusIcon(doc.status),
          size: AppDims.iconInline,
          color: doc == null ? AppColors.textTertiary : _statusColor(doc.status),
        );
    }
  }

  Widget _trailing(KbTreeNode node) {
    if (node.kind == KbNodeKind.document) {
      final chunks = node.doc == null ? null : (chunkCounts[node.doc!.id] ?? 0);
      final orphan = node.doc?.folderId == null;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (orphan)
            Container(
              margin: const EdgeInsets.only(right: AppDims.space1),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppDims.radiusS),
              ),
              child: const Text('未关联',
                  style: TextStyle(fontSize: 9, color: AppColors.warning)),
            ),
          Text(chunks == null ? '' : '$chunks 块',
              style: const TextStyle(fontSize: 10, color: AppColors.textTertiary)),
          const SizedBox(width: AppDims.space1),
        ],
      );
    }
    // 目录 / 桶：显示其下文档数（核心放在 subtitle）。
    if (node.subtitle == null) return const SizedBox.shrink();
    return Flexible(
      child: Text(node.subtitle!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: AppColors.textTertiary)),
    );
  }

  IconData _statusIcon(DocumentStatus s) {
    switch (s) {
      case DocumentStatus.indexed:
        return Icons.check_circle_outline;
      case DocumentStatus.parsing:
        return Icons.hourglass_top;
      case DocumentStatus.failed:
        return Icons.error_outline;
      case DocumentStatus.pending:
        return Icons.schedule;
    }
  }

  Color _statusColor(DocumentStatus s) {
    switch (s) {
      case DocumentStatus.indexed:
        return AppColors.success;
      case DocumentStatus.parsing:
        return AppColors.warning;
      case DocumentStatus.failed:
        return AppColors.error;
      case DocumentStatus.pending:
        return AppColors.textTertiary;
    }
  }
}

/// 收集某节点（含自身）下的全部文档（用于右栏按选中目录过滤）。
List<KnowledgeDocument> collectDocs(KbTreeNode node) {
  final out = <KnowledgeDocument>[];
  void walk(KbTreeNode n) {
    if (n.doc != null) out.add(n.doc!);
    for (final c in n.children) {
      walk(c);
    }
  }

  walk(node);
  return out;
}
