/// QA 独立验收脚本（严过关 · 任务 #69 专家导入/导出）—— **证伪导向**。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_expert_bundle.dart`
///
/// 与工程师的 `verify_expert_bundle.dart` **相互独立**：本脚本只读取 / 调用生产代码，
/// 不修改任何生产代码，不引用其断言措辞；重点攻击其**未覆盖**的对抗面：
///   1. 密钥外泄：解包后对**全部文件** grep，证明文 Key 零出现（不只是 profile）。
///   2. 导入拒收密钥：**profile.json 内嵌 sk-** 必须拒；且 valid 包的 manifest
///      `sha256`(64hex) **不得**被误判为「长随机串」（证明 manifest 排除真生效）。
///      （§2f 反向断言：真赋值形态仍必须被拒，防「收窄正则时把防线改没」。）
///   3. 路径穿越：`../` / `/abs/` / `C:\` 三形态全拒。
///   4. 哈希篡改：内容篡改 / 整包 sha 篡改 / files[].sha 篡改 三种向量全拒
///      （整包口径 = seal 内容口径 `path\0sha\n`，已自证与生产同值，不用错口径）。
///   5. 版本兼容：高拒（含理由）、低接并补齐默认值。
///   6. 冲突三策略：默认副本（新 id + 「（导入 2）」+ 不带绑定）/ 跳过（不落库）/
///      覆盖（保留原 id + createdAt + source）。
///   7. 单条原子性：新副本失败 + **覆盖失败**（工程师未覆盖的重灾区）→ 直接查 5 集合。
///   8. 往返一致：导出→导入→再导出，内容口径哈希相等。
///   9. 边界：空 zip / 缺 manifest / 缺 entry / expert.json 缺字段 / emoji & 超长名 /
///      批量部分失败。
///  10. UI 静态：导出默认不勾、入口仅在通讯录（真交互无法验证，如实声明）。
///
/// **状态：全部断言预期为绿（含 §2e 防回归、§2f 反向防过宽）。** §2e 曾以红态记录
/// 一处真实缺陷（赋值式密钥正则过宽误伤英文散文），工程师已收窄修复，本脚本据此转绿；
/// §2f 为新增的反向护栏，确保修复未把密钥防线一并改没。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:archive/archive.dart' as arc;
import 'package:crypto/crypto.dart' as crypto;

// ---------------------------------------------------------------------------
// 迷你断言框架
// ---------------------------------------------------------------------------

class Case {
  Case(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name, expected, actual;
  final bool pass;
  final String? note;
}

final List<Case> _res = [];
int _pass = 0, _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _res.add(Case(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// 独立实现 seal 内容口径哈希（`path\0sha256hex\n` 字典序拼接后再 sha256）。
///
/// 与生产 `PackageManifest.computePackageHash` / `contentHashFromPayload`
/// **逐字同口径**；本脚本用它构造 fixture，并在 §0 自证与生产同值——
/// 避免"用错口径（ZIP 字节哈希）得出假结论"。
String _sealHashFiles(List<({String path, Uint8List bytes})> files) {
  final rows = [
    for (final f in files) (path: f.path, sha: crypto.sha256.convert(f.bytes).toString()),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final buf = StringBuffer();
  for (final r in rows) {
    buf.write(r.path);
    buf.write('\u0000');
    buf.write(r.sha);
    buf.write('\n');
  }
  return crypto.sha256.convert(utf8.encode(buf.toString())).toString();
}

Uint8List _zip(List<({String path, Uint8List bytes})> files) {
  final a = arc.Archive();
  for (final f in files) {
    a.addFile(arc.ArchiveFile(f.path, f.bytes.length, f.bytes));
  }
  return Uint8List.fromList(arc.ZipEncoder().encode(a)!);
}

Map<String, Uint8List> _unzip(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final a = arc.ZipDecoder().decodeBytes(data);
  final out = <String, Uint8List>{};
  for (final f in a.files) {
    if (f.isFile) out[f.name] = _fb(f);
  }
  return out;
}

Uint8List _fb(arc.ArchiveFile f) {
  final c = f.content;
  if (c is Uint8List) return c;
  return Uint8List.fromList(List<int>.from(c as List<int>));
}

/// 手工构造一个 `.expert` 包（manifest 的哈希用**本脚本**口径计算）。
({Uint8List bytes, String manifestJson}) _buildPackage({
  required Map<String, Uint8List> files,
  String entry = 'agents/main.md',
  String packageId = 'org.private-advisor.test',
  String slug = 'test-expert',
  String version = '1.0.0',
  String displayName = '测试专家',
  String appVersion = '>=1.3.0',
  Map<String, dynamic>? capabilitiesOverride,
  bool includeExpertJson = true,
}) {
  final entriesList = <({String path, Uint8List bytes})>[
    for (final e in files.entries) (path: e.key, bytes: e.value),
  ];
  final manifest = <String, dynamic>{
    'schemaVersion': 1,
    'packageId': packageId,
    'slug': slug,
    'version': version,
    'appVersion': appVersion,
    'displayName': displayName,
    'categoryId': '12-IndustryConsultant',
    'entry': entry,
    'capabilities': capabilitiesOverride ??
        {'network': false, 'filesystem': false, 'shell': false, 'tools': false},
    'sha256': _sealHashFiles(entriesList),
    'files': [
      for (final f in entriesList)
        {
          'path': f.path,
          'sha256': crypto.sha256.convert(f.bytes).toString(),
        },
    ],
    'publishedAt': 1,
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  final a = arc.Archive();
  a.addFile(arc.ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  for (final f in entriesList) {
    a.addFile(arc.ArchiveFile(f.path, f.bytes.length, f.bytes));
  }
  return (
    bytes: Uint8List.fromList(arc.ZipEncoder().encode(a)!),
    manifestJson: jsonEncode(manifest),
  );
}

/// 一个「最小合法」包成员集合（expert.json + agents/main.md）。
Map<String, Uint8List> _benignFiles({String name = '人类学家', String prompt = '你是人类学家，研究文化。'}) => {
      'expert.json': _b(jsonEncode({'displayName': name})),
      'agents/main.md': _b(prompt),
      'README.md': _b('# $name\n'),
    };

Repositories _reposWith(ExpertRepository experts) {
  final messages = InMemoryMessageRepository();
  return Repositories(
    experts: experts,
    groups: InMemoryGroupRepository(),
    conversations: InMemoryConversationRepository(messages: messages),
    messages: messages,
    generations: InMemoryGenerationRepository(),
    knowledge: InMemoryKnowledgeRepository(),
    providers: InMemoryProviderRepository(),
    credentials: InMemoryCredentialRepository(),
    secrets: InMemorySecretStore(),
    market: InMemoryMarketRepository(),
    settings: InMemorySettingsRepository(),
    jobs: InMemoryJobRepository(),
    attachments: InMemoryAttachmentRepository(),
  );
}

/// 播种：1 位自建专家（可选运行配置 / 用户状态 / 标签 / 知识库绑定 / 凭据）。
Future<({Expert expert, KnowledgeBase? kb, CredentialProfile? cred})> _seedExpert(
  Repositories repos, {
  String name = '招标文件解读专家',
  String prompt = '你是政府采购与招投标顾问，逐条响应招标要求。',
  String profession = '政府采购与招投标顾问',
  bool withProfile = true,
  String? kbName,
  String apiKey = 'sk-live-SUPERSECRET-abcdefghijklmnop1234567890',
}) async {
  final experts = ExpertService(repos);
  final providers = ProviderService(repos);
  final credentials = CredentialService(repos);

  await providers.registerBuiltins();
  final cred = await credentials.saveDefault(
    apiKey: apiKey,
    providerProfileId: ProviderService.deepseekProviderId,
    name: '默认凭据',
  );

  final expert = await experts.createLocal(
    name: name,
    systemPrompt: prompt,
    profession: profession,
    quickPrompts: const ['拆解这份招标文件'],
    welcomeMessage: '把文件发我。',
  );
  await experts.setTags(expert.id, ['招标文件', '资格条件']);

  if (withProfile) {
    await experts.updateRuntimeConfig(ExpertRuntimeConfig(
      expertId: expert.id,
      modelProfileId: 'mp_deepseek_chat',
      credentialProfileId: cred.id,
      temperature: 0.2,
      topP: 0.9,
      maxTokens: 2048,
      groundingPolicy: GroundingPolicy.preferred,
    ));
    await experts.updateUserState(ExpertUserState(
      expertId: expert.id,
      remark: '老王',
      styleId: 'professional',
      pinned: true,
    ));
  }

  KnowledgeBase? kb;
  if (kbName != null) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final created = KnowledgeBase(
        id: Ids.next('kb'), name: kbName, createdAt: now, updatedAt: now);
    await repos.knowledge.upsertBase(created);
    kb = created;
    await experts.bindKnowledge(expert.id, created.id, topK: 3, threshold: 0.4);
  }
  return (expert: expert, kb: kb, cred: cred);
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验收（任务 #69 专家导入/导出）');
  stdout.writeln('=' * 62);
  stdout.writeln('dart = ${Platform.version}');

  _t0SealHashParity();
  await _t1SecretNeverExported();
  await _t2ImportRejectsSecret();
  await _t3PathTraversal();
  await _t4HashTamper();
  await _t5VersionCompat();
  await _t6ConflictStrategies();
  await _t7SingleItemAtomicity();
  await _t8RoundTripStable();
  await _t9Boundaries();
  _t10UiStaticReview();

  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// 0. 哈希口径自证（防「用错口径」）
// ---------------------------------------------------------------------------

void _t0SealHashParity() {
  section('0 哈希口径自证（本脚本 seal 口径 == 生产 computePackageHash）');

  final entries = <({String path, Uint8List bytes})>[
    (path: 'agents/main.md', bytes: _b('提示词正文')),
    (path: 'expert.json', bytes: _b('{"displayName":"A"}')),
  ];
  final mine = _sealHashFiles(entries);
  final prod = PackageManifest.contentHashFromPayload(
    [for (final e in entries) PackageEntry(path: e.path, bytes: e.bytes)],
  );
  t('0.1', 'seal 口径与生产 contentHashFromPayload 同值', true, mine == prod,
      note: 'mine=$mine prod=$prod');
  // 反向：ZIP 字节哈希 ≠ seal 口径（证明两者确实不同，不能用错）
  final zipBytes = _zip(entries);
  final zipHash = crypto.sha256.convert(zipBytes).toString();
  t('0.2', 'ZIP 字节哈希 ≠ seal 内容口径（口径不可混用）', false,
      zipHash == mine);
}

// ---------------------------------------------------------------------------
// 1. 密钥外泄：导出包全文件 grep
// ---------------------------------------------------------------------------

Future<void> _t1SecretNeverExported() async {
  section('1 密钥外泄：解包后全文件 grep（红线）');

  const secret = 'sk-live-SUPERSECRET-abcdefghijklmnop1234567890';
  final repos = inMemoryRepositories();
  final seeded = await _seedExpert(repos, kbName: '投标知识库', apiKey: secret);

  final result = await ExpertExportService(repos)
      .build(expertIds: [seeded.expert.id], includeLocal: true);

  final inner = _unzip(result.bytes);
  // 全部文件内容拼在一起（含 manifest.json）后 grep。
  final all = inner.entries.map((e) {
    // 头像 / 二进制按 latin1 近似（本用例无头像）；文本按 utf8。
    try {
      return utf8.decode(e.value);
    } catch (_) {
      return String.fromCharCodes(e.value);
    }
  }).join('\n');

  t('1.1', '全文件不含明文 Key（sk-live-…）', false, all.contains(secret));
  t('1.2', '全文件不含 Key 的主体片段（SUPERSECRET）', false,
      all.contains('SUPERSECRET'));
  final secretRef = seeded.cred!.secretRef;
  t('1.3', '全文件不含 SecretStore 的 secretRef', false, all.contains(secretRef));

  final profileText = utf8.decode(inner['profile.json']!);
  final profile = ExpertProfile.parse(profileText);
  // 正向控制：引用名必须在（证明不是"整段没导"）
  t('1.4', 'profile 只写凭据引用名（正向控制）', '默认凭据',
      profile.runtime?.credentialRefName);
  t('1.5', 'profile 不含明文 Key', false, profileText.contains(secret));
  t('1.6', '导出包清单含 profile.json（确已带本机设置）', true,
      inner.containsKey('profile.json'));
}

// ---------------------------------------------------------------------------
// 2. 导入拒收密钥 + manifest 哈希不误判
// ---------------------------------------------------------------------------

Future<void> _t2ImportRejectsSecret() async {
  section('2 导入拒收密钥（profile.json 内嵌）+ manifest 哈希不误判');

  // 2a：profile.json 内嵌 sk- 密钥 → 拒绝
  final withSecretProfile = _buildPackage(
    files: {
      'expert.json': _b(jsonEncode({'displayName': '暗藏密钥专家'})),
      'agents/main.md': _b('你是普通助手。'),
      'profile.json': _b(jsonEncode({
        'specVersion': 1,
        'runtime': {'credentialRefName': 'x', 'apiKey': 'sk-abcdefghijklmnop1234'},
      })),
    },
    displayName: '暗藏密钥专家',
    slug: 'secret-profile-expert',
  );
  final plan2a = await ExpertImportService(inMemoryRepositories()).plan(withSecretProfile.bytes);
  t('2a.1', 'profile.json 内嵌 sk- → rejected', true, plan2a.items.first.isRejected);
  t('2a.2', '拒绝理由含「密钥」', true,
      plan2a.items.first.reason?.contains('密钥') ?? false,
      note: plan2a.items.first.reason);
  final rep2a = await ExpertImportService(inMemoryRepositories()).apply(plan2a);
  t('2a.3', '含密钥不计入成功', 0, rep2a.success);

  // 2b：agents/main.md 含 Bearer 令牌 → 拒绝
  final withBearer = _buildPackage(
    files: {
      'expert.json': _b(jsonEncode({'displayName': 'Bearer专家'})),
      'agents/main.md': _b('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9abcdefghijklmnop'),
    },
    displayName: 'Bearer专家',
    slug: 'bearer-expert',
  );
  final plan2b = await ExpertImportService(inMemoryRepositories()).plan(withBearer.bytes);
  t('2b.1', 'agents/main.md 含 Bearer → rejected', true, plan2b.items.first.isRejected);

  // 2c：**valid 包的 manifest sha256(64hex) 不得被误判**（证明 manifest 排除生效）
  final valid = _buildPackage(files: _benignFiles());
  // 先自证：manifest 文本本身确实命中「长随机串」扫描
  t('2c.1', 'manifest 文本本身命中「长随机串」扫描（前置事实）', true,
      SecretLeakScan.contains(valid.manifestJson));
  final plan2c = await ExpertImportService(inMemoryRepositories()).plan(valid.bytes);
  t('2c.2', 'valid 包不被误判 → ready（manifest 排除生效）', true,
      plan2c.items.first.isReady,
      note: plan2c.items.first.isRejected ? plan2c.items.first.reason : 'ready');

  // 2d：profile.json 里合法的 modelProfileRef（如 mp_deepseek_chat）不该误伤
  final withRef = _buildPackage(
    files: {
      ..._benignFiles(name: '引用专家'),
      'profile.json': _b(jsonEncode({
        'specVersion': 1,
        'runtime': {'modelProfileRef': 'mp_deepseek_chat', 'credentialRefName': '默认凭据'},
      })),
    },
    displayName: '引用专家',
    slug: 'ref-expert',
  );
  final plan2d = await ExpertImportService(inMemoryRepositories()).plan(withRef.bytes);
  t('2d.1', '合法引用名（非密钥）→ ready', true, plan2d.items.first.isReady,
      note: plan2d.items.first.reason);

  // 2e：**赋值式密钥正则的误伤面**（曾由本脚本证伪的真实缺陷；现已修复）——
  // 旧模式 `(?:...|secret|passwd|password|...)[\s"']{0,4}[:=]`（大小写不敏感）仅
  // 要求「关键词 + 冒号/等号」、**不要求后面真有值**，会命中英文散文里的普通词
  // （如 "the secret: keep it"）→ 合法专家被拒 / 导出被中止。工程师已收窄为
  // 「关键词后必须紧跟长度达标的实值」，本组断言 2e.1/2e.2 现为**防回归**：
  // 合法（非密钥）内容**不应**被拒；若正则再被放宽，此处会重新转红。
  final benignEn = _buildPackage(
    files: {
      'expert.json': _b(jsonEncode({'displayName': '英文助手'})),
      'agents/main.md':
          _b('You are a careful assistant. Never reveal the user secret: keep it private.'),
    },
    displayName: '英文助手',
    slug: 'english-helper',
  );
  final plan2e = await ExpertImportService(inMemoryRepositories()).plan(benignEn.bytes);
  stdout.writeln('    · 2e 探针：合法英文提示词（含 "secret:"）导入判定 → '
      'status=${plan2e.items.first.status.name} reason=${plan2e.items.first.reason}');
  t('2e.1', '合法英文提示词（含普通词 secret:）不应被拒', false,
      plan2e.items.first.isRejected,
      note: plan2e.items.first.reason);

  // 2e.2 同一误伤在**导出侧**（`_scanOrThrow` 落 zip 前扫描）——用户可能无法导出自己的专家。
  final reposEn = inMemoryRepositories();
  final enExpert = await ExpertService(reposEn).createLocal(
      name: '英文助手', systemPrompt: 'Never reveal the user secret: keep it private.');
  var exportThrew = false;
  String? exportErr;
  try {
    await ExpertExportService(reposEn).build(expertIds: [enExpert.id]);
  } catch (e) {
    exportThrew = true;
    exportErr = '$e';
  }
  stdout.writeln('    · 2e.2 探针：合法英文提示词导出 → ' +
      (exportThrew ? '被中止：$exportErr' : '成功'));
  t('2e.2', '合法英文提示词应可导出（不应被中止）', false, exportThrew,
      note: exportErr);

  // 2f：**反向断言——防「修复过宽」**（team-lead 要求）。
  // 收窄正则不能把防线一并改没：真正的赋值形态仍必须被判为密钥；纯散文必须放行。
  // 2f.1–2f.5 打在**生产谓词** `SecretLeakScan.contains` 上（判定核心，最精确）；
  // 2f.6 / 2f.7 走**端到端**（导入拒绝 / 导出中止），证接线层同样生效。
  t('2f.1', '真赋值（API_KEY=sk-abcdef123456）仍被判密钥', true,
      SecretLeakScan.contains('API_KEY=sk-abcdef123456'));
  t('2f.2', '真赋值（password=hunter2xyzabc）仍被判密钥', true,
      SecretLeakScan.contains('password=hunter2xyzabc'));
  t('2f.3', '真赋值（行首大写键 SECRET: 8f3a9c2b7d1e）仍被判密钥', true,
      SecretLeakScan.contains('SECRET: 8f3a9c2b7d1e'));
  t('2f.4', '对照：英文散文含普通词 secret:（后带空格）必须放行', false,
      SecretLeakScan.contains('Never reveal the user secret: keep it private.'));
  t('2f.5', '对照：散文含普通词 password:（后带空格）必须放行', false,
      SecretLeakScan.contains('Set a strong password: use a long passphrase.'));

  // 2f.6 E2E 导入：包内含真赋值 → 必须 rejected（理由含「密钥」）。
  final leaky = _buildPackage(
    files: {
      'expert.json': _b(jsonEncode({'displayName': '泄密专家'})),
      'agents/main.md': _b('配置示例：\nAPI_KEY=sk-abcdef123456\n结束。'),
    },
    displayName: '泄密专家',
    slug: 'leaky-expert',
  );
  final planLeaky = await ExpertImportService(inMemoryRepositories()).plan(leaky.bytes);
  t('2f.6', 'E2E 导入：真赋值内容 → rejected', true, planLeaky.items.first.isRejected,
      note: planLeaky.items.first.reason);

  // 2f.7 E2E 导出：专家提示词含真赋值 → 必须中止导出（抛 export.secret）。
  final reposLeak = inMemoryRepositories();
  final leakyExpert = await ExpertService(reposLeak).createLocal(
      name: '泄密专家', systemPrompt: 'API_KEY=sk-abcdef123456');
  var leakExportThrew = false;
  String? leakExportErr;
  try {
    await ExpertExportService(reposLeak).build(expertIds: [leakyExpert.id]);
  } catch (e) {
    leakExportThrew = true;
    leakExportErr = '$e';
  }
  t('2f.7', 'E2E 导出：真赋值内容 → 中止导出', true, leakExportThrew,
      note: leakExportErr);
}

// ---------------------------------------------------------------------------
// 3. 路径穿越
// ---------------------------------------------------------------------------

Future<void> _t3PathTraversal() async {
  section('3 路径穿越（../  /abs/  C:\\ 三形态）');

  Future<void> attack(String evilPath, String id) async {
    final pkg = _buildPackage(
      files: {
        ..._benignFiles(name: '越界专家'),
        evilPath: _b('逃逸内容'),
      },
      displayName: '越界专家',
      slug: 'slip-expert',
    );
    final plan = await ExpertImportService(inMemoryRepositories()).plan(pkg.bytes);
    final it = plan.items.first;
    final r = it.reason ?? '';
    stdout.writeln('    · 「$evilPath」实际拒绝原因：$r');
    t(id, '「$evilPath」→ rejected', true, it.isRejected, note: r);
    // 安全类原因：Path Safety / 盘符 / 非法字符 / 逃逸，或（含盘符名部分平台被前序步骤拦）缺少文件
    final safeReason = r.contains('Path Safety') ||
        r.contains('盘符') ||
        r.contains('非法字符') ||
        r.contains('逃逸') ||
        r.contains('缺少文件') ||
        r.contains('未声明');
    t('$id.b', '「$evilPath」拒绝指向安全原因', true, safeReason, note: r);
  }

  await attack('../evil.txt', '3.1');
  await attack('/abs/evil.txt', '3.2');
  await attack(r'C:\evil.txt', '3.3');
}

// ---------------------------------------------------------------------------
// 4. 哈希篡改
// ---------------------------------------------------------------------------

Future<void> _t4HashTamper() async {
  section('4 哈希篡改（内容 / 整包 sha / files[].sha 三向量）');

  // 4a：内容改一字节，manifest 原封不动 → SHA256 拦截
  final good = _buildPackage(files: _benignFiles(name: '篡改专家'), slug: 'tamper-expert');
  final files = _unzip(good.bytes);
  final tampered = _zip([
    for (final e in files.entries)
      (path: e.key, bytes: e.key == 'agents/main.md' ? _b('被篡改的内容。') : e.value),
  ]);
  final plan4a = await ExpertImportService(inMemoryRepositories()).plan(tampered);
  t('4a.1', '内容篡改 → rejected', true, plan4a.items.first.isRejected);
  t('4a.2', '失败点含 SHA256', true,
      plan4a.items.first.reason?.contains('SHA256') ?? false,
      note: plan4a.items.first.reason);

  // 4b：manifest.sha256（整包）被改成全 0，其余不动 → 整包哈希不符
  final manifest = jsonDecode(good.manifestJson) as Map<String, dynamic>;
  manifest['sha256'] = '0' * 64;
  final bytes4b = _rezipWithManifest(files, manifest);
  final plan4b = await ExpertImportService(inMemoryRepositories()).plan(bytes4b);
  t('4b.1', '整包 sha256 篡改 → rejected', true, plan4b.items.first.isRejected);
  t('4b.2', '失败点含整包哈希', true,
      plan4b.items.first.reason?.contains('整包哈希') ?? false,
      note: plan4b.items.first.reason);

  // 4c：仅 files[].sha256 篡改，且整包 sha 按篡改后的 files[] 重算 → 逐文件不符
  final m4c = jsonDecode(good.manifestJson) as Map<String, dynamic>;
  final fl = (m4c['files'] as List).cast<Map<String, dynamic>>();
  fl.firstWhere((f) => f['path'] == 'agents/main.md')['sha256'] = '0' * 64;
  m4c['files'] = fl;
  // 用「假的 files[]」重算整包 sha（seal 口径），使整包哈希自洽 → 只剩逐文件不符
  final fakeRows = [
    for (final f in fl) (path: f['path'] as String, sha: f['sha256'] as String),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final buf = StringBuffer();
  for (final r in fakeRows) {
    buf..write(r.path)..write('\u0000')..write(r.sha)..write('\n');
  }
  m4c['sha256'] = crypto.sha256.convert(utf8.encode(buf.toString())).toString();
  final bytes4c = _rezipWithManifest(files, m4c);
  final plan4c = await ExpertImportService(inMemoryRepositories()).plan(bytes4c);
  t('4c.1', 'files[].sha 篡改（整包自洽）→ rejected', true, plan4c.items.first.isRejected);
  t('4c.2', '失败点含「哈希不符」', true,
      plan4c.items.first.reason?.contains('哈希不符') ?? false,
      note: plan4c.items.first.reason);
}

Uint8List _rezipWithManifest(Map<String, Uint8List> files, Map<String, dynamic> manifest) {
  final mb = utf8.encode(jsonEncode(manifest));
  final a = arc.Archive();
  a.addFile(arc.ArchiveFile('manifest.json', mb.length, mb));
  for (final e in files.entries) {
    if (e.key == 'manifest.json') continue;
    a.addFile(arc.ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(arc.ZipEncoder().encode(a)!);
}

// ---------------------------------------------------------------------------
// 5. 版本兼容
// ---------------------------------------------------------------------------

Future<void> _t5VersionCompat() async {
  section('5 版本兼容（高拒 / 低接补齐）');

  final high = _buildPackage(
    files: {
      ..._benignFiles(name: '未来专家'),
      'profile.json': _b(jsonEncode({'specVersion': 2, 'exportedAt': 1})),
    },
    displayName: '未来专家',
    slug: 'future-expert',
  );
  final planH = await ExpertImportService(inMemoryRepositories()).plan(high.bytes);
  t('5.1', 'specVersion=2 → rejected', true, planH.items.first.isRejected);
  t('5.2', '理由含「更新版本」+「请升级」', true,
      (planH.items.first.reason?.contains('更新版本') ?? false) &&
          (planH.items.first.reason?.contains('请升级') ?? false),
      note: planH.items.first.reason);

  final low = _buildPackage(
    files: {
      ..._benignFiles(name: '旧版专家'),
      'profile.json': _b(jsonEncode({'specVersion': 0, 'exportedAt': 1})),
    },
    displayName: '旧版专家',
    slug: 'legacy-expert',
  );
  final reposL = inMemoryRepositories();
  final svcL = ExpertImportService(reposL);
  final planL = await svcL.plan(low.bytes);
  t('5.3', 'specVersion=0 → 不拒', true, !planL.items.first.isRejected,
      note: planL.items.first.reason);
  t('5.4', '低版本判定 = older', SpecCompat.older, planL.items.first.compat);
  final repL = await svcL.apply(planL);
  t('5.5', '低版本仍导入成功', 1, repL.added);
  t('5.6', '结果记「旧版规范」提示', true,
      repL.results.first.notes.any((n) => n.contains('旧版规范')),
      note: '${repL.results.first.notes}');
  final importedL = (await ExpertService(reposL).list()).single;
  t('5.7', '缺失运行配置补默认（接地=off）', GroundingPolicy.off,
      (await reposL.experts.getRuntimeConfig(importedL.id))?.groundingPolicy);

  // 无 profile → 默认同版本
  final none = _buildPackage(files: _benignFiles(name: '无档专家'), displayName: '无档专家', slug: 'nofile-expert');
  final planN = await ExpertImportService(inMemoryRepositories()).plan(none.bytes);
  t('5.8', '无 profile → compat=equal', SpecCompat.equal, planN.items.first.compat);
}

// ---------------------------------------------------------------------------
// 6. 冲突三策略
// ---------------------------------------------------------------------------

Future<void> _t6ConflictStrategies() async {
  section('6 冲突三策略（副本 / 跳过 / 覆盖）');

  // 源：导出「人类学家」带 profile（含知识库绑定）。
  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src, name: '人类学家', kbName: '投标知识库');
  final one = await ExpertExportService(src)
      .build(expertIds: [seeded.expert.id], includeLocal: true);

  // —— 默认（不传 decisions）= 新建副本 ——
  final copyRepos = inMemoryRepositories();
  final copySvcE = ExpertService(copyRepos);
  final original = await copySvcE.createLocal(name: '人类学家', systemPrompt: '既有占位。');
  final copySvc = ExpertImportService(copyRepos);
  final copyPlan = await copySvc.plan(one.bytes);
  t('6.1', '同名 → conflict', true, copyPlan.items.first.isConflict);
  final copyRep = await copySvc.apply(copyPlan); // 不传 decisions
  t('6.2', '默认策略 → 新增 1 位', 1, copyRep.added);
  final copyList = await copySvcE.list();
  final copyNew = copyList.where((e) => e.id != original.id).toList();
  t('6.3', '副本新 id（≠ 原 id）', true,
      copyNew.length == 1 && copyNew.first.id != original.id);
  t('6.4', '副本名带「（导入 2）」', true,
      copyNew.any((e) => e.name == '人类学家（导入 2）'),
      note: '${copyList.map((e) => e.name).toList()}');
  t('6.5', '副本不携带知识库绑定', 0,
      (await copyRepos.experts.listKnowledgeBindings(copyNew.first.id)).length);
  t('6.6', '副本 outcome=added', ImportOutcome.added, copyRep.results.first.outcome);

  // —— 跳过 ——
  final skipRepos = inMemoryRepositories();
  final skipSvcE = ExpertService(skipRepos);
  await skipSvcE.createLocal(name: '人类学家', systemPrompt: '旧。');
  final skipSvc = ExpertImportService(skipRepos);
  final skipPlan = await skipSvc.plan(one.bytes);
  final skipRep = await skipSvc.apply(skipPlan, decisions: {
    skipPlan.items.first.key: ConflictStrategy.skip,
  });
  t('6.7', '跳过 1 位', 1, skipRep.skipped);
  t('6.8', '跳过后库内仍 1 位（未落库）', 1, (await skipSvcE.list()).length);

  // —— 覆盖 ——
  final overRepos = inMemoryRepositories();
  final overSvcE = ExpertService(overRepos);
  final existing = await overSvcE.createLocal(
      name: '人类学家', systemPrompt: '旧提示词。', profession: '旧职业');
  await overSvcE.setTags(existing.id, ['旧标签']);
  final overSvc = ExpertImportService(overRepos);
  final overPlan = await overSvc.plan(one.bytes);
  final overRep = await overSvc.apply(overPlan, decisions: {
    overPlan.items.first.key: ConflictStrategy.overwrite,
  });
  t('6.9', '覆盖 1 位', 1, overRep.overwritten);
  final overList = await overSvcE.list();
  t('6.10', '覆盖后仍只有 1 位', 1, overList.length);
  t('6.11', '覆盖保留原 id', existing.id, overList.single.id);
  t('6.12', '覆盖更新内容（systemPrompt）', seeded.expert.systemPrompt,
      overList.single.systemPrompt);
  t('6.13', '覆盖保留 createdAt', existing.createdAt, overList.single.createdAt);
  t('6.14', '覆盖 outcome=overwritten', ImportOutcome.overwritten,
      overRep.results.first.outcome);

  // —— 冲突判定：slug 命中（不同名、同 slug）——
  final slugRepos = inMemoryRepositories();
  final slugSvcE = ExpertService(slugRepos);
  await slugSvcE.createLocal(name: 'humanist', systemPrompt: '占位'); // slug=humanist
  final slugPkg = _buildPackage(
    files: _benignFiles(name: 'Humanist'),
    displayName: 'Humanist',
    slug: 'humanist',
    packageId: 'org.private-advisor.local.humanist',
  );
  final slugPlan = await ExpertImportService(slugRepos).plan(slugPkg.bytes);
  t('6.15', '同 slug 不同名 → conflict（slug 命中）', true,
      slugPlan.items.first.isConflict,
      note: slugPlan.items.first.conflict?.kind.label);
}

// ---------------------------------------------------------------------------
// 7. 单条原子性（含工程师未覆盖的「覆盖失败」）
// ---------------------------------------------------------------------------

/// 可注入一次性失败的专家仓储。
class _FaultRepo extends InMemoryExpertRepository {
  String? failMethod;

  void _maybe(String m) {
    if (failMethod == m) {
      failMethod = null;
      throw const StorageError('test.write', '模拟落库中途失败');
    }
  }

  @override
  Future<void> upsertExpert(Expert expert) async {
    _maybe('upsertExpert');
    return super.upsertExpert(expert);
  }

  @override
  Future<void> upsertRuntimeConfig(ExpertRuntimeConfig config) async {
    _maybe('upsertRuntimeConfig');
    return super.upsertRuntimeConfig(config);
  }

  @override
  Future<void> upsertUserState(ExpertUserState state) async {
    _maybe('upsertUserState');
    return super.upsertUserState(state);
  }

  @override
  Future<void> setTags(String expertId, List<String> tagNames) async {
    _maybe('setTags');
    return super.setTags(expertId, tagNames);
  }

  @override
  Future<void> upsertKnowledgeBinding(ExpertKnowledgeBinding binding) async {
    _maybe('upsertKnowledgeBinding');
    return super.upsertKnowledgeBinding(binding);
  }
}

Future<void> _t7SingleItemAtomicity() async {
  section('7 单条原子性（新副本失败 + 覆盖失败 → 查 5 集合）');

  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src, name: '原子专家', kbName: '投标知识库');
  final one = await ExpertExportService(src)
      .build(expertIds: [seeded.expert.id], includeLocal: true);

  // 7a：全新导入（无冲突），在写 runtime 时失败 → 5 集合全空
  final fr = _FaultRepo()..failMethod = 'upsertRuntimeConfig';
  final reposA = _reposWith(fr);
  final svcA = ExpertImportService(reposA);
  final planA = await svcA.plan(one.bytes);
  final repA = await svcA.apply(planA);
  t('7a.1', '新副本中途失败 → 记失败 1 条', 1, repA.failed);
  t('7a.2', 'experts 无残留', 0, fr.experts.length);
  t('7a.3', 'runtime_configs 无残留', 0, fr.configs.length);
  t('7a.4', 'user_states 无残留', 0, fr.states.length);
  t('7a.5', 'tag_relations 无残留', 0, fr.tags.length);
  t('7a.6', 'knowledge_bindings 无残留', 0, fr.bindings.length);

  // 7b：**覆盖失败**（工程师未覆盖的重灾区）——
  // 目标机：既有专家 + 同名知识库；导入同专家并选覆盖，注入 upsertUserState 失败。
  // 注意：故障注入必须在**播种之后**设置，否则 createLocal 自身即触发。
  final fr2 = _FaultRepo();
  final reposB = _reposWith(fr2);
  // 目标机需要：同名 KB（供 S5 解析）+ 既有专家（含 cfg/state/tags/binding）。
  final now = DateTime.now().millisecondsSinceEpoch;
  final kb = KnowledgeBase(id: Ids.next('kb'), name: '投标知识库', createdAt: now, updatedAt: now);
  await reposB.knowledge.upsertBase(kb);
  final expertsB = ExpertService(reposB);
  final existing = await expertsB.createLocal(
      name: '原子专家', systemPrompt: '旧提示词。', profession: '旧职业');
  await reposB.experts.upsertRuntimeConfig(ExpertRuntimeConfig(
      expertId: existing.id, modelProfileId: 'mp_old', temperature: 0.1,
      groundingPolicy: GroundingPolicy.strict));
  await reposB.experts.upsertUserState(
      ExpertUserState(expertId: existing.id, remark: '旧备注', styleId: 'sharp'));
  await expertsB.setTags(existing.id, ['旧A', '旧B']);
  await reposB.experts.upsertKnowledgeBinding(ExpertKnowledgeBinding(
      expertId: existing.id, knowledgeBaseId: kb.id, priority: 9, topK: 9));

  fr2.failMethod = 'upsertUserState'; // 播种完成后再装故障
  final svcB = ExpertImportService(reposB);
  final planB = await svcB.plan(one.bytes);
  t('7b.1', '覆盖场景 → conflict', true, planB.items.first.isConflict);
  final repB = await svcB.apply(planB, decisions: {
    planB.items.first.key: ConflictStrategy.overwrite,
  });
  t('7b.2', '覆盖中途失败 → 记失败 1 条', 1, repB.failed);

  // 快照还原校验：既有专家应完整如初（不是半新半旧）
  final after = await reposB.experts.getExpert(existing.id);
  t('7b.3', '专家行仍在（未删除）', true, after != null);
  t('7b.4', '专家内容还原为旧值（systemPrompt）', '旧提示词。', after?.systemPrompt);
  t('7b.5', '专家 profession 还原', '旧职业', after?.profession);
  final cfgAfter = await reposB.experts.getRuntimeConfig(existing.id);
  t('7b.6', '运行配置还原（modelProfileId=mp_old）', 'mp_old', cfgAfter?.modelProfileId);
  t('7b.7', '运行配置还原（温度=0.1）', 0.1, cfgAfter?.temperature);
  final stAfter = await reposB.experts.getUserState(existing.id);
  t('7b.8', '用户状态还原（remark=旧备注）', '旧备注', stAfter?.remark);
  t('7b.9', '用户状态还原（styleId=sharp）', 'sharp', stAfter?.styleId);
  final tagsAfter = (await reposB.experts.getTags(existing.id)).toSet();
  t('7b.10', '标签还原', true, tagsAfter.containsAll({'旧A', '旧B'}), note: '$tagsAfter');
  final bindAfter = await reposB.experts.listKnowledgeBindings(existing.id);
  t('7b.11', '知识库绑定还原（1 条，priority=9）', true,
      bindAfter.length == 1 && bindAfter.first.priority == 9,
      note: bindAfter.map((b) => '${b.knowledgeBaseId}/p=${b.priority}').join(', '));
  t('7b.12', '无「半新旧」残留（库内仍只有 1 位专家）', 1,
      (await expertsB.list()).length);

  // 7c：覆盖 + 绑定写入失败（最凶险——旧绑定已被删、新绑定写一半）
  final fr3 = _FaultRepo();
  final reposC = _reposWith(fr3);
  final kbC = KnowledgeBase(id: Ids.next('kb'), name: '投标知识库', createdAt: now, updatedAt: now);
  await reposC.knowledge.upsertBase(kbC);
  final expertsC = ExpertService(reposC);
  final existingC = await expertsC.createLocal(name: '原子专家', systemPrompt: '旧提示词3。');
  await reposC.experts.upsertKnowledgeBinding(ExpertKnowledgeBinding(
      expertId: existingC.id, knowledgeBaseId: kbC.id, priority: 5));
  fr3.failMethod = 'upsertKnowledgeBinding'; // 播种完成后再装故障
  final svcC = ExpertImportService(reposC);
  final planC = await svcC.plan(one.bytes);
  await svcC.apply(planC, decisions: {
    planC.items.first.key: ConflictStrategy.overwrite,
  });
  final bindC = await reposC.experts.listKnowledgeBindings(existingC.id);
  t('7c.1', '绑定写入失败后：旧绑定被还原（1 条）', 1, bindC.length,
      note: bindC.map((b) => b.knowledgeBaseId).join(', '));
  t('7c.2', '旧绑定 priority 还原=5', 5, bindC.isEmpty ? -1 : bindC.first.priority);
  t('7c.3', '专家主行还原为旧值', '旧提示词3。',
      (await reposC.experts.getExpert(existingC.id))?.systemPrompt);
}

// ---------------------------------------------------------------------------
// 8. 往返一致（导出→导入→再导出，内容口径哈希）
// ---------------------------------------------------------------------------

Future<void> _t8RoundTripStable() async {
  section('8 往返一致（两次导出内容口径哈希相等）');

  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src, name: 'Round Trip Expert');
  final bytes1 = (await ExpertExportService(src).build(expertIds: [seeded.expert.id])).bytes;

  final dst = inMemoryRepositories();
  await ProviderService(dst).registerBuiltins();
  final svc = ExpertImportService(dst);
  final plan = await svc.plan(bytes1);
  t('8.1', 'round-trip 首次导入 ready', true, plan.items.first.isReady,
      note: plan.items.first.reason);
  await svc.apply(plan);
  final imported = (await ExpertService(dst).list()).single;

  final bytes2 = (await ExpertExportService(dst).build(expertIds: [imported.id])).bytes;

  String contentHash(List<int> bytes) {
    final inner = _unzip(bytes)..remove('manifest.json');
    final entries = [for (final e in inner.entries) (path: e.key, bytes: e.value)];
    return _sealHashFiles(entries);
  }

  final h1 = contentHash(bytes1);
  final h2 = contentHash(bytes2);
  t('8.2', '两次导出内容口径哈希一致', true, h1 == h2, note: '$h1 vs $h2');

  // 逐文件内容相等（更细）
  final a = _unzip(bytes1)..remove('manifest.json');
  final b = _unzip(bytes2)..remove('manifest.json');
  t('8.3', '包内文件名集合一致', true,
      a.keys.toSet().difference(b.keys.toSet()).isEmpty &&
          b.keys.toSet().difference(a.keys.toSet()).isEmpty,
      note: 'a=${a.keys.toList()} b=${b.keys.toList()}');
  var same = true;
  for (final k in a.keys) {
    if (b[k] == null || !_bytesEq(a[k]!, b[k]!)) same = false;
  }
  t('8.4', '逐文件字节一致', true, same);

  // manifest 的 seal 口径 sha256 也应一致（同一口径自洽）
  final m1 = PackageManifest.parse(utf8.decode(_unzip(bytes1)['manifest.json']!));
  final m2 = PackageManifest.parse(utf8.decode(_unzip(bytes2)['manifest.json']!));
  t('8.5', 'manifest.sha256（seal 口径）一致', m1.sha256, m2.sha256);
}

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 9. 边界
// ---------------------------------------------------------------------------

Future<void> _t9Boundaries() async {
  section('9 边界（空 / 缺件 / 脏字段 / 名字 / 批量部分失败）');

  // 9a 空字节 → 抛（不是静默成功）
  var threw9a = false;
  try {
    await ExpertImportService(inMemoryRepositories()).plan(<int>[]);
  } on AppError {
    threw9a = true;
  } catch (_) {
    threw9a = true;
  }
  t('9a', '空内容 → 抛错（不放行）', true, threw9a);

  // 9b 顶层包无 manifest 且无 .expert → 抛
  var threw9b = false;
  try {
    await ExpertImportService(inMemoryRepositories()).plan(
      _zip([(path: 'expert.json', bytes: _b('{}')), (path: 'agents/main.md', bytes: _b('x'))]),
    );
  } on AppError {
    threw9b = true;
  } catch (_) {
    threw9b = true;
  }
  t('9b', '缺 manifest.json → 抛错（不放行）', true, threw9b);

  // 9c manifest.entry 指向不存在的文件 → Schema Validate 拒
  final missingEntry = _buildPackage(
    files: {
      'expert.json': _b(jsonEncode({'displayName': '缺入口'})),
      'README.md': _b('# x'),
    }, // 故意不放 agents/main.md
    entry: 'agents/main.md',
    displayName: '缺入口',
    slug: 'no-entry-expert',
  );
  final plan9c = await ExpertImportService(inMemoryRepositories()).plan(missingEntry.bytes);
  t('9c.1', '缺 entry 文件 → rejected', true, plan9c.items.first.isRejected);
  t('9c.2', '失败点含 Schema/entry', true,
      (plan9c.items.first.reason?.contains('Schema') ?? false) ||
          (plan9c.items.first.reason?.contains('entry') ?? false),
      note: plan9c.items.first.reason);

  // 9d expert.json 缺 displayName：记录**实际行为**（manifest.displayName 权威）
  final noDisp = _buildPackage(
    files: {
      'expert.json': _b(jsonEncode({'profession': '无名字段'})),
      'agents/main.md': _b('你是助手。'),
    },
    displayName: '来自manifest的名字',
    slug: 'nodisp-expert',
  );
  final plan9d = await ExpertImportService(inMemoryRepositories()).plan(noDisp.bytes);
  t('9d.1', 'expert.json 缺 displayName → 不崩（ready/rejected 均可，非异常）', true,
      !plan9d.items.first.isRejected || (plan9d.items.first.reason?.isNotEmpty ?? false),
      note: 'status=${plan9d.items.first.status.name} reason=${plan9d.items.first.reason}');

  // 9e emoji 名 / 超长名：slug 合法 + 可导出可导入
  final emoRepos = inMemoryRepositories();
  final emo = await ExpertService(emoRepos).createLocal(
      name: '🤖机器人专家✨', systemPrompt: '你是机器人专家。');
  final emoExport = await ExpertExportService(emoRepos).build(expertIds: [emo.id]);
  t('9e.1', 'emoji 名导出不崩', true, emoExport.bytes.isNotEmpty);
  t('9e.2', 'emoji 名 slug 退化合法（expert-<id8>）', true,
      RegExp(r'^expert-[a-z0-9]{8}$').hasMatch(
          SlugRule.fromName(emo.name, fallbackId: emo.id)),
      note: SlugRule.fromName(emo.name, fallbackId: emo.id));
  final longName = 'A' * 200;
  final longSlug = SlugRule.fromName(longName);
  t('9e.3', '超长名 slug ≤64 且合法', true,
      longSlug.length <= 64 && SlugRule.isValid(longSlug), note: '$longSlug');

  // 9f 批量部分失败：good + tampered → 1 成功 1 失败，good 仍落库
  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src, name: '批量好专家');
  final goodBytes = Uint8List.fromList(
      (await ExpertExportService(src).build(expertIds: [seeded.expert.id])).bytes);
  final badInner = _unzip(goodBytes);
  final badBytes = _zip([
    for (final e in badInner.entries)
      (path: e.key, bytes: e.key == 'agents/main.md' ? _b('篡改') : e.value),
  ]);
  final batch = _zip([
    (path: 'good-1.0.0.expert', bytes: goodBytes),
    (path: 'bad-1.0.0.expert', bytes: badBytes),
    (path: 'bundle.json', bytes: _b(jsonEncode({'specVersion': 1, 'count': 2, 'items': []}))),
  ]);
  final dst = inMemoryRepositories();
  final plan9f = await ExpertImportService(dst).plan(batch);
  t('9f.1', '批量：1 ready + 1 rejected', true,
      plan9f.ready.length == 1 && plan9f.rejected.length == 1,
      note: 'ready=${plan9f.ready.length} rej=${plan9f.rejected.length}');
  final rep9f = await ExpertImportService(dst).apply(plan9f);
  t('9f.2', '批量：good 仍成功（失败隔离）', 1, rep9f.added);
  t('9f.3', '批量：bad 记失败', 1, rep9f.failed);
  t('9f.4', '批量：good 已落库', 1, (await ExpertService(dst).list()).length);
}

// ---------------------------------------------------------------------------
// 10. UI 静态评审（真交互无法验证）
// ---------------------------------------------------------------------------

String? _readApp(String rel) {
  for (final base in ['../app/lib', 'app/lib']) {
    final f = File('$base/$rel');
    if (f.existsSync()) return f.readAsStringSync();
  }
  return null;
}

void _t10UiStaticReview() {
  section('10 UI 静态评审（默认值 / 入口位置；真交互无法验证）');

  final exportDialog = _readApp('features/contacts/export_options_dialog.dart');
  final transferBar = _readApp('features/contacts/expert_transfer_bar.dart');
  final contactsPane = _readApp('features/contacts/contacts_pane.dart');

  t('10.1', '导出对话框源码可读', true, exportDialog != null);
  if (exportDialog != null) {
    t('10.2', '「包含本机设置」默认 false', true,
        exportDialog.contains('var includeLocal = false'));
    t('10.3', '「包含头像图片」默认 false', true,
        exportDialog.contains('var includeAvatar = false'));
    t('10.4', '文案告知"明文 API Key 永不导出"', true,
        exportDialog.contains('明文 API Key 永不导出'));
  }

  t('10.5', '导入文件类型限定 expert/zip', true,
      transferBar?.contains("allowedExtensions: const ['expert', 'zip']") ?? false);

  t('10.6', '通讯录页装配 ExpertTransferBar', true,
      contactsPane?.contains('ExpertTransferBar(') ?? false);

  // 市场页签不应出现导入导出入口
  final marketDir = Directory('../app/lib/features/market');
  var marketHasTransfer = false;
  if (marketDir.existsSync()) {
    for (final f in marketDir.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        final s = f.readAsStringSync();
        if (s.contains('ExpertTransferBar') ||
            s.contains('runExpertImport') ||
            s.contains('runExpertExport')) {
          marketHasTransfer = true;
        }
      }
    }
  }
  t('10.7', '市场页签无导入/导出入口（职责单一）', false, marketHasTransfer);

  // app 通过 Bootstrap 装配两个服务
  final main = _readApp('main.dart');
  t('10.8', 'main.dart 装配 ExpertExportService/ExpertImportService', true,
      (main?.contains('ExpertExportService(repos)') ?? false) &&
          (main?.contains('ExpertImportService(repos)') ?? false));
}

// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 任务 #69 用例表');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    final e = r.expected.replaceAll('|', r'\|');
    final a = r.actual.replaceAll('|', r'\|');
    stdout.writeln('| ${r.id} | ${r.name} | $e | $a | ${r.pass ? 'PASS' : 'FAIL'} |');
  }
  stdout.writeln('\n合计：通过 $_pass ／ 失败 $_fail');
  if (_fail > 0) {
    stdout.writeln('\n失败明细：');
    for (final r in _res.where((r) => !r.pass)) {
      stdout.writeln('  - [${r.id}] ${r.name}：期望=${r.expected} 实际=${r.actual}'
          '${r.note == null ? '' : '  （${r.note}）'}');
    }
  }
}
