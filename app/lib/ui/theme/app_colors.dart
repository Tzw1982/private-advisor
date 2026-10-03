/// 全局颜色常量（第 5 轮 UI 改版 · 规格表 §一 逐项）。
///
/// **全 app 唯一颜色事实来源**：任何页面不得新写裸 `Color(0x...)`；
/// 走查硬项「页面无裸色值」以本文件为对照基准。
///
/// 依据：`私人顾问团 · 三栏式 UI 组件规格表.txt` §1.1 / §1.2，
/// 以及架构设计 §1.4 的两个附加色（会话选中态 / 发送按钮禁用）。
library;

import 'package:flutter/material.dart';

/// 颜色常量集（12 色板 + 2 附加语义色）。
abstract final class AppColors {
  // ---------------------------------------------------------------------
  // 核心色（规格 §1.1，5 个）
  // ---------------------------------------------------------------------

  /// 主色（深靛蓝）：导航选中态、主按钮、关键高亮、重要标识。
  static const Color primary = Color(0xFF2E3A8C);

  /// 用户气泡色（微信同款）：**仅**用于当前用户发送的消息气泡背景
  /// （规格 §1.1 明确其唯一用途，冲突裁定 #5）。
  static const Color userBubble = Color(0xFF95EC69);

  /// 成功色：在线状态、操作成功提示。
  static const Color success = Color(0xFF52C41A);

  /// 警告色：未读提醒、异常状态。
  static const Color warning = Color(0xFFFA8C16);

  /// 错误色：错误提示、高危操作。
  static const Color error = Color(0xFFF5222D);

  // ---------------------------------------------------------------------
  // 中性色阶（规格 §1.2，7 级，全界面统一）
  // ---------------------------------------------------------------------

  /// 一级背景：列表区、卡片、输入框背景。
  static const Color bgPrimary = Color(0xFFFFFFFF);

  /// 二级背景：导航栏、聊天区整体背景。
  static const Color bgSecondary = Color(0xFFF7F8FA);

  /// 三级背景：分割线、输入框边框、禁用态背景。
  static const Color bgTertiary = Color(0xFFEBEEF5);

  /// 一级文字：标题、消息正文、重要信息。
  static const Color textPrimary = Color(0xFF111827);

  /// 二级文字：次要标题、摘要、普通文本。
  static const Color textSecondary = Color(0xFF4B5563);

  /// 三级文字：时间戳、辅助说明、置灰文字。
  static const Color textTertiary = Color(0xFF9CA3AF);

  /// 分割线：列表分割、区域边界。
  static const Color divider = Color(0xFFE5E7EB);

  // ---------------------------------------------------------------------
  // 附加语义色（架构设计 §1.4）
  // ---------------------------------------------------------------------

  /// 会话项选中态背景（规格 4.2）。
  static const Color sessionSelected = Color(0xFFF0F2F8);

  /// 发送按钮禁用态背景（规格 4.4）。
  static const Color sendDisabled = Color(0xFFC9CDD4);

  // ---------------------------------------------------------------------
  // 附加语义色（第 7 轮 T01 · 规格 4.5 卡片阴影）
  // ---------------------------------------------------------------------

  /// 卡片静态阴影色（规格 4.5：`0 1px 2px`；近黑低透明度叠加）。
  static const Color cardShadow = Color(0x14111827);

  /// 卡片悬停阴影色（规格 4.5：`0 2px 8px`；比静态略强）。
  static const Color cardShadowHover = Color(0x24111827);
}
