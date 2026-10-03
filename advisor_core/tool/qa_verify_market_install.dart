/// QA 独立验证脚本（严过关）——executive-assistant（总裁助理）端到端安装链路。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_market_install.dart`
///
/// 覆盖（第 6 轮 T04 依赖市场包）：
///   下载产物(.expert) → 解包 → **客户端 PackageVerifier 校验**（逐文件+整包 sha256、
///   schema、大小、路径安全）→ 市场口径 sha256 == 契约值 → 安装落库（package_id）
///   → 加入群聊 → 设为组长；
/// 反向用例：翻转 1 bit → 校验必拒；注入未声明文件 → 校验必拒；Zip Slip 路径 → 拒绝。
///
/// 只读取 / 调用生产代码，不修改任何生产代码；不写真实安装目录。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

int _pass = 0, _fail = 0;
void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  ok ? _pass++ : _fail++;
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

const String kExpectedSha =
    '80669a528a23f5cc1bae3709fb5a46b59cfe488bd627389837babc61c949e5f0';
const String kPackageId = 'org.private-advisor.executive-assistant';

File? _locateExpert() {
  final candidates = <String>[
    'market/dist/executive-assistant-1.0.0.expert',
    '../market/dist/executive-assistant-1.0.0.expert',
  ];
  try {
    final repoRoot = File.fromUri(Platform.script).parent.parent;
    candidates.add('${repoRoot.path}${Platform.pathSeparator}market'
        '${Platform.pathSeparator}dist'
        '${Platform.pathSeparator}executive-assistant-1.0.0.expert');
  } catch (_) {}
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  return null;
}

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验证（executive-assistant 端到端）');
  stdout.writeln('=' * 62);

  final expertFile = _locateExpert();
  if (expertFile == null) {
    stdout.writeln('✗ 未找到 executive-assistant-1.0.0.expert');
    exitCode = 1;
    return;
  }
  stdout.writeln('包 = ${expertFile.path}');

  // ---- 1. 解包（模拟客户端下载后）
  final zip = OoxmlZip.openBytes(expertFile.readAsBytesSync());
  section('1 解包与载荷构造');
  final names = zip.fileNames()..sort();
  t('1.1', '包内文件含 manifest/README/agents/expert', true,
      names.contains('manifest.json') &&
          names.contains('README.md') &&
          names.contains('agents/main.md') &&
          names.contains('expert.json'),
      note: 'names=$names');

  final entries = <PackageEntry>[
    for (final e in zip.files) PackageEntry(path: e.name, bytes: Uint8List.fromList(e.content)),
  ];
  final payload = PackagePayload(entries);
  final manifest = PackageManifest.parse(zip.readText('manifest.json')!);

  // ---- 2. 客户端校验链
  section('2 客户端 PackageVerifier 校验（下载产物）');
  final verification = PackageVerifier.verify(payload: payload, manifest: manifest);
  stdout.writeln(verification.report());
  t('2.1', '整体校验通过', true, verification.ok,
      note: verification.ok ? null : '首个失败=${verification.firstFailure?.name}');
  for (final step in verification.steps) {
    t('2.2', '步骤通过：${step.name}', true, step.passed);
  }

  // ---- 3. 口径与契约值
  section('3 哈希口径 == 契约值');
  t('3.1', 'manifest.sha256 = 契约值', kExpectedSha, manifest.sha256);
  t('3.2', 'packageId', kPackageId, manifest.packageId);
  t('3.3', '客户端复算整包哈希 == manifest（口径一致）', manifest.sha256,
      PackageManifest.computePackageHash(manifest.files));

  // ---- 4. 反向：翻转 1 bit → 必拒
  section('4 反向用例：篡改 / 注入 / 路径');
  final tampered = List<PackageEntry>.from(entries);
  final ri = tampered.indexWhere((e) => e.path == 'README.md');
  final rb = Uint8List.fromList(tampered[ri].bytes);
  rb[rb.length ~/ 2] ^= 0x01;
  tampered[ri] = PackageEntry(path: 'README.md', bytes: rb);
  final vTamper = PackageVerifier.verify(payload: PackagePayload(tampered), manifest: manifest);
  t('4.1', '翻转 1 bit → 校验失败', false, vTamper.ok);
  t('4.2', '失败点在 SHA256 Verify 步骤', true,
      vTamper.steps.any((s) => s.name.contains('SHA256') && !s.passed),
      note: 'fail=${vTamper.firstFailure?.name} ${vTamper.firstFailure?.detail}');

  // 注入未声明文件
  final injected = List<PackageEntry>.from(entries)
    ..add(PackageEntry(path: 'evil.txt', bytes: Uint8List.fromList([1, 2, 3])));
  final vInject =
      PackageVerifier.verify(payload: PackagePayload(injected), manifest: manifest);
  t('4.3', '注入未声明文件 → 校验失败', false, vInject.ok);

  // Zip Slip / 绝对路径 / 盘符
  t('4.4', 'Zip Slip “../x” 被拒', true, ZipPathSafety.reject('../etc/passwd') != null);
  t('4.5', '绝对路径被拒', true, ZipPathSafety.reject('/etc/passwd') != null);
  t('4.6', '盘符被拒', true, ZipPathSafety.reject(r'C:\x') != null);
  t('4.7', '正常相对路径放行', null, ZipPathSafety.reject('agents/main.md'));

  // ---- 5. 安装落库（内存仓储）
  section('5 安装落库 → 专家 package_id');
  final repos = inMemoryRepositories();
  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);
  final market = MarketService(repos, experts: experts);

  final systemPrompt = zip.readText('agents/main.md') ?? '';
  final installed = await market.installPackage(
    manifest: manifest,
    verification: verification,
    systemPrompt: systemPrompt,
    installPath: '/tmp/executive-assistant',
  );
  t('5.1', '安装后专家 package_id 正确', kPackageId, installed.packageId);
  t('5.2', 'source = market', ExpertSource.market, installed.source);
  t('5.3', 'displayName=总裁助理', '总裁助理', installed.name);
  t('5.4', '已安装记录可查（package_id）', kPackageId,
      (await repos.market.getInstalledByPackageId(kPackageId))?.packageId);
  t('5.5', 'runtime_config 已建', true, (await repos.experts.getRuntimeConfig(installed.id)) != null);

  // 未通过校验的包不得安装（且**不落库**）
  final expertsBefore = (await repos.experts.listExperts()).length;
  final installedBefore = (await repos.market.listInstalled()).length;
  var threw = false;
  try {
    await market.installPackage(
      manifest: manifest,
      verification: vTamper,
      systemPrompt: systemPrompt,
      installPath: '/tmp/x',
    );
  } catch (_) {
    threw = true;
  }
  t('5.6', '校验未通过时 installPackage 拒绝', true, threw);
  t('5.7', '拒绝后专家数不变（不落库）', expertsBefore,
      (await repos.experts.listExperts()).length);
  t('5.8', '拒绝后已安装记录数不变（不落库）', installedBefore,
      (await repos.market.listInstalled()).length);

  // ---- 6. 加入群聊并设为组长
  section('6 加入群聊 → 设为组长');
  final conv = await conversations.createGroup(
    title: '总裁办',
    expertIds: [installed.id],
  );
  final group = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: KnowledgeService(
      repos,
      parsers: [PlainTextParser()],
      chunker: SimpleChunker(),
      vectorStore: InMemoryVectorStore(repos.knowledge),
      retriever: InMemoryRetriever(repos.knowledge),
    ),
    llmFactory: (_) => ScriptedLlmProvider(),
  );
  await group.addMember(conv.id, 'helperE');
  await group.setLeader(conv.id, installed.id);
  final members = await conversations.members(conv.id);
  t('6.1', '群成员数=2', 2, members.length);
  t('6.2', '总裁助理被设为组长', installed.id, await group.leaderId(conv.id));
  t('6.3', '全群恰好 1 名组长', 1,
      members.where((m) => m.role == MemberRole.leader).length);

  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('合计：通过 $_pass ／ 失败 $_fail');
  exitCode = _fail == 0 ? 0 : 1;
}
