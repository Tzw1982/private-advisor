/// `SqliteAttachmentRepository`：`AttachmentRepository` 端口的 SQLite 实现（raw SQL）。
///
/// 对应表 `message_attachments`（第 8 轮 v6 新增）。
///
/// **归属红线（架构 §4 / 共享约定 1）**：附件归属**只认 `message_id`**；
/// [countByStoredPath] 是 **DB 登记计数**（`SELECT COUNT(*) ... WHERE stored_path = ?`），
/// **不是文件系统扫描**——任何扫盘都不得参与归属判定。
///
/// 两处 `DELETE` 的差异：
/// - [deleteMessage] 在 `messages` 表删消息 → `message_attachments` 行由 **DDL 级联**
///   （`ON DELETE CASCADE`）自动清除（前提：连接 `PRAGMA foreign_keys = ON`，
///   由 `openAdvisorDatabase` / `ensureSchema` 保证）；
/// - [deleteByMessage] 是**服务层显式删**（双保险：即使某连接 FK 为 OFF 也不漏行）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

class SqliteAttachmentRepository implements AttachmentRepository {
  SqliteAttachmentRepository(this.db);

  final Database db;

  static const _columns =
      'id, message_id, kind, file_name, stored_path, sha256, size_bytes, '
      'mime_type, width, height, page_count, sent_to_model_at, created_at';

  @override
  Future<void> insertAttachment(Attachment a) async {
    db.execute('''
      INSERT INTO message_attachments
        ($_columns)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        kind=excluded.kind, file_name=excluded.file_name,
        stored_path=excluded.stored_path, sha256=excluded.sha256,
        size_bytes=excluded.size_bytes, mime_type=excluded.mime_type,
        width=excluded.width, height=excluded.height,
        page_count=excluded.page_count, sent_to_model_at=excluded.sent_to_model_at
    ''', [
      a.id, a.messageId, a.kind.name, a.fileName, a.storedPath, a.sha256, a.sizeBytes,
      a.mimeType, a.width, a.height, a.pageCount, a.sentToModelAt, a.createdAt,
    ]);
  }

  @override
  Future<void> insertAttachments(List<Attachment> list) async {
    for (final a in list) {
      await insertAttachment(a);
    }
  }

  @override
  Future<List<Attachment>> listAttachmentsByMessage(String messageId) async => db
      .select(
          'SELECT $_columns FROM message_attachments WHERE message_id = ? '
          'ORDER BY created_at ASC, rowid ASC', [messageId])
      .map(_row)
      .toList();

  @override
  Future<List<Attachment>> listAttachmentsByMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    // 批量查（防 N+1）：消息流一次性取全，再在内存里按 message_id 归组。
    final marks = List.filled(messageIds.length, '?').join(',');
    final rows = db.select(
      'SELECT $_columns FROM message_attachments WHERE message_id IN ($marks) '
      'ORDER BY message_id ASC, created_at ASC, rowid ASC',
      messageIds,
    );
    return rows.map(_row).toList();
  }

  @override
  Future<Attachment?> findBySha256(String sha256) async {
    final rs = db.select(
      'SELECT $_columns FROM message_attachments WHERE sha256 = ? '
      'ORDER BY created_at ASC, rowid ASC LIMIT 1',
      [sha256],
    );
    return rs.isEmpty ? null : _row(rs.first);
  }

  @override
  Future<int> countByStoredPath(String storedPath, {String? excludeId}) async {
    final buffer = StringBuffer('SELECT COUNT(*) AS c FROM message_attachments WHERE stored_path = ?');
    final params = <Object?>[storedPath];
    if (excludeId != null) {
      buffer.write(' AND id != ?');
      params.add(excludeId);
    }
    final rs = db.select(buffer.toString(), params);
    return (rs.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> deleteByMessage(String messageId) async {
    db.execute('DELETE FROM message_attachments WHERE message_id = ?', [messageId]);
  }

  Attachment _row(Row r) => Attachment(
        id: r['id'] as String,
        messageId: r['message_id'] as String,
        kind: AttachmentKind.parse(r['kind'] as String?),
        fileName: r['file_name'] as String,
        storedPath: r['stored_path'] as String,
        sha256: r['sha256'] as String,
        sizeBytes: rowInt(r['size_bytes']) ?? 0,
        mimeType: rowString(r['mime_type']),
        width: rowInt(r['width']),
        height: rowInt(r['height']),
        pageCount: rowInt(r['page_count']),
        sentToModelAt: rowInt(r['sent_to_model_at']),
        createdAt: rowInt(r['created_at']) ?? 0,
      );
}
