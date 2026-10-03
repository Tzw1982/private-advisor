/// 核心纯逻辑第 3 轮验证脚本（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_round3.dart`
///
/// 覆盖（T02 完成判据）：
/// 1. 风格注入顺序（风格 → 提示词 → 严格规则 → 证据）；
/// 2. 思考剥离 A②（含「正文混入」情形，保守不误删）；
/// 3. 拼音首字母排序（`#` 置顶）——含拼音库探针结论；
/// 4. 组长唯一性与降级 / 删成员边界 / 默认总结者；
/// 5. 批量导入编排（递归 / 跳隐藏临时 / 分类 / 去重跳过 / 失败隔离 / 分批）；
/// 6. 会话摘要（listInbox 标题与排序）；
/// 7. 内容呈现（结论 / 理由）。
///
/// ## 拼音库探针结论（裁定 #3 验证门，已实测）
/// 沙箱内 `dart pub get` 成功解析 `lpinyin 2.0.3`，且实测首字母正确：
/// `张→Z`、`李→L`、`阿→A`、`重庆→C`（多音字消歧）、`11月→#`（数字开头）、
/// `Alpha→A`（英文混排）。**故采用 lpinyin 为默认来源**；`PinyinInitial.builtinOf`
/// 保留内置高频字表作兜底。`ContactSorter` 与拼音来源**解耦**（注入 `initialOf`）。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架
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
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 第 3 轮核心验证（advisor_core）');
  stdout.writeln('=' * 60);

  _verifyStyleInjectionOrder();
  _verifyReasoningStripping();
  _verifyPinyinAndSort();
  _verifyGroupRolePolicy();
  await _verifyImportOrchestration();
  await _verifyInboxAndGroups();
  _verifyContentPresenter();

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failures.isNotEmpty) {
    stdout.writeln('\n失败明细：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  } else {
    stdout.writeln('全部通过 ✅');
  }
}

// ---------------------------------------------------------------------------
// 1. 风格注入顺序
// ---------------------------------------------------------------------------

void _verifyStyleInjectionOrder() {
  section('1. 风格注入顺序（风格 → 提示词 → 严格规则 → 证据）');

  final citation = Citation(
    chunkId: 'c1',
    documentId: 'd1',
    fileName: '规格书.md',
    text: '额定流量 60 L/s',
    score: 0.9,
    headingPath: '3.2 泵参数',
  );

  final msgs = ContextManager.build(
    systemPrompt: '【提示词】你是工程车专家。',
    styleDirective: StyleLibrary.directiveFor('professional'),
    userTask: '请分析',
    evidence: [citation],
    strictGrounding: true,
  );

  final system = msgs.first;
  checkEq('首条为 system 消息', system.role, ChatRole.system);
  final sys = system.content;

  final iStyle = sys.indexOf('风格要求');
  final iPrompt = sys.indexOf('【提示词】');
  final iStrict = sys.indexOf(GroundingResolver.strictSystemRule);
  final iEvidence = sys.indexOf('以下是可引用的知识库片段');

  check('风格指令在最前', iStyle >= 0 && iPrompt > iStyle, 'style=$iStyle prompt=$iPrompt');
  check('提示词位于风格之后', iPrompt >= 0);
  check('严格规则位于提示词之后', iStrict > iPrompt, 'prompt=$iPrompt strict=$iStrict');
  check('证据块位于最后', iEvidence > iStrict, 'strict=$iStrict evidence=$iEvidence');

  // 无风格时不注入「风格要求」
  final noStyle = ContextManager.build(systemPrompt: 'P', userTask: 'T');
  check('无风格 → 不注入风格指令', !noStyle.first.content.contains('风格要求'));

  // 关闭风格（null / 未知 id）→ 空串
  checkEq('directiveFor(null) 为空', StyleLibrary.directiveFor(null), '');
  checkEq('directiveFor(未知) 为空', StyleLibrary.directiveFor('nope'), '');
  check('directiveFor(sharp) 含标签', StyleLibrary.directiveFor('sharp').contains('毒舌吐槽'));
  checkEq('7 个预设风格', StyleLibrary.all.length, 7);
}

// ---------------------------------------------------------------------------
// 2. 思考剥离 A②
// ---------------------------------------------------------------------------

void _verifyReasoningStripping() {
  section('2. 思考剥离 A②（保守：显式围栏 + 段首元叙述；正文混入不误删）');

  // 显式围栏：剥离
  final fenced = ReasoningStripper.strip('【思考】用户其实想要 A，但我要先排除 B【/思考】结论：建议选 A。');
  check('剥离【思考】围栏', !fenced.text.contains('排除 B'));
  check('保留围栏后的结论', fenced.text.contains('结论：建议选 A'));
  check('记录了被剥离片段', fenced.changed);

  // ```thinking``` 围栏
  final fence2 = ReasoningStripper.strip('```thinking\n先想想…\n```\n正文：净利率 12%。');
  check('剥离 ```thinking``` 围栏', !fence2.text.contains('想想'));
  check('保留正文', fence2.text.contains('净利率 12%'));

  // 段首元叙述短句：剥离
  final lead = ReasoningStripper.strip('让我分析一下。该方案成本偏高，建议改用方案 B。');
  check('剥离段首元叙述', !lead.text.contains('让我分析'));
  check('保留真实内容', lead.text.contains('成本偏高'));

  // 正文混入（非段首）：不剥离
  final mid = ReasoningStripper.strip('该方案成本偏高。让我想想还有没有别的办法。');
  check('正文中间的元叙述不剥离（保守）', mid.text.contains('让我想想'));

  // 段首但不是思考动词：不剥离
  final notVerb = ReasoningStripper.strip('让我给你三点建议：一、二、三。');
  check('段首「让我给你建议」不在思考动词表 → 不剥离', notVerb.text.contains('三点建议'));

  // 兜底：整段都是元叙述 → 保持原文（绝不删空）
  final allMeta = ReasoningStripper.strip('让我想想。');
  check('整段元叙述时回退原文（不删空）', allMeta.text.trim().isNotEmpty);

  // 正常内容原样
  const normal = '结论：建议分三步推进。\n理由：成本低、风险可控。';
  checkEq('正常内容不被改动', ReasoningStripper.strip(normal).text, normal);
}

// ---------------------------------------------------------------------------
// 3. 拼音首字母排序
// ---------------------------------------------------------------------------

void _verifyPinyinAndSort() {
  section('3. 拼音首字母排序（PinyinInitial 探针 + ContactSorter，`#` 置顶）');

  // 探针断言（裁定 #3）
  checkEq('张 → Z', PinyinInitial.of('张伟'), 'Z');
  checkEq('李 → L', PinyinInitial.of('李娜'), 'L');
  checkEq('阿 → A', PinyinInitial.of('阿宝'), 'A');
  checkEq('重庆 → C（多音字消歧）', PinyinInitial.of('重庆小面'), 'C');
  checkEq('11月 → #（数字开头）', PinyinInitial.of('11月'), '#');
  checkEq('Alpha → A（英文混排）', PinyinInitial.of('Alpha'), 'A');
  checkEq('空串 → #', PinyinInitial.of(''), '#');
  checkEq('内置表兜底：张 → Z', PinyinInitial.builtinOf('张'), 'Z');

  // ContactSorter（注入 initialOf，解耦）
  final names = ['张伟', '李娜', '阿宝', '11月', 'Alpha', 'Bob', '重庆小面'];
  final sorted = ContactSorter.sortByName<String>(
    names,
    nameOf: (s) => s,
    initialOf: PinyinInitial.of,
  );
  checkEq('排序后数量不变', sorted.length, names.length);
  checkEq('`#` 组置顶', sorted.first, '11月');

  final grouped = ContactSorter.groupByInitial<String>(
    names,
    nameOf: (s) => s,
    initialOf: PinyinInitial.of,
  );
  final keys = grouped.keys.toList();
  checkEq('首组为 #', keys.first, '#');
  check('键按 # → A→Z 有序', _isRankSorted(keys), 'keys=$keys');
  check('含 A 组且含 阿宝', (grouped['A'] ?? []).contains('阿宝'));
  check('含 C 组且含 重庆小面', (grouped['C'] ?? []).contains('重庆小面'));
  check('含 Z 组且含 张伟', (grouped['Z'] ?? []).contains('张伟'));

  // rank 语义
  check('rank(#) < rank(A)', ContactSorter.rankOf('#') < ContactSorter.rankOf('A'));
  check('rank(A) < rank(Z)', ContactSorter.rankOf('A') < ContactSorter.rankOf('Z'));

  // 排序键 = 展示名（备注优先）：模拟备注名影响排序
  final displayNames = ['乙', '甲']; // 备注重命名场景：这里只用拼音验证稳定性
  final byDisplay = ContactSorter.sortByName<String>(
    displayNames,
    nameOf: (s) => s,
    initialOf: (s) => s == '甲' ? 'A' : 'Z', // 注入：甲备注后视为 A
  );
  checkEq('按注入 initialOf 排序（备注优先）', byDisplay.first, '甲');
}

bool _isRankSorted(List<String> keys) {
  for (var i = 1; i < keys.length; i++) {
    if (ContactSorter.rankOf(keys[i]) < ContactSorter.rankOf(keys[i - 1])) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 4. 组长 / 组员策略
// ---------------------------------------------------------------------------

void _verifyGroupRolePolicy() {
  section('4. 组长唯一性与降级 / 删成员边界 / 默认总结者');

  ConversationMember m(String id, MemberRole role) =>
      ConversationMember(conversationId: 'c', expertId: id, role: role);

  // 唯一性校验
  check('两个组长 → 校验报错',
      GroupRolePolicy.validateMembers([m('a', MemberRole.leader), m('b', MemberRole.leader)]) != null);
  check('一个组长 → 校验通过',
      GroupRolePolicy.validateMembers([m('a', MemberRole.leader), m('b', MemberRole.member)]) == null);

  // 提升：旧组长降级
  final members = [m('a', MemberRole.leader), m('b', MemberRole.member), m('c', MemberRole.member)];
  final promoted = GroupRolePolicy.promoteToLeader(members, 'b');
  checkEq('新组长为 b', GroupRolePolicy.leaderId(promoted), 'b');
  checkEq('组长总数 = 1', promoted.where((e) => e.role == MemberRole.leader).length, 1);

  // 删除边界：最后一名成员 → 拒绝
  final solo = [m('a', MemberRole.member)];
  final r1 = GroupRolePolicy.removeMember(solo, 'a');
  check('删到 0 → 被拒绝', !r1.applied);
  check('拒绝提示可读', (r1.message ?? '').contains('至少保留 1 名成员'));

  // 删除组长 → 允许，进入无组长态
  final withLeader = [m('a', MemberRole.leader), m('b', MemberRole.member)];
  final r2 = GroupRolePolicy.removeMember(withLeader, 'a');
  check('删组长 → 允许', r2.applied);
  check('删组长后无组长', GroupRolePolicy.leaderId(r2.members) == null);
  check('给出无组长提示', (r2.message ?? '').contains('无组长'));

  // 默认总结者：配置优先，否则回退组长
  final leaderMembers = [m('a', MemberRole.leader), m('b', MemberRole.member)];
  checkEq('无配置 → 回退组长', GroupRolePolicy.effectiveSummarizerId(null, leaderMembers), 'a');
  checkEq('有配置 → 用配置', GroupRolePolicy.effectiveSummarizerId('b', leaderMembers), 'b');
}

// ---------------------------------------------------------------------------
// 5. 批量导入编排
// ---------------------------------------------------------------------------

Future<void> _verifyImportOrchestration() async {
  section('5. 批量导入编排（递归 / 跳隐藏临时 / 分类 / 去重跳过 / 失败隔离）');

  final root = Directory.systemTemp.createTempSync('pa_round3_import_');
  File('${root.path}/a.md').writeAsStringSync('A');
  File('${root.path}/a_copy.md').writeAsStringSync('A'); // 与 a.md 同内容
  File('${root.path}/b.txt').writeAsStringSync('B');
  File('${root.path}/c.xyz').writeAsStringSync('C'); // 不支持
  File('${root.path}/.hidden.md').writeAsStringSync('H');
  File('${root.path}/~\$lock.md').writeAsStringSync('L');
  File('${root.path}/desktop.ini').writeAsStringSync('D');
  File('${root.path}/x.tmp').writeAsStringSync('T');
  Directory('${root.path}/deep').createSync();
  File('${root.path}/deep/d.md').writeAsStringSync('D2');

  final scanned = DirectoryScanner.scan([root.path]);
  final names = scanned.map((f) => f.name).toSet();
  check('递归含 deep/d.md', names.contains('d.md'));
  check('跳过 .hidden.md', !names.contains('.hidden.md'));
  check('跳过 ~\$lock.md', !names.contains('~\$lock.md'));
  check('跳过 desktop.ini', !names.contains('desktop.ini'));
  check('跳过 x.tmp', !names.contains('x.tmp'));
  checkEq('候选数 = 5（a/a_copy/b/c/d）', scanned.length, 5);

  final plan = ImportPlanner.plan([root.path], supportedExtensions: const {'.md', '.txt'});
  checkEq('supported = 4（a/a_copy/b/d）', plan.supported.length, 4);
  checkEq('unsupported = 1（c.xyz）', plan.unsupported.length, 1);
  checkEq('total = 5', plan.total, 5);

  // 大小上限
  final over = ImportPlanner.planFiles(
    const [ScannedFile(path: 'big.md', name: 'big.md', sizeBytes: 60 * 1024 * 1024, extension: '.md')],
    supportedExtensions: const {'.md'},
  );
  checkEq('超限 → oversize', over.oversize.length, 1);

  // 执行：以「文件内容」模拟去重（同内容第二次 skipped）
  final seen = <String>{};
  ImportProgress? last;
  final doneFlags = <bool>[];
  await for (final p in BatchImporter(batchSize: 2).run(
    plan: plan,
    importFile: (f) async {
      final content = File(f.path).readAsStringSync();
      if (seen.contains(content)) return ImportFileResult.skipped('已存在，跳过');
      seen.add(content);
      return ImportFileResult.success(chunkCount: 1);
    },
  )) {
    last = p;
    doneFlags.add(p.done);
  }
  check('进度流收尾 done=true', doneFlags.last);
  checkEq('processed = 5', last!.processed, 5);
  checkEq('success = 3（a/b/d）', last.success, 3);
  checkEq('skipped = 1（a_copy 去重）', last.skipped, 1);
  checkEq('failed = 1（c.xyz）', last.failed, 1);

  // 失败隔离
  ImportProgress? last2;
  await for (final p in BatchImporter().run(
    plan: ImportPlanner.planFiles(
      const [
        ScannedFile(path: 'ok.md', name: 'ok.md', sizeBytes: 1, extension: '.md'),
        ScannedFile(path: 'bad.md', name: 'bad.md', sizeBytes: 1, extension: '.md'),
      ],
      supportedExtensions: const {'.md'},
    ),
    importFile: (f) async {
      if (f.name == 'bad.md') throw StateError('boom');
      return ImportFileResult.success();
    },
  )) {
    last2 = p;
  }
  checkEq('失败隔离 1 成功 / 1 失败', '${last2!.success}/${last2.failed}', '1/1');

  // DirectoryScanner.isIgnored 单元
  check('isIgnored("Thumbs.db")', DirectoryScanner.isIgnored('Thumbs.db'));
  check('extensionOf("a.MD") == ".md"', DirectoryScanner.extensionOf('a.MD') == '.md');

  try {
    root.deleteSync(recursive: true);
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// 6. 会话摘要 + 分组（内存仓储）
// ---------------------------------------------------------------------------

Future<void> _verifyInboxAndGroups() async {
  section('6. 会话摘要（listInbox）+ 分组（内存仓储）');

  final repos = inMemoryRepositories();
  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);

  final zhang = await experts.createLocal(name: '张三', systemPrompt: 'p');
  final li = await experts.createLocal(name: '李四', systemPrompt: 'p');

  // 备注优先作为单聊标题
  await experts.updateUserState(
    (await repos.experts.getUserState(zhang.id) ?? ExpertUserState(expertId: zhang.id))
        .copyWith(remark: '小张顾问'),
  );

  final c1 = await conversations.createSingle(zhang.id);
  await conversations.appendUserMessage(c1.id, '请分析这份工程车长篇文档的风险点');

  final c2 = await conversations.createGroup(
    title: '决策群',
    expertIds: [zhang.id, li.id],
    leaderExpertId: li.id,
  );
  await conversations.appendUserMessage(c2.id, '群聊第一条');

  // 置顶 c2 → 应排在最前
  await repos.conversations.upsertConversation(c2.copyWith(pinned: true));

  final inbox = await conversations.listInbox();
  checkEq('会话数 = 2', inbox.length, 2);
  checkEq('置顶会话排最前', inbox.first.conversation.id, c2.id);
  checkEq('群聊标题 = conversations.title', inbox.first.title, '决策群');
  check('摘要含用户消息前段', inbox.first.snippet.contains('群聊第一条'));

  final singleEntry = inbox.firstWhere((e) => e.conversation.id == c1.id);
  checkEq('单聊标题 = 备注名（优先）', singleEntry.title, '小张顾问');
  check('单聊摘要来自最后一条消息', singleEntry.snippet.contains('工程车'));

  // 分组（内存）
  final g = await experts.createGroup('工作组');
  await experts.assignGroup(zhang.id, g.id);
  checkEq('zhang 已入组', (await repos.experts.getUserState(zhang.id))?.groupId, g.id);
  await experts.deleteGroup(g.id);
  check('删组清空成员 group_id', (await repos.experts.getUserState(zhang.id))?.groupId != g.id);
  checkEq('分组清空', (await experts.listGroups()).length, 0);

  // GroupService：组长 / 删成员 / 生效总结者
  final groups = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: KnowledgeService(
      repos,
      parsers: const [PlainTextParser()],
      chunker: SimpleChunker(),
      vectorStore: InMemoryVectorStore(repos.knowledge),
    ),
    llmFactory: (id) => ScriptedLlmProvider(),
  );

  await groups.setLeader(c2.id, zhang.id);
  checkEq('setLeader 生效（旧组长降级）', await groups.leaderId(c2.id), zhang.id);
  checkEq('生效总结者回退到组长', await groups.effectiveSummarizer(c2.id), zhang.id);

  final removal = await groups.removeMember(c2.id, li.id);
  check('移除成员成功', removal.applied);
  checkEq('移除后成员数 = 1', (await conversations.members(c2.id)).length, 1);

  final soloremove = await groups.removeMember(c2.id, zhang.id);
  check('最后一名成员不可移除', !soloremove.applied);
}

// ---------------------------------------------------------------------------
// 7. 内容呈现
// ---------------------------------------------------------------------------

void _verifyContentPresenter() {
  section('7. 内容呈现（结论 / 理由）');

  final messy = '结论：建议先做资格预审。\n\n\n\n理由：可提前排雷，降低废标风险。  ';
  final presented = ContentPresenter.present(messy);
  check('压缩连续空行', !presented.contains('\n\n\n'));
  check('去行尾空白', presented.endsWith('。'));

  final split = ContentPresenter.split('建议分三步推进。\n\n第一步：尽调。\n第二步：成本。');
  checkEq('结论取首段', split.conclusion, '建议分三步推进。');
  check('理由取其余段', split.reasons.contains('第一步'));

  checkEq('空输入 → 空结论', ContentPresenter.split('').conclusion, '');
}
