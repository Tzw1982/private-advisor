/// ExpertGroup 领域：通讯录「分组」主实体（PRD §7 缺口 2 的落库模型）。
///
/// 分组是**用户级**数据（与 `experts` 无强归属）：删除分组不清除专家，
/// 只由服务层把成员 `group_id` 置空（`expert_user_states.group_id` 为逻辑外键，
/// **无 DB 级 FK** —— 见第 3 轮架构设计 §3.1 FK 取舍）。
library;

import 'common.dart';

/// 通讯录分组。
class ExpertGroup {
  const ExpertGroup({
    required this.id,
    required this.name,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// 组内排序权重（越大越靠前由 UI 决定；存储层只保序）。
  final int sortOrder;
  final int createdAt;
  final int updatedAt;

  ExpertGroup copyWith({
    String? name,
    int? sortOrder,
    int? updatedAt,
  }) =>
      ExpertGroup(
        id: id,
        name: name ?? this.name,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 新建分组（生成 ID 与时间戳）。名称为空抛 [ValidationError]。
  static ExpertGroup create(String name, {int sortOrder = 0, int? now}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationError('group.name', '分组名称不能为空');
    }
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    return ExpertGroup(
      id: Ids.next('grp'),
      name: trimmed,
      sortOrder: sortOrder,
      createdAt: t,
      updatedAt: t,
    );
  }
}
