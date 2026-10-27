# Archive Log — `Done`

Physical `.xcarchive` bundles accumulate under `~/Library/Developer/Xcode/Archives/` (they are **not** in git — each is a signed binary + dSYMs). To reclaim disk without losing the record, this log preserves every archive's metadata; the bundles themselves are pruned.

**Pruned 2026-09-13**: 131 archives (~7.0 GB) recorded below, then deleted **except the current TestFlight build v0.5.0 (b2), 2026-09-08**, which is kept on disk for its dSYMs (crash symbolication of the live beta). dSYMs for older, no-longer-distributed builds are gone; their metadata survives here.

## Milestone nodes (first archive of each version)

| Version | Build | Scheme | First archived | Notes |
|---|---|---|---|---|
| 0.2.2 | 1 | Done | 2026-04-04 06:33 | earliest tracked build |
| 0.2.3 | 1 | Done | 2026-04-14 06:06 |  |
| 0.2.4 | 1 | Done | 2026-04-18 11:21 |  |
| 0.3.0 | 1 | Done | 2026-04-23 13:51 |  |
| 0.4.0 | 1 | Done | 2026-05-23 03:24 |  |
| 0.4.5 | 1 | Done | 2026-06-02 20:17 | long-lived line — marketing version held at 0.4.5/b1 through Jun–Sep while work continued |
| 0.5.0 | 2 | Done | 2026-09-08 04:13 | **current TestFlight build (b2, 2026-09-08)** — resource-waste campaign build (measured perf + Fix Watch resident + hot-path + delta writes); kept on disk |
| 0.1.0 | 1 | OffloadClient | 2026-04-13 10:28 | separate experiment scheme |
| 1.0 | 1 | maymay | 2026-06-15 00:17 | one-off scheme (2026-06-14) |

## Full inventory (131 archives, chronological)

| Created | Version | Build | Scheme | Size (MB) |
|---|---|---|---|---|
| 2026-04-04 06:33:51 | 0.2.2 | 1 | Done | 51.4 |
| 2026-04-04 08:10:45 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-04 10:32:04 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-06 10:30:46 | 0.2.2 | 1 | Done | 51.4 |
| 2026-04-06 15:34:11 | 0.2.2 | 1 | Done | 51.4 |
| 2026-04-06 16:39:43 | 0.2.2 | 1 | Done | 51.2 |
| 2026-04-07 07:26:41 | 0.2.2 | 1 | Done | 51.0 |
| 2026-04-07 08:46:31 | 0.2.2 | 1 | Done | 51.1 |
| 2026-04-08 05:57:22 | 0.2.2 | 1 | Done | 51.1 |
| 2026-04-08 07:33:48 | 0.2.2 | 1 | Done | 51.1 |
| 2026-04-08 07:50:15 | 0.2.2 | 1 | Done | 51.2 |
| 2026-04-08 08:26:52 | 0.2.2 | 1 | Done | 51.2 |
| 2026-04-08 09:29:36 | 0.2.2 | 1 | Done | 51.2 |
| 2026-04-08 10:40:50 | 0.2.2 | 1 | Done | 51.5 |
| 2026-04-09 10:44:09 | 0.2.2 | 1 | Done | 52.0 |
| 2026-04-09 10:45:47 | 0.2.2 | 1 | Done | 52.0 |
| 2026-04-10 08:01:49 | 0.2.2 | 1 | Done | 52.0 |
| 2026-04-10 16:00:57 | 0.2.2 | 1 | Done | 52.1 |
| 2026-04-11 10:09:24 | 0.2.2 | 1 | Done | 52.1 |
| 2026-04-12 06:49:51 | 0.2.2 | 1 | Done | 52.0 |
| 2026-04-12 07:40:08 | 0.2.2 | 1 | Done | 52.1 |
| 2026-04-12 08:00:27 | 0.2.2 | 1 | Done | 52.0 |
| 2026-04-12 08:21:29 | 0.2.2 | 1 | Done | 52.0 |
| 2026-04-12 08:44:18 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-12 08:59:27 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-13 06:01:21 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-13 06:17:44 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-13 07:08:40 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 07:18:16 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 08:17:00 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 09:10:59 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 09:35:43 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 09:47:51 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 10:17:38 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 10:28:06 | 0.1.0 | 1 | OffloadClient | 7.9 |
| 2026-04-13 15:11:52 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-13 15:24:46 | 0.1.0 | 1 | OffloadClient | 7.9 |
| 2026-04-13 15:30:16 | 0.2.2 | 1 | Done | 51.8 |
| 2026-04-13 15:49:39 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 15:52:31 | 0.1.0 | 1 | OffloadClient | 7.9 |
| 2026-04-13 15:54:47 | 0.1.0 | 1 | OffloadClient | 7.9 |
| 2026-04-13 16:00:20 | 0.1.0 | 1 | OffloadClient | 7.9 |
| 2026-04-13 16:04:14 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 16:31:30 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 16:33:15 | 0.1.0 | 1 | OffloadClient | 7.9 |
| 2026-04-13 16:51:24 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 16:57:03 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-13 17:18:00 | 0.2.2 | 1 | Done | 51.9 |
| 2026-04-14 06:06:40 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 06:27:12 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 06:40:54 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 07:11:56 | 0.2.2 | 1 | Done | 52.1 |
| 2026-04-14 07:14:14 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 07:50:11 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 08:05:33 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 08:22:43 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-14 12:03:28 | 0.2.3 | 1 | Done | 52.1 |
| 2026-04-15 06:42:18 | 0.2.3 | 1 | Done | 52.7 |
| 2026-04-17 08:02:08 | 0.2.3 | 1 | Done | 52.7 |
| 2026-04-18 09:42:10 | 0.2.3 | 1 | Done | 52.9 |
| 2026-04-18 10:09:35 | 0.2.3 | 1 | Done | 52.9 |
| 2026-04-18 11:21:20 | 0.2.4 | 1 | Done | 53.0 |
| 2026-04-18 12:00:23 | 0.2.4 | 1 | Done | 53.0 |
| 2026-04-23 13:51:18 | 0.3.0 | 1 | Done | 53.1 |
| 2026-04-24 10:42:38 | 0.3.0 | 1 | Done | 53.0 |
| 2026-04-24 16:40:03 | 0.1.0 | 1 | OffloadClient | 9.7 |
| 2026-04-24 17:09:11 | 0.3.0 | 1 | Done | 53.2 |
| 2026-04-24 17:17:17 | 0.1.0 | 1 | OffloadClient | 9.7 |
| 2026-04-24 17:25:42 | 0.3.0 | 1 | Done | 53.2 |
| 2026-04-24 17:55:09 | 0.3.0 | 1 | Done | 52.2 |
| 2026-04-26 09:53:41 | 0.1.0 | 1 | OffloadClient | 10.0 |
| 2026-04-26 10:20:29 | 0.3.0 | 1 | Done | 53.4 |
| 2026-04-29 07:30:21 | 0.3.0 | 1 | Done | 53.6 |
| 2026-05-01 08:43:45 | 0.3.0 | 1 | Done | 54.8 |
| 2026-05-04 18:00:54 | 0.3.0 | 1 | Done | 56.1 |
| 2026-05-04 18:36:02 | 0.3.0 | 1 | Done | 56.1 |
| 2026-05-04 18:57:22 | 0.1.0 | 1 | OffloadClient | 10.5 |
| 2026-05-05 06:40:50 | 0.3.0 | 1 | Done | 56.1 |
| 2026-05-05 06:42:37 | 0.3.0 | 1 | Done | 56.1 |
| 2026-05-05 10:36:28 | 0.3.0 | 1 | Done | 56.3 |
| 2026-05-14 19:33:40 | 0.3.0 | 1 | Done | 59.2 |
| 2026-05-14 20:22:31 | 0.3.0 | 1 | Done | 58.7 |
| 2026-05-14 20:38:41 | 0.3.0 | 1 | Done | 58.7 |
| 2026-05-15 17:01:27 | 0.3.0 | 1 | Done | 58.9 |
| 2026-05-15 18:03:39 | 0.3.0 | 1 | Done | 58.9 |
| 2026-05-15 18:35:20 | 0.3.0 | 1 | Done | 59.0 |
| 2026-05-15 18:48:58 | 0.3.0 | 1 | Done | 59.0 |
| 2026-05-15 18:54:06 | 0.3.0 | 1 | Done | 59.0 |
| 2026-05-15 19:27:54 | 0.3.0 | 1 | Done | 59.0 |
| 2026-05-15 19:47:00 | 0.3.0 | 1 | Done | 59.1 |
| 2026-05-15 20:42:17 | 0.3.0 | 1 | Done | 59.1 |
| 2026-05-15 21:15:01 | 0.3.0 | 1 | Done | 59.2 |
| 2026-05-15 21:26:45 | 0.3.0 | 1 | Done | 59.2 |
| 2026-05-16 03:57:25 | 0.3.0 | 1 | Done | 59.1 |
| 2026-05-23 03:19:42 | 0.3.0 | 1 | Done | 64.1 |
| 2026-05-23 03:22:00 | 0.3.0 | 1 | Done | 64.1 |
| 2026-05-23 03:24:57 | 0.4.0 | 1 | Done | 64.1 |
| 2026-06-01 23:24:18 | 0.4.0 | 1 | Done | 66.9 |
| 2026-06-01 23:49:11 | 0.4.0 | 1 | Done | 66.9 |
| 2026-06-01 23:50:47 | 0.4.0 | 1 | Done | 66.9 |
| 2026-06-02 20:14:39 | 0.4.0 | 1 | Done | 69.0 |
| 2026-06-02 20:17:32 | 0.4.5 | 1 | Done | 69.0 |
| 2026-06-03 06:00:12 | 0.4.5 | 1 | Done | 69.1 |
| 2026-06-03 16:13:18 | 0.4.5 | 1 | Done | 69.1 |
| 2026-06-03 18:05:08 | 0.4.5 | 1 | Done | 69.1 |
| 2026-06-04 22:57:54 | 0.4.5 | 1 | Done | 69.1 |
| 2026-06-05 21:31:45 | 0.4.5 | 1 | Done | 70.9 |
| 2026-06-05 21:44:31 | 0.4.5 | 1 | Done | 70.9 |
| 2026-06-13 23:05:57 | 0.4.5 | 1 | Done | 72.6 |
| 2026-06-14 04:28:26 | 0.4.5 | 1 | Done | 72.5 |
| 2026-06-14 05:29:00 | 0.4.5 | 1 | Done | 72.6 |
| 2026-06-15 00:17:35 | 1.0 | 1 | maymay | 7.1 |
| 2026-06-15 02:51:13 | 0.4.5 | 1 | Done | 71.4 |
| 2026-06-22 18:41:51 | 0.4.5 | 1 | Done | 68.8 |
| 2026-07-02 15:56:28 | 0.4.5 | 1 | Done | 69.8 |
| 2026-07-02 20:34:12 | 0.4.5 | 1 | Done | 69.9 |
| 2026-07-10 15:31:49 | 0.4.5 | 1 | Done | 70.4 |
| 2026-07-12 03:44:51 | 0.4.5 | 1 | Done | 71.9 |
| 2026-07-14 00:15:07 | 0.4.5 | 1 | Done | 72.3 |
| 2026-07-14 14:17:24 | 0.4.5 | 1 | Done | 72.1 |
| 2026-07-20 02:03:42 | 0.4.5 | 1 | Done | 72.6 |
| 2026-07-29 03:00:13 | 0.4.5 | 1 | Done | 73.2 |
| 2026-07-30 14:36:25 | 0.4.5 | 1 | Done | 74.1 |
| 2026-07-30 18:53:25 | 0.4.5 | 1 | Done | 74.1 |
| 2026-08-04 16:43:02 | 0.4.5 | 1 | Done | 75.2 |
| 2026-08-05 02:59:01 | 0.4.5 | 1 | Done | 75.3 |
| 2026-08-11 05:50:54 | 0.4.5 | 1 | Done | 76.8 |
| 2026-09-03 19:08:43 | 0.4.5 | 1 | Done | 77.3 |
| 2026-09-07 21:27:32 | 0.4.5 | 1 | Done | 80.3 |
| 2026-09-07 23:36:51 | 0.4.5 | 1 | Done | 80.3 |
| 2026-09-08 04:13:50 | 0.5.0 | 2 | Done | 80.5  ← **KEPT** |
| 2026-09-16 07:39:00 | 0.5.0 | 3 | Done | ~80 ← **已分发,带泄露 key**(bump `4ee1a68` 早于修复 `3eb5c13` 5 分钟) |
| 2026-09-21 22:59:00 | 0.5.0 | 3 | Done | ~80 |
| 2026-09-21 23:02:00 | 0.5.0 | 4 | Done | ~80 ← **KEPT**,第一个带 gh#232 修复,已上 TestFlight |
| 2026-10-07 16:14:50 | 0.5.0 | 5 | Done | 81 ← **已按用户要求删除**(2026-10-13),从未上传 TestFlight;四条 held 分支首次出包,源 commit `aa577df` 仍在 king 上,可重建 |
| 2026-10-14 16:09:36 | 0.5.0 | 5 | Done | ~81 ← Organizer 手切(`Done 10-14-26, 4.09 PM`),build 号仍是 5,**源 commit 未记录**;是否上传未知 |
| 2026-10-16 20:26:19 | 0.5.0 | 6 | Done | 81 ← `Done build6.xcarchive`,源 commit `a6b034a`(king,merge `47a1410` 之上的 bump),含 `2e93cab`;身份门 ✅;装机反馈「松手跳到左边」→ 被 build 7 取代 |
| 2026-10-16 20:57:26 | 0.5.0 | 7 | Done | 81 ← **KEPT**,`Done build7.xcarchive`,源 commit `f33eb3f`(king,`4639fc4` 之上的 bump),含 `2e93cab`;身份门 ✅;若尚未上传,由 build 8 取代(build 8 包含它的全部内容) |
| 2026-10-17 23:11:21 | 0.5.0 | 8 | Done | 82 ← **KEPT**,`Done build8.xcarchive`,源 commit `c8290d7`(king,merge `5779e97` 之上的 bump),含 `2e93cab`;身份门 ✅;**已上传 TestFlight**(用户 2026-10-19 确认,装机「问题不大」) |

---

## 节点 10 — build 5(2026-10-07):积压两周的 held 工作首次出包

build 4 之后两周零 archive。期间四条分支各自跑完独立验证循环却一条都没装机,积压成本在这里结清。

- **含**:#234 auth 终端分类 · #235 日历增量写(461× 写入降幅)· #229 note 落盘防抖 · #181 密集日拖拽 memo
- **不含**:#231(flag 门控测量 spike,设计上永不进生产)· #239(同日归档到 `archive/widget-layout-239`,装机截图仍是老症状)
- **合并方式**:逐条合 + 每条后跑全套,1759 → 1895 → 1921 → 1931,0 失败
- **合并点才暴露的一处**:#229 的 13 个 `onSlotCommitted` 单参数闭包撞上 #235 改宽的两参数签名,编译失败且编译器报不出原因("failed to produce diagnostic")。两条分支各自绿
- **身份门**:`sb_publishable_` ×1 ✅ · 泄露 key 前缀 `LUwM3K` ×0 ✅ · JWT 形状字符串 ×0 ✅
- **口径**:marketing version 刻意留 0.5.0 —— 内测阶段同一 version 多个 build
- **2026-10-13 结局**:**archive 已按用户要求删除,从未上传 TestFlight**。删除前核过可重建性:源 commit `aa577df` 在 king 上,四条分支的内容全在历史里。它的作用是证明积压已清,不是待分发的产物 —— 装机验证转由 build 6 承载,见节点 11

---

## 节点 11 — build 6(2026-10-16):擦除家族 + 日历重叠排列

- **源**:king `a6b034a`(bump 提交,在 merge `47a1410` 之上;含安全修复 `2e93cab`)。archive `~/Library/Developer/Xcode/Archives/2026-10-16/Done build6.xcarchive`,0.5.0 · 6,81M,本地时间 20:26。
- **含**:擦除完整性家族 gh#255/#256/#258/#260/#261/#263/#265/#266(king `739fee9`,见 RELEASE_CHECK 顶部)· **日历重叠排列**(merge `47a1410`,七个 commit:落地 peek 门问 host 三问 / 拖拽中被拖事件占右半列 / 放下后 drop 目标列真正回到 `.auto` / in-grid preview 不再滞后一个触摸事件)。
- **不含**:gh#266 的 `ErasableLocalStore` 注册表 · 普查 · gh#239 小组件簇(`archive/widget-layout-239`)· 报告 token 晚一跳等三项刻意未动(见 RELEASE_CHECK)。
- **身份门**:`sb_publishable_` ×1 ✅ · 泄露 key 前缀 `LUwM3K` ×0 ✅ · JWT 形状字符串 ×0 ✅ · Info.plist 读出 0.5.0 / 6 ✅。
- **验证**:合并树全量 **2004 / 0 / 1 skip**。重叠排列这条走了三轮独立 review + 两轮独立 QA(变异 20+ 全杀,等价变异 3 个;fuzz 800 簇零失败;带 UIWindow 的 harness 覆盖 preview / 跨列 / 落地 / resize)。
- **本版装机重点**:RELEASE_CHECK ③ 四条 + 擦除完整性验收 + **新增**:拖拽手感(进簇半列、落地 1/2→1/3 跳变、resize 也 held)和截图场景落地后是否并排三列。
- **同日清理**:上一版 10-07 的 build5 archive 已于 10-13 删除;10-14 的 Organizer 手切包(build 号 5)保留在 Archives 目录,来源提交未记录。

---

## 节点 12 — build 7(2026-10-16):held 放到落地那一侧

- **源**:king `f33eb3f`(bump,在 `4639fc4` 之上;含 `2e93cab`)。archive `~/Library/Developer/Xcode/Archives/2026-10-16/Done build7.xcarchive`,0.5.0 · 7,81M,本地时间 20:57。
- **与 build 6 的唯一差别**:`4639fc4` —— build 6 装机反馈「松手那一下被拖的事件从右半边跳到左边」。live 的 `.held` 先对簇跑一遍 `.auto`,把被拖事件放到它落地会去的那一侧(最左 / 底座 → 左半,否则右半),其余在另一半等分;松手只变宽度。两个方向的强制变异各被 4–5 个测试抓到;全量 2004/0。
- **身份门**:`sb_publishable_` ×1 ✅ · `LUwM3K` ×0 ✅ · JWT 形状 ×0 ✅ · Info.plist 0.5.0 / 7 ✅。
- **装机重点**:同节点 11,外加:拖过邻居起点时被拖块会中途换边(这是在预览落地位置),看是否可接受。

---

## 节点 13 — build 8(2026-10-17):小组件第一次出包

- **来源**:king `c8290d7`(bump 提交,在 merge `5779e97` 之上;含安全修复 `2e93cab`)。archive 路径 `~/Library/Developer/Xcode/Archives/2026-10-17/Done build8.xcarchive`,0.5.0 · 8,82M,本地时间 23:11。
- **相对 build 7 新增**:
  - gh#239 小组件排版修复(merge `12ef94f`;#239 已关);
  - gh#248 四项(merge `5779e97`):小号列表的后续事件、时间条两行标题、列表跟随系统字号、列表组件画廊名本地化。
- **不含**:
  - gh#245 第 3 条;
  - gh#248 的占位态,以及画廊字符串只在启动时求值一次;
  - gh#269 的 X5 / SE 截断;
  - 时间条短标题也用两行行距的问题(终审发现,用户定下一版修,记在 #248)。
- **身份门**:
  - `sb_publishable_` ×1 ✅;
  - `LUwM3K` app ×0 / widget ×0 ✅;
  - JWT 形状 ×0 ✅;
  - app 和 widget 的 Info.plist 都是 0.5.0 / 8 ✅;
  - widget dSYM 含 `miniTitleRun` / `smallListFollowing`,确认新代码在包里。小组件的短字符串在 Swift 里是内联存储,所以 `strings` 搜不到,不能拿来当这一项的判据。
- **验证**:
  - 合并树全量 2103 / 0 / 1 skip。
  - #239:四台模拟器边界 QA,八轮;独立变异 44 个杀 43 个,剩 1 个等价。
  - #248:模拟器复核 10/10(含最大字号冷启动);终审结论 ship-with-notes;变异 32 个杀 20 个,11 个测试缺口随后补,不影响本包。
- **打包过程中的一次失败**:清空 DerivedData 后第一次打包时,Swift 包解析报 `invalid custom path 'SwiftDraw/Sources'`。原因是 SwiftDraw 的检出还没完成就开始解析了。先单独跑一遍 `xcodebuild -resolvePackageDependencies`,再打包就成功了。
- **装机重点**:RELEASE_CHECK ③ 新增的「小组件」一节。这些组件全程只在模拟器上验证过,这是第一次上真机。
- **2026-10-19**:用户确认已上传 TestFlight,装机「问题不大」。build 8 之后合入的 af9a30e(时间条两行只在标题需要时才用,以及 #248 的测试缺口)要等下一个 build 才会带上。

---

## 节点 14 — build 9（2026-10-20）：两个类别小组件

- **来源**：king `b8501f7`（bump 提交，在 merge `5ec8f68` 之上；含安全修复 `2e93cab`）。archive `~/Library/Developer/Xcode/Archives/2026-10-20/Done build9.xcarchive`，0.5.0 · 9，83M，本地时间 20:36。
- **相对 build 8 新增**：
  - 时间条跟进（merge `af9a30e`）：第二行只在标题需要时才用，补上 #248 的测试缺口；
  - **「按类别占比」小组件**（merge `6962af5`）：今天 / 本周 / 本月、占已记录 / 占已过去、排除背景类别；主屏小号、中号，锁屏长条、圆形；
  - **「类别仪表」小组件**（merge `7e43ce8` → `0d630b6` → `5ec8f68`）：无字 270° 缺底弧，只有主屏小号；全彩每类一段不设上限，着色 4 类 + 其余；「分段间隔」开关默认关。
- **不含**：类别仪表说明里「背景类别在哪设」那句；两个新组件在用户自选白 / 近黑 / 浅灰 / 半透明色下会融进背景或轨道；锁屏长条「占已过去时间」只列第一名 + 未记录，不满 100%（有意）。
- **身份门**：`sb_publishable_` ×1 ✅ · `LUwM3K` app ×0 / widget ×0 ✅ · JWT 形状 app ×0 / widget ×0 ✅ · app 与 widget 的 Info.plist 都是 0.5.0 / 9 ✅ · widget dSYM 含 `CategoryGauge` ×232、`CategoryStats` ×1001，widget 二进制含 `DoneCategoryStatsWidget` / `DoneCategoryGaugeWidget` 两个 kind ✅。
- **验证**：合并树全量 2233 / 0 / 2 skip（已知的 AgenticIntake 一个，仪表的 PNG 写盘一个）。按类别占比：两轮修复、渲染 QA 约 3.8 万格 0 越界、变异全杀。类别仪表：两轮 Fable 独立审查 + 一轮 Fable 渲染 QA（1728 格 0 越界；两台模拟器主屏 / 画廊 / 编辑页），审查抓到两个真问题（着色阶梯只有 5 档、半透明色下 1pt 叠色）均已修。用户拍板「小 feature 不要花过多代价」后不再加轮次。
- **打包**：DerivedData 在外接盘 `/Volumes/AgentAPFS/dd9rel`；先单独 `-resolvePackageDependencies` 再 archive，一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 9 装机重点」。上传 TestFlight 是用户动作。

---

## 节点 15 — build 10（2026-10-21）：实时同步上线

- **来源**：`release/build10` @ `b3b0a55`（bump `72cc0e1` 在 `5df8370` 之上，再合入 king 的 `6208204` 与只动服务端的 `79ed917`；含安全修复 `2e93cab`）。archive `~/Library/Developer/Xcode/Archives/2026-10-21/Done build10.xcarchive`，0.5.0 · 10，87M，本地时间 21:54。最初在 `72cc0e1` 上 20:40 打的那个包没有上传过，已被这次重打取代并删除，build 号仍是 10。
- **相对 build 9 新增**：
  - **全平台实时同步**（gh#257）：同一账号下所有设备的所有数据实时同步（门铃约 1 s），删除也同步；需要服务端迁移 015；登录后第一次自动追平。
  - **换账号：数据跟账号走**：本机数据全在云端就直接切；本机有没同步的改动才弹「本机还有 N 条修改没有同步到云端，现在切换会丢失它们。」+「仍要切换 / 取消」。
  - **恢复提示**：服务端整库恢复后弹一次，可写回 / 稍后 / 丢弃，写回保两份。
  - 账户卡片「同步」总开关与状态行；同步设置（语言等）跨设备，最后选中的 tab 与日历视图留本机；旧「从云端恢复」sheet 在新服务端退役。
  - **类别仪表圆心**（merge `5df8370`）：显示已记录时长与时段。
  - 聊天记录行(agent_conversations)编码顺序固定,不再每次启动重传(6208204)。
- **不含 / 已知**：未登录时的游客示例数据登录后会上传（默认绑账号待定）；偏好丢失时语言临时回英文；Google 登录配置本就不完整；启动弹窗点「取消」后留在日历页。
- **身份门**：
  - app 与 widget 的 Info.plist 都是 0.5.0 / 10 ✅；
  - `LUwM3K` app ×0 / widget ×0 ✅；JWT 形状 app ×0 / widget ×0 ✅；`sb_secret_` ×0 ✅；
  - `sb_publishable_` app ×1 / widget ×0：**只有生产那一把**（`sb_publishable_1Cd8…`），域名只有 `uqnvtzblppjblwgbpqhf.supabase.co` ×1。staging 的 key / 域名和 local 的 `127.0.0.1:54321` 在二进制里按原始字节搜都是 ×0——Release 下 `SupabaseEnvironment.current` 恒为生产，编译器把另两个环境的常量整个裁掉了。这一项比预期（两把 key）更严，是好事；
  - Release 选生产：`SupabaseEnvironmentTests` 全过（含 `testAReleaseBuildIsProductionWhateverTheLaunchSays`）；`SYNC_ENV` / `SYNC_DEBUG_SESSION` 都只在 `#if DEBUG` 里，包内 ×0；
  - app dSYM 含 `SyncPuller` ×242、`SyncCatchUp` ×150、`SyncRecovery` ×508、`SyncOwnerRecord` ×53；app dSYM 含 `AgentConversation` ×718，其中 `6208204` 新增的 `orderedIDs` ×16（20:40 那个旧包里是 ×0）；widget dSYM 含 `GaugeWords` ×48（圆心文字视图），widget 二进制含 `DoneCategoryGaugeWidget` / `DoneCategoryStatsWidget` ✅。
- **验证**：`b3b0a55` 全量 2826 / 0 / 2 skip（AgenticIntake 一个、仪表 PNG 写盘一个；新增的 `AgentConversationEncodingTests` 5 个全过），iPhone 17 Pro 模拟器；此前 `5df8370` 为 2821 / 0 / 2。staging 真实数据彩排(P2):5075 条原地升级不丢不重复;生产 015 已于 2026-10-22 01:23Z 应用,逐行对拍 14532 行 lost=0 changed=0。同步：模拟器 QA 三轮 + staging（`done-staging`）QA 五轮（第四到第八轮，真账号 qa-a / qa-b），第八轮无 bug；详见 `Docs/sync/04-design-changelog.md`。SE 真机：见编排方记录。
- **打包**：DerivedData `/Volumes/AgentAPFS/done-sync/dd10rel`；先单独 `-resolvePackageDependencies` 再 archive，一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 10 装机重点」——18 Pro 升级后首启不该弹任何提示、事件数不变、账户卡片「已连接」；SE 登录同一账号后增删改与删除两边互通；旧小组件设置还在。
- **上传 TestFlight 是用户动作。**

## 节点 16 — build 11（2026-10-22）：类型推荐改写 + 同名类型胜者

- **来源**：`release/build11` @ `c84d2ab`（bump 在 merge `4e38fc2` 之上，`4e38fc2` = king `43f654a` + `feat/type-suggest-tokens` `e8cce91`；含 `6de93d8`）。archive `~/Library/Developer/Xcode/Archives/2026-10-22/Done build11.xcarchive`，0.5.0 · 11，87M，本地时间 09:34。
- **相对 build 10 新增**：
  - **类型推荐**（merge `4e38fc2`）：NLTokenizer 分词（中文也分）+ 相邻词对；每个词按历史里落在哪些类型上算「预测性 / 方向性」，90 天半衰；有预测性词撑腰且领先第二名 2 倍才选，否则不动类型（边打字与保存后都一样）；内置英文关键词表只在历史从没见过这些词时才用。
  - **同名类型胜者**（`6de93d8`）：首次全量拉取时同名类型留服务端 `updated_at` 最新者（build 10 装机后的类型颜色事故）。
- **身份门**：app 与 widget 的 Info.plist 都是 0.5.0 / 11 ✅；`LUwM3K` app ×0 / widget ×0 ✅；JWT 形状 ×0 / ×0 ✅；`sb_secret_` ×0 / ×0 ✅；`sb_publishable_` app ×1 / widget ×0，生产域名 ×1 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；签名 Apple Development: Yifan Mei (68QDD6QY34)；app dSYM 含 `calendarHistoricalTypeEvidence` ×39，二进制引用 `NLTokenizer` ✅。
- **验证**：merge `4e38fc2` 全量 2841 / 0 / 2 skip，iPhone 17 Pro 模拟器（iOS 26.4）。类型推荐两个测试类 35 / 0；新增 9 个用例在旧打分器（垫片转接签名）下 8 个红、13 处断言失败。
- **打包**：DerivedData `/Volumes/AgentAPFS/claude-build-cache/b11-rel-dd`，archive 一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 11 装机重点」。
- **上传 TestFlight 是用户动作。**

## 节点 17 — build 12（2026-10-25）：Apple Watch app + 遥测底盘 + 删除动效

- **来源**：`release/build12` @ `27655ae`（bump 在 king `bbe6519` 之上；含手表 merge `799040f`、遥测 gh#273、删除动效 merge `1f6899c`；含安全修复 `2e93cab`）。archive `~/Library/Developer/Xcode/Archives/2026-10-25/Done build12.xcarchive`，0.5.0 · 12，93M，本地时间 17:27。
- **相对 build 11 新增**：Apple Watch app（gh#274，第一次上真机）；遥测底盘（gh#273，默认关）；时间线删除动效（默认溶解）。
- **身份门**：app / widget / watch 三个 Info.plist 都是 0.5.0 / 12 ✅（手表与 iOS build 号一致，App Store 校验要求）；手表 `WKCompanionAppBundleIdentifier` = `wordless.shiqiliuyifanmei.app` ✅；`LUwM3K` ×0/×0/×0 ✅；JWT 形状 ×0/×0/×0 ✅；`sb_secret_` ×0/×0/×0 ✅；`sb_publishable_` app ×1、widget ×0、watch ×0 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；手表 DEBUG 驱动参数 `wristAutoStart` ×0 ✅；签名 Apple Development: Yifan Mei (68QDD6QY34)，`codesign --verify --deep --strict` 通过。
- **导出预演**：`-exportArchive` method app-store-connect、destination export 成功；自动签名为新 bundle id `…watchkitapp` 生成了 App Store 分发 profile，手表 app 由 Apple Distribution 签名。上传时不应再卡签名。
- **验证**：全量 3032 / 16 断言失败（4 个测试）/ 2 skip，iPhone 17 Pro 模拟器。4 个失败均为 SyncApplierTests ×2、SyncCatchUpTests ×2 的「shared token state is empty」夹具守卫：测试依赖模拟器上 app 容器里的真实 token 推断状态，分支点 fd92618 同样红，非产品问题。手表 wrist 套件 87/87，配对模拟器端到端七轮。
- **打包**：DerivedData `/Volumes/AgentAPFS/claude-build-cache/b12/rel-dd`，archive 一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 12 装机重点」。
- **上传 TestFlight 是用户动作。**

## 节点 18 — build 13（2026-10-25）：手表当天视图

- **来源**：`release/build13` @ `d7c7167`（bump 在 king `a410b3e` 之上 = build 12 + 手表当天视图 merge；含安全修复 `2e93cab`）。archive `~/Library/Developer/Xcode/Archives/2026-10-25/Done build13.xcarchive`，0.5.0 · 13，95M，本地时间 18:58。
- **相对 build 12 新增**：手表三页（记录 / 今天时间轴 / 统计），统计复用小组件 payload；快照体积阶梯 ≤ 60,000 B。
- **身份门**：app / widget / watch 三个 Info.plist 都是 0.5.0 / 13 ✅；`LUwM3K` ×0/×0/×0 ✅；JWT 形状 ×0 ✅；`sb_secret_` ×0 ✅；`sb_publishable_` app ×1、widget ×0、watch ×0 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；手表调试参数（`wristAutoStart` / `wristPage`）×0 ✅；`codesign --verify --deep --strict` 通过；`-exportArchive` app-store-connect 预演成功。
- **验证**：全量 3053 / 16 断言失败（4 个测试）/ 2 skip，iPhone 17 Pro 模拟器；4 个失败与 build 12 相同（SyncApplierTests ×2、SyncCatchUpTests ×2 夹具读模拟器上的真实 token 推断状态，非产品问题）。手表套件 115/115。
- **打包**：DerivedData `/Volumes/AgentAPFS/claude-build-cache/b13/rel-dd`，archive 一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 13 装机重点」。
- **上传 TestFlight 是用户动作。**


## 节点 19 — build 14（2026-10-25）：手表观感与滚动统计口径

- **来源**：`release/build14` @ `dffc108`（bump 在 king `fd782be` + merge `e2855ab` 之上）。archive `~/Library/Developer/Xcode/Archives/2026-10-25/Done build14.xcarchive`，0.5.0 · 14，95M，本地时间 23:33。
- **相对 build 13 新增**：手表三页统一框架（时钟行信息 + 浅磨砂玻璃、无大标题、白字、手机配色）；统计口径今天 / 近 3 / 7 / 30 天点按切换；小组件 payload 往前写到 30 天前，快照阶梯 30 天 → 7 天 → 3 天 → 无统计。
- **身份门**：app / widget / watch 三个 Info.plist 都是 0.5.0 / 14 ✅；`LUwM3K` ×0/×0/×0 ✅；JWT 形状 ×0 ✅；`sb_secret_` ×0 ✅；`sb_publishable_` app ×1、widget ×0、watch ×0 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；手表调试参数（`wristAutoStart` / `wristPage` / `wristStatsPeriod`）×0 ✅；`codesign --verify --deep --strict` 通过；`-exportArchive` app-store-connect 预演成功。
- **验证**：全量 3055 / 0 失败 / 2 skip，专用 iPhone 17 Full 模拟器先 erase（build 13 的 4 个同步夹具红在干净机上不出现）。
- **打包**：DerivedData `/Volumes/AgentAPFS/claude-build-cache/b14/rel-dd`，archive 一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 14 装机重点」。
- **上传 TestFlight 是用户动作。**

## 节点 20 — build 15（2026-10-26）：创建动效 + 膨胀破裂 + 周视图圆角

- **来源**：`release/build15` @ `014cc5f`（bump 在 king `ffd0167` 之上 = build 14 + 创建动效 / 膨胀破裂 merge + 周视图圆角 `56f358a`）。archive `~/Library/Developer/Xcode/Archives/2026-10-26/Done build15.xcarchive`，0.5.0 · 15，96M，本地时间 00:47。build 14 未上传，被本版取代。
- **身份门**：app / widget / watch 三个 Info.plist 都是 0.5.0 / 15 ✅；`LUwM3K` ×0/×0/×0 ✅；JWT 形状 ×0 ✅；`sb_secret_` ×0 ✅；`sb_publishable_` app ×1、widget ×0、watch ×0 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；手表调试参数 ×0 ✅；`codesign --verify --deep --strict` 通过；`-exportArchive` app-store-connect 预演成功。
- **验证**：全量 3099 / 0 失败 / 2 skip，专用 iPhone 17 Full 模拟器先 erase。
- **打包**：DerivedData `/Volumes/AgentAPFS/claude-build-cache/b15/rel-dd`，archive 一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 15 装机重点」。
- **上传 TestFlight 是用户动作。**

## 节点 21 — build 16（2026-10-26）：调时长补帧 + 创建动效点保存即播

- **来源**：`release/build16` @ `5374acd`（bump 在 king `5157670` + `b62e375` 之上 = build 15 + 调时长补帧 merge + 创建动效点保存即播）。archive `~/Library/Developer/Xcode/Archives/2026-10-26/Done build16.xcarchive`，0.5.0 · 16，96M。build 15 若未上传，被本版取代。
- **身份门**：app / widget / watch 三个 Info.plist 都是 0.5.0 / 16 ✅；`LUwM3K` ×0/×0/×0 ✅；JWT 形状 ×0 ✅；`sb_secret_` ×0 ✅；`sb_publishable_` app ×1、widget ×0、watch ×0 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；手表调试参数 ×0 ✅；`codesign --verify --deep --strict` 通过；`-exportArchive` app-store-connect 预演成功。
- **验证**：全量 3105 / 0 失败 / 2 skip（king `76a49b6` 合并树），专用 iPhone 17 模拟器先 erase。
- **打包**：DerivedData `/Volumes/AgentAPFS/claude-build-cache/b16/rel-dd`，archive 一次成功。
- **装机重点**：见 RELEASE_CHECK 顶部「build 16 装机重点」。
- **上传 TestFlight 是用户动作。**

## 节点 22 — build 17（2026-10-27）：手表修复 + 拖拽建块 + 名字推荐 + 手表设置

- **来源**：`release/build17-candidate` @ `82b2c80`（king `74e07cf` = build 16 之上 merge 手表分支 `f3df873` + 审查修复 `21ae787` + bump）。archive `~/Library/Developer/Xcode/Archives/2026-10-27/Done build17.xcarchive`，0.5.0 · 17，98M，本地时间 00:07。
- **相对 build 16 新增**：手表计时页每帧重绘修复（真机「删除后卡死」的根因）；手表开始按 15 分钟吸附；今天页长按拖拽建块；按时段/时长/星期/前后事件/距首条记录推荐名字；设置 → Apple Watch（默认口径、重叠算法、计入类型）。
- **审查**：独立审查无 ship-blocker；三条 should-fix（名字表序号两端不一致、重复事件不进邻居、已结束系列不衰减）已修并各配回归测试，旧代码下 4 处断言失败。余下 nit 见 RELEASE_CHECK。
- **身份门**：app / widget / watch 三个 Info.plist 都是 0.5.0 / 17 ✅；`LUwM3K` ×0/×0/×0 ✅；JWT 形状 ×0 ✅；`sb_secret_` ×0 ✅；`sb_publishable_` app ×1、widget ×0、watch ×0 ✅；`SYNC_DEBUG_SESSION` ×0 ✅；手表全部调试参数 ×0 ✅；`codesign --verify --deep --strict` 通过；`-exportArchive` app-store-connect 预演成功。
- **验证**：全量 3173 / 0 失败 / 2 skip，专用 iPhone 17 Full 模拟器先 erase。
- **上传 TestFlight 是用户动作。**

## 节点 23 — build 18（2026-10-27）：手表今天页放大 + 拖拽边缘滚动

- **来源**：`release/build18` @ `712b965`（king `c60dff0` = build 17 + `feat/watch-timeline-scale` + bump）。archive `~/Library/Developer/Xcode/Archives/2026-10-27/Done build18.xcarchive`，0.5.0 · 18，98M，本地时间 00:35。
- **相对 build 17 新增**：手表今天页一小时 64pt（原 34pt），块显示名字 + 时间，打开以现在居中；拖拽建块到上下边缘自动滚动；邻块吸附 8pt。
- **身份门**：三个 Info.plist 0.5.0 / 18 ✅；`LUwM3K` / JWT / `sb_secret_` / `SYNC_DEBUG_SESSION` / 手表调试参数 ×0 ✅；`sb_publishable_` 仅 app ×1 ✅；codesign 通过；`-exportArchive` 预演成功。
- **验证**：全量 3173 / 0 失败 / 2 skip（专用机先 erase）；手表 177/0；模拟器实测边缘滚动（5–8 点 → 8–11 点，块 06:45–11:30）。
- **上传 TestFlight 是用户动作。**
