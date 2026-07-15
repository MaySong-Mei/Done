# Report System 研究报告（2026-07-15）

> 分支 `research/report-system`，基于 `king-of-rubbish-bin` @ `4f762f2`。所有 `file:line` 引用以此为准。
> 结论先行：**#111 已经不是"暂缓的设计构想"——P0 已在 07-02～07-11 全部建成并合入 king，且远超当初 P0 范围**（EVENTS block、vision、memory v1、AFM 端上、确定性图表都已落地）。Discussion #111 文档停在 07-02（"当前只存计划，未动工"），与代码现实脱节两周。当前最实的活是 #116（报告与 Analysis 双数字分歧）和一批评审遗留项。

---

## 一、时间线（设计 → 评审 → 建成）

| 日期 | 事件 |
|---|---|
| 06-22 | Discussion #111 立项（生成式报告系统设计构想，暂缓） |
| 06-24 / 06-30 | 两轮收敛：`report = f(data)` 双模式（总结 P0 / 分析延后），报告即记忆 |
| 07-01 | DnD 留存仿真（禁鸡汤、三种杠杆、忌复读机）；AFM 转向评审 |
| 07-02 上午 | 定稿：no-imply 报告定义 + 阶段一 P0 四层计划（统一云模型） |
| 07-02 | 五方 panel 对抗评审：5/5 共识"写代码前先做真人 WoZ" |
| **07-02 当天** | **P0 一天建成**（`acba127`：统计层 + 生成 + 本地存储 + Analysis 卡片入口），随即 owner 决策改独立 tab（`705cf9c`）、接 AFM（`b6dfcc2`）、editorial 阅读设计、prompt v2 persona（`997cc11`） |
| 07-07 | EVENTS block（原始记录进 prompt）、端到端 vision、确定性图表（`b015f4f`） |
| 07-09 | memory v1（旧报告回流 + frozen spine + userNote 闭环）、backfill awareness（`4ef9f61`） |
| 07-11 | 合入 king（`57c0fa9`）；partial-window 精化 |
| 07-12 | Analysis 侧 overlap-sharing（`0797421`）**未同步到报告侧** |
| 07-14 | **#116 立案**：Report stats 与 Analysis charts 在重叠事件上分歧 |

评审要求的 WoZ 没有做——实际走的是"直接建 + dogfood 迭代"。dogfood 的痕迹已进代码：`charsPerToken` 3→2 的 CJK 修正（`ReportModels.swift:119-126`）、prompt v2 注释"太 technical"（`ReportGenerationService.swift:652-660`）。

## 二、架构现状（已建成的东西）

```
EventStore（@MainActor，主线程快照）
  canvasRenderableCalendarEvents + logRecords + feedbackRecords
        │
        ▼  （非隔离 async，统计在后台跑）
ReportStatsBuilder.build(events, start, end, calendar)   ← 纯函数，无 Date()/无 store
  · perTypeHours：midnight-split + 权重多类型分摊 + interrupt netting
  · sessionDaily：整段归 dominant day（跨夜修复，评审要求 ✓）
  · typePairRelations：top-6 类目 generic pairwise Pearson（用户原词，无语义锚点 ✓）
  · 置信度三信号：overlapDays / 半窗符号一致性 / 效应量 → low 直接不进 prompt
        │
        ▼
ReportStats.promptText(budget:)          ← token 预算参数（评审建议 8 ✓）
+ promptEvents(...)                      ← EVENTS block：记录明细 + LOG/FELT/NOTE 子行 + [photo #k]
+ memoryBlock(...)                       ← 同 kind 旧报告×2：USER NOTES > backfill hint > frozen spine > 旧散文
        │
        ▼
LLMProvider.send / sendVision（BYOK Claude/OpenAI/DeepSeek + AFM 端上）
  · 云：DATA 3750 + EVENTS 7500 + MEMORY 3000 token
  · AFM：DATA 1800，EVENTS=0，MEMORY=0（4096 共享窗降级）
  · vision 被端点拒绝 → 一次性降级纯文本重发（4xx 判别，`ReportGenerationService.swift:604`）
        │
        ▼
Report{prose, statsSnapshot, providerModel, comparedToPreviousWindow, userNote}
  → ReportStore：Documents/Reports/<uuid>.json（file-per-report，快照防漂移 ✓）
  → ReportTabView（第二 tab）：period picker + 生成按钮 + 历史列表
  → ReportDetailView：确定性图表（从快照现画，零 LLM）+ MarkdownUI editorial 散文 + userNote 编辑
```

单元测试 31 个（`DoneTests/ReportStatsBuilderTests.swift`），覆盖统计、门控、序列化、memory 选择、backfill、todo 语义、partial progress。

## 三、对照 07-02 评审的 16 条建议：采纳 / 推翻 / 未做

**采纳（机制层几乎全收）**：
- ✓ 跨夜归因修复进了 P0.1（`sessionDaily` dominant-day，`ReportStatsBuilder.swift:764-815`；`dailyTotals` 保持 midnight-split 和图表对齐——两套语义分开、各有注释）
- ✓ generic pairwise 去语义化（用户原词 top-6，`makePairRelations`）
- ✓ token 预算参数第一天就有（`promptText(budget:)`）
- ✓ file-per-report JSON + schemaVersion 容错解码（`ReportStore.swift`）
- ✓ 可刷 feed 被砍——tab 是"可回访的目的地"（`ReportViews.swift:8-10` 明写 "a report is a destination you revisit, not a feed you scroll"），无自动生成、无 engagement 机制
- ✓ 比较门控：partial window 或 previous 窗无记录 → 撤掉全部对比材料（`includeComparisons`，`ReportGenerationService.swift:297`），图表 delta chips 同步跟随（chart/prose parity）

**被 owner 显式推翻**：
- ✗ "砍独立 tab → Analysis 卡片"：先按卡片建（`acba127`），当天 owner 决策升独立 tab（`705cf9c`），但放第二位（calendar → report → me，`ContentView.swift:12-15`），没抢首位——算是评审「日历留门面」与 owner「报告要成门面」的折中
- ✗ "先 WoZ 再写代码"（5/5 共识）：直接建 + dogfood 替代。事后看：dogfood 确实驱动了 prompt v2 和 CJK 预算修正，验证环成立了，只是样本 = owner 本人而非 #115 流失者

**未做（真正的遗留）**：
- ☐ **recordStreak 上屏**（评审 5/5、排在"一切报告工作之前"的最便宜留存动作）：至今零 UI 消费（grep 全库仅 `AnalysisViewModel.swift` 定义 + `AnalysisSuggestionService` 拼 prompt）
- ☐ **#115 激活/通知管道**：`UNUserNotification` 全库仍 0 命中；"分析是 push"的留存故事依旧没有送达管道
- ☐ **Discussion #111 文档更新**：正文仍写"当前只存计划，未动工"；评审建议 12/13（06-23 成本评论标作废、07-01 批评标记处置）也没落
- ☐ 团队 key / 变现决策段：代码仍纯 BYOK（`buildProvider` 读 `agentAPIKey`），StoreKit 仍 0 命中——AFM 端上路径某种程度上替代了"免费层"答案
- ☐ 真实数据门控存活率实测（评审开放问题 1/4）：本想用 done-mcp `query_events` answered，但 MCP token 过期需重新授权；且现在可以直接在 dogfood 设备上看真实报告了，这个问题的形态已从"预测"变为"观察"

## 四、设计漂移：no-imply 定稿 vs prompt v2

07-02 定稿的三条硬规则是"不推测动机/情绪、不给建议、不夸"。`997cc11` prompt v2（dogfood 后重写）保留的是三条**有证据的**边界（`ReportGenerationService.swift:683-694`）：
1. 不评判/说教/开药方（design bedrock）
2. 禁通用夸奖（留存仿真唯一硬验证结论）
3. 不编造记录/数字（幻觉红线）

**"不推测动机/情绪"这条被有意放开了**——persona 是 "perceptive friend who looked through their calendar"，允许 "notice patterns and gently say what they look like"。这更接近留存实验的「被看见镜像」而不是 07-02 的 no-imply 定稿。注意 `ReportModels.swift:7-14` 的文件头**仍在描述严格 no-imply**（"never infers motive or emotion"）——代码内部两处文档已经互相矛盾。这不是 bug，是定义演化没回写：需要 owner 确认 v2 persona 就是新定义，然后统一 ReportModels 头注释和 #111 正文。

其余值得记录的设计决策（都写在代码注释里，质量很高）：
- **报告即记忆已提前落地**（原计划"分析模式以后再说"）：memory v1 限同 kind、最新 2 篇、period 去重、regeneration 不喂自己（`selectPriorReports`）；USER NOTES 永不被裁（最高权威）；frozen spine 尊重旧报告自己的比较决策（`ReportGenerationService.swift:504-528`）
- **backfill awareness 的不对称构造**：只认 `Event.createdAt > spine.createdAt` 的新增，机制上不可能叙述删除/修改（"forgotten-record 红线靠构造不靠规则"，`ReportStatsBuilder.swift:140-179`）
- **AFM 降级策略**：端上 = 纯 DATA（无 EVENTS 无 MEMORY），正是 #111 里"B→C 旋钮在端上关死"的实现
- **todo 身份**：TODO 行带 (open)/(done)，防止把未完成的 plan 叙述成度过的时间（`ReportStatsBuilder.swift:272-295`）

## 五、当前问题清单（按优先级）

1. **#116 双数字分歧（OPEN，07-14，已有完整修复方案）**：`0797421` 的 overlap-sharing 只进了 AnalysisViewModel；`ReportStatsBuilder.weightedTypeHours/:722` 和 `netClampedTotalHours/:748` 仍双计重叠时段 → 同一窗口 Analysis 页 2h、报告 4h，直接违反 builder 自己的头注释契约（`:21` "must never disagree"）。修法：把 overlap-share 抽成纯函数共享。`sessionDaily`（相关性数学）是否要 sharing 需要单独决定并写注释。
2. **#111 文档滞后**：把"已建成什么/推翻了什么/为什么"回写进 discussion，不然下一次读它的人（包括未来的 Claude）会以为还在暂缓。
3. **recordStreak 上屏**：评审 5/5 且成本一小时级，一直没做。首个上屏点避开 Calendar 头部（#37/#47/#43 perf 雷区），放记录完成瞬间或 me tab。
4. **prompt v2 与 ReportModels 头注释对齐**（+ #111 定义章节）——一次注释级 PR。
5. **AFM 体验债**：`AFMProvider.send` 是一次性 await（`AFMProvider.swift:34`），无 streaming/prewarm；~30 tok/s 下 150-300 词要等半分钟级、生成期间只有小 spinner。评审预判过（流式 + prewarm + 按段懒加载），迟早要还。
6. **报告不同步**：ReportStore 纯本地（by design），换机/多设备 dogfood 会丢报告历史；`ai_summaries` 表仍无 iOS 写路径。阶段二再议，但 memory 机制依赖旧报告在场——设备迁移会静默清空"记忆"。
7. **分析模式（sudden 触发）**：memory v1 已把地基打了（旧报告回流、spine、userNote），差的是触发器（总结顺带判断"值不值得深挖"）和 push 管道（依赖 #115）。

## 六、给下一步的建议

**本周可做、低风险**：#116 修复（方案已写好）→ recordStreak 上屏 → #111 文档回写 + no-imply 定义章节更新。
**需要 owner 拍板**：v2 persona 是否就是新的报告定义（推翻/修订 07-02 no-imply 定稿的"不推测动机/情绪"条）；报告同步进不进阶段二。
**等数据**：dogfood 报告攒够一批后，回头看 memory 对比是否真的"越用越准"（现在每篇报告都有 frozen snapshot + userNote，素材在自动积累，这就是当初想要 WoZ 买的东西）。
