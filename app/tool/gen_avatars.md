# 头像批处理生成（第 6 轮 T05 · 头像拟人化）

> app 运行时**无图像生成服务**（只有 chat 补全）→ 头像经**批处理一次性生成** PNG 落盘，
> app 侧只做「读取 + 回退」（`AvatarResolver` + `ExpertAvatar`）。本文件是**可复用的再跑说明**。
>
> ⚠️ 本流程**不写数据库、不改 schema、不触碰 `market/`**——头像只是 `<data>/avatars/` 下的本地文件。

---

## 0. 约定（写死）

| 项 | 约定 |
|---|---|
| 存放路径 | `<data>/avatars/<expertId>.png` |
| `<data>`（Windows） | `%APPDATA%/com.example/private_advisor/PrivateAdvisor` |
| `<data>`（macOS） | `~/Library/Application Support/com.example.private_advisor/PrivateAdvisor` |
| 解析优先级 | `Expert.avatarPath`（市场包自带，存在则用）→ `<data>/avatars/<expertId>.png` → `null`（回退首字/emoji） |
| 文件名 | **必须**等于 `experts.id`（本地实例 id，形如 `e_mupgsjty_1ssvkqg001`） |
| 图片规格 | 1024×1024 PNG / JPG 均可（app 显示时缩放到 26–36px）；方形构图、居中 |
| 缺图行为 | `ExpertAvatar` 自动回退**首字圆形头像**（群聊行回退群组图标），**不崩溃、不留白** |
| 市场列表 | **不使用** `ExpertAvatar`（B5 约定维持 emoji），本流程与市场无关 |

> 头像解析代码：`app/lib/infrastructure/avatar/avatar_resolver.dart` + `app/lib/ui/widgets/expert_avatar.dart`。

---

## 1. 枚举需要生成头像的专家

头像**只给已添加专家**生成（市场列表保持 emoji）。从 `experts` 表读 `id` / `name`：

**方式 A：Python（无需 Flutter）**

```bash
python -c "
import sqlite3, os
db = os.path.expandvars(r'%APPDATA%/com.example/private_advisor/PrivateAdvisor/database/advisor.sqlite')
c = sqlite3.connect(db).cursor()
for r in c.execute('select id, name, avatar_path from experts order by created_at'):
    print(r)
"
```

**方式 B：Dart（复用 advisor_storage）**

```dart
// 在 advisor_storage 包内 dart run 一个临时脚本：
// final db = openAdvisorDatabase('<data>/database/advisor.sqlite');
// 复用 sqliteRepositories(db).experts.listExperts() 取 id / name。
```

输出示例（2026-10-01 实测 7 位）：

| expertId | name | 建议配色（提示词用） |
|---|---|---|
| `e_mupgsjty_1ssvkqg001` | Discovery 教练 | teal→mint |
| `e_mupgta7u_09tu0vj003` | UI 设计师 | violet→blue |
| `e_mupgugyv_1g05y4b005` | 前端开发者 | blue→cyan |
| `e_mupgv1ew_0q9r7no007` | 后端架构师 | indigo→slate |
| `e_mupgvtuc_0l0et7w009` | 商务标书专家 | amber→orange |
| `e_mupgwfbg_1ed6zfg00b` | 长篇文档解读专家 | green→teal |
| `e_mupjbwsf_1ucyrek001` | 技术规格专家 | steel-blue→gray |

---

## 2. ImageGen 提示词模板

**统一风格**（保证一组头像视觉一致）：卡通扁平插画、正面、居中、半身、单一中性色渐变背景、方形构图、无文字。

英文模板（实测效果好）：

```
Professional avatar illustration: a {角色描述}, head-and-shoulders portrait,
modern flat vector illustration style, soft {配色} gradient background,
{表情}, minimal, clean, centered circular composition, no text
```

参数：`size="1024x1024"`、`quality="medium"`、`output_dir=<data>/avatars`。

各专家替换项示例：

| expertId | 角色描述（role） | 配色 | 表情 |
|---|---|---|---|
| `e_mupgsjty_1ssvkqg001` | a warm, confident sales discovery coach | teal-to-mint | friendly expression |
| `e_mupgta7u_09tu0vj003` | a creative UI/UX designer | violet-to-blue | approachable expression |
| `e_mupgugyv_1g05y4b005` | a frontend web developer | blue-to-cyan | focused friendly expression |
| `e_mupgv1ew_0q9r7no007` | a senior backend architect engineer | indigo-to-slate | calm confident expression |
| `e_mupgvtuc_0l0et7w009` | a meticulous bid proposal specialist working with business documents | amber-to-orange | professional friendly expression |
| `e_mupgwfbg_1ed6zfg00b` | a tender document analyst expert | green-to-teal | attentive professional expression |
| `e_mupjbwsf_1ucyrek001` | a technical specification consultant specialized in vehicle engineering | steel-blue-to-gray | precise confident expression |

---

## 3. 生成 → 落盘（踩坑与正确做法）

⚠️ **坑：ImageGen 输出文件名是按"秒级时间戳"自动命名的**（如
`Professional_avatar_illustrati_2026-10-01T15-42-14.png`）。**并行**调用会在同一秒内
**互相覆盖**（实测 6 并发只剩 2 个文件）。

✅ **正确做法：一次生成一张，立即重命名落盘**（每次调用间隔 ≥1 秒即不会撞名）：

1. 生成第 i 张 → 得到 `Professional_avatar_illustrati_<ts>.png`；
2. `mv` / `cp` 重命名为 `<data>/avatars/<expertId>.png`；
3. 清理临时文件名残留；再生成下一张。

**安全兜底**（可选，进一步防撞名）：每次指定**独立的 `output_dir`**（如
`<data>/avatars/_gen/<n>/`），生成后把该目录内唯一 PNG 移到 `<data>/avatars/<expertId>.png`，
最后 `rm -rf _gen`。

**校验**（生成后逐张肉眼核对风格与角色匹配，再按色彩/内容归位）：

```bash
ls -la "%APPDATA%/com.example/private_advisor/PrivateAdvisor/avatars"
# 期望：7 个 <expertId>.png，无 Professional_*.png 残留、无 _gen/ 目录
```

---

## 4. 再跑步骤（新增专家后）

1. 按 §1 枚举 `experts` 表，找出**尚无 `<data>/avatars/<id>.png`** 的专家；
2. 按 §2 模板逐位生成（**一次一张**，见 §3 踩坑）；
3. 重命名为 `<data>/avatars/<expertId>.png`；
4. 重启 app（或切页触发重建）即可看到新头像；缺图者自动回退首字/emoji。

> **注**：本流程为**开发者/维护者手动批处理**，非 app 内一键功能（运行时无图像服务）。
> 若某位专家市场包自带 `avatars/expert.png`，安装后 `Expert.avatarPath` 非空，**优先级更高**，无需本流程。
