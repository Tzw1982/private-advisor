/// 头像路径解析（第 6 轮 T05 · 头像拟人化）。
///
/// **设计边界（架构 §1.4 / 待明确 #3）**：
/// - 头像按 **`<data>/avatars/<expertId>.png`** 约定推导路径——**不写 DB、不动 schema**；
/// - 解析优先级：`Expert.avatarPath`（市场包自带，存在则用）→ 约定路径 `<data>/avatars/<expertId>.png`
///   → 都没有则返回 `null`（由 [ExpertAvatar] 回退为首字/emoji）；
/// - app 运行时**无图像生成服务**，PNG 由**批处理**产出（见 `process`：工程师用 ImageGen 一次性生成，
///   落盘到 `<data>/avatars/`），app 侧只做「读取 + 回退」。
///
/// 本类为**全局配置式**（与 `AppColors` / `AppDims` 同风格）：`Bootstrap.run()` 启动时调用
/// [configure] 注入数据目录一次，之后各处只读。无 IO 副作用（除 `existsSync` 探测）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 头像解析器（静态配置 + 只读查询）。
abstract final class AvatarResolver {
  static Directory? _avatarsDir;

  /// 启动时注入数据目录（`<data>` 下的 `avatars/` 子目录）。
  ///
  /// 幂等：可重复调用；仅在目录缺失时创建（不抛异常、不影响启动）。
  static void configure(Directory dataDir) {
    final dir = Directory(p.join(dataDir.path, 'avatars'));
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (_) {
      // 建目录失败不阻断启动：后续 pathFor 探测不到文件，自然回退首字/emoji。
    }
    _avatarsDir = dir;
  }

  /// 头像目录路径（未配置时返回空串，供调试/文档展示）。
  static String get avatarsDirPath => _avatarsDir?.path ?? '';

  /// 解析某专家的可用头像文件绝对路径；无可用头像返回 `null`。
  ///
  /// - [explicitPath] 非空且文件存在 → 直接采用（市场包自带头像优先）；
  /// - 否则取 `<data>/avatars/<expertId>.png`（存在才返回）；
  /// - 其余返回 `null`（交给调用方回退）。
  static String? pathFor(String expertId, {String? explicitPath}) {
    if (explicitPath != null && explicitPath.trim().isNotEmpty) {
      final f = File(explicitPath);
      if (f.existsSync()) return f.path;
    }
    final dir = _avatarsDir;
    if (dir == null || expertId.isEmpty) return null;
    final f = File(p.join(dir.path, '$expertId.png'));
    return f.existsSync() ? f.path : null;
  }
}
