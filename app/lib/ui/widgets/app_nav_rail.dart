/// 左侧全局导航栏（第 5 轮 UI 改版 · 规格表 4.1 逐项）。
///
/// 规格（4.1，数值不发挥）：
/// - 宽 180px、高 100%、背景 `#F7F8FA`；
/// - 顶部 Logo 区 56px、左右内边距 16：Logo 20×20 + 产品名 14px/500；
/// - 导航项单行 40px、左右内边距 12、图标 18×18 线性 + 文字（间距 8）；
/// - 三态：默认文字/图标 `#4B5563` 无背景 ／ 悬停背景 `#EBEEF5` 文字 `#111827`
///   ／ 选中背景 `#FFFFFF` + 文字图标 `#2E3A8C` + 左侧 2px 竖条 `#2E3A8C`；
/// - 底部：顶部 1px 分割线 `#E5E7EB` + 设置项（样式同普通导航项）。
library;

import 'package:flutter/material.dart';

import '../../app_version.dart';
import '../theme/app_colors.dart';
import '../theme/app_dims.dart';

/// 导航项数据。
class NavRailItem {
  const NavRailItem({required this.icon, required this.label});

  /// 线性风格图标（18×18）。
  final IconData icon;

  /// 文字标签（简体中文）。
  final String label;
}

/// 左侧全局导航栏（宽 180px）。
class AppNavRail extends StatelessWidget {
  const AppNavRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSettings,
  });

  /// 模块导航项（会话 / 通讯录 / 人才市场 / 知识库）。
  final List<NavRailItem> items;

  /// 当前选中索引（切页签不丢选中态由宿主持有状态保证）。
  final int selectedIndex;

  final ValueChanged<int> onSelected;

  /// 底部设置项回调（保持 Dialog，主理人裁定）。
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppDims.navWidth,
      color: AppColors.bgSecondary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _logoArea(),
          const SizedBox(height: AppDims.space2),
          for (var i = 0; i < items.length; i++)
            _NavRailItemView(
              item: items[i],
              selected: i == selectedIndex,
              onTap: () => onSelected(i),
            ),
          const Spacer(),
          // 底部分隔：顶部 1px 分割线（规格 4.1）。
          const Divider(height: 1, thickness: 1, color: AppColors.divider),
          _NavRailItemView(
            item: const NavRailItem(icon: Icons.settings_outlined, label: '设置'),
            selected: false,
            onTap: onSettings,
          ),
          const SizedBox(height: AppDims.space3),
        ],
      ),
    );
  }

  /// Logo 区：56px、左右内边距 16、Logo 20×20 + 产品名 14px/500。
  Widget _logoArea() {
    return SizedBox(
      height: AppDims.logoAreaHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space4),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              // 走查修复 #65：左上角名称曾与窗口标题重复。这里改为**软件 ICON 图标**
              // + 名称 + 版本号（窗口标题已清空，避免两处同名）。
              child: ClipOval(
                child: Image.asset(
                  'assets/app_icon.png',
                  width: 24,
                  height: 24,
                  fit: BoxFit.cover,
                  // 资源缺失时回退到主色圆形 + 首字（不白屏、不崩）。
                  errorBuilder: (_, __, ___) => Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '私',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.bgPrimary),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppDims.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '私人顾问团',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary),
                  ),
                  Text(
                    kAppVersion,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个导航项（带悬停态的三态渲染：默认 / 悬停 / 选中）。
class _NavRailItemView extends StatefulWidget {
  const _NavRailItemView({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavRailItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavRailItemView> createState() => _NavRailItemViewState();
}

class _NavRailItemViewState extends State<_NavRailItemView> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    // 三态前景色：选中 #2E3A8C ／ 悬停 #111827 ／ 默认 #4B5563（图标同色）。
    final fg = selected
        ? AppColors.primary
        : (_hover ? AppColors.textPrimary : AppColors.textSecondary);
    // 三态背景：选中 #FFFFFF ／ 悬停 #EBEEF5 ／ 默认无背景。
    final bg = selected
        ? AppColors.bgPrimary
        : (_hover ? AppColors.bgTertiary : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: AppDims.navItemHeight,
          color: bg,
          child: Row(
            children: [
              // 左侧 2px 竖条（选中态高亮 #2E3A8C；未选中占位保持内容对齐）。
              Container(
                width: 2,
                height: double.infinity,
                color: selected ? AppColors.primary : Colors.transparent,
              ),
              // 竖条之后到 12px 内边距的补齐（2 + 10 = 12，规格 4.1）。
              const SizedBox(width: 10),
              Icon(widget.item.icon, size: AppDims.iconNav, color: fg),
              const SizedBox(width: AppDims.space2),
              Expanded(
                child: Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 导航选中项 14px/500（H2），其余 14px/400。
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
