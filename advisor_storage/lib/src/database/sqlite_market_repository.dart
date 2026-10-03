/// `SqliteMarketRepository`：`MarketRepository` 端口的 SQLite 实现。
///
/// 覆盖四张表：`market_sources` / `market_packages` / `market_versions` /
/// `installed_packages`。
///
/// 关键点：
/// - `replacePackages(sourceId, packages)`：**单事务**，且**按 `source_id` 作用域**
///   删旧（`DELETE ... WHERE source_id = ?`，级联删 versions），随后逐包 / 逐版本写入。
///   注意：不是"清空全表"，多源并存时互不影响。
/// - `setIndexEtag` / `getIndexEtag`：**复用 `settings` 表 KV**
///   （键 `market.index.etag.<sourceId>` / `market.index.refreshedAt.<sourceId>`），
///   不改 schema。
/// - 所有 SQLite 异常均归一化为 [StorageError]（`storage.market.*`）。
library;

import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

class SqliteMarketRepository implements MarketRepository {
  SqliteMarketRepository(this.db);

  final Database db;

  /// etag / refreshedAt 在 `settings` 表中的键前缀。
  static const String _etagKeyPrefix = 'market.index.etag.';
  static const String _refreshedKeyPrefix = 'market.index.refreshedAt.';

  // -------------------------------------------------------------------------
  // 市场源
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertSource(MarketSource source) async {
    _guard('storage.market.upsert_source', () {
      db.execute('''
        INSERT INTO market_sources (id,name,base_url,enabled,last_refresh_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, base_url=excluded.base_url,
          enabled=excluded.enabled, last_refresh_at=excluded.last_refresh_at
      ''', [source.id, source.name, source.baseUrl, boolToInt(source.enabled), source.lastRefreshAt]);
    });
  }

  @override
  Future<List<MarketSource>> listSources() async {
    final rows = _guard('storage.market.list_sources',
        () => db.select('SELECT * FROM market_sources ORDER BY name'));
    return rows.map(_source).toList();
  }

  MarketSource _source(Row r) => MarketSource(
        id: r['id'] as String,
        name: r['name'] as String,
        baseUrl: r['base_url'] as String,
        enabled: rowBool(r['enabled']),
        lastRefreshAt: rowInt(r['last_refresh_at']),
      );

  // -------------------------------------------------------------------------
  // 包 / 版本
  // -------------------------------------------------------------------------

  @override
  Future<void> replacePackages(String sourceId, List<MarketPackage> packages) async {
    _guard('storage.market.replace_packages', () {
      transaction(db, () {
        // 按 source_id 作用域删旧（级联删 market_versions）。
        db.execute('DELETE FROM market_packages WHERE source_id = ?', [sourceId]);
        for (final p in packages) {
          db.execute('''
            INSERT INTO market_packages
              (package_id,source_id,display_name,profession,description,category_id,
               tags_json,latest_version,sha256,signature,emoji,color,slug)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
          ''', [
            p.packageId, sourceId, p.displayName, p.profession, p.description,
            p.categoryId, jsonEncode(p.tags), p.latestVersion.toString(), null, null,
            // 第 #58 轮：emoji / color 落库（null 如实写 NULL，禁止写空串——
            // 空串会被 UI 误判为「有值但渲染不出」，且污染旧库升级后的默认值语义）。
            p.emoji, p.color,
            // 第 #59 轮：slug 落库——安装目录 `packages/<slug>-<version>` 与卡片
            // 标识的组成部分；v7 及之前未持久化该字段，所有安装目录坍缩为同一个
            // `packages/-1.0.0`（用户走查「点击添加没反应」根因之二）。
            p.slug,
          ]);
          for (final v in p.versions) {
            db.execute('''
              INSERT INTO market_versions
                (package_id,version,release_url,sha256,signature,size_bytes,published_at)
              VALUES (?,?,?,?,?,?,?)
            ''', [
              p.packageId, v.version.toString(), v.releaseUrl, v.sha256,
              v.signature, v.sizeBytes, v.publishedAt,
            ]);
          }
        }
      });
    });
  }

  @override
  Future<List<MarketPackage>> listPackages({String? sourceId, String? categoryId}) async {
    final conditions = <String>[];
    final params = <Object?>[];
    if (sourceId != null) {
      conditions.add('source_id = ?');
      params.add(sourceId);
    }
    if (categoryId != null) {
      conditions.add('category_id = ?');
      params.add(categoryId);
    }
    final where = conditions.isEmpty ? '' : ' WHERE ${conditions.join(' AND ')}';
    final rows = _guard('storage.market.list_packages',
        () => db.select('SELECT * FROM market_packages$where', params));
    return rows
        .map((r) => _package(r, _versionsFor(r['package_id'] as String)))
        .toList();
  }

  @override
  Future<MarketPackage?> getPackage(String packageId) async {
    final rs = _guard('storage.market.get_package',
        () => db.select('SELECT * FROM market_packages WHERE package_id = ?', [packageId]));
    if (rs.isEmpty) return null;
    return _package(rs.first, _versionsFor(packageId));
  }

  List<MarketVersion> _versionsFor(String packageId) => db
      .select('SELECT * FROM market_versions WHERE package_id = ?', [packageId])
      .map((r) => MarketVersion(
            packageId: packageId,
            version: SemVer.tryParse(r['version'] as String?) ?? const SemVer(0, 0, 0),
            releaseUrl: rowString(r['release_url']) ?? '',
            sha256: rowString(r['sha256']) ?? '',
            signature: rowString(r['signature']),
            sizeBytes: rowInt(r['size_bytes']),
            publishedAt: rowInt(r['published_at']),
          ))
      .toList();

  MarketPackage _package(Row r, List<MarketVersion> versions) => MarketPackage(
        packageId: r['package_id'] as String,
        // 第 #59 轮（v8）：slug 持久化——它是安装目录 `packages/<slug>-<version>`
        // （market_page.dart 的 install()）与卡片标识的组成部分，**必须落库**；
        // v7 及之前本方法以空串还原，导致所有安装目录坍缩为 `packages/-1.0.0`。
        // 存量旧库升级行该列为 NULL → 读回空串（与 `MarketPackage.fromJson` 的
        // `(j['slug'] ?? '')` 口径一致），待用户下次「刷新索引」经 replacePackages
        // 写入真实 slug（verify_storage v7→v8 迁移节实证该路径）。
        slug: rowString(r['slug']) ?? '',
        displayName: r['display_name'] as String,
        profession: rowString(r['profession']),
        description: rowString(r['description']),
        categoryId: rowString(r['category_id']) ?? '',
        tags: rowJsonList(r['tags_json']),
        latestVersion: SemVer.tryParse(r['latest_version'] as String?) ?? const SemVer(0, 0, 0),
        versions: versions,
        // 第 #58 轮：emoji / color 读回（NULL 透传为 null；存量旧库升级行同样为 null
        // → 走回退档「首字 + 确定性色」，行为不变）。
        emoji: rowString(r['emoji']),
        color: rowString(r['color']),
      );

  // -------------------------------------------------------------------------
  // 已安装
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertInstalled(InstalledPackage pkg) async {
    _guard('storage.market.upsert_installed', () {
      db.execute('''
        INSERT INTO installed_packages
          (installation_id,package_id,version,install_path,installed_at,local_modified,source)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(installation_id) DO UPDATE SET
          package_id=excluded.package_id, version=excluded.version,
          install_path=excluded.install_path, installed_at=excluded.installed_at,
          local_modified=excluded.local_modified, source=excluded.source
      ''', [
        pkg.installationId, pkg.packageId, pkg.version.toString(), pkg.installPath,
        pkg.installedAt, boolToInt(pkg.localModified), pkg.source,
      ]);
    });
  }

  @override
  Future<List<InstalledPackage>> listInstalled() async {
    final rows = _guard('storage.market.list_installed',
        () => db.select('SELECT * FROM installed_packages ORDER BY installed_at DESC'));
    return rows.map(_installed).toList();
  }

  @override
  Future<InstalledPackage?> getInstalledByPackageId(String packageId) async {
    final rs = _guard('storage.market.get_installed_by_package',
        () => db.select('SELECT * FROM installed_packages WHERE package_id = ? LIMIT 1', [packageId]));
    return rs.isEmpty ? null : _installed(rs.first);
  }

  @override
  Future<void> deleteInstalled(String installationId) async {
    _guard('storage.market.delete_installed',
        () => db.execute('DELETE FROM installed_packages WHERE installation_id = ?', [installationId]));
  }

  @override
  Future<void> deleteInstalledByPackageId(String packageId) async {
    // 第 #80 轮（缺陷 B）：按 package_id 删除**全部**行——用于①「删除市场来源专家
    // → 卸载该包」②「安装前去重」。一次 DELETE 覆盖存量重复行（幂等；无匹配行时
    // 影响 0 行）。⛔ 不动 schema（不加 UNIQUE 索引），纯应用层去重。
    _guard('storage.market.delete_installed_by_package',
        () => db.execute('DELETE FROM installed_packages WHERE package_id = ?', [packageId]));
  }

  InstalledPackage _installed(Row r) => InstalledPackage(
        installationId: r['installation_id'] as String,
        packageId: r['package_id'] as String,
        version: SemVer.tryParse(r['version'] as String?) ?? const SemVer(0, 0, 0),
        installPath: r['install_path'] as String,
        installedAt: rowInt(r['installed_at']) ?? 0,
        localModified: rowBool(r['local_modified']),
        source: r['source'] as String? ?? 'market',
      );

  // -------------------------------------------------------------------------
  // 索引 etag（复用 settings 表 KV）
  // -------------------------------------------------------------------------

  @override
  Future<void> setIndexEtag(String sourceId, String? etag, int refreshedAt) async {
    _guard('storage.market.set_index_etag', () {
      _setSetting('$_refreshedKeyPrefix$sourceId', '$refreshedAt');
      if (etag == null) {
        _removeSetting('$_etagKeyPrefix$sourceId');
      } else {
        _setSetting('$_etagKeyPrefix$sourceId', etag);
      }
    });
  }

  @override
  Future<({String? etag, int? refreshedAt})?> getIndexEtag(String sourceId) async {
    return _guard('storage.market.get_index_etag', () {
      final etag = _getSetting('$_etagKeyPrefix$sourceId');
      final refreshedRaw = _getSetting('$_refreshedKeyPrefix$sourceId');
      final refreshedAt = refreshedRaw == null ? null : int.tryParse(refreshedRaw);
      if (etag == null && refreshedAt == null) return null;
      return (etag: etag, refreshedAt: refreshedAt);
    });
  }

  // --- settings KV 直读（避免与 SettingsRepository 耦合） ---

  String? _getSetting(String key) {
    final rs = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String;
  }

  void _setSetting(String key, String value) {
    db.execute('''
      INSERT INTO settings (key,value) VALUES (?,?)
      ON CONFLICT(key) DO UPDATE SET value=excluded.value
    ''', [key, value]);
  }

  void _removeSetting(String key) {
    db.execute('DELETE FROM settings WHERE key = ?', [key]);
  }

  // -------------------------------------------------------------------------
  // 内部工具
  // -------------------------------------------------------------------------

  /// 执行 [body]，把任何异常归一化为 [StorageError]（不泄漏 `SqliteException`）。
  T _guard<T>(String code, T Function() body) {
    try {
      return body();
    } catch (e) {
      if (e is StorageError) rethrow;
      throw normalizeStorageError(code, e);
    }
  }
}
