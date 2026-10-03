/// 仓储组装：把 10 个 SQLite 仓储 + SecretStore 装配为一个 `Repositories` 聚合。
///
/// `app` 启动时只需调用 [sqliteRepositories] 一次；`advisor_core` 的服务层
/// 统一依赖 `Repositories` 抽象，不感知底层实现。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_attachment_repository.dart';
import 'sqlite_group_repository.dart';
import 'sqlite_knowledge_repository.dart';
import 'sqlite_market_repository.dart';
import 'sqlite_repositories.dart';

/// 构造一套 SQLite 仓储。
///
/// - [db]：由 `openAdvisorDatabase(...)` 打开、并已 `ensureSchema(...)` 的数据库连接；
/// - [secrets]：Secret 存储端口（生产为 OS Secure Storage；测试可用内存实现）。
///
/// 注意：Knowledge / Market 现已为 **SQLite 实现**（不再使用内存兜底）。
Repositories sqliteRepositories(
  Database db, {
  required SecretStore secrets,
}) =>
    Repositories(
      experts: SqliteExpertRepository(db),
      groups: SqliteGroupRepository(db),
      conversations: SqliteConversationRepository(db),
      messages: SqliteMessageRepository(db),
      generations: SqliteGenerationRepository(db),
      knowledge: SqliteKnowledgeRepository(db),
      providers: SqliteProviderRepository(db),
      credentials: SqliteCredentialRepository(db),
      secrets: secrets,
      market: SqliteMarketRepository(db),
      settings: SqliteSettingsRepository(db),
      jobs: SqliteJobRepository(db),
      attachments: SqliteAttachmentRepository(db),
    );
