/// 联系人名称行 + 内联展开操作（[⚙设置][💬对话]）。
///
/// 该文件同时承载通讯录各页签共用的 [ContactEntry] 视图模型：
/// 排序键 = **展示名（备注优先）**（PRD 裁定 #7），由 [ExpertService] 侧的
/// `EffectiveExpertConfig.resolveName` 产出。
///
/// 视觉（第 5 轮 B3 规格 4.2「会话项」同规，数值不发挥）：
/// - 行高 **64px**（`AppDims.sessionItemHeight`），左右内边距 12、上下 10；
/// - 头像 **36×36 圆角 12**（`AppDims.avatarList` / `AppDims.radiusL`），
///   底色 `bgTertiary`、字色 `textSecondary`（与中栏会话列表一致）；
/// - 名称 14px/500 `textPrimary`；「备注」徽标 11px/`textTertiary`、
///   底 `bgSecondary`、圆角 4、内边距 2×4（规格 4.2 群聊标签同款）；
/// - 副标题（职业 / 分组名）12px `textTertiary`，最多一行；
/// - **展开态 = 选中态**：底色 `AppColors.sessionSelected`（#F0F2F8）+
///   左侧 2px 主色竖条；悬停态底色 `bgSecondary`；
/// - 分割线 1px `divider`（主题色），左边距 58px（对齐文字）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import '../../ui/widgets/expert_avatar.dart';

/// 通讯录联系人视图模型。
class ContactEntry {
  const ContactEntry({
    required this.expert,
    required this.displayName,
    this.remark,
    this.groupId,
    this.pinned = false,
  });

  final Expert expert;
  final String displayName;
  final String? remark;

  /// 所属分组 id（未分组为 null / 空）。
  final String? groupId;
  final bool pinned;

  /// 从领域对象组装（展示名 = 备注优先）。
  static ContactEntry of(Expert expert, ExpertUserState? state) => ContactEntry(
        expert: expert,
        displayName: EffectiveExpertConfig.resolveName(expert, state),
        remark: state?.remark,
        groupId: state?.groupId,
        pinned: state?.pinned ?? false,
      );
}

/// 联系人名称行：点击行内联展开 [⚙设置][💬对话]。
///
/// **第 6 轮 T03 受控化**：展开态由**父级**持有（`expanded` + `onToggle`），
/// 移除内部 `_expanded` —— 落实「单一展开原则」（父级持 `String? _expandedId`，
/// 点开一行自然收起其余），A 组群卡片与 C 组好友卡**同源**。
///
/// B3 视觉重刷只改**呈现**（密度 / 选中态 / 色板来源），受控契约不变。
class ContactNameRow extends StatelessWidget {
  const ContactNameRow({
    super.key,
    required this.entry,
    this.expanded = false,
    this.onToggle,
    this.onOpenSettings,
    this.onOpenChat,
    this.subtitle,
  });

  final ContactEntry entry;

  /// 是否展开（父级受控）；视觉上等同中栏会话列表的「选中态」。
  final bool expanded;

  /// 点击行 → 切换展开（父级负责切换单一展开 id）。
  final VoidCallback? onToggle;

  /// 点「⚙设置」→ 中栏打开专家设置面板。
  final VoidCallback? onOpenSettings;

  /// 点「💬对话」→ 打开（或复用）该专家的单聊。
  final VoidCallback? onOpenChat;

  /// 副标题（默认显示职业 / 分组名）。
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final remark = (e.remark ?? '').trim();
    return Column(
      children: [
        Stack(
          children: [
            Material(
              color: expanded ? AppColors.sessionSelected : Colors.transparent,
              child: InkWell(
                hoverColor: AppColors.bgSecondary,
                onTap: onToggle,
                child: SizedBox(
                  height: AppDims.sessionItemHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppDims.space3, vertical: 10),
                    child: Row(
                      children: [
                        ExpertAvatar(
                          expertId: e.expert.id,
                          name: e.displayName,
                          explicitPath: e.expert.avatarPath,
                          // 第 #66 轮：市场包自带 emoji 头像（无本地图片时用它，
                          // 再没有才回退首字）——此前安装只落 avatar_path，
                          // 专家进通讯录就"头像没了"。
                          avatarEmoji: e.expert.avatarEmoji,
                          avatarColor: e.expert.avatarColor,
                          radius: AppDims.avatarList / 2,
                          borderRadius: BorderRadius.circular(AppDims.radiusL),
                          backgroundColor: AppColors.bgTertiary,
                          foregroundColor: AppColors.textSecondary,
                          fontSize: 15,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  // 「备注」徽标：规格 4.2 群聊标签同款版式。
                                  if (remark.isNotEmpty) ...[
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: AppDims.space1,
                                          vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.bgSecondary,
                                        borderRadius: BorderRadius.circular(
                                            AppDims.radiusS),
                                      ),
                                      child: const Text('备注',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: AppColors.textTertiary)),
                                    ),
                                    const SizedBox(width: AppDims.space1),
                                  ],
                                  Flexible(
                                    child: Text(
                                      e.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.textPrimary),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle ?? (e.expert.profession ?? '—'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppDims.space2),
                        Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                          size: AppDims.iconInline,
                          color: AppColors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 展开态左侧 2px 主色竖条（叠加层，不占内容宽度）。
            if (expanded)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 2,
                child: Container(color: AppColors.primary),
              ),
          ],
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppDims.space4, 0, AppDims.space4, AppDims.space2),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings_outlined,
                        size: AppDims.iconInline),
                    label: const Text('设置'),
                  ),
                ),
                const SizedBox(width: AppDims.space2),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: onOpenChat,
                    icon: const Icon(Icons.chat_bubble_outline,
                        size: AppDims.iconInline),
                    label: const Text('对话'),
                  ),
                ),
              ],
            ),
          ),
        // 分割线：左边距 58px（对齐文字，规格 4.2）。
        const Divider(height: 1, indent: 58),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 共享加载器
// ---------------------------------------------------------------------------

/// 加载全部联系人（展示名 = 备注优先）并按**首字母**排序（`#` 置顶）。
Future<List<ContactEntry>> loadSortedContacts({
  required ExpertService experts,
  required Repositories repos,
}) async {
  final list = await experts.list();
  final out = <ContactEntry>[];
  for (final e in list) {
    final state = await repos.experts.getUserState(e.id);
    out.add(ContactEntry.of(e, state));
  }
  return ContactSorter.sortByName<ContactEntry>(
    out,
    nameOf: (c) => c.displayName,
    initialOf: PinyinInitial.of,
  );
}

/// 通讯录空态提示（裁定 #9：默认空态 + 引导，不自动猜选）。
class ContactsEmptyHint extends StatelessWidget {
  const ContactsEmptyHint({super.key, this.message = '请从右侧选择联系人'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.people_outline,
                size: 44, color: AppColors.textTertiary),
            const SizedBox(height: AppDims.space3),
            Text(message,
                style: const TextStyle(color: AppColors.textTertiary)),
          ],
        ),
      );
}
