/// 头像确定性色板索引（第 7 轮 T01 · E｜市场拟人化）。
///
/// **纯 Dart、零 Flutter、零 IO**：把稳定种子（`packageId` / `expertId`）映射到
/// 固定色板下标 `0 .. size-1`，保证**同一专家恒同色**（"拟人化"的可辨识性）。
///
/// 为什么下沉 `advisor_core`：本项目铁律「写代码必须能在 `dart run` 下验证」，
/// 而本模块最危险处恰是**纯逻辑**（哈希稳定性 + 边界），放 `app/lib` 等于没有测试网。
/// `app/lib/ui/theme/avatar_palette.dart` 只做 `index → Color` 映射（`Color` 是
/// Flutter 类型，不能进 core）。
///
/// **哈希口径（写死）**：FNV-1a 32 位，输入 = 种子的 **UTF-8 code units**。
/// **严禁** `Object.hashCode` / `String.hashCode`（Dart 实现自由、跨版本可能变 →
/// 用户换了版本同一专家就变色）。
library;

import 'dart:convert';

/// 头像色板索引。
abstract final class AvatarPaletteIndex {
  /// 色板大小（8 色）。
  static const int size = 8;

  /// FNV-1a 32 位哈希（输入按 UTF-8 编码逐字节处理）。
  ///
  /// - 空串不抛异常（返回 offset basis `0x811C9DC5`）；
  /// - 纯中文 / emoji / 超长串均可计算；
  /// - **大小写敏感**：按原始字节，不做任何折叠（`hash('A') != hash('a')`）。
  static int hash(String seed) {
    var h = 0x811C9DC5; // FNV-1a 32-bit offset basis
    const int prime = 0x01000193; // FNV-1a 32-bit prime
    for (final b in utf8.encode(seed)) {
      h ^= b;
      h = (h * prime) & 0xFFFFFFFF; // 保持 32 位（Dart VM 上 64 位乘法精确）
    }
    return h;
  }

  /// 稳定色板下标 = `hash(seed) % size`。
  ///
  /// 碰撞说明（数学事实，非缺陷）：`% 8` 只看哈希低 3 位，而 ASCII 大小写位
  /// （`0x20`）在 FNV-1a 下每次乘法都以 `0x20 * prime^k`（必含因子 8）传递，
  /// **不改变低 3 位** → 故 `of('A') == of('a')` 恒成立。
  /// 「大小写敏感」的要求由 [hash] 层满足（`hash('A') != hash('a')`）；
  /// 8 桶下不同种子碰撞到同一色属**正常且不可避免**。
  static int of(String seed) => hash(seed) % size;
}
