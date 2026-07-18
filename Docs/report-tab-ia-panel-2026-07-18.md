# Report Tab 信息架构收束报告 — #111 UI 重排

**日期** 2026-07-18 · **分支** king-of-rubbish-bin · **辩题** owner 提案「report tab 可以考虑直接是报告，但是分类排序可以不一样」 · **参与方** READER/IA、DESIGN GUARD、ARCHITECT、DESCOPER（两轮：立场 + 互相攻击/让步） · **主持** 收束稿，关键代码引证已逐条抽查（见附录）

**一行结论**：四方一致——现在就做，把 Report tab 从「生成仪表盘 + 列表」重排为杂志式「封面卡 + thread 标题目录」，生成/选窗整块收进右上 ✦ sheet；一致反对「最新一篇全文铺开」；schema 零改动；总量 2–3 天、同一窗口合完形成单一评分断点。留给 owner 的真裁决只有两项（见 §6）。

---

## 1. 共识

| # | 共识 | 票 |
|---|---|---|
| 1 | **时机 = 现在做**。评分星标只存在于详情页（ReportViews.swift:399-421），dogfood 主路径是生成完直推详情（:63-65、:252），tab 重排不触碰评分发生的界面；采集前、样本 <20 篇的此刻是唯一低污染窗口——拖到采集中期改才是把 UI 变量混进评分曲线 | 4/4 |
| 2 | **首屏 = rich 封面卡（最新一篇）+ 升级目录，反对全文铺开**。三套独立论证同一结论：评分/userNote 双入口两难、历史被逐出首屏、tab 每次 appear 付全量 MarkdownUI 布局成本、destination 感稀释 | 4/4 |
| 3 | **生成入口收进右上 ✦ → medium sheet**，controls 整块零交互重设计搬迁（ReportViews.swift:71-162），「翻过去完整窗口取对比材料」路径 1:1 保留（chevron/offset 逻辑 :83-127、:113-115 零改动）。三条不可让渡补偿：✦ 常驻 toolbar 禁入 overflow；空态例外；生成中 tab 内状态可见 | 4/4 |
| 4 | **生成状态（isGenerating/stageText/error + Task）由 tab 层持有，sheet 只读投影**——sheet 可中途关闭，tab 横幅与 sheet 按钮必须同源（现状这些 @State 本就在 tab，:37-47） | 4/4（二轮收敛，DESCOPER 提出） |
| 5 | **空态 = 完整 controls 内联**（picker+chevron+Generate，即今天的形态）——首篇的选窗权不收纳；当前窗口生成必然 partial 且被剥离对比材料（:28-31 注释），裸按钮会把最差一篇放在第一印象位 | 4/4（二轮从 2:2 收敛：READER/ARCHITECT 均改投内联） |
| 6 | **thread 标题 = 确定性 runtime parse，不入 schema**。fallback 链一等公民：无标题是三条**正常**路径（单线索塌回 ReportGenerationService.swift:774 明文 "skip the headings" / 0 线索整篇 recap / v1 旧报告 ReportStore.swift:74），不是边界异常；fallback 终点 = 现首句行（ReportViews.swift:519-526、:201-204）= 零回归 | 4/4 |
| 7 | **parse 规格**：Services/Report 层 `ReportProseIndex.swift`、fence-aware（``` 内不采）、接受 `#{1,3}`（与 editorial 把 H1 防御性按 H2 渲染同宽容，:468-476）、六 fixture 单测、loadAll 后一次 pass 进 RowModel 禁入 ForEach body、**无内容长度魔数**（30 字符阈值被否：中英信息密度差 ~2 倍，"The week deep work came back" 已 28 字符，视觉截断归 lineLimit） | 4/4 |
| 8 | **schema v2 零改动**；sectionTitles 不落盘（双真相源 + 违背「prose 是唯一自由文本字段」承诺 ReportStore.swift:48，且回填换不来删除任何 runtime parse 路径——v1/v2 文件永在 :139 白名单内）；**v3 的结构化 sections 由生成端契约产出，不是 parse 回填** | 4/4 |
| 9 | **kind 消费收口单一 accessor** `Report.periodKind`（包 ReportPeriodKind.of，ReportModels.swift:317-325）；现有四处派生点（ReportViews.swift:551 / ReportGenerationService.swift:469、631 / ReportClueBuilder.swift:85、693）之外禁止第五个裸调用；分组/身份键禁用 period 日期区间（同窗可多篇、sudden 报告无 periodEnd 语义）；封面排序键 = createdAt | 4/4 |
| 10 | **排序唯一 createdAt 最新在前**（ReportStore.swift:148 现状），chips 只过滤不重排；显式禁按 ownerRating 或任何 engagement 指标排序 | 4/4 |
| 11 | **kind chips 动态生成**（按实存 kind 集合）、≥2 种 kind 才显示整行、`.custom` 一等 case 显示「其他」（不折进「全部」；不叫「报告」——L(.reportTitle) 已是导航题 :61 与 custom 标签 :555 双用，会歧义） | 4/4（二轮收敛：GUARD 弃静态四枚、DESCOPER 弃 custom 折叠） |
| 12 | **评分星标与 userNote 一个像素不动**：只在详情页原位（:384-421），封面/目录一律不内联、连只读展示也不做（自我 engagement 反馈环） | 4/4 |
| 13 | **topic/线索轴留坑，双门槛**：行为信号（owner 出现「想找上次说 X 的那篇」检索性抱怨）+ v3 结构化 sections 地基，齐备才开工；本轮 thread 标题可见性本身就是采集该信号的仪器 | 4/4 |
| 14 | **destination-not-feed 禁令取并集固化为 PR checklist**（见 §4.6，约十条），含 clickbait 反灌防线：任何 prompt 标题迭代评审必须重申禁货架词 | 4/4 |
| 15 | 生成中 = **横幅叠加在封面上方，不替换封面**（等新刊时旧刊仍在桌上，避免两次布局大跳） | 3/4 明示，GUARD 二轮措辞已转向横幅，按叠加执行 |
| 16 | **ReportViews.swift 拆四文件移出本轮**（四个 formatting helper 均 file-private :519/:530/:550/:562，做不到 move-only；采集窗口内改动面最小化优先），采集稳定后单独 refactor PR | 4/4 |
| 17 | **合入节奏 = 三片同一窗口合完、单一评分断点、记录 merge 日期**；合入后 Report tab 软冻结（只修 bug/文案，无第二次 IA 变更）至 pass-1 首轮评估。不设一周回滚悬崖（与「每片独立可 ship」自相矛盾，且 2–3 天工作量使悬崖无对象） | 核心 4/4；悬崖 3:1 否，主持采纳无悬崖 |

## 2. 真分歧（owner 裁决项）

**R1 「全文铺开」的否决等级：结构性否决入档 vs 保留可证伪复活条件门。**
- 结构性否决（READER+GUARD，ARCHITECT 倾向）：铺开的死因是结构不是采用率——星标要么复制上首屏（污染 pass-1 采集语境）要么读完全文碰不到（丢数据），此二难不随任何使用信号消失；且 DESCOPER 的条件①「几乎只读最新一篇」被封面卡形态同样满足（封面就是 1 tap），闸门逻辑上永远推不出「所以要铺开」，留着就是给未来一次「够激进」的 PR 留后门。点击摩擦信号出现时的正确响应是缩短到详情的路径（冷启动深链最新详情），不是铺开。
- 条件门（DESCOPER）：把否决权交还数据而非立场——2 周回访模式确证 + owner 明确抱怨点击摩擦 + pass-1 首轮评估完成，三条同时满足才重开；这是把重排推迟到评分数据能自证需求的位置，且钥匙明确交 owner。
- 代价一句话：选死刑 = 将来若评分通道整体重设计，铺开需重新立案；选条件门 = 档案里永远躺着一扇理论上推不开却随时可被引用的门。

**R2 「分类排序不必以时间窗为第一公民」的本轮交付范围（panel 一致立场 vs owner 提案的完整读法）。**
- panel（4/4）：本轮对这半句的直接回应只有 kind chips——而 kind 本身仍是时间窗分类法；真正的非窗口组织轴（topic/线索索引）押到 schema v3 + memory scope-selector，本轮的过渡答案是让 thread 标题在封面与目录里可见，先把「按主题回访」的需求信号采出来。现在做 topic 轴 = 在 <20 篇库存上做跨报告聚合的过度工程 + 每次全量 parse 全部 prose + 最大的 feed 化诱因（一篇报告打散成无穷卡片）。
- owner 提案完整读法：内容优先的组织方式本轮就该有非窗口的一轴，否则「分类排序可以不一样」只落地了改良版的老分类。
- 代价一句话：接受 panel 版 = 提案第二半本轮实质缩水成伏笔；坚持完整版 = 在无结构化 sections、无回访信号的地基上先建索引，大概率 v3 时重做一遍。

**主持已裁的次级分歧**（owner 可否决，默认按此执行）：① 生成中呈现 = 横幅叠加非替换（3:1）；② AnalysisViewModel = `@StateObject` 留在 ReportTabView 原位（:35）、实例传给 sheet，不做 ReportWindowSelection 纯 struct 抽取（终局 2:2，按最小回归面裁——不碰 Analysis 共享的 yearForWeekOfYear 地基 AnalysisViewModel.swift:207-211；抽取留给 v3 生成参数对象化）；③ 封面标题 .title3（不用 .title2：不高于详情刊头 :331，且最小化 clickbait 反灌压力），验收按行数不按屏高比例；④ 滚动位置条款折中措辞：不写持久化代码也不写主动重置代码（跨 session 不保留本是平台默认，session 内保留也是平台默认——GUARD 防的威胁不需要代码，READER 反对的伤害只来自主动重置）；⑤ 历史列表不含封面篇，chips 只作用历史区（已知小缺口：封面篇暂无左滑删除路径，dogfood 期可接受）。

## 3. 被说服的时刻

1. **READER ← ARCHITECT**：「无标题是三条正常路径不是异常」——回读 ReportGenerationService.swift:774 确认 prompt 明文指示单线索/简单窗口跳过标题；fallback 从边界防御升格为一等设计。
2. **READER ← ARCHITECT**：裸正则会误采 code fence 内的 `##`——采纳 fence-aware ReportProseIndex + 六 fixture。
3. **ARCHITECT 自我修正**（由攻击 READER 触发）：自己的「sheet 自持 @State period/offset」与 READER 的「@StateObject 搬进 sheet」有同一个 presentation 重置 bug（period 每次弹出回 .week）——修正为窗口状态归属上移到 tab 层；本收束稿以「viewModel 留在 tab 原位传入 sheet」实现，重置 bug 自然消失。
4. **GUARD ← ARCHITECT**：放弃四周 UI 冻结与一周悬崖——「污染来自采集中途换动线」推不出硬时限；底线降为单断点 + 采集期内无第二次 IA 变更。
5. **DESCOPER ← READER/GUARD**：放弃「最小切片先上、完整重排 2 周后尾随」的分批节奏——那恰好制造采集中期的第二断点；改为同窗一次收完。
6. **DESCOPER ← ARCHITECT**：「row 层 `let titles = ...` 是缓存」不成立——SwiftUI body 每次重估都重跑，正名为 RowModel 一次 pass。
7. **READER/GUARD/ARCHITECT ← DESCOPER**：生成状态提升 tab 层、sheet 只读投影的状态拓扑。
8. **READER/ARCHITECT ← GUARD**：clickbait 反灌机制——thread 标题一旦落盘成一等字段，「标题要好看」的压力会从 UI 反灌 prompt、蚕食禁货架词纪律；这给「不落盘」补上了产品层理由（此前只有成本与追溯论据）。
9. **DESCOPER ← 三方合围**：「custom 折进全部」与其自身 Q7(b)「.custom 必须一等 case」直接矛盾——弃守，改投动态 chips。
10. **ARCHITECT ← GUARD**：sheet 内对比提示不能写「offset≠0 才有对比」——comparedToPreviousWindow 需要完整窗口 + tracked baseline（ReportStore.swift:56-62），offset≠0 必要不充分，措辞必须是「完整的过去窗口才**可能**带对比」。
11. **ARCHITECT ← READER**：5–8h 是低估——文件拆分做不到 move-only（helpers 全 file-private）、跨容器状态同步未预算；工时按 2–3 天报。
12. **READER ← DESCOPER/GUARD**：生成频率若下滑，第一补救是 sheet 记住上次 period（轻）而非把按钮搬回首屏（推翻 IA）。

## 4. 建议方案（收敛稿，可开工）

### 4.1 时机
现在做（4/4）。三片同一窗口（2–3 天）合完 → 单一评分断点，merge 日期记入 #111 → Report tab 软冻结（只修 bug/文案）至 pass-1 首轮评估。评分通道（详情页星标 + userNote）零像素改动。

### 4.2 首屏线框（非空态）
```
NavigationStack（ContentView 提供）
├─ navigationTitle「Report」(.inline)
├─ toolbar(.topBarTrailing): ✦ sparkles（常驻，禁 overflow）→ .sheet(ReportGenerateSheet, .medium)
├─ [仅生成中] 状态横幅（叠加，封面不替换）：ProgressView(.small) + stageText(caption)；
│    失败 → 错误行 + 内嵌 Retry（即现 :129-140、:149-152 的内容换容器）
├─ 封面卡 = 最新一篇（整卡 NavigationLink → 现有 ReportDetailView，零新页面）
│    ├ 眉线：kind 微标签(caption2 胶囊) + periodText(caption,.secondary) + Spacer + provider 胶囊(:194-199 样式)
│    ├ 标题：首 thread 标题 .system(.title3, design:.serif).semibold, lineLimit(2)；无标题 → 退为「kind · period」刊头（卡不塌）
│    ├ 摘要：首段 serif 3 行 lineLimit(3)
│    └ hairline 收尾（复用 :445-449 样式，需提升为共享成员）
├─ Section header「往期」+ kind chips（动态实存 kind、≥2 种才显示、custom=「其他」、只过滤）
└─ 历史行（不含封面篇；NavigationLink；左滑删除保留 :175）
     ├ 首行：kind 微标签 + createdAt 小字 + Spacer + provider 尾徽(caption2)
     └ 主体：thread 标题串 ≤3 条（serif subheadline，lineLimit 2）；
        fallback = 现首句两行预览（:201-204 原样 = 零回归）
```
thin/短报告：封面结构不变，标题位退为 kind·period。**空态**：List 隐藏，页面主体 = 空态一句（L(.reportHistoryEmpty)）+ 完整 controls 内联（即今天的 :71-162 形态）；✦ 冗余无害。

### 4.3 选窗去向与状态归属
- ReportGenerateSheet（.medium detent）：Day/Week/Month segmented + chevron 窗口导航 + Today + 错误/重试 + Generate，整块零改动搬迁；顶部一行衬线引导语；对比提示文案（可选）按 4.2 之 GUARD 修正措辞。
- 状态：`@StateObject viewModel` 留 ReportTabView 原位（:35）传入 sheet → period 天然跨 presentation 存活；offset 在 sheet onAppear 归零（防残留 offset 悄悄生成旧窗口）。生成状态 + Task 留 tab，sheet 只读。生成成功 dismiss + justGenerated 直推详情保持（:63-65）。

### 4.4 ## parse fallback 链
`Done/Services/Report/ReportProseIndex.swift`，`threadTitles(in:) -> [String]`：逐行扫描，``` 切换 fence 状态，fence 外匹配 `^#{1,3}\s+`，strip 尾部 # 与空白，去空串，取前 3。链：(1) ≥1 标题 → 标题串；(2) 空 → reportFirstLine（:519-526）；(3) prose 全空白 → kind·period 标签。中英混排无影响。单测 fixture：多标题 / 无标题 / H1 / H3 / 中英混排 / fence 内 ##。loadAll 后以 reports 变化为条件一次 pass 进 RowModel。

### 4.5 schema 决策
本轮零改动（v2 不动）。v3 伏笔三防线：`Report.periodKind` 唯一 accessor；身份/分组键禁 period 区间；chips 枚举经 ReportPeriodKind、custom 一等。v3 时 sections 由生成端契约产出、与显式 kind/来源字段一次 bump。

### 4.6 destination-not-feed checklist（并集，进 PR review）
禁：无限滚动/分页加载；红点/badge/未读态（#115 不搭车）；pull-to-refresh 或进 tab 自动生成；推荐位/轮播/「往期精选」/详情页 recirculation；clickbait（悬念截断、emoji 诱饵、标题长度魔数）；收藏/稍后读/归档（左滑删除是唯一行操作）；滚动位置的持久化代码与主动重置代码；按评分/engagement 排序；评分星标/userNote 出现在封面或目录（含只读展示）；封面多于一张或 carousel。附：prompt 标题迭代评审必须重申禁货架词。

### 4.7 Post-merge 观察项（dogfood 一周）
生成频率（掉 → sheet 记 period，不搬按钮）；offset 使用率/对比出现率（掉 → sheet 内引导句）；thread 标题质量（平庸 → 目录行改「首标题+首句」混合行）。封面显示旧报告的时效语义由眉线 period 承担，**不加**「该生成了」nudge（归 #115）。

## 5. 切片与工作量

总量 **2–3 天**（中位 ~2.5；ARCHITECT 的 5–8h 判为低估：漏算跨容器状态同步，文件拆分非 move-only），三片各自独立可 ship、同一窗口合完：

| 片 | 内容 | 量 | 验收 |
|---|---|---|---|
| S1 入口收纳 | ReportGenerateSheet（controls 整块搬迁，viewModel tab 层传入）、toolbar ✦、空态内联完整 controls 分支、tab 顶横幅（进行/错误/重试）、justGenerated 保持 | 0.5–1 天 | 翻过去窗口生成/对比出现/错误重试与今天等价；三补偿条款齐备 |
| S2 封面+目录 | ReportProseIndex + 六 fixture 单测、RowModel 一次 pass、封面卡（.title3 标题 + 3 行摘要，复用现有样式，最小成员提升）、历史行 thread 标题化（fallback=现状）、Report.periodKind accessor | ~1 天 | 无标题/v1 报告行 = 今天的行；不动详情页 |
| S3 kind chips | 动态 chips、≥2 kinds 显示、custom=「其他」、只过滤、空过滤结果一句话 | 0.25–0.5 天 | 单 kind 库存下 chips 行不出现；可无限推迟不欠债 |

移出本轮：文件拆分（采集期后单独 refactor PR）、topic 轴、schema v3、threadTitles 落盘。

## 6. 给 owner 的裁决项

1. **铺开的死法**：全文铺开「结构性否决入档」（panel 推荐，3:1）还是保留 DESCOPER 的三条件复活门？（推荐：入档；若将来推翻，GUARD 星标守卫条款自动生效——星标不得随全文进首屏。）
2. **「分类排序」本轮交付范围**：接受「kind chips + thread 标题可见性」作为过渡答案、topic 轴押 v3 双门槛（panel 4/4 推荐），还是要求本轮就上非窗口组织轴？诚实交底：kind 本身仍是时间窗分类法，本轮对你那半句提案只有弱回应。
3. （知情确认，非分歧）§2 末「主持已裁的次级分歧」①–⑤ 按默认执行，如有异议请点名。

---

## 附录：关键代码引证抽查

| 引证 | 结论 |
|---|---|
| ReportViews.swift:35 tab 级 `AnalysisViewModel(initialPeriod: .week)` 仅为 dateRange/periodLabel | 已核实 |
| :28-31 当前窗口恒 partial、对比材料只在过去窗口 | 已核实（注释原文一致） |
| :37-47 生成状态 @State 在 tab；:52-60 controls 在列表之前；:71-162 controls+generateButton；:113-115 offset≥0 禁右箭头；:149-152 spinner+stageText | 已核实 |
| :63-65 justGenerated 直推详情；:252 赋值点；:66 onAppear loadAll | 已核实 |
| :175 左滑删除；:178-184 空态为 List overlay 一句话（GUARD「裸按钮比现状倒退」的事实基础成立） | 已核实 |
| :187-207 行结构、:194-199 provider 胶囊、:201-204 首句两行衬线预览 | 已核实 |
| :330-331 详情刊头 kind·period，.title3 serif semibold；:384-421 noteEditor+ratingRow；:399-421 评分星标 | 已核实 |
| :468-476 H1 防御性按 H2 渲染；:519-526 reportFirstLine；:550-557 reportKindLabel；:555 custom → L(.reportTitle)（与 :61 导航题同 key，「其他」chip 命名依据成立） | 已核实 |
| :445-449 hairline、:519/:530/:550/:562 四 helper 均 private（READER「拆文件非 move-only」论据成立；副作用：S2 复用需最小成员提升） | 已核实，附实现注意 |
| ReportStore.swift:40 v2；:48 prose 唯一自由文本字段；:56-62 comparedToPreviousWindow=完整窗口+tracked baseline（GUARD 措辞修正成立）；:74 clues nil on v1；:83-87 ownerRating 为 pass-1 唯一观测通道且永不进 prompt；:139 版本白名单；:148 createdAt 降序 | 已核实 |
| ReportModels.swift:308-326 ReportPeriodKind；:317-325 `.of` 按天数分桶 | 已核实 |
| ReportGenerationService.swift:750-752 formatLine 允许 ##/### 禁 H1；:774 单线索/简单窗口 skip headings + 禁货架词；:469-473、:631 kind 派生点 | 已核实 |
| ReportClueBuilder.swift:85、:693 kind 派生点（合计四处派生点清单成立） | 已核实 |
| ReportCharts.swift:31 showDeltas 跟随 comparedToPreviousWindow | 已核实 |
| AnalysisViewModel.swift:184-198 仅 period/offset 两个 @Published、initialPeriod 传值时不读 UserDefaults；:200-241 dateRange/periodLabel 纯计算；:207-211 yearForWeekOfYear 周起点 | 已核实 |
| ContentView.swift:11-15 RootTab wanna/calendar/report/me | 已核实 |
| ARCHITECT「.sheet 内 @StateObject 每次 presentation 重建」 | 仓库内不可直接核（SwiftUI 语义），两轮无人反驳，按成立采纳；收敛稿以状态上移使其不再构成风险 |
| 背景文档 Docs/report-clue-search-panel-2026-07-15.md | 有出入：当前工作树未找到该路径（可能在他处/未提交），不影响本稿结论 |