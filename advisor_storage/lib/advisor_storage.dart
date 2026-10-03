/// 私人顾问团 · 存储层入口（barrel）。
///
/// 依赖方向：`app (Flutter) → advisor_storage (纯 Dart) → advisor_core (纯 Dart)`。
/// 本包**不依赖 Flutter**，可 `dart pub get` + `dart run` 独立验证。
///
/// 典型用法：
/// ```dart
/// final db = openAdvisorDatabase(path);
/// ensureSchema(db);
/// final repos = sqliteRepositories(db, secrets: mySecretStore);
/// ```
library;

export 'src/database/schema.g.dart';

export 'src/database/support.dart';

export 'src/database/sqlite_repositories.dart';

export 'src/database/sqlite_group_repository.dart';

export 'src/database/sqlite_knowledge_repository.dart';

export 'src/database/sqlite_market_repository.dart';

export 'src/database/storage_bootstrap.dart';

export 'src/database/fts_retriever.dart';
