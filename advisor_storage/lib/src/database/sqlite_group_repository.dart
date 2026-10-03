/// `SqliteGroupRepository`：`GroupRepository` 端口的 SQLite 实现（raw SQL）。
///
/// 对应表 `expert_groups`（第 3 轮 v3 新增）。
/// 说明：成员 `expert_user_states.group_id` 为**逻辑外键**（**无 DB 级 FK**），
/// 删除分组时清空成员 `group_id` 由 `ExpertService.deleteGroup` 在服务层保证。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

class SqliteGroupRepository implements GroupRepository {
  SqliteGroupRepository(this.db);

  final Database db;

  @override
  Future<void> upsertGroup(ExpertGroup group) async {
    db.execute('''
      INSERT INTO expert_groups (id,name,sort_order,created_at,updated_at)
      VALUES (?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        name=excluded.name, sort_order=excluded.sort_order, updated_at=excluded.updated_at
    ''', [group.id, group.name, group.sortOrder, group.createdAt, group.updatedAt]);
  }

  @override
  Future<ExpertGroup?> getGroup(String id) async {
    final rs = db.select('SELECT * FROM expert_groups WHERE id = ?', [id]);
    return rs.isEmpty ? null : _group(rs.first);
  }

  @override
  Future<List<ExpertGroup>> listGroups() async => db
      .select('SELECT * FROM expert_groups ORDER BY sort_order ASC, created_at ASC')
      .map(_group)
      .toList();

  @override
  Future<void> deleteGroup(String id) async {
    db.execute('DELETE FROM expert_groups WHERE id = ?', [id]);
  }

  ExpertGroup _group(Row r) => ExpertGroup(
        id: r['id'] as String,
        name: r['name'] as String,
        sortOrder: rowInt(r['sort_order']) ?? 0,
        createdAt: rowInt(r['created_at'])!,
        updatedAt: rowInt(r['updated_at'])!,
      );
}
