/// Schema 生成器：把 `schema.sql` 内联为 Dart 常量，便于在无文件系统 / 无 asset
/// 的运行环境（如 Flutter 打包后）直接使用。
///
/// 运行：`dart run tool/gen_schema.dart`
///
/// 产出：`lib/src/database/schema.g.dart`（`const String kAdvisorSchemaSql = r'''...'''`）。
/// 一致性由 `tool/verify_storage.dart` 断言（生成物必须与 schema.sql 逐字相等）。
library;

import 'dart:io';

/// canonical DDL 源文件路径（相对包根）。
const String _sqlPath = 'lib/src/database/schema.sql';

/// 生成物路径（相对包根）。
const String _outPath = 'lib/src/database/schema.g.dart';

void main() {
  final sqlFile = File(_sqlPath);
  if (!sqlFile.existsSync()) {
    stderr.writeln('找不到源文件：$_sqlPath（请在 advisor_storage 包根目录运行）');
    exitCode = 1;
    return;
  }
  final sql = sqlFile.readAsStringSync();

  // 防御：raw 三引号字符串不能包含连续三个单引号。
  if (sql.contains("'''")) {
    stderr.writeln('schema.sql 含三连单引号，无法内联为 raw 字符串。');
    exitCode = 1;
    return;
  }

  final buffer = StringBuffer()
    ..writeln('// 本文件由 tool/gen_schema.dart 自动生成，请勿手工修改。')
    ..writeln('// 源文件：lib/src/database/schema.sql')
    ..writeln('// 重新生成：cd advisor_storage && dart run tool/gen_schema.dart')
    ..writeln('library;')
    ..writeln()
    ..writeln('/// canonical DDL（与 schema.sql 逐字一致）。')
    ..writeln("const String kAdvisorSchemaSql = r'''")
    ..write(sql)
    ..writeln("''';");

  File(_outPath).writeAsStringSync(buffer.toString());
  stdout.writeln('已生成 $_outPath（内联 ${sql.length} 个字符）');
}
