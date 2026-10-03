/// 专家 emoji 头像落库 + 市场列表「切页签状态保持」验证（第 #66 轮，纯 Dart）。
///
/// 运行：`cd advisor_core && dart run tool/verify_avatar_emoji.dart`
///
/// 覆盖两件走查缺陷的**可验证层**（app 的 Widget 行为由 appcheck 静态门禁守护）：
///
/// 1. **缺陷②「添加到通讯录后头像没了」**：
///    - `Expert` 的 `avatarEmoji` / `avatarColor` 是 **additive** 新增（默认 null，
///      既有构造零变化）；`copyWith` 的设置 / 保留 / 清空三态；
///    - `MarketService.installPackage` 安装时把市场索引里的 `emoji` / `color`
///      一并写进专家档案（此前只落 `avatarPath`，emoji 直接丢失 → 回退首字）；
///    - 索引里查不到该包（侧载安装）→ 两字段为 null，**回退档不被破坏**。
///
/// 2. **缺陷①「切页签回来分类/卡片空白」的数据侧根因**：
///    市场数据**在库里**、不在 UI/内存里——模拟"中栏 pane 被销毁重建"
///    （**新建一个 `MarketService`**、零内存缓存、**不联网**）：
///    `listPackages()` / `installed()` 返回与重建前完全一致的结果。
///    这证明"切回来必须有数据"不依赖任何 UI 状态，也不依赖刷新索引。
library;

import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_market 同款）
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];
String _current = '';

void section(String name) {
  _current = name;
  stdout.writeln('\n── $name ─────────────────────────────');
}

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    final msg = '[$_current] $name${detail == null ? '' : '  → $detail'}';
    _failures.add(msg);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) =>
    check(name, actual == expected, 'actual=$actual expected=$expected');

// ---------------------------------------------------------------------------
// 夹具：带 emoji / color 的市场索引（与线上 `catalog/index.json` 同结构）
// ---------------------------------------------------------------------------

const _kPkgA = 'org.test.emoji-hero';
const _kPkgB = 'org.test.plain-hero';

String _indexJson() => jsonEncode({
      'schemaVersion': 1,
      'generatedAt': 1790785441428,
      'packages': [
        {
          'packageId': _kPkgA,
          'slug': 'emoji-hero',
          'displayName': '带表情专家',
          'profession': '表情顾问',
          'description': '索引里带 emoji 与 color',
          'categoryId': '02-Engineering',
          'tags': ['emoji'],
          'emoji': '🤖',
          'color': '#6D28D9',
          'latestVersion': '1.0.0',
          'versions': [
            {
              'version': '1.0.0',
              'releaseUrl': 'https://example.test/emoji-hero-1.0.0.expert',
              'sha256': 'a' * 64,
              'publishedAt': 1,
            }
          ],
        },
        {
          'packageId': _kPkgB,
          'slug': 'plain-hero',
          'displayName': '无色专家',
          'profession': '朴素顾问',
          'description': '索引里不带 emoji / color（回退档）',
          'categoryId': '05-MarketingGrowth',
          'tags': ['plain'],
          'latestVersion': '1.0.0',
          'versions': [
            {
              'version': '1.0.0',
              'releaseUrl': 'https://example.test/plain-hero-1.0.0.expert',
              'sha256': 'b' * 64,
              'publishedAt': 2,
            }
          ],
        },
      ],
    });

/// 直接构造"校验全过"的报告（本脚本验证的是**落库链路**，不重复覆盖
/// 10 步校验链——那部分由 `verify_market.dart` 全量守护）。
PackageVerification _okVerification() => const PackageVerification([
      VerifyStep('1. HTTPS 传输', true, '内容口径'),
      VerifyStep('2. Manifest', true),
      VerifyStep('4. SHA256', true),
    ]);

PackageManifest _manifest(String packageId, String slug) => PackageManifest(
      packageId: packageId,
      slug: slug,
      version: const SemVer(1, 0, 0),
      appVersion: AppVersionRequirement.parse('>=0.1.0'),
      displayName: '落库用专家',
      categoryId: '02-Engineering',
      entry: 'agents/main.md',
      sha256: 'c' * 64,
    );

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 专家 emoji 落库 / 市场列表状态保持（advisor_core）');
  stdout.writeln('=' * 60);

  final repos = inMemoryRepositories();
  final experts = ExpertService(repos);
  final market = MarketService(repos, experts: experts);
  await market.registerDefaultSource();
  await market.applyIndex(_indexJson());

  // ── §1 Expert 域模型：additive 不变式 ─────────────────────────
  section('§1 Expert.avatarEmoji / avatarColor（additive，默认 null）');
  final base = Expert(
    id: 'e1',
    name: '原型专家',
    systemPrompt: 'p',
    createdAt: 1,
    updatedAt: 1,
  );
  check('新构造默认 avatarEmoji = null', base.avatarEmoji == null);
  check('新构造默认 avatarColor = null', base.avatarColor == null);
  check('新构造默认 avatarPath = null', base.avatarPath == null);

  final withEmoji = base.copyWith(avatarEmoji: '🤖', avatarColor: '#6D28D9');
  checkEq('copyWith 写入 emoji', withEmoji.avatarEmoji, '🤖');
  checkEq('copyWith 写入 color', withEmoji.avatarColor, '#6D28D9');
  checkEq('copyWith 不传参时保留 emoji（不被清空）',
      withEmoji.copyWith(name: '改名').avatarEmoji, '🤖');
  checkEq('copyWith 不传参时保留 color', withEmoji.copyWith().avatarColor,
      '#6D28D9');
  check('copyWith clearAvatarEmoji 可清空',
      withEmoji.copyWith(clearAvatarEmoji: true).avatarEmoji == null);
  check('copyWith clearAvatarColor 可清空',
      withEmoji.copyWith(clearAvatarColor: true).avatarColor == null);
  checkEq('copyWith 不动 id / createdAt', withEmoji.id, 'e1');
  checkEq('copyWith 不动 createdAt', withEmoji.createdAt, 1);

  // ── §2 安装落库：索引 emoji / color 写进专家档案 ────────────────
  section('§2 安装落库（MarketService.installPackage → Expert 带 emoji）');
  final installedA = await market.installPackage(
    manifest: _manifest(_kPkgA, 'emoji-hero'),
    verification: _okVerification(),
    systemPrompt: '你是带表情专家',
    installPath: '/tmp/market/packages/emoji-hero-1.0.0',
  );
  checkEq('专家名', installedA.name, '落库用专家');
  checkEq('专家来源', installedA.source.name, 'market');
  checkEq('★ 专家 avatarEmoji = 索引 emoji', installedA.avatarEmoji, '🤖');
  checkEq('★ 专家 avatarColor = 索引 color', installedA.avatarColor, '#6D28D9');

  final rereadA = await experts.get(installedA.id);
  check('★ 重新读回（通讯录数据源）仍有 emoji', rereadA?.avatarEmoji == '🤖',
      '${rereadA?.avatarEmoji}');
  checkEq('★ 重新读回 color', rereadA?.avatarColor, '#6D28D9');
  final inList = await experts.list();
  check('★ listExperts 里也带 emoji',
      inList.any((e) => e.id == installedA.id && e.avatarEmoji == '🤖'));

  // ── §3 索引无 emoji / 侧载：null，回退档不被破坏 ────────────────
  section('§3 索引无 emoji / 侧载安装 → null（回退首字，行为不变）');
  final installedB = await market.installPackage(
    manifest: _manifest(_kPkgB, 'plain-hero'),
    verification: _okVerification(),
    systemPrompt: '你是无色专家',
    installPath: '/tmp/market/packages/plain-hero-1.0.0',
  );
  check('索引无 emoji → 专家 avatarEmoji = null',
      installedB.avatarEmoji == null, '${installedB.avatarEmoji}');
  check('索引无 color → 专家 avatarColor = null',
      installedB.avatarColor == null, '${installedB.avatarColor}');

  final sideload = await market.installPackage(
    manifest: _manifest('org.test.sideloaded', 'sideloaded'),
    verification: _okVerification(),
    systemPrompt: '侧载专家',
    installPath: '/tmp/market/packages/sideloaded-1.0.0',
  );
  check('侧载（索引查不到该包）→ avatarEmoji = null',
      sideload.avatarEmoji == null, '${sideload.avatarEmoji}');
  check('侧载 → avatarColor = null', sideload.avatarColor == null,
      '${sideload.avatarColor}');

  // ── §4 缺陷①数据侧：切页签（pane 销毁重建）后数据仍在 ────────────
  section('§4 切页签状态保持（新建 Service 模拟 pane 重建 · 不联网）');
  final before = await market.listPackages();
  final beforeInstalled = await market.installed();
  final beforeCats = before.map((p) => p.categoryId).toSet().toList()..sort();
  checkEq('重建前包数', before.length, 2);
  checkEq('重建前已安装数', beforeInstalled.length, 3);

  // 模拟"中栏 pane 被销毁重建"：全新的服务实例（**零内存缓存**），
  // 且**不调用 refreshIndex**（不联网）——只做重建后的那次读库。
  final rebuiltMarket = MarketService(repos, experts: ExpertService(repos));
  final after = await rebuiltMarket.listPackages();
  final afterInstalled = await rebuiltMarket.installed();
  final afterCats = after.map((p) => p.categoryId).toSet().toList()..sort();

  checkEq('★ 重建后包数不变（数据在库里，不在 UI/内存里）', after.length,
      before.length);
  checkEq('★ 重建后已安装数不变', afterInstalled.length, beforeInstalled.length);
  checkEq('★ 重建后分类集合一致（中栏分类列表数据源）',
      afterCats.join('|'), beforeCats.join('|'));
  check('★ 重建后 emoji 仍在（右栏卡片数据源）',
      after.any((p) => p.packageId == _kPkgA && p.emoji == '🤖'));
  check('★ 重建后 slug 仍在（安装目录口径）',
      after.any((p) => p.packageId == _kPkgA && p.slug == 'emoji-hero'));
  check('★ 重建后 installedIds 命中已添加包',
      afterInstalled.any((i) => i.packageId == _kPkgA));

  // 再"切"一次（第二次重建）→ 幂等，不丢数据。
  final thirdMarket = MarketService(repos, experts: ExpertService(repos));
  checkEq('★ 二次重建后包数仍不变（幂等）',
      (await thirdMarket.listPackages()).length, before.length);

  // ── §5 存量专家回填（v9 之前安装的专家补 emoji） ────────────────
  section('§5 backfillExpertAvatars（存量老专家补 emoji · 幂等）');
  // 造一个"v9 之前安装的专家"：市场来源 + packageId 命中索引，但无 emoji。
  final old = await experts.installFromPackage(
    packageId: _kPkgA,
    version: '1.0.0',
    displayName: '老专家（升级前安装）',
    systemPrompt: 'p',
    installPath: '/tmp/market/packages/old-1.0.0',
  );
  final oldCleared = old.copyWith(clearAvatarEmoji: true, clearAvatarColor: true);
  await repos.experts.upsertExpert(oldCleared);
  check('前置：老专家无 emoji',
      (await experts.get(old.id))?.avatarEmoji == null);

  final filled = await market.backfillExpertAvatars();
  checkEq('★ 回填命中 1 位（老专家）', filled, 1);
  final oldAfter = await experts.get(old.id);
  checkEq('★ 回填后 emoji = 索引值', oldAfter?.avatarEmoji, '🤖');
  checkEq('★ 回填后 color = 索引值', oldAfter?.avatarColor, '#6D28D9');
  check('★ 回填不动本地修改标记（user_state 未被标脏）',
      (await repos.experts.getUserState(old.id))?.localModifiedAt == null);
  check('★ 回填不动 packageId / name',
      oldAfter?.packageId == _kPkgA && oldAfter?.name == '老专家（升级前安装）');
  checkEq('★ 再次回填为 0（幂等）', await market.backfillExpertAvatars(), 0);

  // ── 汇总 ─────────────────────────────────────────────────────
  stdout.writeln('\n' + '=' * 60);
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过 ✅');
  } else {
    stdout.writeln('失败项：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
  }
  if (_failed > 0) throw StateError('verify_avatar_emoji 失败 $_failed 项');
}
