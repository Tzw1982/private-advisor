// 冒烟测试（第 7 轮 T06 修复）。
//
// 背景：本文件原为 Flutter 模板残留，引用了**从不存在的 `MyApp`**，
// 导致静态分析报 `creation_with_non_type`（appcheck ERROR）。
// 真实根 widget 是 `main.dart` 中的 `PrivateAdvisorApp`（需 Bootstrap，
// 构造依赖 DB/网络装配套件，不便于在单元测试里直接 pump）。
//
// 这里改为：① 引用真实根 widget 类型，锁死"根 widget 存在"这一事实；
//           ② 用一个无外部依赖的真实子组件 `EmptyPane` 渲染一帧，
//              确保 widget 层可正常构建（最小 smoke）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_advisor/main.dart';
import 'package:private_advisor/ui/widgets/empty_pane.dart';

void main() {
  testWidgets('真实根 widget 类型可达（防误引不存在的类型）', (WidgetTester tester) async {
    // 若 `PrivateAdvisorApp` 不存在，此处会直接编译失败——
    // 正是本文件此前引用 `MyApp` 暴露的问题。
    expect(PrivateAdvisorApp, isNotNull);
  });

  testWidgets('EmptyPane 渲染一帧（最小冒烟）', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyPane(title: 'Smoke'),
        ),
      ),
    );
    expect(find.text('Smoke'), findsOneWidget);
  });
}
