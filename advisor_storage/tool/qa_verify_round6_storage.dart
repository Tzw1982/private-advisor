/// QA 独立验证脚本（严过关）——第 6 轮「群聊体验改造」T01/T04 存储层。
///
/// 运行：`cd advisor_storage && dart run tool/qa_verify_round6_storage.dart`
///
/// 与 `qa_verify.dart`（schema/迁移/存量仓储）分工：本脚本专测**第 6 轮新增/改动**：
/// - `expert_groups`（v3 表，仍在 v5 库上）CRUD 与排序；
/// - `group_configs` v5 三列（announcement / announcement_updated_at /
///   max_speakers_per_round）经真实仓储与 GroupService 落库往返；
/// - 群管理四方法（公告 / 策略 / 上限 / 群名）持久化 + 校验；
/// - 会话删除对 group_configs / conversation_members 的级联；
/// - 分组删除对成员 `group_id` 的服务层清空（逻辑外键）。
///
/// 只读取 / 调用生产代码，不修改任何生产代码。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

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

Object? _scalar(Database db, String sql, [List<Object?> params = const []]) {
  final rs = db.select(sql, params);
  return rs.isEmpty ? null : rs.first.values.first;
}

int _count(Database db, String table, [String? where, List<Object?> params = const []]) =>
    (_scalar(db, 'SELECT COUNT(*) FROM $table${where == null ? '' : ' WHERE $where'}', params)
            as int?) ??
    0;

// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('严过关 · 独立 QA 验证（第 6 轮 存储层）');
  stdout.writeln('=' * 62);
  stdout.writeln('sqlite3 = ${sqlite3.version.libVersion}  |  dart = ${Platform.version}');

  final tmp = Directory.systemTemp.createTempSync('pa_qa_r6store_');
  final sep = Platform.pathSeparator;
  final db = openAdvisorDatabase('${tmp.path}${sep}r6.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: InMemoryRetriever(repos.knowledge),
  );
  final group = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => ScriptedLlmProvider(),
  );
  SpeakingStrategies.registerBuiltins();

  await _t_groups(db, experts);
  await _t_groupConfig(db, repos);
  await _t_members(db, repos, group);
  await _t_groupService(db, repos, group, conversations);

  _print();
  db.dispose();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// expert_groups：CRUD + 排序
// ---------------------------------------------------------------------------

Future<void> _t_groups(Database db, ExpertService experts) async {
  section('expert_groups CRUD 与排序（T01 v3 表 / T04 逻辑外键）');

  t('G0', 'expert_groups 表存在', true,
      db.select("SELECT name FROM sqlite_master WHERE type='table' AND name='expert_groups'").isNotEmpty);

  final g1 = await experts.createGroup('重要客户', sortOrder: 10);
  final g2 = await experts.createGroup('普通', sortOrder: 1);
  final g3 = await experts.createGroup('其它', sortOrder: 5);

  final list = await experts.listGroups();
  t('G1', 'listGroups 数量=3', 3, list.length);
  t('G2', '按 sort_order 升序：普通(1)→其它(5)→重要客户(10)', '普通,其它,重要客户',
      list.map((g) => g.name).join(','));

  // 改名 + 改排序
  await experts.updateGroup(g2.copyWith(name: '普通改', sortOrder: 20));
  final list2 = await experts.listGroups();
  t('G3', '改名生效', '普通改', list2.firstWhere((g) => g.id == g2.id).name);
  t('G4', '改排序后升到末尾', '普通改', list2.last.name);

  // 空名称校验
  var threw = false;
  try {
    await experts.createGroup('   ');
  } catch (_) {
    threw = true;
  }
  t('G5', '空名称分组被拒', true, threw);

  // 删除
  await experts.deleteGroup(g3.id);
  t('G6', '删除后分组数=2', 2, (await experts.listGroups()).length);
  t('G7', '删除的行已不在裸表中', 0, _count(db, 'expert_groups', 'id=?', [g3.id]));
  t('G8', '剩余分组仍在裸表中', 2, _count(db, 'expert_groups'));

  // 逻辑外键：删除分组须清空成员 group_id（服务层保证，无 DB FK）
  final e = await experts.createLocal(name: '分组专家', systemPrompt: 'sp');
  await experts.assignGroup(e.id, g1.id);
  t('G9', '分配到分组后 user_state.group_id 落库', g1.id,
      _scalar(db, 'SELECT group_id FROM expert_user_states WHERE expert_id=?', [e.id]));
  await experts.deleteGroup(g1.id);
  t('G10', '删分组后成员 group_id 被清空（逻辑外键）', '',
      _scalar(db, 'SELECT group_id FROM expert_user_states WHERE expert_id=?', [e.id]));
}

// ---------------------------------------------------------------------------
// group_configs v5 三列 & 群管理方法
// ---------------------------------------------------------------------------

Future<void> _t_groupConfig(Database db, Repositories repos) async {
  section('group_configs v5 三列往返（T01/T04）');

  // 造一个会话（供 FK）
  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.conversations.upsertConversation(
      Conversation(id: 'gc_conv', type: ConversationType.group, title: '群', createdAt: now, updatedAt: now));

  await repos.conversations.upsertGroupConfig(const GroupConfig(
    conversationId: 'gc_conv',
    speakStrategy: 'leader_led',
    announcement: '本群共识：结论优先',
    announcementUpdatedAt: 1000,
    maxSpeakersPerRound: 4,
  ));
  final back = await repos.conversations.getGroupConfig('gc_conv');
  t('C1', 'announcement 往返', '本群共识：结论优先', back?.announcement);
  t('C2', 'announcementUpdatedAt 往返', 1000, back?.announcementUpdatedAt);
  t('C3', 'maxSpeakersPerRound 往返', 4, back?.maxSpeakersPerRound);
  t('C4', 'speakStrategy 往返(leader_led)', 'leader_led', back?.speakStrategy);
  t('C5', '裸表三列已落库', '本群共识：结论优先|1000|4',
      '${_scalar(db, 'SELECT announcement FROM group_configs WHERE conversation_id=?', ['gc_conv'])}|'
      '${_scalar(db, 'SELECT announcement_updated_at FROM group_configs WHERE conversation_id=?', ['gc_conv'])}|'
      '${_scalar(db, 'SELECT max_speakers_per_round FROM group_configs WHERE conversation_id=?', ['gc_conv'])}');

  // 更新（ON CONFLICT）不得插入第二行
  await repos.conversations.upsertGroupConfig(
      (back!).copyWith(announcement: '新公告', maxSpeakersPerRound: 2));
  t('C6', 'upsert 冲突更新（仍 1 行）', 1, _count(db, 'group_configs', 'conversation_id=?', ['gc_conv']));
  t('C7', '冲突更新后 announcement 生效', '新公告',
      _scalar(db, 'SELECT announcement FROM group_configs WHERE conversation_id=?', ['gc_conv']));

  // 未设置 → null
  t('C8', '未设置会话返回 null', null, await repos.conversations.getGroupConfig('nope'));
}

// ---------------------------------------------------------------------------
// conversation_members 角色（组长）往返 + 级联删除
// ---------------------------------------------------------------------------

Future<void> _t_members(Database db, Repositories repos, GroupService group) async {
  section('conversation_members 角色往返 + 会话删除级联（T04）');

  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.conversations.upsertConversation(
      Conversation(id: 'm_conv', type: ConversationType.group, title: 'M', createdAt: now, updatedAt: now));
  for (final e in ['mA', 'mB', 'mC']) {
    await repos.experts.upsertExpert(Expert(
        id: e, name: e, systemPrompt: 'sp', source: ExpertSource.local,
        createdAt: now, updatedAt: now));
  }
  await group.addMember('m_conv', 'mA');
  await group.addMember('m_conv', 'mB');
  await group.addMember('m_conv', 'mC');
  await group.setLeader('m_conv', 'mB');

  t('M1', '成员数=3', 3, _count(db, 'conversation_members', 'conversation_id=?', ['m_conv']));
  t('M2', '组长唯一且为 mB', 'mB', (await group.leaderId('m_conv')));
  t('M3', '裸表 role 落为 "leader"', 'leader',
      _scalar(db, "SELECT role FROM conversation_members WHERE conversation_id='m_conv' AND expert_id='mB'"));
  t('M4', '其余成员 role=member', 2,
      _count(db, "conversation_members", "conversation_id='m_conv' AND role='member'"));

  // 提升新组长 → 旧组长降级
  await group.setLeader('m_conv', 'mA');
  t('M5', '提升 mA 后组长=mA', 'mA', await group.leaderId('m_conv'));
  t('M6', '旧组长 mB 降为 member', 'member',
      _scalar(db, "SELECT role FROM conversation_members WHERE conversation_id='m_conv' AND expert_id='mB'"));
  t('M7', '全群仍恰好 1 名组长', 1,
      _count(db, "conversation_members", "conversation_id='m_conv' AND role='leader'"));

  // 级联：删会话 → 成员 + group_config 一起清
  await repos.conversations.upsertGroupConfig(
      const GroupConfig(conversationId: 'm_conv', announcement: 'x'));
  await repos.conversations.deleteConversation('m_conv');
  t('M8', '删会话后成员级联清 0', 0, _count(db, 'conversation_members', 'conversation_id=?', ['m_conv']));
  t('M9', '删会话后 group_config 级联清 0', 0, _count(db, 'group_configs', 'conversation_id=?', ['m_conv']));
}

// ---------------------------------------------------------------------------
// GroupService 群管理四方法 + 校验（T04）
// ---------------------------------------------------------------------------

Future<void> _t_groupService(
    Database db, Repositories repos, GroupService group, ConversationService conversations) async {
  section('GroupService 群管理四方法持久化 + 校验（T04）');

  final now = DateTime.now().millisecondsSinceEpoch;
  final owner = Expert(
      id: 'gOwner', name: '群主', systemPrompt: 'sp', source: ExpertSource.local,
      createdAt: now, updatedAt: now);
  await repos.experts.upsertExpert(owner);
  final conv = await conversations.createGroup(title: '管理群', expertIds: [owner.id]);
  final cid = conv.id;

  // 公告
  await group.updateAnnouncement(cid, '共识：先给结论');
  var cfg = await group.config(cid);
  t('S1', 'updateAnnouncement 落库', '共识：先给结论', cfg?.announcement);
  t('S2', '公告更新时间被写入（非空）', true, (cfg?.announcementUpdatedAt ?? 0) > 0);

  // 空公告清除（存 ''，非 null）
  await group.updateAnnouncement(cid, '   ');
  cfg = await group.config(cid);
  t('S3', '空公告清除为 ""', '', cfg?.announcement);

  // 策略
  await group.updateSpeakStrategy(cid, 'leader_led');
  t('S4', 'updateSpeakStrategy 落库', 'leader_led', (await group.config(cid))?.speakStrategy);
  var threw = false;
  try {
    await group.updateSpeakStrategy(cid, 'no_such_strategy');
  } catch (_) {
    threw = true;
  }
  t('S5', '未知策略被拒', true, threw);
  t('S5b', '拒绝后策略未被写坏', 'leader_led', (await group.config(cid))?.speakStrategy);

  // 单轮上限
  await group.updateMaxSpeakers(cid, 7);
  t('S6', 'updateMaxSpeakers 落库', 7, (await group.config(cid))?.maxSpeakersPerRound);
  var threw2 = false;
  try {
    await group.updateMaxSpeakers(cid, 0);
  } catch (_) {
    threw2 = true;
  }
  t('S7', '上限 0 被拒（1..20）', true, threw2);
  var threw3 = false;
  try {
    await group.updateMaxSpeakers(cid, 21);
  } catch (_) {
    threw3 = true;
  }
  t('S7b', '上限 21 被拒', true, threw3);

  // 群名
  await group.renameGroup(cid, '  新群名  ');
  t('S8', 'renameGroup 去空白后落库', '新群名',
      _scalar(db, 'SELECT title FROM conversations WHERE id=?', [cid]));
  var threw4 = false;
  try {
    await group.renameGroup(cid, '   ');
  } catch (_) {
    threw4 = true;
  }
  t('S9', '空群名被拒', true, threw4);

  // 持久化确认：四方法写入均可在裸表读到（非内存假象）
  t('S10', '四方法写入可在裸表读到', 'leader_led|7|新群名',
      '${_scalar(db, 'SELECT speak_strategy FROM group_configs WHERE conversation_id=?', [cid])}|'
      '${_scalar(db, 'SELECT max_speakers_per_round FROM group_configs WHERE conversation_id=?', [cid])}|'
      '${_scalar(db, 'SELECT title FROM conversations WHERE id=?', [cid])}');
  t('S11', 'group_configs 未产生重复行（1 行）', 1,
      _count(db, 'group_configs', 'conversation_id=?', [cid]));
}

// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 第 6 轮存储层用例表');
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
