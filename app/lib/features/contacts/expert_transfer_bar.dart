/// 通讯录「导入专家 / 导出专家」入口 + 多选态列表 + 两条完整流程（规范 §10）。
///
/// 落点：通讯录中栏顶部工具栏（市场页签**不放**导入导出——职责单一）。
/// 本文件承载：
/// - [ExpertTransferBar]：工具栏右侧两个按钮；
/// - [ExpertExportSelectionView]：多选态列表（行尾复选框 + 底部「取消 / 导出（N）」）；
/// - [runExpertImport] / [runExpertExport]：文件选择 → 校验 → 决策 → 落库/落盘 →
///   结果提示的完整编排（纯 UI 编排 + 端口调用，业务规则在 `advisor_core`）。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'contact_name_row.dart';
import 'export_options_dialog.dart';
import 'import_conflict_dialog.dart';
import 'import_result_dialog.dart';

// ---------------------------------------------------------------------------
// 工具栏按钮
// ---------------------------------------------------------------------------

/// 工具栏右侧「导入专家 / 导出专家」按钮组。
class ExpertTransferBar extends StatelessWidget {
  const ExpertTransferBar({
    super.key,
    required this.onImport,
    required this.onExport,
    this.busy = false,
  });

  final VoidCallback onImport;
  final VoidCallback onExport;
  final bool busy;

  static ButtonStyle _style() => TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space2),
        minimumSize: const Size(0, 28),
        textStyle: const TextStyle(fontSize: 12),
      );

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          style: _style(),
          onPressed: busy ? null : onImport,
          icon: const Icon(Icons.file_download_outlined,
              size: AppDims.iconInline),
          label: const Text('导入专家'),
        ),
        const SizedBox(width: AppDims.space1),
        TextButton.icon(
          style: _style(),
          onPressed: busy ? null : onExport,
          icon: const Icon(Icons.file_upload_outlined, size: AppDims.iconInline),
          label: const Text('导出专家'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 多选态列表
// ---------------------------------------------------------------------------

/// 导出多选态：专家列表（行尾复选框）+ 底部「取消 / 全选 / 导出（N）」。
class ExpertExportSelectionView extends StatelessWidget {
  const ExpertExportSelectionView({
    super.key,
    required this.entries,
    required this.selectedIds,
    required this.onToggle,
    required this.onSelectAll,
    required this.onExport,
    required this.onCancel,
    this.busy = false,
  });

  final List<ContactEntry> entries;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onExport;
  final VoidCallback onCancel;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text('暂无可导出的专家',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textTertiary)),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    final checked = selectedIds.contains(e.expert.id);
                    return InkWell(
                      onTap: () => onToggle(e.expert.id),
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            const SizedBox(width: AppDims.space2),
                            Checkbox(
                              value: checked,
                              onChanged: (_) => onToggle(e.expert.id),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(e.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.textPrimary)),
                                  Text(e.expert.profession ?? '—',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textTertiary)),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppDims.space3),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppDims.space3, vertical: AppDims.space2),
          child: Row(
            children: [
              TextButton(
                onPressed: busy ? null : onCancel,
                child: const Text('取消'),
              ),
              const SizedBox(width: AppDims.space1),
              TextButton(
                onPressed: busy ? null : onSelectAll,
                child: Text(
                    selectedIds.length == entries.length && entries.isNotEmpty
                        ? '全不选'
                        : '全选'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: (busy || selectedIds.isEmpty) ? null : onExport,
                child: Text('导出（${selectedIds.length}）'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 导入流程
// ---------------------------------------------------------------------------

/// 完整导入流程；返回是否至少成功导入 1 位（供调用方刷新通讯录）。
Future<bool> runExpertImport(
  BuildContext context, {
  required ExpertImportService importService,
  required Repositories repos,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  // 1) 选文件（.expert / .zip）。
  FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择要导入的专家包（.expert / .zip）',
      type: FileType.custom,
      allowedExtensions: const ['expert', 'zip'],
      withData: true,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('打开文件选择器失败：$e')));
    return false;
  }
  if (picked == null || picked.files.isEmpty) return false;

  final file = picked.files.first;
  List<int>? bytes = file.bytes;
  if (bytes == null && (file.path ?? '').isNotEmpty) {
    // 兜底：只给了路径（网络位置 / 大文件未内联）时直接读盘。
    try {
      bytes = await File(file.path!).readAsBytes();
    } catch (_) {
      bytes = null;
    }
  }
  if (bytes == null) {
    messenger.showSnackBar(const SnackBar(content: Text('无法读取所选文件')));
    return false;
  }

  // 2) 校验 + 冲突预检（不落库）。
  ExpertImportPlan plan;
  try {
    plan = await importService.plan(bytes);
  } on AppError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导入失败：${e.message}')));
    return false;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    return false;
  }
  if (plan.total == 0) {
    messenger.showSnackBar(const SnackBar(content: Text('文件中没有可导入的专家')));
    return false;
  }

  // 3) 冲突决策（无冲突则自动跳过，不打扰）。
  var decisions = <String, ConflictStrategy>{};
  if (plan.hasConflicts) {
    if (!context.mounted) return false;
    final chosen =
        await showImportConflictDialog(context, conflicts: plan.conflicts);
    if (chosen == null) return false; // 用户取消
    decisions = chosen;
  }

  // 4) 执行（带进度对话框）。
  ExpertImportReport? report;
  try {
    report = await _runWithProgress<ExpertImportReport>(
      context,
      label: '正在导入…',
      task: (onProgress) => importService.apply(
        plan,
        decisions: decisions,
        onProgress: onProgress,
      ),
    );
  } on AppError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导入失败：${e.message}')));
    return false;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    return false;
  }
  if (report == null) return false;

  // 5) 结果报告。
  if (context.mounted) {
    await showImportResultDialog(context, report: report);
  }
  return report.success > 0;
}

// ---------------------------------------------------------------------------
// 导出流程
// ---------------------------------------------------------------------------

/// 完整导出流程；返回是否成功导出（供调用方退出多选态）。
Future<bool> runExpertExport(
  BuildContext context, {
  required ExpertExportService exportService,
  required List<String> expertIds,
}) async {
  if (expertIds.isEmpty) return false;
  final messenger = ScaffoldMessenger.of(context);

  // 1) 选项。
  final options =
      await showExportOptionsDialog(context, count: expertIds.length);
  if (options == null) return false;

  // 2) 打包（带进度对话框）。
  ExportResult? result;
  try {
    result = await _runWithProgress<ExportResult>(
      context,
      label: '正在导出…',
      task: (onProgress) => exportService.build(
        expertIds: expertIds,
        includeLocal: options.includeLocal,
        includeAvatar: options.includeAvatar,
        onProgress: onProgress,
      ),
    );
  } on AppError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导出失败：${e.message}')));
    return false;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    return false;
  }
  if (result == null) return false;

  // 3) 选保存位置。
  String? savePath;
  try {
    savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存专家包',
      fileName: result.fileName,
      type: FileType.custom,
      allowedExtensions: [result.isBundle ? 'zip' : 'expert'],
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    return false;
  }
  if (savePath == null || savePath.isEmpty) return false; // 用户取消

  // 4) 写盘。
  try {
    await File(savePath).writeAsBytes(result.bytes, flush: true);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('写入文件失败：$e')));
    return false;
  }

  messenger.showSnackBar(
      SnackBar(content: Text('已导出 ${result.count} 位专家：${result.fileName}')));
  return true;
}

// ---------------------------------------------------------------------------
// 进度对话框
// ---------------------------------------------------------------------------

/// 展示不可取消的进度对话框并执行 [task]，完成后自动关闭并返回结果。
Future<T?> _runWithProgress<T>(
  BuildContext context, {
  required String label,
  required Future<T> Function(void Function(int done, int total) onProgress)
      task,
}) async {
  final progress = ValueNotifier<String>(label);
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppDims.space4),
          ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, v, __) =>
                Text(v, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    ),
  );
  try {
    final result = await task((done, total) {
      progress.value = total <= 1 ? label : '$label（$done/$total）';
    });
    if (navigator.canPop()) navigator.pop();
    return result;
  } catch (e) {
    if (navigator.canPop()) navigator.pop();
    rethrow;
  }
}
