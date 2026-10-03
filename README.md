# 私人顾问团 · Private Advisor

> 一个**本地优先**的 AI 专家顾问团桌面工作台 —— 把大模型组织成一支可自定义的顾问团队。

面向 Windows 桌面的多专家协作应用。你可以在「人才市场」招募不同领域的 AI 专家，把它们加进
「通讯录」；与单个专家一对一会话，或把多位专家拉进「群聊」围绕同一个问题协作；也可以接入本地
文件夹构建「知识库」，让专家基于你自己的资料回答。

**所有数据都留在本机**（SQLite 数据库 + 系统凭据库），不上传任何云端。

---

## 核心功能

| 模块 | 能力 |
|---|---|
| **会话** | 单聊 / 群聊流式对话；Enter 发送、Shift+Enter 换行；群聊 @ 点名；右键菜单（置顶 / 清空 / 删除） |
| **群聊协作** | 组长制发言编排（组长先行 + 按相关度筛选发言人）、@ 提名、群公告与发言范围指令、静默契约（成员可声明本轮不参与） |
| **通讯录** | 好友（首字母排序）/ 分组 / 群聊三页签；专家备注名；头像支持 emoji 或本地图片 |
| **人才市场** | 浏览与检索专家包，一键安装；安装走 **10 步安全校验链**（清单解析 → 签名 → SHA256 → Schema → 体积 → 路径安全 → 能力声明 → 可执行扫描 → 版本兼容） |
| **知识库** | 关联本地文件夹（可多选）；两阶段重扫（干跑计划 → 三防线确认 → 执行）；中文全文检索（FTS5 + 应用层 bigram） |
| **附件** | 文件 / 图片随消息发送；文档自动抽取文本注入上下文；图片走多模态（需模型支持视觉） |
| **专家导入 / 导出** | 复用市场 `.expert` 包格式（ZIP）；冲突默认「新建副本」，绝不破坏既有专家；**明文 API Key 永不导出**，导入侧另做疑似密钥扫描 |
| **大模型管理** | 可注册多个模型（含自定义 OpenAI 兼容端点）、设置全局默认；每位专家可单独覆盖 |
| **设置** | 默认 API Key（仅存系统凭据库，不写库不写日志）、模型视觉能力开关 |

## 技术架构

```
app (Flutter 桌面)  →  advisor_storage (纯 Dart 存储)  →  advisor_core (纯 Dart 领域 + 应用)
```

- **`advisor_core`** —— 领域模型与应用服务，**零基础设施依赖**（不依赖 Flutter / SQLite / HTTP），
  可在纯 Dart 环境下完整测试；仓储端口（interface）定义在此。
- **`advisor_storage`** —— SQLite 仓储实现 + schema + 迁移链（`PRAGMA user_version`，**只做 additive 迁移**，当前 v9）；
  数据库异常统一归一化为 `StorageError`。
- **`app`** —— Flutter 三栏界面（左侧导航 / 中栏列表 / 右侧详情）；UI 只调用应用层服务，不直接访问数据库。

## 快速开始

**环境要求**：Flutter 3.44+（Dart 3.12+）、Windows 10/11、Visual Studio 生成工具（勾选「使用 C++ 的桌面开发」）。

```bash
cd app
flutter pub get
flutter run -d windows          # 开发模式，支持热重载
```

打包正式版：

```bash
flutter build windows --release
# 产物目录：app/build/windows/x64/runner/Release/
```

首次启动后，在「设置」中填入你自己的大模型 API Key（支持任何 OpenAI 兼容端点，例如 DeepSeek），
即可开始使用；随后可在「人才市场」招募专家。

## 项目结构

```
app/                  Flutter 应用（界面层 + 平台适配）
  lib/features/       会话 / 通讯录 / 人才市场 / 知识库 / 设置
  lib/ui/             主题、尺寸、通用组件
  windows/            Windows 平台工程（图标、CMake）
advisor_core/         纯 Dart：领域模型 + 应用服务 + 仓储端口
  lib/domain/         实体、规则、编排策略
  lib/application/    服务与编排（专家 / 会话 / 群聊 / 市场 / 知识库 / 附件 / 导入导出）
  testing/            内存替身仓储（供测试）
advisor_storage/      纯 Dart：SQLite 仓储实现 + schema + 迁移
docs/                 工程契约（数据库与迁移、接口契约等）
```

## 开发与测试

本项目自带大量 `dart run` 断言脚本，**无需 Flutter 运行时**即可执行：

```bash
cd advisor_core    && dart run tool/verify.dart            # 领域层回归
cd advisor_storage && dart run tool/verify_storage.dart    # 存储层回归（含迁移链）
```

## 许可

[MIT](LICENSE)
