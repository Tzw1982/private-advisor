/// 通用卡片（第 7 轮 T01 · 规格 4.5）。
///
/// 白底 / 圆角 8 / 阴影 `0 1px 2px` → **悬停** `0 2px 8px` / 内边距可配。
/// 市场与知识库的中栏列表卡共用（[dense] = 紧凑列表卡变体）。
///
/// **视觉事实唯一来源**：色值与尺寸只从 [AppColors] / [AppDims] 取，无裸 `Color(0x…)`、无魔法数。
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dims.dart';

/// 规格 4.5 通用卡片（悬停阴影加深）。
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
    this.dense = false,
  });

  /// 卡片内容。
  final Widget child;

  /// 内边距；缺省：dense → `AppDims.space3`(12)，否则 `AppDims.space4`(16)。
  final EdgeInsetsGeometry? padding;

  /// 外边距（缺省无）。
  final EdgeInsetsGeometry? margin;

  /// 点击回调；非空时悬停显示手型光标。
  final VoidCallback? onTap;

  /// 紧凑列表卡（内边距 12，中栏用）。
  final bool dense;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rest = BoxShadow(
      color: AppColors.cardShadow,
      offset: const Offset(0, AppDims.cardShadowRestOffsetY),
      blurRadius: AppDims.cardShadowRestBlur,
    );
    final hover = BoxShadow(
      color: AppColors.cardShadowHover,
      offset: const Offset(0, AppDims.cardShadowHoverOffsetY),
      blurRadius: AppDims.cardShadowHoverBlur,
    );

    final card = Container(
      margin: widget.margin,
      padding: widget.padding ??
          EdgeInsets.all(widget.dense ? AppDims.space3 : AppDims.space4),
      decoration: BoxDecoration(
        color: AppColors.bgPrimary,
        borderRadius: BorderRadius.circular(AppDims.radiusM),
        boxShadow: <BoxShadow>[_hover ? hover : rest],
      ),
      child: widget.child,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: widget.onTap == null
          ? card
          : GestureDetector(onTap: widget.onTap, child: card),
    );
  }
}
