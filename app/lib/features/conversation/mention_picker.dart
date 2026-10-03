/// @成员候选面板（第 7 轮走查 E-2 · 仅群聊）。
///
/// 在会话输入框上方展开：顶部**过滤输入** + 候选列表（头像 / 显示名 / 角色徽标）+
/// 底部键位提示。候选来自群成员（`conversation_members`，本就只含专家，天然**不含用户自己**），
/// 按**显示名去重**。
///
/// 键位（父级输入框持焦时由父级转发；过滤框持焦时由本组件处理）：
/// `↑/↓` 移动 · `Enter` / `Tab` 选中 · `Esc` 关闭。
///
/// **鼠标选取（走查反馈 #52）**：候选行支持点击选中（与 Enter 完全等价）、
/// 悬停高亮（[AppColors.sessionSelected]）与手型光标（`SystemMouseCursors.click`）。
/// **命中保障（实机走查缺陷修复）**：面板整体与两个输入框登记同一
/// [mentionPickerTapGroup]，点候选行不再触发输入框的 `onTapOutside` 失焦关面板
/// （否则 `InkWell.onTap` 会在指针抬起前被 dispose 取消，见该常量文档）。
/// 其余三处保障：
/// 1. **总高封顶**：面板内联在输入栏 `Column`（非 flex 子节点、无高度上限），
///    不封顶会把输入框/发送栏顶出可视区，用户点到的是别的组件 →
///    [LayoutBuilder] + [ConstrainedBox] 钳制 [_panelMaxHeight]，候选列表在
///    剩余空间内滚动（不再随候选数无限增高）；
/// 2. **墨水可绘**：候选行 `InkWell` 的墨水墨绘在最近的 Material 祖先上，
///    而 `AppCard` 是普通 `Container`（非 Material）→ 不补透明 Material 时
///    墨水墨在 Scaffold 根 Material、被卡片白底盖住 → 用户看不到点击反馈；
/// 3. **悬停可辨**：行级 `MouseRegion` 高亮 + 手型光标，桌面端一眼可点。
///
/// **视觉事实唯一来源**：色值与尺寸只从 [AppColors] / [AppDims] 取，无裸 `Color(0x…)`。
library;

import 'dart:math' as math;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import '../../ui/widgets/app_card.dart';
import '../../ui/widgets/expert_avatar.dart';

/// @成员选择器与主输入框共享的 [TapRegion] 分组标识（走查缺陷修复：鼠标点候选行无反应）。
///
/// **根因**：Windows 桌面下 `EditableText` 的默认 `onTapOutside` 会对落在输入框之外的
/// **指针按下**调用 `focusNode.unfocus()`（SDK `editable_text.dart:6802-6805`，
/// `_EditableTextTapOutsideAction`）。候选行位于输入框之外 → 鼠标按下即让主输入框
/// （工具栏路径下为过滤框）失焦 → 宿主 `_closeMentionIfFocusLeft` 在帧末关闭面板 →
/// 面板被移除、行内 `InkWell` 手势随组件 dispose 被取消 → `onTap` 永不触发，
/// 表现为"鼠标点候选行没反应"；键盘不产生 tap outside，故不受影响。
///
/// **修法**：把主输入框、过滤框与整块面板登记到**同一 tap 分组**——分组内任一区域
/// 被命中时，同组成员的 `onTapOutside` 都不触发（SDK `tap_region.dart:451-457`），
/// 于是点候选行不再让输入框失焦、面板不被误关，`InkWell.onTap` 正常命中并插入。
/// 点击面板外部仍按默认失焦 → 面板照常关闭（既有行为不变）。
final Object mentionPickerTapGroup = Object();

/// 一位可 @ 的候选人。
class MentionCandidate {
  const MentionCandidate({
    required this.expertId,
    required this.name,
    required this.role,
    this.avatarEmoji,
    this.avatarColor,
  });

  final String expertId;

  /// 展示名（备注优先）；已按此字段去重。
  final String name;
  final MemberRole role;

  /// 市场包自带 emoji 头像（第 #66 轮；可为 null → 回退首字）。
  final String? avatarEmoji;

  /// emoji 底色（市场包 `color`；可为 null → 回退确定性色板）。
  final String? avatarColor;
}

/// @成员候选面板。
class MentionPicker extends StatefulWidget {
  const MentionPicker({
    super.key,
    required this.candidates,
    required this.selectedIndex,
    required this.filterController,
    required this.filterFocus,
    required this.onSelectedIndex,
    required this.onConfirmed,
    required this.onFilterChanged,
  });

  /// 过滤后的候选（已由父级按 `@` 后的输入词过滤）。
  final List<MentionCandidate> candidates;

  /// 当前高亮下标。
  final int selectedIndex;

  /// 顶部过滤输入控制器（父级持有，与 `@` 词同步）。
  final TextEditingController filterController;

  /// 顶部过滤输入焦点（父级持有：据此区分"焦点移入面板"与"焦点离开整个输入区"）。
  final FocusNode filterFocus;

  /// 高亮下标变化（↑/↓）。
  final ValueChanged<int> onSelectedIndex;

  /// 确认选中当前高亮项。
  final VoidCallback onConfirmed;

  /// 过滤词变化（父级据此重算候选）。
  final ValueChanged<String> onFilterChanged;

  @override
  State<MentionPicker> createState() => _MentionPickerState();
}

/// 面板总高封顶值（魔法数集中定义于本文件，便于走查核对）。
///
/// 上限 260 的依据：输入栏其余件（工具栏 36 + 输入框 ≤4 行 ≈116 + 发送行 ≈52 +
/// 内外边距 ≈20）+ 标题栏 57 后，1280×800 基准窗口下消息列表仍保有 ~250px；
/// 候选列表在剩余空间内滚动（键盘 ↑/↓ 与鼠标同源，行高一致）。
const double _panelMaxHeight = 260;

class _MentionPickerState extends State<MentionPicker> {
  /// 鼠标悬停中的行下标（触屏无悬停事件，恒为 null）。
  int? _hoverIndex;

  @override
  Widget build(BuildContext context) {
    // 高度封顶（走查 #52-1）：父级 Column 为非 flex 子节点，约束 maxHeight 为
    // 无穷；有限时（如未来改挂 overlay / 受外层 SizedBox 约束）再收一档，
    // 取二者的较小值，保证面板永不超过 [_panelMaxHeight]。
    //
    // 外层 [TapRegion]（同一 [mentionPickerTapGroup] 分组）：让"点击面板内部"
    // 不被输入框视为"点击外部"，从根上消除"鼠标按下即失焦关面板"的竞态。
    return TapRegion(
      groupId: mentionPickerTapGroup,
      // 整块面板矩形都算"内部"（含候选列表的空白间隙），不因空白无子命中而漏注册。
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxHeight = constraints.maxHeight.isFinite
              ? math.min(_panelMaxHeight, constraints.maxHeight)
              : _panelMaxHeight;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: AppCard(
              dense: true,
              margin: const EdgeInsets.only(bottom: AppDims.space2),
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _filterField(),
                  const Divider(height: 1, color: AppColors.divider),
                  // 候选列表在剩余空间内滚动：少候选时收缩（shrinkWrap），
                  // 多候选时受面板封顶约束而内部滚动。
                  Flexible(
                    // 透明 Material（走查 #52-2）：给 InkWell 一个**卡片内层**的
                    // 墨水墨绘目标。缺它时最近 Material 是 Scaffold 根节点，墨水
                    // 被卡片白底盖住 → 点击无任何视觉反馈。
                    child: Material(
                      type: MaterialType.transparency,
                      child: _list(),
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.divider),
                  _footer(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _filterField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppDims.space3, AppDims.space2, AppDims.space3, AppDims.space2),
      child: TextField(
        controller: widget.filterController,
        focusNode: widget.filterFocus,
        // 与主输入框、整块面板同一 tap 分组：点过滤框/候选行都不会被判定为
        // "点击输入框外部"（见 [mentionPickerTapGroup]）。
        groupId: mentionPickerTapGroup,
        onChanged: widget.onFilterChanged,
        // 面板内输入不再触发发送（Enter 只用于确认选中）。
        textInputAction: TextInputAction.none,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: '按姓名筛选',
          hintStyle:
              const TextStyle(fontSize: 12, color: AppColors.textTertiary),
          prefixIcon: const Icon(Icons.search,
              size: AppDims.iconInline, color: AppColors.textTertiary),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 30, minHeight: 30),
          contentPadding: EdgeInsets.zero,
          border: const OutlineInputBorder(
            borderSide: BorderSide(color: AppColors.bgTertiary),
            borderRadius: BorderRadius.all(Radius.circular(AppDims.radiusM)),
          ),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppColors.bgTertiary),
            borderRadius: BorderRadius.all(Radius.circular(AppDims.radiusM)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppColors.bgTertiary),
            borderRadius: BorderRadius.all(Radius.circular(AppDims.radiusM)),
          ),
        ),
      ),
    );
  }

  Widget _list() {
    final list = widget.candidates;
    if (list.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppDims.space4),
        child: Text('没有匹配的群成员',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: list.length,
      itemBuilder: (_, i) => _row(list[i], i),
    );
  }

  Widget _row(MentionCandidate c, int index) {
    final selected = index == widget.selectedIndex;
    final hovered = index == _hoverIndex;
    // 选中与悬停同色（spec：sessionSelected 唯一用途即"当前会话选中/悬停底色"）。
    final bg =
        selected || hovered ? AppColors.sessionSelected : AppColors.bgPrimary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverIndex = index),
      onExit: (_) => setState(() => _hoverIndex = null),
      cursor: SystemMouseCursors.click,
      child: InkWell(
        // 鼠标点选与 Enter/Tab 完全等价：选中当前行并插入（父级 `_selectMention`）。
        // 只发选中回调、不触发任何键位路径 → 不会同时触发发送（互斥由父级
        // `_onInputKeyEvent` 的面板优先分支保证）。
        onTap: () {
          widget.onSelectedIndex(index);
          widget.onConfirmed();
        },
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          color: bg,
          padding: const EdgeInsets.symmetric(
              horizontal: AppDims.space3, vertical: AppDims.space1),
          child: Row(
            children: [
              ExpertAvatar(
                expertId: c.expertId,
                name: c.name,
                avatarEmoji: c.avatarEmoji,
                avatarColor: c.avatarColor,
                radius: 14,
                fontSize: 12,
              ),
              const SizedBox(width: AppDims.space2),
              Expanded(
                child: Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textPrimary)),
              ),
              const SizedBox(width: AppDims.space2),
              _roleBadge(c.role),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleBadge(MemberRole role) {
    final isLeader = role == MemberRole.leader;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: AppDims.space1, vertical: 1),
      decoration: BoxDecoration(
        color: isLeader ? AppColors.primary : AppColors.bgSecondary,
        borderRadius: BorderRadius.circular(AppDims.radiusS),
      ),
      child: Text(role.label,
          style: TextStyle(
            fontSize: 10,
            color: isLeader ? AppColors.bgPrimary : AppColors.textSecondary,
          )),
    );
  }

  Widget _footer() {
    return const Padding(
      padding: EdgeInsets.symmetric(
          horizontal: AppDims.space3, vertical: AppDims.space1),
      child: Text('↑↓ 选择 · Enter / Tab 确认 · Esc 关闭',
          style: TextStyle(fontSize: 10, color: AppColors.textTertiary)),
    );
  }
}
