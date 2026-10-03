/// 知识库**右栏**：库设置（关联文件夹 · 三防线原样保留）+ 文档详情 + 检索测试。
///
/// 第 7 轮 T02（D 知识库层级）新增；原 `KnowledgePage._documentsPane()` 的
/// **逻辑全部平移**，只改布局与"按树节点过滤"。
///
/// 冻结项（第 4/5 轮既有交互，**一行逻辑都不改**）：
/// - [FolderSection]：关联 / 重新扫描（dry-run → 确认后执行）/ unlink 二选一 /
///   backfill 补绑 / 三防线（失联零删除 · 大比例删除确认 · 删除铁律）；
/// - [RetrievalTestPage]：检索测试；
/// - 删除文档 / 删除知识库：经应用层服务，交互与确认文案不变。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'folder_section.dart';
import 'knowledge_tree_pane.dart' show collectDocs;
import 'retrieval_test_page.dart';

/// 右栏详情面板。
class KnowledgeDetailPane extends StatelessWidget {
  const KnowledgeDetailPane({
    super.key,
    required this.base,
    required this.treeRoot,
    required this.documents,
    required this.chunkCounts,
    required this.folders,
    required this.selectedNodeId,
    required this.showRetrieval,
    required this.busy,
    required this.knowledge,
    required this.folderSync,
    required this.onFolderChanged,
    required this.onToggleRetrieval,
    required this.onDeleteDocument,
    required this.onClearSelection,
  });

  final KnowledgeBase base;

  /// 中栏同一棵树（核心纯逻辑产出；右栏只读它来做"按选中节点过滤"）。
  final KbTreeNode treeRoot;

  /// 当前库全部文档（未经树过滤）。
  final List<KnowledgeDocument> documents;

  final Map<String, int> chunkCounts;

  /// 当前库的关联文件夹登记行（用于未关联计数提示）。
  final List<KnowledgeBaseFolder> folders;

  /// 中栏选中的节点 id（null = 未选中 → 显示全部）。
  final String? selectedNodeId;

  final bool showRetrieval;
  final bool busy;

  final KnowledgeService knowledge;
  final FolderSyncService folderSync;

  /// FolderSection 变更后回调（只刷当前库文档，不整页重载）。
  final Future<void> Function() onFolderChanged;

  final ValueChanged<bool> onToggleRetrieval;
  final ValueChanged<KnowledgeDocument> onDeleteDocument;
  final VoidCallback onClearSelection;

  /// 选中节点对应的文档（null = 未选中/找不到 → 全部）。
  List<KnowledgeDocument> get _visibleDocs {
    if (selectedNodeId == null) return documents;
    final node = _find(treeRoot, selectedNodeId!);
    if (node == null) return documents;
    final docs = collectDocs(node);
    return docs.isEmpty ? const [] : docs;
  }

  KbTreeNode? _find(KbTreeNode node, String id) {
    if (node.id == id) return node;
    for (final c in node.children) {
      final hit = _find(c, id);
      if (hit != null) return hit;
    }
    return null;
  }

  String get _scopeLabel {
    if (selectedNodeId == null) return '全部';
    final node = _find(treeRoot, selectedNodeId!);
    if (node == null) return '全部';
    switch (node.kind) {
      case KbNodeKind.document:
        return node.label;
      case KbNodeKind.orphanBucket:
        return '未关联';
      default:
        return node.label;
    }
  }

  @override
  Widget build(BuildContext context) {
    final orphanCount = documents.where((d) => d.folderId == null).length;
    final visible = _visibleDocs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppDims.space4, AppDims.space3, AppDims.space4, AppDims.space3),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${base.name} · 文档（${documents.length}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    Text('当前范围：$_scopeLabel（${visible.length} 篇）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              if (selectedNodeId != null)
                TextButton(
                  onPressed: onClearSelection,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('看全部', style: TextStyle(fontSize: 12)),
                ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      label: Text('文档'),
                      icon: Icon(Icons.article_outlined, size: 14)),
                  ButtonSegment(
                      value: true,
                      label: Text('检索测试'),
                      icon: Icon(Icons.search, size: 14)),
                ],
                selected: {showRetrieval},
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: busy ? null : (s) => onToggleRetrieval(s.first),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 关联文件夹区（第 4 轮：link / 重扫两阶段 / unlink 二选一 / backfill；三防线在此）。
        if (!showRetrieval)
          FolderSection(
            key: ValueKey('folders_${base.id}'),
            folderSync: folderSync,
            knowledgeBaseId: base.id,
            onChanged: onFolderChanged,
          ),
        if (!showRetrieval && orphanCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppDims.space4, AppDims.space2, AppDims.space4, 0),
            child: Row(
              children: [
                const Icon(Icons.link_off, size: 14, color: AppColors.warning),
                const SizedBox(width: AppDims.space1),
                Expanded(
                  child: Text(
                    '有 $orphanCount 篇「未关联」文档（旧导入或已断开关联）：内容保留、'
                    '仍可检索，重扫不会删除；可在关联文件夹行菜单「补绑未关联文档」认领。',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 16),
        Expanded(
          child: showRetrieval
              ? RetrievalTestPage(knowledge: knowledge, base: base)
              : visible.isEmpty
                  ? Center(
                      child: Text(
                        documents.isEmpty
                            ? '这个范围还没有内容。\n点上方「关联文件夹」绑定本地文件夹，'
                                '再「重新扫描」即可自动导入。'
                            : '当前范围（$_scopeLabel）下没有文档。',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary, height: 1.6),
                      ),
                    )
                  : ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final doc = visible[i];
                        final chunks = chunkCounts[doc.id] ?? 0;
                        final orphan = doc.folderId == null;
                        return ListTile(
                          leading: Icon(_statusIcon(doc.status), color: _statusColor(doc.status)),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(doc.fileName,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              if (orphan) ...[
                                const SizedBox(width: AppDims.space1),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: AppColors.warning.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(AppDims.radiusS),
                                  ),
                                  child: const Text('未关联',
                                      style: TextStyle(fontSize: 10, color: AppColors.warning)),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            '状态：${doc.status.label} · 分块数：$chunks · ${_formatSize(doc.fileSize)}'
                            '${orphan ? ' · 来源：未关联（重扫不管理）' : ''}',
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          ),
                          trailing: IconButton(
                            tooltip: '删除文档',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: busy ? null : () => onDeleteDocument(doc),
                          ),
                        );
                      },
                    ),
        ),
      ],
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

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
