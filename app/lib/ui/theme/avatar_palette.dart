/// 头像确定性色板（第 7 轮 T01 · E｜市场拟人化）。
///
/// `Color` 是 Flutter 类型，不能进 `advisor_core`；**哈希/取色下标**（纯逻辑）
/// 已在 core 的 [AvatarPaletteIndex]（`dart run` 可测）。本文件只做 **`index → Color`** 映射。
///
/// ## 色板与对比度（WCAG，14px 可读判据）
///
/// 8 色均**对齐规格中性/主色系**、克制不刺眼；每色配**白色文字**（`AppColors.bgPrimary`）。
/// 与白色对比度（AA 正文需 ≥4.5:1）：
///
/// | # | 色值 | 语义 | vs 白 | 结论 |
/// |---|------|------|-------|------|
/// | 0 | `#2E3A8C` | 靛蓝（对齐主色） | 10.00:1 | ✅ 白字可读 |
/// | 1 | `#00695C` | 深青 | 6.61:1 | ✅ |
/// | 2 | `#37474F` | 蓝灰 | 9.65:1 | ✅ |
/// | 3 | `#5E35B1` | 深紫 | 8.02:1 | ✅ |
/// | 4 | `#AD1457` | 洋红 | 6.97:1 | ✅ |
/// | 5 | `#6D4C41` | 棕 | 7.61:1 | ✅ |
/// | 6 | `#1565C0` | 蓝 | 5.75:1 | ✅ |
/// | 7 | `#2E7D32` | 绿 | 5.13:1 | ✅ |
///
/// **深色文字（`#111827`）对比度仅 1.77–3.46:1（不可读）→ 一律用白字。**
///
/// > 规格表**未定义**头像底色（原 app 微信绿 `#E8F6EE`/`#07C160` 弃用）——本色板为
/// > **新视觉决策**，列入走查确认项。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

/// 头像确定性色板（8 色）。
abstract final class AvatarPalette {
  /// 色板（下标与 [AvatarPaletteIndex.of] 的 `0..7` 对齐）。
  static const List<Color> colors = <Color>[
    Color(0xFF2E3A8C), // 0 靛蓝（对齐主色系）
    Color(0xFF00695C), // 1 深青
    Color(0xFF37474F), // 2 蓝灰
    Color(0xFF5E35B1), // 3 深紫
    Color(0xFFAD1457), // 4 洋红
    Color(0xFF6D4C41), // 5 棕
    Color(0xFF1565C0), // 6 蓝
    Color(0xFF2E7D32), // 7 绿
  ];

  /// 由稳定种子取色：同一 `packageId` / `expertId` **恒同色**。
  static Color colorFor(String seed) =>
      colors[AvatarPaletteIndex.of(seed) % colors.length];
}

/// 解析专家/市场包自带 `color`（`#RRGGBB`）。
///
/// **必须容错**：null / 缺 `#` 可接受（市场索引里既有 `#059669` 也有 `purple`
/// 这类色名），但长度非 6、非十六进制等非预期输入一律返回 `null`（调用方回退
/// [AvatarPalette.colorFor]）——**绝不抛异常**。
///
/// 原定义在 `features/market/market_card.dart`，第 #66 轮上移到主题层：
/// `ExpertAvatar`（通讯录 / 会话）也要用它渲染 emoji 底色，避免 UI 组件反向
/// 依赖 feature 层。
Color? parseHexColor(String? s) {
  if (s == null) return null;
  var v = s.trim();
  if (v.startsWith('#')) v = v.substring(1);
  if (v.length != 6) return null;
  final n = int.tryParse(v, radix: 16);
  if (n == null) return null;
  return Color(0xFF000000 | n);
}
