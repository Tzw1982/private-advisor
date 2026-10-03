/// 检索测试界面（M2 · 第 2 轮）。
///
/// 归属（第 2 轮裁定 #7）：作为**知识库页内的入口**（选中知识库后可用），
/// 不做独立导航页——由 [KnowledgePage] 内嵌渲染。
///
/// 功能：输入问题 → 展示命中片段 / 来源文件 / 相关度；并明确提示：
/// - 查询词过短（无 bigram，如单字）时提示"请输入至少 2 个字"，**不误导为 bug**；
/// - 检索后端降级（FTS5 不可用）时**可见提示**，严禁静默降级。
///
/// UI 只调用 [KnowledgeService]（应用层），不直接触碰数据库。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

/// 检索测试面板（可内嵌；给定一个已选中的知识库）。
class RetrievalTestPage extends StatefulWidget {
  const RetrievalTestPage(
      {super.key, required this.knowledge, required this.base});

  /// 应用层知识库服务（由 Bootstrap 注入）。
  final KnowledgeService knowledge;

  /// 当前选中、用于检索的知识库。
  final KnowledgeBase base;

  @override
  State<RetrievalTestPage> createState() => _RetrievalTestPageState();
}

class _RetrievalTestPageState extends State<RetrievalTestPage> {
  final TextEditingController _queryCtrl = TextEditingController();

  double _threshold = kDefaultCoverageThreshold;
  int _topK = 5;

  bool _searching = false;
  List<Citation>? _results;
  String? _error;

  /// 检索后端标签（用于降级提示）。
  String _backendLabel = '检测中…';
  bool _degraded = false;

  @override
  void initState() {
    super.initState();
    _loadBackend();
  }

  Future<void> _loadBackend() async {
    final label = await widget.knowledge.retrievalBackendLabel();
    if (!mounted) return;
    setState(() {
      _backendLabel = label;
      _degraded = label.contains('降级');
    });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// 是否"查询词过短"（无 bigram，例如单个 CJK 字）——
  /// 此时检索必然无结果，需明确提示而非让用户误判。
  bool get _tooShort {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return false;
    return ChineseBigram.tokenize(q).isEmpty;
  }

  Future<void> _run() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _results = null;
    });
    try {
      final hits = await widget.knowledge.retrieve(
        query: query,
        knowledgeBaseIds: [widget.base.id],
        topK: _topK,
        threshold: _threshold,
      );
      if (!mounted) return;
      setState(() => _results = hits);
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '检索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _backendBanner(),
        _searchBar(),
        const Divider(height: 1),
        Expanded(child: _resultArea()),
      ],
    );
  }

  Widget _backendBanner() {
    final color = _degraded ? Colors.orange.shade700 : const Color(0xFF07C160);
    final icon =
        _degraded ? Icons.warning_amber_outlined : Icons.check_circle_outline;
    return Container(
      width: double.infinity,
      color: _degraded ? const Color(0xFFFFF4E5) : const Color(0xFFE8F6EE),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text('当前检索后端：$_backendLabel',
              style: TextStyle(fontSize: 12, color: color)),
          if (_degraded) ...[
            const SizedBox(width: 8),
            const Expanded(
              child: Text('（FTS5 不可用，已回退到向量检索；结果仅供参考）',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtrl,
                  onSubmitted: (_) => _searching ? null : _run(),
                  decoration: InputDecoration(
                    labelText: '检索问题',
                    hintText: '例如：废标条款有哪些？',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: _tooShort ? '查询词过短，请输入至少 2 个字' : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _searching ? null : _run,
                icon: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('检索'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text('阈值 ${_threshold.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _threshold,
                        min: 0.1,
                        max: 0.9,
                        divisions: 16,
                        label: _threshold.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _threshold = v),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Text('TopK', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              DropdownButton<int>(
                value: _topK,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 3, child: Text('3')),
                  DropdownMenuItem(value: 5, child: Text('5')),
                  DropdownMenuItem(value: 10, child: Text('10')),
                ],
                onChanged: (v) => setState(() => _topK = v ?? 5),
              ),
            ],
          ),
          const Text(
            '阈值 = 查询 bigram 在片段中的最低命中比例（coverage）；越大越严格，越小召回越多。',
            style: TextStyle(fontSize: 11, color: Colors.black45),
          ),
        ],
      ),
    );
  }

  Widget _resultArea() {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final results = _results;
    if (results == null) {
      return const Center(
        child: Text('输入问题后回车或点击「检索」，查看命中片段与来源。',
            style: TextStyle(color: Colors.black54)),
      );
    }
    if (results.isEmpty) {
      return Center(
        child: Text(
          _tooShort ? '查询词过短，请输入至少 2 个字。' : '知识库中未找到相关内容。',
          style: const TextStyle(color: Colors.black54),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final c = results[i];
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.description_outlined,
                        size: 16, color: Colors.black45),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${i + 1}. ${c.fileName}'
                        '${c.headingPath == null ? '' : ' ｜ ${c.headingPath}'}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('相关度 ${c.score.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF07C160))),
                  ],
                ),
                const SizedBox(height: 6),
                Text(c.text, style: const TextStyle(fontSize: 13, height: 1.5)),
              ],
            ),
          ),
        );
      },
    );
  }
}
