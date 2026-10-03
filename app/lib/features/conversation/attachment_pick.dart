/// 附件选择（阶段①入口，第 8 轮 T04）。
///
/// **不预复制**（共享约定 11）：本函数只做 `FilePicker` + `AttachmentPolicy` **纯校验**，
/// 拿到的是 pending 描述；真正的 save + insert 在**发送阶段**由 [AttachmentService.send] 完成。
/// 因此"选了又取消"不会在磁盘上留下任何孤儿文件。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:file_picker/file_picker.dart';

/// 打开文件选择器并返回 pending 列表。
///
/// - 用户取消 → 返回空列表；
/// - 校验失败（超限 / 类型不符）→ 仍返回该条 pending，`status = rejected` 且带明确原因，
///   由 UI 在 pending 条上展示（**不静默**）；
/// - 文件无本地路径（网络位置 / 压缩包内选中）→ 同样以 `rejected` 形式返回，原因明确。
Future<List<PendingAttachment>> pickAttachments() async {
  FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      withReadStream: false,
      // 不过滤扩展名：白名单统一交给 AttachmentPolicy（错误信息可读、口径唯一）。
    );
  } catch (e) {
    throw ValidationError('attach.pick', '打开文件选择器失败：$e', e);
  }
  if (result == null) return const [];

  final out = <PendingAttachment>[];
  for (final f in result.files) {
    final path = f.path;
    if (path == null || path.isEmpty) {
      out.add(PendingAttachment(
        id: Ids.next('att'),
        sourcePath: f.name,
        fileName: AttachmentPolicy.sanitizeFileName(f.name),
        sizeBytes: f.size,
        kind: AttachmentPolicy.kindOf(f.name),
        status: PendingAttachmentStatus.rejected,
        error: '无法读取该文件（无本地路径，可能位于网络位置或压缩包内）',
      ));
      continue;
    }
    out.add(AttachmentService.draft(
      sourcePath: path,
      fileName: f.name,
      sizeBytes: f.size,
    ));
  }
  return out;
}
