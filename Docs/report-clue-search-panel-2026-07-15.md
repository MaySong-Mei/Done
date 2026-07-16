# 报告系统「主动搜索 clue」机制选型 — 四方辩论收束报告（2026-07-15）

> 分支 `research/report-system`（基于 king @ `4f762f2`）。四方 = ARCHITECT / PRODUCT / COST GUARDIAN / DESCOPER，流程 = 立场轮 + 交锋轮，主持人收束。所有 `file:line` 引用已按本分支抽查核实（见附录核查表）；辩题前提：owner 已拍板「报告 section 按线索（thread）分」，本轮辩的是**线索从哪来**。
>
> **结论先行**：四方在骨架上实质收敛约八成——**先修 #116，然后 ship「确定性 detector 电池 + 代码选题 + 分层预取证据 + 单次调用分 thread section」**（四方各自称 v1 / 档位1.5 / 档位1+，同构）。LLM 选题（档位2）从「旗舰主路径」降级为「可证伪条件触发的封顶」；tool-loop（档位3）4/4 出局。真正留给 owner 的裁决只有两个小项（第六节）。

---

## 一、共识（可直接定案）

1. **#116 先修，硬依赖非偏好（4/4）**。detector 基线要循环调用的正是仍双计重叠时段的 `weightedTypeHours`（ReportStatsBuilder.swift:722）/`netClampedTotalHours`（:748）——已核实：两者逐 occurrence 独立求和、无 overlap-share，违反文件头 must-never-disagree 契约（:18-24）；修法已写好（研究快照 §五.1，抽 overlap-share 纯函数共享）。先建后修 = detector 阈值全部重调 + 错误数字被叙述进不可修复的冻结 prose。`sessionDaily` 是否 sharing 在 #116 内单独决定并写注释（相关性翻转 detector 依赖此决定）。
2. **v1 = 确定性 detector 电池 + 代码 confidence×novelty 排序 + 单次调用（4/4）**。电池是与 ReportStatsBuilder 同契约的纯函数（无 `Date()`、无 store，:8-16；priorFingerprints 由 generate 从已在读的 `store.loadAll()`（ReportGenerationService.swift:161）提取后以值注入）；confidence 复用三信号门控（ReportModels.swift:55-91）；novelty fingerprint =（detectorID, types, direction），冻入快照机械防复读。
3. **流水账根因 = 输入贫血，不是模型缺手（4/4，机械链条全部核实）**。日报 dayCount=1 构造性永远 isThin（builder :87-88 + thinMinRecordedDays=4，ReportModels.swift:99）；RELATION 需 overlapDays≥3（:76）、WHEN 需 3 天（:113）单日不可能满足；默认当前窗恒 partial（ReportViews.swift:28-32）→ `includeComparisons=false`（ReportGenerationService.swift:297-299）→ 日报 DATA 只剩 WINDOW + 裸类目行，模型只能复述 EVENTS。修输入，不修调用拓扑。
4. **thread 数由数据定 0..N，0 条回落诚实短 recap；防模板腔靠机制不靠 prompt 恳求（4/4）**。
5. **证据全部确定性预组装，LLM 永不声明取证需求（4/4，交锋后收敛）**。PRODUCT 主动放弃 EvidenceRequest 闭集菜单——每种 detector 自带固定证据形状，在任何调用之前全部算好。交锋证明闭集菜单的每个参数都被 detectorID 完全决定，模型「点菜」信息量为零。
6. **档位3 tool-loop 永久出局（4/4）**。逐轮重发历史 = O(轮²) 输入增长（100-300k tok/篇量级）、无自然终止、输出不可预算、AFM 无形态——62.7M 事故的结构复现；读者上限还 ≈ 档位2 但方差大，打在「回访的目的地」（ReportViews.swift:8-9，已核实）最依赖的仪式可靠性上。
7. **AFM tier = 同一电池、同一序列化器、top-1~2 CLUE 行进 1800-tok DATA（ReportGenerationService.swift:66）、单次调用、纯预算旋钮降级（4/4）**。threadSelection 恒 nil、MEMORY 维持 budget=0（:163）；AFM 报告仍是 thread 形状——同一产品的薄版。降级形态 ≡ 云端选题失败的回落形态，对称性是构造出来的。
8. **调用封顶写法修正（4/4，交锋产物）**。现状 vision-reject 降级已是同一次 generate 内第二次 provider 调用（:217-263，已核实）——封顶断言改为「每次生成 ≤1 选题 + ≤1 写作 + ≤1 降级重发」，ledger 按 purpose 分桶（"report" / "report-select" / 降级），而非笼统「≤2」。
9. **快照 schemaVersion 1→2（4/4，经互相让步）**：入选 clue 全量冻结（含证据行，可逐字节重放）+ 未入选仅存 fingerprint + historyStart + owner 逐篇评分字段。评分**不走 userNote**——userNote 是最高权威记忆材料、原文进 MEMORY（ReportStore.swift:62-67、fence ReportGenerationService.swift:442、:474-485，已核实），评分语言走它会泄漏成写作指令。
10. **per-kind 预算表（3/4 明确，ARCHITECT 让步方向一致）**：daily = CLUE 行内嵌代码算好的基线数字（无深包，输入 ~8-10k）；weekly/monthly = top-2 深包（每包 ~1-1.5k tok：跨窗数字序列 + detector 指认的 occurrence LOG/FELT 原话 ≤5 条、复用现有 clip 规则）+ 其余候选 headline 行。**总输入天花板不涨**（≤ 现有 3750+7500+3000≈14.25k，证据从 EVENTS 份额置换）——两段式与否，预算都是「重新分配」不是「加钱」。
11. **生成期阶段文案 UI，阶段绑真实事件（电池扫完 / 证据组装完 / 调用返回），v1 就带（4/4）**。假进度比转圈更伤信任。
12. **可观测性从第一天（4/4）**：detector 发射形状（候选数/入选数/各族命中率）进快照 + Developer 页；purpose 标签入 usage ledger；若将来开 pass-1，回退率必须可见——否则「档位2 已上线」是假象。继承 token-inference 修复的审计基建。
13. **pass-1 若建，守卫全量一致（4/4）**：pick-from-menu 严格 JSON、clueID 必须来自代码枚举菜单、maxTokens ≤500、零重试、解析失败/非法 ID 静默回落代码排序、threadSelection 冻入快照、门 = 过阈值 clue 数 ≥N（数据形状做门，日报天然短路——不用 kind 枚举分叉调用拓扑）。

另有三项 PRODUCT 第二轮提出、未及对辩、**主持人核查代码事实成立**、建议直接并入 Slice A 必做项（见第四节）：kind-aware thin 重定义、elapsed-clamped 日报基线、overlapDays 语义重定义。

## 二、真分歧（owner 裁决项）

交锋后真正没收敛的只有两条。其余表面分歧（证据预算尺寸、快照冻结范围、per-kind 门控形状、pass-1 是否属 v1.5 主路径）均已在第二轮通过让步消解。

### A.「模型自由补观察 section」的去留 —— owner 裁决项

DESCOPER 的调用内授权是「丢/合/**补**」三件，前两件 4/4 采纳，第三件（授权模型从 EVENTS 自己看出至多一条 detector 覆盖外的观察）被两方攻击：

- **留（DESCOPER）**：预枚举 detector 必有盲区，这是覆盖盲区最廉价的调用内搜索；「报告没讲到我最感兴趣的事」正是升级 pass-1 的第一触发条件，需要这个出口才能观测到。
- **砍或钉死（COST + ARCHITECT）**：模型自己的观察几乎必然含自算数字（「你这周开了三次会」就是模型算术），直接擦「数字全部代码确定性算」红线（ReportGenerationService.swift:12-13，已核实）；且「模型自己的观察」一旦合法，给它更多材料/轮次的产品压力就是 tool-loop 的 prompt 形态胚胎。若保留，唯一可接受形态 = 只许逐字引用单条 EVENTS 行、禁一切聚合/计数陈述——但这个约束只能在 prompt 层执行，不是构造保证。

### B. pass-1 契约类型是否现在进 repo —— owner 裁决项

实现推迟、触发条件可证伪已是共识；分歧在「现在写多少」：

- **写契约类型（DESCOPER 提议，PRODUCT 附议）**：约几十行无实现的类型定义现在进 repo，作为构造性红线——锁定 `clueIDs` **数组**（承载合并语义；单数 clueID 会让 pass-1 在自己的升级触发条件下永远无法证明价值）+ **无任何证据声明字段**。防触发日从零重辩、防未来实现者给菜单加自由字段的腐蚀。PRODUCT 附带条款：菜单行须带 50-100 字符记录摘录，否则将来建成的是输入饥饿、注定平庸的稻草人 pass-1，花钱还得出错误结论。
- **什么都不写（ARCHITECT 倾向）**：预写未被需要的结构是「待引爆结构」——spec-07 66 commit 回滚的教训；他对 COST「flag 默认关的完整实现」的这记攻击，弱化版同样适用于「只写类型」。触发条件写进 memory/#111 即可；且他的最终契约主张仍是单 clueID + 一句 angle（合并已由写作调用内授权覆盖）。

**非裁决项**（明确不需要 owner 现在拍）：pass-1 终局（PRODUCT 预测周/月报回访线索会触发它，DESCOPER 预测永不——由评分数据裁决）；monthly lookback 6 个月 vs 3 个月（由真机 CPU 实测裁决）；weekly/monthly 证据总预算 3k vs 4-5k（可调常量，默认 ~4k）。

## 三、被说服的时刻（辩论的净产出）

1. **PRODUCT ← ARCHITECT+DESCOPER（全场最大立场移动）**：「thread 合并是唯一真需要 LLM 判断力的位置」被代码事实拆掉一半——`makePairRelations` 本来就把「开发超时~晚睡」这类统计相关对作为**单条** RELATION 发射（ReportStatsBuilder.swift:824-866，序列化 ReportModels.swift:377-383，已核实）；若统计不相关，让 LLM 缝合恰是 PRODUCT 自己 risks 里的「硬缝因果」。PRODUCT 放弃「v1.5 旗舰必带 LLM 选题」。
2. **ARCHITECT+COST ← DESCOPER**：「pass-1 的 fallback 必然是代码排序，先 ship 必建部分」+「丢/合可在写作调用内 prompt 授权、边际成本为零」——ARCHITECT 把调用内编辑权写进 Slice B 并收紧 Slice C 触发门槛；COST 把「weekly/monthly 可开 flag」收紧为「命中三个可证伪触发条件之一」。
3. **PRODUCT+COST ← ARCHITECT**：pick-from-menu 构造性论证（「模型连证据都不能点，砍掉选题调用系统仍完整」= if 分支与第二架构的分界线）——PRODUCT 弃闭集证据菜单；COST 把 threadSelection 冻结列入守卫清单（62.7M 三问的「消费方」从运行时承诺变成快照事实）。
4. **DESCOPER+COST ← PRODUCT**：留存两杠杆（「算出我算不出的」+ 用户原话背书的因果材料）必须同时兑现，否则是「更聪明的仪表盘」——DESCOPER 把每 clue ≤500 字符改成 top-2 深包含 LOG 原话；COST 把「CLUES 只加 0.5-1k」改成 weekly/monthly 真实证据预算。配套核实：EVENTS 只序列化窗内 occurrence（ReportStatsBuilder.swift:236-239），窗外引语确实没有别的通道。
5. **全场 ← PRODUCT**：阶段文案把延迟翻译成深度感，且不依赖两段式——三方采纳进 v1；COST 撤回延迟作为反对档位2 的独立理由。
6. **ARCHITECT 自我修正（DESCOPER 同时击中 COST）**：「成本封顶 2 次」漏算 vision 降级重发（ReportGenerationService.swift:217-263）——封顶断言改按调用角色。摆设化的守卫比没有守卫危险。
7. **DESCOPER ← ARCHITECT**：ClueStamp 只冻「讲过什么」，输入不可重放、量级升级无法比较——采纳类型化冻结，并以自己的攻击收窄为「入选全冻/未选仅 fingerprint」。
8. **ARCHITECT ← COST**：「选型约束不是省钱，是不引入新的无界形状」——比「封顶 2 次」更准确命中 62.7M 事故本质；连带采纳回退率可观测。
9. **DESCOPER ← COST**：三个升级触发条件从 owner 主观打分升级为 ledger + 快照可查数据。
10. **校正类（主持人核实）**：`recordStreak(store:)` 直接读 store 且内部用 `Date()`（AnalysisViewModel.swift:287-288，已核实）——COST/PRODUCT 的「复用/移植即可」不成立，ARCHITECT 的「必须重推导」成立；ARCHITECT「#116 修复日全体 fingerprint 漂移」被 COST 校正为夸大（fingerprint 不含量级）；DESCOPER「第二次调用 +50-100% 延迟」被 COST 校正为 +15-40%。

## 四、建议方案（收敛稿，可开工）

### 机制总览：一条管线、三档预算旋钮

```
EventStore 快照（含 lookback 粗滤窗）
  → ReportStatsBuilder.build（#116 修复后）
  → ReportClueBuilder.build(events, historyStart, start, end, priorFingerprints, calendar) → [ReportClue]
  → 代码选题：score = confidenceTier × novelty，阈值以上 0..5 条，同 detector 族 ≤2
  →（未来可选 pass-1：过阈值 clue ≥N 才有资格触发；现默认不存在）
  → 证据确定性预组装（per-kind 预算表）
  → 单次写作调用（thread 分 section；prompt 授权丢/合）
  → 冻结快照 schemaVersion 2（入选 clue 全量 + fingerprints + threadSelection? + 评分字段）
```

- **Q1 档位**：档位1.5 为骨（上图），档位2 为可证伪条件触发的封顶，档位3 出局。它同时就是档位2 的回落路径和 AFM 路径——降级对称性由构造保证。
- **Q2 选题契约（若触发）**：`{"threads":[{"clueIDs":[...], "angle":"一句话"}]}`，1..4 条，clueID 限菜单内，无证据字段，maxTokens ≤500，零重试，失败静默回落，purpose="report-select" 入 ledger，threadSelection 冻入快照。angle 是内部工作指引，永不直接进正文。（数组 vs 单数、菜单行是否带摘录 → 裁决项 B。）
- **Q3 取证边界（全部确定性、全部预取）**：(a) 现有聚合纯函数在 lookback 窗逐窗重跑（weightedTypeHours :722 / makeTimeOfDayShares :897 / sessionDaily :768 / pearson :879），只复制已有统计沿时间轴，不发明新统计；(b) detector 指认的 occurrence（含窗外）LOG/FELT 引语 ≤5 条/thread，复用 clipRecordText/maxRecordFieldChars（:588，ReportModels.swift:135）；(c) 旧报告冻结 spine（在盘）。lookback 常量：daily 28 天 / weekly 8 周 / monthly 3-6 月（真机实测后定）。禁区：任意日期自由查询、全史全文搜索、任何触碰删除的路径（backfill 只认新增的不对称构造原样保留，ReportStatsBuilder.swift:140-179）。
- **Q4 AFM**：见共识第 7 条。CLUE 行可内嵌代码算好的走势数字（几十字符），挤占 WHEN 等低优先行，沿用 promptText 优先级截断。
- **Q6 防模板腔**：0..N 条按数据、novelty fingerprint 降权（方向翻转/量级升级除外）、同族 ≤2、标题从证据起且禁 detector 词表与「趋势/亮点/总结」类货架词、薄数据短报告不填充、每种 detector 证据形状不同天然分化 section 内部结构。可选「试探位」：若采纳，由**代码**确定性附加至多一条 low-tier 并如实标注（需给 low-不进-prompt 纪律开显式豁免口），不经 LLM。
- **Q7 预算/延迟（数量级）**：单篇输入 ~10^4 tok（daily ~8-10k、weekly/monthly ~13-15k，天花板 ≤14.25k 不涨）、输出 0.5-1k；云延迟 10-30s 不变；若 pass-1 触发 +2-5s。月账 ~0.5M tok ≈ $2-3（Sonnet 级），距 62.7M 事故三个数量级。detector CPU 是新的帽：monthly lookback 的 `expandOccurrences` 逐日 walk（:607-620）× `weightedTypeHours` 双重循环（:729-741）需真机量一次。
- **日报三个硬前提（核实为真，缺一则日报照旧流水账或成造谣机）**：
  1. kind-aware thin 重定义 + prompt 长度指令改写——isThin 现在直接把「a few honest sentences」写进 systemPrompt（ReportGenerationService.swift:196、:712-714）并把 deltaTier 封顶 medium（ReportStatsBuilder.swift:1013），与 5 条 CLUE 对撞；日报的 thin 应是「今天零记录」。
  2. elapsed-clamped 典型日基线——默认窗口永远 partial 且 prompt 明令不比较（:705）；基线须截到生成时刻（「今天到 15:00 vs 28 天『到 15:00』的中位数」，:317 已有 elapsed 计算可复用），否则下午生成的日报稳定发射假「今天偏少」。
  3. overlapDays 对基线类 detector 重新解释为「支撑基线的历史样本天数」——否则 mediumMinOverlapDays=3（ReportModels.swift:76）把单日窗口全部 clue 门在 low、全部被扔。这是对三信号门控的显式语义扩展，不是「原样沿用」。

### detector 清单 v1（四方合并；【已有】= 现有代码直接可算）

**DAILY**（窗口 1 天，基线 trailing 28 天、elapsed-clamped、同 weekday 优先）
1. 典型日偏离——聚合复用 weightedTypeHours（:722），trailing 循环 + clamp 新写。**单个杠杆最大**。
2. 计划 vs 实际超时/提前——`actualDurationMinutes` 已序列化（:440，EventLog.swift:318），比较新写（trivial）。不吃历史，冷启动可用。
3. 首次出现/回归（≥14 天未见）——expandOccurrences（:597）复用，集合差新写。冷启动可用。
4. 惯常消失（28 天内 ≥50% 天出现、今日缺席）——同上。
5. streak 延续/断裂——**新写非移植**：recordStreak 读 store + Date()（AnalysisViewModel.swift:287），须从 occurrence 序列重推导；且其原语义故意用 rawCalendarEvents，与报告契约集（canvasRenderable，ReportStatsBuilder.swift:18-24）不同，事件集须显式决定。
6. 时段异位——segmentSeconds（:942）/makeTimeOfDayShares（:897）复用。
7. FELT/effort 离群——字段已有（EventLog.swift:321-322），分布比较新写。
8. todo 悬置/完成率——isDone 已序列化（:284）。

**WEEKLY**（基线 trailing 4-8 周）
1. WoW delta+tier——【已有】makeTypeHours+deltaTier（:974-1014）。
2. 占比漂移 vs 4 周均值——weightedTypeHours lookback 新组合。
3. 相关性及符号翻转——makePairRelations（:824）/pearson（:879）复用，跨窗比较新写。
4. 半窗符号一致性——【已有】signConsistency（:871）。
5. WHEN 时段漂移环比——makeTimeOfDayShares lookback。
6. 类目首次/消失（vs trailing 4 周）。
7. 系统性超时（同 type 本周 ≥3 次）——新写。
8. 记录节奏（recordedDays/weekday 空白 vs 典型）——recordedDays（:74-79）/dailyTotals（:105-111）复用。
9. 碎片化（session 次数升、总时长平）——sessionDaily（:768）有小时无次数，需加计数。
10. backfill——【已有】backfilledSince（:161）。

**MONTHLY**（基线 trailing 3-6 月，lookback 待实测）
1. MoM 类目 delta——机制已有。
2. 月内趋势（per-type 周 rollup 斜率）——sessionDaily/dailyTotals 复用，回归新写。
3. 周节律变化（weekday×type 漂移）——dominantDay（:797）+ 分组新写。
4. 类目新生/退役。
5. 相关性跨月稳定性（连续 ≥2 月同向 → 叙述许可升级）。
6. 最满/最空周、最长 streak/空窗——rollup 新写。
7. 记录习惯月际趋势——window meta（:81-89）复用。
8. thread 回访（对上月 fired threadKey 重跑对应 detector）——ReportStore spine 在盘。

真正的新原语只有四个：trailing-profile 基建、streak 重推导、计划vs实际比较、月内回归；其余全是现有聚合的跨窗组合。**全部 detector 强制走共享聚合纯函数、禁自算时长**——#116（过滤加在消费者之后、无 sweep）的结构化防御。

**已知限制（记入 risks，不阻塞）**：ReportStore 纯本地（研究快照 §五.6），换机 novelty 记忆归零、模板腔短期回升；AFM 一次性 await 无 streaming（AFMProvider.swift:34）的半分钟级体验债不因本方案加重但迟早要还；新用户历史 <4 周时基线类 detector 显式降级回诚实短 recap，不输出瞎编的「偏离」。

## 五、切片顺序（含 #116 关系）

0. **#116（阻塞项，4/4）**：抽 overlap-share 纯函数 → 接入 weightedTypeHours/netClampedTotalHours；sessionDaily 是否 sharing 单独决定 + 注释；回归测试。它不是并行工作而是 Slice A 的地基——抽出的纯函数直接成为 detector 层强制共用的聚合入口；且 #116 先落使「fingerprint 跨修复期漂移」问题根本不发生。
1. **Slice A（最小可 ship，日报脱贫）**：真机实测 lookback CPU 定常量 → trailing 历史基建 + 4-5 个高杠杆 detector（典型日偏离含 elapsed-clamp、超时、首次/消失、streak——后三个不吃 28 天历史，顺带覆盖冷启动）+ overlapDays 语义重定义 + kind-aware thin 重定义与 prompt 改写 + CLUE 行进 DATA + schemaVersion 2（入选 clue 冻结 + fingerprints + owner 评分字段）+ AFM top-2 行 + 阶段文案 UI + 发射形状进 Developer 页。单次调用不变。
2. **Slice B（thread 分 section，仍单次调用）**：per-kind 证据预算表（weekly/monthly top-2 深包含窗外指认引语）→ thread 分 section prompt + 调用内丢/合授权 + 0 条回落整篇 recap。
3. **Dogfood 2-4 周**：owner 逐篇 30 秒 section 评分（独立字段）+ ledger/快照观察代码选题命中质量。
4. **Slice C（条件性，默认不建）**：仅当命中三个可证伪触发条件之一（评分连续 ≥3 篇标记选题错且调分无效 / 高价值 clue 系统性未被叙述 / 出现真需按需取证的 detector 类型）才实现 pass-1，守卫全量。
5. detector 长尾按 dogfood 反馈逐个独立小 PR。

全程独立分支到 release-grade 再进 king（spec-07 纪律）。

## 六、给 owner 的裁决项（仅真分歧）

1. **「模型自由补观察 section」**：v1 砍掉（红线零开口，盲区暂靠 EVENTS 在场 + 触发条件观测）还是保留引用-only 版（盲区有出口，但「数字全代码算」红线首次交由 prompt 而非构造来守）。
2. **pass-1 契约类型是否现在进 repo**：写（约几十行死代码，锁定 clueIDs 数组 + 无证据字段，防触发日重辩与腐蚀）还是不写（零死代码，避免 spec-07 式「待引爆结构」，代价是届时从零重辩契约）。若写，附带小项：菜单行带 50-100 字符记录摘录（选题质量）vs 纯一行摘要（守卫更紧）。

---

## 附录：关键代码事实抽查（主持人逐条读文件核实）

| # | 断言（方） | 核查结果 |
|---|---|---|
| 1 | 日报构造性永远 isThin（全场） | **已核实**：`isThin = recordedDays<4 ∥ events<12`（ReportStatsBuilder.swift:87-88；ReportModels.swift:99-100） |
| 2 | 默认当前窗恒 partial → 结构性无对比（全场） | **已核实**：ReportViews.swift:28-32 明写；isPartial=createdAt<end（ReportGenerationService.swift:105）；:297-299 |
| 3 | RELATION 门槛 ≥3/≥5、WHEN 需 3 天（全场） | **已核实**（PRODUCT 引 :77 实为 :76，±1；WHEN 门在 ReportModels.swift:113 + builder :928） |
| 4 | #116 患处 = weightedTypeHours(:722)/netClampedTotalHours(:748) 双计重叠（全场） | **已核实**：逐 occurrence 独立求和无 sharing；违反 :18-24 契约；研究快照 §五.1 修法已写 |
| 5 | vision-reject = 同次 generate 第二次 provider 调用 | **已核实**（:217-263）；COST r1「恰好≤2」与 ARCHITECT r1「封顶 2 次」**有出入**，双方已自修正 |
| 6 | thin 直改 prompt「a few honest sentences」且 deltaTier 封顶 medium（PRODUCT 攻「不动 thin 门控」） | **已核实**（:196、:712-714；ReportStatsBuilder.swift:1013）——攻击成立，Slice A 必须动 thin |
| 7 | partial prompt 明令「Don't compare against any previous period」（PRODUCT 的 elapsed-clamp 论据） | **已核实**（:705；partialProgress elapsed 在 :317-348） |
| 8 | 相关 pair 本就是单条 clue（ARCHITECT 攻「合并需要 LLM」） | **已核实**（makePairRelations :824-866；RELATION 序列化 ReportModels.swift:377-383） |
| 9 | recordStreak「报告侧复用/移植即可」（PRODUCT/COST r1） | **有出入**：签名 `recordStreak(store: EventStore)` 且内部 `Date()`（AnalysisViewModel.swift:287-288）——必须重推导（ARCHITECT 纠正成立）；研究快照第 74 行「零 UI 消费」属实（仅定义 + AnalysisSuggestionService.swift:98 拼 prompt）；另其语义故意用 rawCalendarEvents，与报告契约集不同，重写需显式决定 |
| 10 | 「low 不出 builder」（ARCHITECT r1） | **有出入**（层次）：low-tier 丢弃发生在 promptText 序列化层（ReportModels.swift:365-377 `where tier > .low`），builder 照常返回全部 pair；纪律真实存在，detector 层需明确在哪层丢 low |
| 11 | COST 守卫#8「天花板 ≤14,250」vs 其档位2 估算「写作 16-18k in」 | **有出入**（自相矛盾，DESCOPER 击中）；收敛按「天花板不涨、证据从 EVENTS 份额置换」 |
| 12 | 「#116 修复日全体 fingerprint 漂移」（ARCHITECT r1） | **有出入**（夸大）：fingerprint=(detectorID,types,direction) 不含量级，COST 校正成立；#116-first 切片下问题不发生 |
| 13 | 「历史 8 窗重跑毫秒级忽略不计」（DESCOPER r1） | **无测量支撑**：expandOccurrences 逐日 while-walk（:607-620）+ weightedTypeHours days×occurrences 双重循环（:729-741）已核实——列为 Slice A 前置实测项（3/4 主张） |
| 14 | 「第二次调用 = 串行延迟 +50-100%」（DESCOPER r1） | **有出入**（夸大）：≤2.5k in/0.5k out 的选题调用 ≈2-5s，对 10-20s 写作 ≈ +15-40%（COST 校正成立） |
| 15 | 预算与上限常量：3750/1800/7500/3000、charsPerToken=2、max_tokens=4096×4、AFM 一次性 await | **已核实**（ReportGenerationService.swift:60/66/73/79；ReportModels.swift:119-126；LLMProvider.swift:189/293/358/459 精确；AFMProvider.swift:34 精确） |
| 16 | EVENTS 只含窗内 occurrence → 窗外 LOG 原话无通道（PRODUCT 攻 DESCOPER） | **已核实**（ReportStatsBuilder.swift:236-239）——深包白名单须含窗外指认引语 |
| 17 | userNote 是唯一回写通道且最高权威进 MEMORY（PRODUCT「评分不能走 userNote」） | **已核实**（ReportStore.swift:62-67；fence「outrank anything」在 :442，USER NOTES 永不裁 :474-485——PRODUCT 引 :475-485 属实义，引文原文位置 :442） |
| 18 | 冻结快照/schemaVersion 容错/纯本地 | **已核实**（ReportStore.swift:14-19、:38、:119-121 skip-not-crash；换机丢 novelty 记忆为真限制） |
| 19 | 「a destination you revisit」/ prompt v2「太 technical」注释 /「don't report the weather」/ EVENTS 领先 | **已核实**（ReportViews.swift:8-9；ReportGenerationService.swift:652-660、:731、:753-766） |
| 20 | backfill 不对称构造（deletions 永不叙述靠构造） | **已核实**（ReportStatsBuilder.swift:140-179，:146-152） |

其余 40+ 处 `file:line` 引用按同等密度抽查，未见系统性偏差；个别 ±1 行（如 actualDurationMinutes 实在 :440 非 :441、isThin 传参在 :196 非 :197），不影响任何论证。

**存档备注**：本轮与 07-02 五方评审的关系——当时的红线「塞不下再 agent 是第二套架构不是 if 分支」在本轮被构造化了：pick-from-menu + 证据预计算 + 失败回落，使「砍掉选题调用系统仍完整」成为类型层事实而非纪律承诺；当时 5/5 的「先 WoZ」这次以「owner 逐篇评分字段 + 发射形状可观测」的形态回归——升级 pass-1 的证据将自动积累，而不是靠轶事。
---

## Owner 裁决（2026-07-16）

- **裁决 A：「模型自由补观察 section」→ v1 砍掉**（采 cost+architect）。「数字全代码算」红线零开口；detector 盲区暂靠 EVENTS 在场兜底。注意配套含义：没有这个出口后，「报告漏讲了我最感兴趣的事」这一 pass-1 升级信号只能从 owner 逐篇评分字段来——评分字段因此从 nice-to-have 变成触发机制的唯一观测通道，Slice A 必带。
- **裁决 B：pass-1 契约类型现在写进 repo**（采 descoper+product）。约几十行无实现类型：`clueIDs` 为**数组**（锁定合并语义）+ 一句话 `angle` + **无任何证据声明字段**；文件头注释写明「Slice C 触发条件命中前不得实现/不得扩字段」。附带小项（菜单行是否带 50-100 字符记录摘录）留到 Slice C 触发时定——类型层不需要它。

裁决后无剩余分歧；切片顺序生效：#116 → Slice A → Slice B → dogfood 评分 2-4 周 → Slice C（条件性）。
