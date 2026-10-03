/// 私人顾问团 · 核心包入口（Domain + Application）。
///
/// 设计约束（V1.3 §2）：
/// - 本包**不依赖 Flutter / SQLite / HTTP**，可在纯 Dart 环境编译与测试。
/// - 所有外部能力（模型、向量库、文件解析、持久化、密钥）都通过**端口**注入。
library;

export 'domain/attachment.dart';
export 'domain/avatar_palette.dart';
export 'domain/common.dart';
export 'domain/contact_sort.dart';
export 'domain/conversation.dart';
export 'domain/expert.dart';
export 'domain/expert_bundle.dart';
export 'domain/expert_group.dart';
export 'domain/generation.dart';
export 'domain/group_directive.dart';
export 'domain/group_policy.dart';
export 'domain/knowledge.dart';
export 'domain/knowledge_tree.dart';
export 'domain/market.dart';
export 'domain/orchestration.dart';
export 'domain/path_canon.dart';
export 'domain/provider.dart';
export 'domain/reasoning.dart';
export 'domain/relevance.dart';
export 'domain/strategies.dart';
export 'domain/style.dart';
export 'domain/text_index.dart';

export 'application/attachment_context.dart';
export 'application/attachment_store.dart';
export 'application/expert_export.dart';
export 'application/expert_import.dart';
export 'application/folder_sync.dart';
export 'application/import_batch.dart';
export 'application/market_client.dart';
export 'application/repositories.dart';
export 'application/services.dart';
export 'application/vision.dart';

// 纯 Dart 文档解析（第 3 轮）。
export 'parsers/docx_parser.dart';
export 'parsers/legacy_office_parser.dart';
export 'parsers/ooxml_zip.dart';
export 'parsers/pdf_text_parser.dart';
export 'parsers/plain_text_parser.dart';
export 'parsers/pptx_parser.dart';
export 'parsers/xlsx_parser.dart';
