/// 知识库详情页「关联文件夹」区组件（第 4 轮 · 架构设计 §1.6 / docs 04 §11）。
///
/// 交互规则（架构设计写死，不得自行发挥；任务 #28 走查反馈后更新）：
/// - 关联成功后**自动触发首次重扫**（后台静默，无需用户再手动点）；
/// - 重扫**后台静默执行**：不弹进度窗，仅在关联文件夹行内显示轻量进度
///   （「扫描中… x/y」小字 + spinner），**不阻塞**用户其它操作（切页签、
///   看专家、聊天都可用）；完成/失败 → SnackBar 通知（含新增/更新/删除/
///   跳过/失败五项计数），失败给原因；
/// - 重扫仍为**两阶段**：`planRescan`（dry-run，只出计划不执行）→ 失联/大比例
///   删除走三防线交互 → 用户确认后携 `confirmDeletes: true` 执行；
/// - **防线 1（失联）**：文件夹不存在 → 显著红色提示「找不到文件夹」，**零删除**；
/// - **防线 2（大比例删除）**：弹窗展示**逐项删除清单**（deleted ≥50% 或 ≥20 时
///   由核心层判定 `needsConfirmation`），用户确认才执行——**删除确认绝不静默**；
/// - **unlink 二选一**：默认「仅解除关联（保留内容，folder_id 清空）」；第二选项
///   「解除并删除」显示**精确计数** + 不可恢复警告；
/// - 孤儿文档（folder_id IS NULL）任何同步路径都不碰；UI 上标「未关联」，
///   引导「补绑」认领（`backfillFolder`，只增不删）。
///
/// 本组件只调用 [FolderSyncService]（应用层），不直接触碰仓储。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';

/// 单个关联文件夹的后台扫描进度（行内轻量状态；存在于 map 中即表示扫描中）。
class _ScanState {
  const _ScanState({required this.processed, required this.total});

  /// 已处理条目数（含新增/更新/删除/跳过/失败全部去向）。
  final int processed;

  /// 预计需处理总数（added + updated + deleted + failedFiles）。
  final int total;
}

/// 「关联文件夹」卡片。
class FolderSection extends StatefulWidget {
  const FolderSection({
    super.key,
    required this.folderSync,
    required this.knowledgeBaseId,
    this.onChanged,
  });

  /// 文件夹同步服务（Bootstrap 注入）。
  final FolderSyncService folderSync;

  /// 所属知识库。
  final String knowledgeBaseId;

  /// 关联/断开/重扫完成后通知父级刷新（文档列表、统计等）。
  final Future<void> Function()? onChanged;

  @override
  State<FolderSection> createState() => _FolderSectionState();
}

class _FolderSectionState extends State<FolderSection> {
  List<KnowledgeBaseFolder> _folders = const [];
  bool _loading = true;
  bool _busy = false;

  /// 后台扫描状态（folder.id → 进度；在 map 中即「扫描中」）。
  /// 扫描不占用 [_busy]——不阻塞关联/断开/补绑等其它操作。
  final Map<String, _ScanState> _scans = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      _folders = await widget.folderSync.listFolders(widget.knowledgeBaseId);
    } on AppError catch (e) {
      _snack('加载关联文件夹失败：${e.message}');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 统一包裹带忙标志的异步操作，异常转为 SnackBar（AppError 取可读信息）。
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

  /// 关联文件夹：选择目录 → linkFolder（比较键去重、防线 1 存在性检查）
  /// → 成功后自动触发首次重扫（后台静默）。
  Future<void> _link() async {
    final dir =
        await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要关联的文件夹');
    if (dir == null) return;
    await _guard(() async {
      await widget.folderSync.linkFolder(widget.knowledgeBaseId, dir);
      await _reload();
      await widget.onChanged?.call();
      _snack('已关联：$dir，正在后台扫描导入…');
      // 自动首次重扫：按比较键找到刚关联的记录，后台执行（不等待、不占 _busy）。
      final key = folderKey(dir).toLowerCase();
      KnowledgeBaseFolder? created;
      for (final f in _folders) {
        if (f.folderPath.toLowerCase() == key) {
          created = f;
          break;
        }
      }
      if (created != null) {
        _startBackgroundScan(created);
      } else {
        _snack('已关联：$dir（未找到扫描记录，请点该行「重新扫描」手动导入）');
      }
    });
  }

  /// 重扫（后台静默入口）：plan dry-run → 防线交互（保持阻塞式）→
  /// 后台执行进度流（行内轻量状态，完成/失败 SnackBar 通知）。
  Future<void> _startBackgroundScan(KnowledgeBaseFolder folder) async {
    if (_scans.containsKey(folder.id)) {
      _snack('该文件夹正在扫描中，请稍候');
      return;
    }
    try {
      // 阶段一：dry-run 出计划（不执行）。
      final plan = await widget.folderSync.planRescan(folder.id);

      // 防线 1：失联 → 显著红色提示，零删除（保持阻塞式弹窗）。
      if (plan.isAborted) {
        await _showFolderMissingDialog(folder);
        return;
      }

      // 防线 2：大比例删除 → 展示逐项删除清单，确认才执行
      // （保持阻塞式弹窗——删除确认绝不静默）。
      var confirmDeletes = false;
      if (plan.needsConfirmation) {
        confirmDeletes = await _showDeletePlanDialog(plan);
        if (!confirmDeletes) {
          _snack('已取消：本次重扫未执行任何删除');
          return;
        }
      }

      // 阶段二：后台静默执行（不弹窗；仅行内显示进度）。
      final total = plan.added.length +
          plan.updated.length +
          plan.deleted.length +
          plan.failedFiles.length;
      var processed = 0;
      var added = 0;
      var updated = 0;
      var deleted = 0;
      var skipped = 0;
      var failed = 0;
      if (!mounted) return;
      setState(() {
        _scans[folder.id] = _ScanState(processed: 0, total: total);
      });
      try {
        await for (final p in widget.folderSync
            .executeRescan(plan, confirmDeletes: confirmDeletes)) {
          if (!mounted) return;
          processed = p.processed;
          added = p.added;
          updated = p.updated;
          deleted = p.deleted;
          skipped = p.skipped;
          failed = p.failed;
          setState(() {
            _scans[folder.id] = _ScanState(processed: processed, total: total);
          });
        }
        // 流正常结束 → 清理行内状态并通知父级刷新。
        if (mounted) {
          setState(() => _scans.remove(folder.id));
        }
        await _reload();
        await widget.onChanged?.call();
        _snack(
          '「${folder.displayPath}」扫描完成：'
          '新增 $added ｜ 更新 $updated ｜ 删除 $deleted ｜ '
          '跳过 $skipped ｜ 失败 $failed',
        );
      } on AppError catch (e) {
        if (mounted) setState(() => _scans.remove(folder.id));
        _snack('扫描失败：${e.message}');
      } catch (e) {
        if (mounted) setState(() => _scans.remove(folder.id));
        _snack('扫描失败：$e');
      }
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('操作失败：$e');
    }
  }

  /// 断开关联（二选一弹窗；默认「仅解除关联」）。
  Future<void> _unlink(KnowledgeBaseFolder folder) async {
    final choice = await _showUnlinkDialog(folder);
    if (choice == null) return;
    await _guard(() async {
      final r = await widget.folderSync.unlinkFolder(
        folder.id,
        keepDocuments: choice,
      );
      await _reload();
      await widget.onChanged?.call();
      _snack(choice
          ? '已解除关联（保留 ${r.affectedDocuments} 篇文档为「未关联」，仍可检索）'
          : '已解除关联并删除 ${r.affectedDocuments} 篇文档及其全部分块');
    });
  }

  /// 补绑旧文档（backfill：前缀 + 文件在位双条件，只增不删）。
  Future<void> _backfill(KnowledgeBaseFolder folder) async {
    await _guard(() async {
      final r = await widget.folderSync.backfillFolder(folder.id);
      await _reload();
      await widget.onChanged?.call();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('补绑结果'),
          content: Text(
            '匹配回填 ${r.matched} 篇。\n\n'
            '${r.unmatched == 0 ? '' : '未匹配 ${r.unmatched} 篇（文件已移走或不在该文件夹内），'
                '保持「未关联」：内容保留、仍可检索，任何重扫都不会删除它们。'}',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('知道了')),
          ],
        ),
      );
    });
  }

  // -------------------------------------------------------------------------
  // 弹窗
  // -------------------------------------------------------------------------

  /// 防线 1：失联提示（红色显著；明确「零删除」）。
  Future<void> _showFolderMissingDialog(KnowledgeBaseFolder folder) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.folder_off_outlined,
            color: Colors.red.shade600, size: 36),
        title: const Text('找不到关联文件夹'),
        content: Text(
          '「${folder.displayPath}」不存在或无法访问。\n\n'
          '可能原因：文件夹被移动 / 重命名 / 拔出（网络盘断开）。\n\n'
          '本次重扫已中止，**没有删除任何内容**。请恢复路径后重试，或先断开该关联。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 防线 2：删除计划确认（逐项清单 + 占比；返回 true = 用户确认删除）。
  Future<bool> _showDeletePlanDialog(RescanPlan plan) async {
    final percent = (plan.deleteRatio * 100).toStringAsFixed(0);
    final items =
        plan.deleted.take(8).map((c) => '  · ${c.fileName}').join('\n');
    final more =
        plan.deleted.length > 8 ? '\n  · …等共 ${plan.deleted.length} 篇' : '';
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: Colors.orange.shade700, size: 36),
        title: Text('确认删除 ${plan.deleted.length} 篇文档？'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '重扫发现 ${plan.deleted.length} 篇文档的源文件已不在文件夹内'
                '（占该文件夹文档数的 $percent%）：',
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7E6),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text(
                  '$items$more',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '删除将连带其全部分块与索引，不可恢复。\n'
                '若这是文件夹被整体移动导致的，请取消并先恢复路径。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确认删除 ${plan.deleted.length} 篇'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  /// unlink 二选一弹窗（默认「仅解除关联」；第二选项带精确计数 + 不可恢复警告）。
  /// 返回 null = 取消；true = 仅解除关联；false = 解除并删除。
  Future<bool?> _showUnlinkDialog(KnowledgeBaseFolder folder) async {
    // 精确计数（弹窗前取 folder_id 登记事实，与核心层同一判定来源）。
    var count = 0;
    try {
      count = (await widget.folderSync.listDocumentsByFolder(folder.id)).length;
    } on AppError {
      count = 0;
    }
    if (!mounted) return null;

    bool keep = true; // 默认「仅解除关联」（主理人裁定）。
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('断开关联文件夹'),
          content: SizedBox(
            width: 420,
            // RadioGroup 祖先统一管理 groupValue/onChanged（Flutter 3.32+ 新
            // API，SDK radio_group.dart L59）；子级 RadioListTile 只留 value。
            // keep 仍由 StatefulBuilder 持有（受控语义不变）。
            child: RadioGroup<bool>(
              groupValue: keep,
              onChanged: (v) => setDialogState(() => keep = v ?? true),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<bool>(
                    value: true,
                    title: const Text('仅解除关联（推荐）'),
                    subtitle: Text(
                      '保留 $count 篇文档及其分块，仍可检索；变为「未关联」，'
                      '不再被重扫管理，可随时通过「补绑」重新认领。',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  RadioListTile<bool>(
                    value: false,
                    title: Text('解除并删除已索引内容（$count 篇）'),
                    subtitle: const Text(
                      '删除该文件夹名下的全部文档及其分块、索引，不可恢复。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  if (!keep)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        '⚠ 将删除 $count 篇文档及其全部分块与索引，此操作不可恢复。',
                        style:
                            TextStyle(fontSize: 12, color: Colors.red.shade700),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: keep ? null : Colors.red.shade600,
              ),
              onPressed: () => Navigator.of(ctx).pop(keep),
              child: Text(keep ? '仅解除关联' : '解除并删除 $count 篇'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------
  // （任务 #28：重扫进度弹窗与完成摘要弹窗已移除——后台静默扫描，
  //   行内轻量进度 + SnackBar 通知；三防线弹窗保留阻塞式。）

  String _formatTime(int? ms) {
    if (ms == null) return '从未扫描';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final two = (int v) => v.toString().padLeft(2, '0');
    return '最近扫描 ${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFE0E0E0)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_copy_outlined, size: 18),
                const SizedBox(width: 6),
                Text(
                  '关联文件夹（${_folders.length}）',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '关联后自动后台扫描；此后用「重新扫描」增量同步：原文件永不复制、移动、修改。',
                    style: TextStyle(fontSize: 11, color: Colors.black45),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _link,
                  icon: const Icon(Icons.add_link, size: 16),
                  label: const Text('关联文件夹', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_folders.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text(
                  '尚未关联文件夹。关联后将自动后台扫描导入本知识库'
                  '（支持 txt / md / csv / docx / xlsx / pptx / pdf；'
                  '老 doc / xls / ppt 需本机 Office）。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              )
            else
              for (final f in _folders) _buildFolderRow(f),
          ],
        ),
      ),
    );
  }

  /// 单个关联文件夹行（含后台扫描行内轻量进度状态）。
  Widget _buildFolderRow(KnowledgeBaseFolder f) {
    final st = _scans[f.id];
    final scanning = st != null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text(
        f.displayPath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: scanning
          ? Text(
              '扫描中… ${st.processed}/${st.total}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF07C160)),
            )
          : f.lastScanAt == null
              // 走查修复：重扫在页面层执行，**切页签会静默中断**（`if (!mounted) return`），
              // 而 `last_scan_at` 只在全部成功后写入 → 它就是「上次没跑完」的持久标记。
              // 这里显式提示，避免用户以为已经扫全（实测：35 篇只进 11 篇）。
              ? const Text(
                  '⚠️ 上次扫描未完成（可能中途切换了页面）。已导入的文档仍在，'
                  '点右侧「重新扫描」即可增量续扫，不会重复也不会误删。',
                  style: TextStyle(fontSize: 11, color: AppColors.warning),
                )
              : Text(
                  '${_formatTime(f.lastScanAt)}${f.recursive ? ' · 含子文件夹' : ''}',
                  style: const TextStyle(fontSize: 11),
                ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scanning) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
          ],
          TextButton.icon(
            onPressed: scanning ? null : () => _startBackgroundScan(f),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新扫描', style: TextStyle(fontSize: 12)),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            enabled: !_busy && !scanning,
            onSelected: (v) {
              if (v == 'backfill') _backfill(f);
              if (v == 'unlink') _unlink(f);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'backfill',
                child: Text('补绑未关联文档…'),
              ),
              PopupMenuItem(
                value: 'unlink',
                child: Text('断开关联…'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
