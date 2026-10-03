/// 全局主题装配（第 5 轮 UI 改版 · 架构设计 §1.4）。
///
/// **全 app 唯一视觉事实来源**：`MaterialApp(theme: AppTheme.light())`
/// 一处定义，全 app 引用；替换旧 `#07C160` 微信绿 seed 为规格主色。
///
/// 字号字重 5 级映射（规格 §2.2）：
/// H1 16/600 → titleLarge、H2 14/500 → titleMedium、
/// Body 14/400 → bodyLarge、Small 12/400 → bodySmall、Mini 11/400 → labelSmall。
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_dims.dart';

/// 主题装配器。
abstract final class AppTheme {
  /// 字体栈（规格 §2.1：中文 Microsoft YaHei，Windows 桌面默认）。
  static const String fontFamily = 'Microsoft YaHei';

  /// 亮色主题（本 app 唯一主题）。
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: AppColors.primary);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: AppColors.bgPrimary,
      dividerColor: AppColors.divider,
      // 桌面端悬停优先：去点击水波，保留悬停反馈（架构设计 §1.4）。
      splashFactory: NoSplash.splashFactory,
      hoverColor: AppColors.bgTertiary,
      textTheme: const TextTheme(
        // H1 大标题 16/600：窗口标题、页面主标题。
        titleLarge: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
        // H2 次级标题 14/500：会话名称、卡片标题、导航选中项。
        titleMedium: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary),
        // Body 正文 14/400：消息正文、普通文本。
        bodyLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: AppColors.textPrimary),
        // Small 次要文本 12/400：摘要、时间戳、辅助说明。
        bodySmall: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: AppColors.textSecondary),
        // Mini 辅助文字 11/400：角标、版本号、状态小字。
        labelSmall: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: AppColors.textTertiary),
      ),
      // Flutter 3.33+ 迁移：dialogTheme 参数类型改为 DialogThemeData
      // （旧 DialogTheme 类已改型为 InheritedTheme widget，不再是数据类；
      //   参数名仍为 dialogTheme，SDK 源码 theme_data.dart L335 实证）。
      dialogTheme: DialogThemeData(
        // 大圆角 12：弹窗（规格 §3.1）。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDims.radiusL),
        ),
        backgroundColor: AppColors.bgPrimary,
      ),
      // Flutter 3.33+ 迁移：InputDecorationTheme 已改型为 InheritedTheme
      // widget，数据类为 InputDecorationThemeData（参数名仍为
      // inputDecorationTheme，SDK 源码 theme_data.dart L277/L392 实证）。
      inputDecorationTheme: InputDecorationThemeData(
        // 输入框：8 圆角、bgTertiary 边框（架构设计 §1.4）。
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDims.radiusM),
          borderSide: const BorderSide(color: AppColors.bgTertiary),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDims.radiusM),
          borderSide: const BorderSide(color: AppColors.bgTertiary),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDims.radiusM),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
      ),
    );
  }
}
