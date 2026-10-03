/// 知识库层级树构建（第 7 轮 T01 · D｜知识库层级）。
///
/// **纯逻辑、零 IO、零 Flutter**（下沉 `advisor_core`，`dart run` 可测）。
/// 输入是**已归属**的文档 + 关联文件夹登记行，输出是**纯展示树**。
///
/// ## ⚠️ 路径前缀铁律（第 4 轮 §1.1 / 第 7 轮 §1.1.2）
///
/// **归属判定 = `doc.folderId` 登记事实，严禁路径前缀**（三陷阱：大小写 / 父子重叠 /
/// 移动误判）。本模块**完全不参与归属**：文档归哪个根仍 100% 由 [KnowledgeDocument.folderId]
/// 决定；这里推导的 `relPath` **只许进 UI 树（分层摆放 + 面包屑 + 搜索）**，
/// **禁止**用于任何删除 / 同步 / 归属判定。任何"用路径前缀删文档"的代码即违规。
///
/// ## 边界（§1.1.2 逐条）
///
/// | 情形 | 处理 |
/// |------|------|
/// | 跨根 | 相对路径**只对 `folderId` 指向的那个根**计算，绝不拿 A 根文件比 B 根路径 |
/// | 根外 / 根被 rename | 剥前缀失败 → 该根下「其他」桶（不丢弃、不错挂、不抛异常） |
/// | 大小写 | 前缀判定用 `folderPath`（小写比较键），**剥除时按字符数从原 `filePath` 截**，保留原始大小写 |
/// | 分隔符 `\` / `/` | 统一 `canonicalize` 规约为 `\`；展示面包屑用 `/` |
/// | 空目录 | 树由文档构建 → **不含文档的节点天然不出现** |
library;

import 'knowledge.dart';
import 'path_canon.dart';

/// 树节点类型。
enum KbNodeKind {
  /// 知识库根。
  base,

  /// 关联文件夹根（`knowledge_base_folders` 登记行）。
  folder,

  /// 子文件夹（由相对路径段推导）。
  subfolder,

  /// 「未关联」桶（`folderId == null` 的孤儿文档）。
  orphanBucket,

  /// 文档叶。
  document,
}

/// 知识库树节点（不可变）。
class KbTreeNode {
  const KbTreeNode({
    required this.kind,
    required this.id,
    required this.label,
    this.subtitle,
    this.relPath,
    this.doc,
    this.folder,
    this.children = const [],
  });

  final KbNodeKind kind;

  /// 稳定 id：`base.id` / `folderId` / `dir:<rootId>/<relDir>` / `orphan` / `doc.id`。
  final String id;

  /// 展示名（库名 / 文件夹段名 / 文档名 / 「未关联」）。
  final String label;

  /// 副标题（文档：状态·分块数；文件夹：文档计数）。
  final String? subtitle;

  /// 文档相对路径（展示面包屑，`/` 连接）；非文档节点为子目录相对路径或 null。
  final String? relPath;

  /// 文档叶对应的领域对象。
  final KnowledgeDocument? doc;

  /// 关联文件夹根对应的登记行。
  final KnowledgeBaseFolder? folder;

  final List<KbTreeNode> children;

  bool get hasChildren => children.isNotEmpty;
  bool get isDocument => kind == KbNodeKind.document;

  /// 深度优先收集全部节点 id（测试 / 调试用）。
  List<String> allIds() => [
        id,
        for (final c in children) ...c.allIds(),
      ];

  /// 深度优先查找首个满足 [test] 的节点。
  KbTreeNode? firstWhereOrNull(bool Function(KbTreeNode) test) {
    if (test(this)) return this;
    for (final c in children) {
      final hit = c.firstWhereOrNull(test);
      if (hit != null) return hit;
    }
    return null;
  }
}

/// 构建 / 过滤知识库树（全部纯函数）。
abstract final class KnowledgeTreeBuilder {
  /// 「未关联」桶节点 id。
  static const String orphanBucketId = 'orphan';

  /// 剥前缀失败时「其他」桶的相对目录名。
  static const String otherBucketLabel = '其他';

  static const String _sep = r'\';

  /// 构建整棵树。
  ///
  /// - 规则见文件头；**不抛异常**，异常输入落「其他」桶；
  /// - [chunkCounts]：`documentId → 分块数`（UI 侧查得后传入，保持本函数零 IO）；
  ///   缺省时空值，文档副标题仅显示状态。
  static KbTreeNode build({
    required KnowledgeBase base,
    required List<KnowledgeBaseFolder> folders,
    required List<KnowledgeDocument> docs,
    Map<String, int> chunkCounts = const {},
  }) {
    final foldersById = <String, KnowledgeBaseFolder>{
      for (final f in folders) f.id: f,
    };
    final byFolder = <String, List<KnowledgeDocument>>{};
    final orphans = <KnowledgeDocument>[];
    for (final d in docs) {
      final fid = d.folderId;
      if (fid == null || !foldersById.containsKey(fid)) {
        // folderId == null（孤儿）或指向不存在的登记行（防御，正常不应发生）。
        orphans.add(d);
      } else {
        (byFolder[fid] ??= <KnowledgeDocument>[]).add(d);
      }
    }

    final children = <KbTreeNode>[];
    for (final f in folders) {
      final list = byFolder[f.id];
      // 空目录不显示：无文档的关联文件夹不出现（树由文档构建）。
      if (list == null || list.isEmpty) continue;
      children.add(_buildFolderNode(f, list, chunkCounts));
    }
    if (orphans.isNotEmpty) {
      children.add(_buildOrphanNode(orphans, chunkCounts));
    }

    return KbTreeNode(
      kind: KbNodeKind.base,
      id: base.id,
      label: base.name,
      children: children,
    );
  }

  /// 文档相对路径推导（§1.1.2）。
  ///
  /// 成功返回**展示用**相对路径（`/` 连接，保留原始大小写）；无法归属到该根
  /// （根外 / 根被 rename / 非绝对 / 异常）返回 `null`。
  static String? relativePath(
      KnowledgeDocument doc, KnowledgeBaseFolder? root) {
    if (root == null) return null;
    final fk = folderKey(root.folderPath); // 比较键（canonicalize + lowercase）
    if (fk.isEmpty) return null;
    final docKey = folderKey(doc.filePath);
    // 前缀必须带分隔符边界，防 `E:\Docs` 误匹配 `E:\Docs2`。
    if (!docKey.startsWith('$fk$_sep')) return null;

    // 剥除按「字符数」从**原样大小写**的规约路径上截（保留展示大小写）。
    final canonOriginal = canonicalize(doc.filePath); // `\` 规约、原样大小写
    final start = fk.length + 1; // +1 = 分隔符
    if (canonOriginal.length <= start) return null; // 仅前缀、无文件名 → 异常输入
    final rel = canonOriginal.substring(start);
    if (rel.isEmpty) return null;
    return rel.replaceAll(_sep, '/');
  }

  /// 搜索过滤 + 自动展开集（§1.1.4）。
  ///
  /// - [query] 空 → 返回整棵树 + [defaultExpandedIds]；
  /// - 命中（节点 label 或文档 relPath 含 query，大小写不敏感）→ 返回**剪枝树**
  ///   （保留命中节点及其祖先）+ 需自动展开的祖先 id 集。
  static ({KbTreeNode tree, Set<String> autoExpanded}) filter(
    KbTreeNode root,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return (tree: root, autoExpanded: defaultExpandedIds(root));
    }
    final auto = <String>{};

    // [ancestorHit]：某祖先已命中 → 其整棵子树保留（搜索文件夹名时展开其全部内容）。
    KbTreeNode? prune(KbTreeNode node, bool ancestorHit) {
      final selfHit = ancestorHit || _matches(node, q);
      final kept = <KbTreeNode>[];
      for (final c in node.children) {
        final k = prune(c, selfHit);
        if (k != null) kept.add(k);
      }
      if (!selfHit && kept.isEmpty) return null;
      // 有保留的后代（或自身命中且有子节点）→ 本节点需展开。
      if (node.hasChildren) auto.add(node.id);
      return KbTreeNode(
        kind: node.kind,
        id: node.id,
        label: node.label,
        subtitle: node.subtitle,
        relPath: node.relPath,
        doc: node.doc,
        folder: node.folder,
        children: kept,
      );
    }

    final pruned = prune(root, false);
    if (pruned == null) {
      // 无任何命中：返回空内容的根（调用方可据此显示「无匹配」）。
      return (
        tree: KbTreeNode(kind: root.kind, id: root.id, label: root.label),
        autoExpanded: auto,
      );
    }
    return (tree: pruned, autoExpanded: auto);
  }

  /// 默认展开 id 集：**库根 + 关联文件夹 + 一级子文件夹**（更深折叠）。
  static Set<String> defaultExpandedIds(KbTreeNode root) {
    final ids = <String>{root.id};
    for (final f in root.children) {
      if (f.kind != KbNodeKind.folder && f.kind != KbNodeKind.orphanBucket) {
        continue;
      }
      ids.add(f.id);
      for (final c in f.children) {
        if (c.kind == KbNodeKind.subfolder) ids.add(c.id);
      }
    }
    return ids;
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  static bool _matches(KbTreeNode node, String q) {
    if (node.label.toLowerCase().contains(q)) return true;
    final rp = node.relPath;
    if (rp != null && rp.toLowerCase().contains(q)) return true;
    return false;
  }

  static KbTreeNode _buildFolderNode(
    KnowledgeBaseFolder folder,
    List<KnowledgeDocument> docs,
    Map<String, int> chunkCounts,
  ) {
    final dir = _MutableDir();
    final other = <(KnowledgeDocument, String?)>[];
    for (final d in docs) {
      final rel = relativePath(d, folder);
      if (rel == null) {
        other.add((d, null)); // 根外 / rename → 「其他」桶
        continue;
      }
      final segs = rel.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.length <= 1) {
        dir.docs.add((d, rel)); // 文件直接位于根下
      } else {
        var cur = dir;
        for (final seg in segs.sublist(0, segs.length - 1)) {
          cur = cur.sub.putIfAbsent(seg, _MutableDir.new);
        }
        cur.docs.add((d, rel));
      }
    }

    final kids = <KbTreeNode>[
      ..._expandDir(dir, folder.id, '', chunkCounts),
    ];
    if (other.isNotEmpty) {
      kids.add(_buildOtherBucket(folder.id, other, chunkCounts));
    }

    return KbTreeNode(
      kind: KbNodeKind.folder,
      id: folder.id,
      label: folder.displayPath,
      subtitle: '${docs.length} 篇',
      folder: folder,
      children: kids,
    );
  }

  static List<KbTreeNode> _expandDir(
    _MutableDir dir,
    String rootId,
    String relPrefix,
    Map<String, int> chunkCounts,
  ) {
    final out = <KbTreeNode>[];
    final names = dir.sub.keys.toList()..sort();
    for (final name in names) {
      final child = dir.sub[name]!;
      final childPrefix = relPrefix.isEmpty ? name : '$relPrefix/$name';
      out.add(KbTreeNode(
        kind: KbNodeKind.subfolder,
        id: 'dir:$rootId/$childPrefix',
        label: name,
        subtitle: '${_countDocs(child)} 篇',
        relPath: childPrefix,
        children: _expandDir(child, rootId, childPrefix, chunkCounts),
      ));
    }
    final leafDocs = dir.docs.toList()
      ..sort((a, b) => a.$1.fileName.compareTo(b.$1.fileName));
    for (final (d, rel) in leafDocs) {
      out.add(_docLeaf(d, rel, chunkCounts));
    }
    return out;
  }

  static KbTreeNode _buildOtherBucket(
    String rootId,
    List<(KnowledgeDocument, String?)> docs,
    Map<String, int> chunkCounts,
  ) {
    final leaves = docs.toList()
      ..sort((a, b) => a.$1.fileName.compareTo(b.$1.fileName));
    return KbTreeNode(
      kind: KbNodeKind.subfolder,
      id: 'dir:$rootId/__other__',
      label: otherBucketLabel,
      subtitle: '${docs.length} 篇',
      children: [
        for (final (d, _) in leaves) _docLeaf(d, null, chunkCounts),
      ],
    );
  }

  static KbTreeNode _buildOrphanNode(
    List<KnowledgeDocument> docs,
    Map<String, int> chunkCounts,
  ) {
    final leaves = docs.toList()
      ..sort((a, b) => a.fileName.compareTo(b.fileName));
    return KbTreeNode(
      kind: KbNodeKind.orphanBucket,
      id: orphanBucketId,
      label: '未关联',
      subtitle: '${docs.length} 篇',
      children: [
        for (final d in leaves) _docLeaf(d, null, chunkCounts),
      ],
    );
  }

  static KbTreeNode _docLeaf(
    KnowledgeDocument d,
    String? rel,
    Map<String, int> chunkCounts,
  ) {
    final n = chunkCounts[d.id];
    final subtitle = n == null ? d.status.label : '${d.status.label} · $n 块';
    return KbTreeNode(
      kind: KbNodeKind.document,
      id: d.id,
      label: d.fileName,
      subtitle: subtitle,
      relPath: rel,
      doc: d,
    );
  }

  static int _countDocs(_MutableDir dir) {
    var n = dir.docs.length;
    for (final c in dir.sub.values) {
      n += _countDocs(c);
    }
    return n;
  }
}

/// 可变中间目录（仅构建期使用）。
class _MutableDir {
  final Map<String, _MutableDir> sub = {};
  final List<(KnowledgeDocument, String)> docs = [];
}
