// 一次性探针：复现「人生导师」添加流程（下载 → 校验），定位"点击添加没反应"根因。
// 跑完即删，不入库。
import 'dart:io';
import 'package:sqlite3/open.dart' show open, overrideFor;
import 'package:sqlite3/src/platform.dart' show OperatingSystem;
import 'dart:ffi' show DynamicLibrary;
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:advisor_core/advisor_core.dart' show SecretStore;

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
  @override
  Future<List<String>> keys() async => const [];
  @override
  Future<bool> contains(String ref) async => false;
}

Future<void> main(List<String> args) async {
  overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  final home = Platform.environment['APPDATA']!;
  final dataDir = '$home/com.example/private_advisor/PrivateAdvisor';
  final db = openAdvisorDatabase('${dataDir.path}/database/advisor.sqlite');
  final repos = sqliteRepositories(db, secrets: _NoSecrets());

  final pkgs = await repos.market.listPackages();
  print('DB 市场包数：${pkgs.length}');
  final p = pkgs.where((x) => x.slug == 'life-mentor').toList();
  if (p.isEmpty) {
    print('❌ DB 里没有 life-mentor');
    return;
  }
  final pkg = p.first;
  final v = pkg.latest!;
  print('包：${pkg.displayName}  version=${v.version}');
  print('   索引 sha256 = ${v.sha256}');
  print('   releaseUrl  = ${v.releaseUrl}');
  print('   emoji=${pkg.emoji} color=${pkg.color} profession=${pkg.profession}');

  // 1) 下载（与 app 同一 URL）
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(v.releaseUrl));
  final resp = await req.close();
  print('下载 HTTP=${resp.statusCode}');
  if (resp.statusCode != 200) {
    print('❌ 下载失败');
    client.close();
    return;
  }
  final bytes = <int>[];
  await for (final chunk in resp) {
    bytes.addAll(chunk);
  }
  print('下载字节 = ${bytes.length}');
  final zipSha = 'n/a';
  print('zip 字节 sha256 = $zipSha  （与索引 sha256 相同？${zipSha == v.sha256}）');

  // 2) 校验编排（与 app 同一 flow）
  final flow = MarketInstallFlow();
  final installDir = '${dataDir}/market/packages/${pkg.slug}-${v.version}';
  final outcome = await flow.runFromBytes(
    packageBytes: bytes,
    expectedSha256: v.sha256,
    installDir: installDir,
    writeFiles: false,
  );
  print('校验 ok=${outcome.ok}');
  print('   installDir=$installDir');
  print('   installPath=${outcome.installPath}');
  print('   verification=${outcome.verification}');
  print('   systemPrompt 长度=${outcome.systemPrompt.length}');
  print('   manifest.slug=${outcome.manifest.slug} version=${outcome.manifest.version}');
  print('   manifest.packageId=${outcome.manifest.packageId}');
  for (final s in outcome.verification.steps) {
    print('   step ${s.name}: ${s.passed ? "PASS" : "FAIL"} ${s.detail}');
  }
  client.close();
  db.dispose();
}
