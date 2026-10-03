/// 拟人化头像（第 6 轮 T05；第 7 轮 T01 增 `seed` / `skipImage`）。
///
/// 显示专家头像图片（`<data>/avatars/<expertId>.png` 或市场包自带），
/// **缺图/加载失败一律优雅回退**为首字（或指定图标）圆形/圆角头像——
/// 禁止因缺图崩溃或留白（架构 §6.5 硬约束）。
///
/// 形状：
/// - 默认**圆形**（`borderRadius == null`，与通讯录/群成员既有的 `CircleAvatar` 一致）；
/// - 传 [borderRadius] 则用**圆角矩形**（会话列表 36×36 圆角 12 的 B1 规格保持）。
///
/// 数据档（第 7 轮 / 第 #66 轮）：
/// - 通讯录 / 会话 / 群成员：**本地图片优先** → 缺图看 **emoji** → 都无才回退首字；
/// - 市场列表 / 市场详情：传 [skipImage] `true`（**永不加载图片**）+ [seed]（`packageId`）
///   → 回退**确定性底色 + 首字**（同一专家恒同色；283 包视觉统一且可辨识）。
///
/// 第 #66 轮补上 emoji 档：市场包自带 emoji/color 此前只留在市场页，
/// `Expert` 没有对应字段 → 专家「添加到通讯录」后头像回退成首字。
/// 现在安装时 emoji/color 一并落库（`Expert.avatarEmoji/avatarColor`），
/// 本组件按 **图片 > emoji > 首字** 三档渲染，与市场卡片视觉一致。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../infrastructure/avatar/avatar_resolver.dart';
import '../theme/app_colors.dart';
import '../theme/avatar_palette.dart';

/// 拟人化头像（图片优先，回退首字/图标）。
class ExpertAvatar extends StatelessWidget {
  const ExpertAvatar({
    super.key,
    required this.expertId,
    required this.name,
    this.explicitPath,
    this.avatarEmoji,
    this.avatarColor,
    this.radius = 16,
    this.borderRadius,
    this.backgroundColor = const Color(0xFFE8F6EE),
    this.foregroundColor = const Color(0xFF07C160),
    this.fallbackIcon,
    this.fontSize,
    this.seed,
    this.skipImage = false,
  });

  /// 专家本地实例 id（决定约定头像路径 `<data>/avatars/<expertId>.png`）。
  final String expertId;

  /// 展示名（回退时取首字）。
  final String name;

  /// 市场包自带头像路径（`Expert.avatarPath`），优先级最高；可为 null。
  final String? explicitPath;

  /// 专家 emoji 头像（`Expert.avatarEmoji`，市场包自带）；空 / null → 走首字回退。
  ///
  /// 优先级**低于**本地图片、高于首字；[skipImage] 不影响本档（emoji 不读盘）。
  final String? avatarEmoji;

  /// emoji 底色（`Expert.avatarColor`，市场包 `color`：`#RRGGBB` 或色名）。
  ///
  /// null / 无法解析 → 回退 `AvatarPalette.colorFor(seed ?? expertId)`。
  final String? avatarColor;

  /// 半径（直径 = 2 × radius）。
  final double radius;

  /// 圆角；null → 圆形（用 `ClipOval`）。
  final BorderRadius? borderRadius;

  final Color backgroundColor;
  final Color foregroundColor;

  /// 回退图标（如群头像用 `Icons.groups_outlined`）；null → 显示首字。
  final IconData? fallbackIcon;

  /// 回退文字字号；null → 按半径自动推导。
  final double? fontSize;

  /// 无图回退时的**确定性底色种子**（市场传 `packageId`）。
  ///
  /// 非空 → 回退底色 = [AvatarPalette.colorFor]（同一 seed 恒同色），字色 = 白；
  /// null → 用 [backgroundColor] / [foregroundColor]（保持既有调用零变化）。
  final String? seed;

  /// 是否**跳过图片**（市场列表传 `true`，永不读盘加载图片）。
  final bool skipImage;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    // ① 本地图片（市场列表 skipImage=true → 永不读盘，直接落到 ②/③）。
    final path = skipImage
        ? null
        : AvatarResolver.pathFor(expertId, explicitPath: explicitPath);
    if (path != null) {
      final image = Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 文件损坏 / 读取失败 → 同样回退（不崩溃、不留白）。
        errorBuilder: (_, __, ___) => _nonImage(size),
      );
      return borderRadius == null
          ? ClipOval(child: image)
          : ClipRRect(borderRadius: borderRadius!, child: image);
    }
    return _nonImage(size);
  }

  /// 无可用图片时的回退：**emoji → 首字 / 图标**。
  Widget _nonImage(double size) {
    final emoji = (avatarEmoji ?? '').trim();
    return emoji.isNotEmpty ? _emoji(size, emoji) : _textFallback(size);
  }

  /// emoji 头像：底色 = 包 `color`（解析失败则用 [seed] 的确定性色）。
  Widget _emoji(double size, String emoji) {
    final bg = parseHexColor(avatarColor) ??
        AvatarPalette.colorFor(seed ?? (expertId.isEmpty ? name : expertId));
    return Container(
      width: size,
      height: size,
      // 圆形时 borderRadius 必为 null（二者互斥，遵守 BoxDecoration 断言）。
      decoration: BoxDecoration(
        color: bg,
        shape: borderRadius == null ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      // 字号与市场卡片 [marketPackageAvatar] 同口径（`radius`），两处视觉一致。
      child: Text(emoji, style: TextStyle(fontSize: radius)),
    );
  }

  Widget _textFallback(double size) {
    final s = seed;
    final bg = s == null ? backgroundColor : AvatarPalette.colorFor(s);
    final fg =
        s == null ? foregroundColor : AppColors.bgPrimary; // 白字（8 色对比度 ≥4.5:1）
    return Container(
      width: size,
      height: size,
      // 圆形时 borderRadius 必为 null（二者互斥，遵守 BoxDecoration 断言）。
      decoration: BoxDecoration(
        color: bg,
        shape: borderRadius == null ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: fallbackIcon != null
          ? Icon(fallbackIcon, size: size * 0.55, color: fg)
          : Text(
              name.isEmpty ? '?' : name.characters.first,
              style: TextStyle(
                fontSize: fontSize ?? size * 0.42,
                color: fg,
              ),
            ),
    );
  }
}
