# 业内同步引擎金标对照 — 调研、缺口与本地验证计划

日期:2026-10-18(初稿;同日第三轮定稿,三位质疑者 45 条逐条处置,见 §H)· 母票 #257 · 对照对象:设计 v1.4(`Docs/sync/00-realtime-sync-design.md`)与 migration 015 v4,分支 `design/realtime-sync @ 34a7810` 加工作树里未提交的 slice-1 代码(`Done/Services/SupabaseSyncService.swift`、`Done/Services/Sync/`、`DoneTests/Sync*`)

**方法**:八份独立调研报告,每份对照一类系统,并把自己结论里最承重的引文重新取证一次:Replicache / Zero、Linear、CloudKit、PowerSync / Electric、经典复制系统(CouchDB、Couchbase、Atlas Device Sync、Firestore)、Supabase 社区方案、Postgres 变更流、业内验证方法。本文把它们合并去重。报告里关于**本仓库代码**的说法,写本文时逐条对工作树复核过;复核推翻或修正报告结论的地方集中在 §B.4「矛盾与裁决」。本文只做调研和计划,不改设计稿。被采纳的条目按本文编号(G = 缺口,M / S / L / X = 建议)回写进 `00-realtime-sync-design.md`。第三轮之后编号有移动:原 S3 → L8,原 L6 → S11,原 M4 第二部分 → L9,原 M2 触发器 1 → L10,原 M1(d) → X9,原 S8 影子模式 → X10;新增 G23、G24、S11–S13。

**引用约定**:`path:line` 指上面的工作树;`015:N` 指 `done-mcp/supabase/migrations/015_sync_change_feed.sql` 第 N 行;§ 编号不带前缀的指设计稿。

---

# 第一部分 白话版

## A.0 这一版改了什么

上一稿写完之后,三位独立质疑者拿算术、代码和原始文档逐条反驳,一共 45 条。我们逐条复核,能对代码核的都对工作树核过:多数原样采纳,一部分只采纳了一半,没有整条驳回的。每一条怎么处理的,写在文末 §H。下面是改动最大的几处,也包括我们自己上一稿写错的地方:

- **我们自己提的「倒退重置」有错**。上一稿说:发现服务器倒退以后,每台设备一律以本地为准。质疑者构造了这样一个场景:一台设备在导出之前就离线了,手里是旧的、但完全干净的数据;它回来之后会用这份旧数据,盖掉别的设备在恢复之后写的新数据。改法是让纪元表再记一个「恢复点号码」:号码在它之前的行以本地为准,在它之后的行照常三方比较。(M2)
- **今天的 slice-1 代码里就有一个会丢删除的洞**。新建一行,刚发出去、还没等到服务器回声,就把它删掉,这次删除不会发给服务器,别的设备上这一行会一直活着。上一稿只处理了「改了一行、回应丢了」这一种情形,现在推广到所有「不知道服务器收没收到」的写。(G23、S4)
- **「骨架跟业内一样」说得太笼统**。骨架的每一块都有成熟系统用过,但没有哪一家整套都和我们一样。最要紧的一处不同:CloudKit 把「待发送」记在一份持久清单里,服务器确认之前不会划掉;我们每次重新比指纹,一行被改回原值,发送意图也就跟着没了。上面那个洞,还有「回应丢了之后又改回原值」,根子都在这里。(A.1、§B.3)
- **domino 的修法少了一条**。就算按行锚定,设备切回前台时也是先推一遍,后拉到别的设备已经推过的结果,于是每个未来待办都会进一次冲突架。改成:本次启动拉到最新之前不推,每次推之前先拉一次。(M4)
- **砍掉了三样**:
  - 生产上的「影子模式」。它只活一天,要验证的东西别的环节已经覆盖了,而且按原来的写法,要么会造成请求风暴,要么判据根本达不到。
  - UserDefaults 崩溃顺序的测量。笔记本上造不出它要找的那种故障,测出 0 也说明不了什么。这一项改为用构造来保证(S11)。
  - M1 里那个可选的锁命名空间。

  另外,原 S3「本机刚删的条目被旧页闪回」的守卫降为 later:它只会让条目闪一下,不丢数据。
- **测试计划改动最大**。上一稿有四个问题:
  - 「每一步之后先让系统安静下来再对账」,会把被扣住的请求在每一步都放掉,随机套件因此走不到最难的那些交错。
  - 「每个输掉的版本都在 shelf 里」按字面理解,在最正常的路径上就不成立。
  - 层 1 的两台虚拟设备用的是真实时钟,还共用同一份 UserDefaults,同一个种子跑两次,结果都不一样。
  - 层 3 的「一台离线、一台在线」,在同一台笔记本上的两个模拟器里做不出来。

  逐条改法见 §E。
- **没变的**:大方向不变。先改 7 件事,再开始本地测试;本地测出信心,再部署。

## A.1 一句话

**骨架的每一块都有成熟系统用过,护栏不够,测法要升级。**

骨架的每一块都能在成熟系统里找到对应,但对上的系统各不相同,没有哪一家整套和我们一样:

- **服务器给每次改动发递增号码,设备记一个书签**:Replicache、CouchDB、Linear 都是这样。CloudKit 的书签作用相同,但它是一个不透明的令牌,不是递增号码。
- **推送只当门铃,不带数据**:Replicache 的 poke、CloudKit 的静默推送。Linear 和 PowerSync 推送的是数据本身。
- **写之前先对版本,服务器上已经不是那一版就拒绝**:CloudKit、CouchDB、Firestore。Replicache、Linear 和 PowerSync 不这样做,它们在服务器上重放操作,客户端不做条件写。
- **删除留墓碑**:所有系统都这样。多数系统会定期清理墓碑,我们不清理。
- **冲突时两个版本都留下**:CouchDB、Bear、Dropbox。多数系统会直接扔掉其中一方。

**有一处不同必须正视**。CloudKit 的 CKSyncEngine 也是「按状态发」,但它把「这些记录待发送」存成一份持久清单,服务器确认之前不会划掉,真正发送时再去读当前内容。我们没有这份清单,一行脏不脏,是每次拿指纹和基线现算出来的。所以一行被改回基线的值,发送意图就跟着消失了。平时这没有问题,服务器上本来就是基线那一版。但如果一次写已经发出去,却不知道服务器有没有收到,这个意图就丢了。S4 用一个「结果未知」标记把这一处补上(§B.3)。

要补的是两类东西:

1. **出意外时的护栏**:服务器数据被回滚(从一份旧的导出文件恢复);某条写入永远会被拒绝;门铃坏了;两次拉取交叉着到达;每台设备各自给待办做「自动推迟」;写出去之后,不知道服务器收没收到。
2. **测法**:业内金标是制造乱序、断网、丢回应、杀进程。**任何时刻**都检查不该发生的事有没有发生(数据丢了、删掉的复活了);在系统安静下来的时刻,检查各方是否一致;而且一定有一层用真服务器跑。我们现在主要对着自己写的假服务器测,并且只在最后对一次账。

## A.2 哪里和业内一样(放心的部分)

- **书签加号码**。Replicache 叫 cookie,CouchDB 叫 checkpoint,Linear 叫 lastSyncId,本质上都是一个数,拿着它问服务器「比这个新的给我」。CloudKit 的 change token 用途相同,不过它是不透明的令牌,不是递增号码。我们的 `seq` 游标属于前一种。
- **号码顺序要等于提交顺序**。号码要是先取后提交,书签会永远跳过一行。Replicache 文档专门写了「不要拿最后修改时间当游标」,Sequin、Marten 都在这里踩过坑。我们的解法是每个用户一把锁,和 Replicache 的「每空间一个版本号」是同一招。Postgres 源码也确认了:锁放开之前,事务已经对别人可见。
- **门铃不带数据**。Replicache 的 poke、Notion 的版本通知、CloudKit 的静默推送,都只说「有新东西了,你自己来拉」。iOS 一进后台连接就断,本来就得会拉,所以只留「拉」这一条路最简单。
- **删除留墓碑**。所有系统都这么做。很多系统过一段时间会清理墓碑:Couchbase 默认 3 天,Linear 30 天。清理之后它们就得处理「离线太久的设备把删掉的东西复活」。我们干脆不清理。删除很少,存墓碑几乎不花钱,这整类问题也就不存在了。
- **写之前先对版本**。CloudKit 的 change tag、CouchDB 的 `_rev`、Firestore 的前置条件,意思都是「我是在第 N 版上改的,服务器上已经不是第 N 版就拒绝我」。我们的 `PATCH …&seq=eq.<基线>` 就是这个。
- **冲突时不丢东西**。Bear、Dropbox 会留一份「冲突副本」,CouchDB 把输掉的版本存成修订树的叶子,我们放进 conflict shelf。多数系统默认直接扔掉输家,包括 Linear、PowerSync、Firestore 和 Apple 的官方样例。这一点上我们更严。

## A.3 哪里不一样,该不该改

| 差异 | 业内常见做法 | 我们 | 结论 |
|---|---|---|---|
| 写的方式 | 记「操作日志」,由服务器重放(Replicache、Linear、PowerSync、Firestore) | 比对整张表的指纹,把改过的行整行发出去 | **保持**。操作日志需要一台跑业务逻辑的服务器,我们没有。CKSyncEngine 也是按状态发,但它有一份持久的「待发送」清单,我们没有;差出来的这一块,由 S4 的「结果未知」标记补上 |
| 冲突粒度 | 多数按字段(Figma、PowerSync、Linear):两台改了同一条的不同字段,两处改动都留下 | 按整行:一方整行进 shelf | **先量再改**。先在冲突日志里记下「哪些字段不一样」;如果真有很多冲突改的不是同一个字段,再做字段合并 |
| 谁赢 | Apple 样例按编辑时间;Figma、PowerSync 按服务器收到的先后 | 后上传的赢,另一版进 shelf | **暂不改,而且现在量不出来**。服务器上的「更新时间」其实是上传时刻,离线很久的旧编辑上线时会拿到一个新的时间。要量「输的一方有多新」,得先给事件加上编辑时间(D4 已经估过成本) |
| 服务器「倒退」 | 都有重置信号。Replicache 发现书签「来自未来」就中止,文档里的例子发生在开发环境,恢复靠手动清数据;CouchDB 两端核对 checkpoint;Electric 返回 409,让客户端从头来;CloudKit 有 changeTokenExpired(原页没能取回,未证实) | **没有** | **要改**。免费版没有平台备份,唯一的恢复办法是导入一份自己导出的文件。这件事从来没做过,但操作手册和检测要在出事之前就准备好。导入之后,设备会悄悄漏收新改动,还会把自己的编辑误判成「已经上传了」 |
| 永远会被拒的写 | Replicache:必须标成「已处理」,否则「永远卡住」。CouchDB:4xx 错误不重试 | 每次同步都原样重发,日志里分不出「网络慢」和「永远不会成功」 | **要改**。台架已经抓到一个真实案例:`agent_preferences` 从来没有上传成功过,几个月里没人发现 |
| 兜底轮询 | Replicache 默认每 60 秒拉一次,和门铃并存 | 计划「一个版本里从没靠它发现过东西,就删掉」 | **要改,保留它**。轮询只在门铃坏了的时候才有用;门铃好的时候,它当然什么也找不到。拿「什么也没找到」当理由删它,等于在门铃正常的时候拆掉唯一的报警器 |
| 门铃带不带数据 | Linear、Firestore、PowerSync 直接推数据 | 只推号码 | **保持** |
| 墓碑清理 | 多数会清理 | 不清理 | **保持** |

## A.4 本地测试开始之前,要先改的 7 件事

1. **定稿服务器脚本(015)**:
   - 禁止 `TRUNCATE`;
   - 删掉设计稿里「管理员先关触发器再硬删一行」那条说明;
   - 每页最多取的行数从 2000 改到 1000 以内;
   - 部署后的检查加两项:三个同步触发器都开着;服务器每次最多返回的行数没有被调低。

   TRUNCATE 和硬删会让设备以后对那几行的编辑被误判成「内容相同」,从此不再上传。每页上限写错是一个潜伏的常量错配:今天客户端每页只要 500 行,不会出事;但只要有人把每页调到 1000 以上,或者把服务器的上限调到 500 以下,满满一页就会被当成最后一页。
2. **检测「服务器倒退」**:
   - 加一张只有一行的「纪元」表,里面记一个随机值和一个「恢复点号码」;
   - 每次启动先看一眼;另外,在把一次没收到回音的编辑判成「已上传」之前,再看一眼;
   - 值一变就重置:恢复点之前的行以本地为准,之后的行照常比较;
   - 恢复操作写成一个脚本,脚本最后一行在同一个事务里更换纪元。

   如果有人绕过这个脚本手工恢复,只读的设备察觉不到,这一点作为残余风险明确写下来。
3. **同一时间只允许一次拉取**:两次拉取交叉着回来时,旧的那一页可能在删除之后才到,删掉的东西会复活。
4. **「待办自动往后推」(domino)改成全账号只推一次,并且本次启动拉到最新之前不推**:现在每台设备都按「离我自己上次推过了多久」来推,两台设备会叠加,两台时待办以两倍速往后漂,三台就是三倍。设计稿说「两台算的是同一天,所以会收敛」,这个前提在代码里不成立。另外,切回前台时代码是先推、后拉,就算改成按行锚定,也会把每个未来待办送进一次冲突架。具体改法需要你拍板(§D M4)。
5. **保留 60 秒轮询,当门铃的看门狗**;门铃每次重新连上,都立刻拉一次。
6. **给假服务器补上真实行为,把时钟和设置存储都做成可注入的**:假服务器现在模拟不了「服务器已经执行、但回应丢了」「拉取的回应迟到」「一页最多 1000 行」「行已经不存在」这几种情况。层 1 的两台虚拟设备还在用真实时钟、共用同一份设置,所以同一个随机种子跑两次,结果都不一样。
7. **本地测试必须包含真服务器那一层**:同一批请求分别打给假服务器和真服务器,按约定的规则比较,不能有差异;再加几条脚本化的故障场景。

## A.5 部署之前要改的(本地测试期间一起做)

- 写入被服务器永久拒绝时,只报一次,不再重发,也别拖累同一批里的其它行。部署窗口里「表结构缓存还没刷新」这类暂时的拒绝,要和真正的永久拒绝分开。
- 合并两个待办后点「撤销」:撤销提示条显示 4 秒,而同步 2 秒后就把删除发出去了,撤销回来的那一条从此回不到服务器。改法:撤销提示还在的时候,先不发这条删除。
- 凡是「不知道服务器收没收到」的写,都把那一行标成「必须再核一次」。这包括一种今天代码里就有的情形:新建的一行刚发出去就被删掉,删除永远发不出去。
- 普通的「退出登录」不清本地数据。换另一个账号登录后,旧账号的数据会被当成新数据推进新账号。改法:记住「这台设备的数据属于谁」,对不上就停止同步并提示。
- 另一台设备删除了账号以后,这台设备在登录凭证过期之前(最长 1 小时)写出去的东西,会被悄悄吞掉或判成「被拒」。要能认出「账号已经不存在」,并且写清本机数据怎么处置。这一条需要你拍板。
- 「书签」和「基线」的保存顺序用构造保证,不靠测量。
- 冲突日志里记下「哪些字段不同」,以后决定要不要做字段合并就看这个数。
- 对账工具:每台设备上的每一行都和服务器逐行比对,再用一个独立的脚本复核一遍。
- 一条快照测试钉住每张表上传的字段集合和枚举值集合。它一变红,就说明在发版之前得先做「混版本写回」的防护。
- 冲突架在把胜方版本推上服务器之前先真正落盘。

## A.6 怎么在本地测到有信心

1. **假服务器加随机剧本**:
   - 用 XCTest 跑,放在独立的测试计划里,不进默认的全量测试。每次提交跑少量种子,夜里跑大量。
   - 两台虚拟设备在一个假服务器上执行几百步操作,时钟是注入的,每台各有自己的设置存储,同一个种子跑两次,请求日志逐字节相同。
   - **每一步都检查**不该发生的事:一次被确认的写,不能不明不白地消失。它要么是最终值,要么在某个 shelf 里,要么被一个「看见过它」的后续写正当地覆盖。删掉的不能复活,书签不能倒退。
   - **在随机挑选的安静时刻**,再查三方是否一致、安静之后是否还在发请求。这样被扣住的请求可以跨很多步才放出来,最难的交错才走得到。
   - 每个已知 bug 都配一个「故意改坏」的版本,只开随机剧本也必须能把它抓红。
2. **真的本地 Supabase**:
   - 同一套请求分别打给假服务器和真服务器,按约定的规则比较:状态类别、返回空还是有行、有没有删除标记和号码、号码的先后、解码之后的指纹。必须零差异。
   - 然后跑几条脚本化场景:回应丢失、死锁、永久拒绝、门铃服务暂停、两台同时写同一行、另一台设备删除账号、登录凭证刷新、第三方直接写库。
   - 再照 Supabase 文档原样做一次「导出 → 继续写 → 恢复」,分「记得换纪元」和「忘了换」两个版本各跑一次。
3. **两台模拟器跑真 app**:
   - DEBUG 构建里加两个开关:每台设备单独「断网」;在指定的位置让进程自杀。
   - 每个场景结束时对两次账:一次在 app 内;另一次用一个独立的 Python 脚本,拿 psql 导出的数据逐字段比。不一致必须是 0。
   - 对完账再静置 150 秒,服务器上的号码和写入计数都不能动。
4. **只有真机能测的**:app 进后台、socket 被系统断开之后,切回前台能追平;真实网络下的延迟。
5. **生产**:
   - 应用 015,做部署后检查,打开同步;
   - **打开之后立刻**在两台设备上对账,结果必须是 0;之后一周每天对一次账;
   - 任何一次不为 0,就走回滚。回滚流程要先在本地演练过。

## A.7 什么时候算「有信心」

- **随机剧本**:记下跑了多少个种子、在哪个 commit 上跑的。每个「故意改坏」的版本,只靠随机剧本也能在一次提交的预算内被抓红;做不到的,改用穷举覆盖。每一类「有意思的情况」走到的次数,都超过了测试自己算出来的下限。
- **假服务器和真服务器**:按约定的规则比较零差异;脚本化场景全部通过。
- **两台模拟器**:全部场景通过,两种对账都为 0,静置期间零写入。
- **生产**:打开同步后立刻对账为 0,之后一周每天对账都为 0;每一条被拒的写入都有解释;真机上门铃路径的延迟 p95 不超过 2 秒。

具体判据见 §F。

---

# 第二部分 技术版

## B. 对照

### B.1 协议骨架

| 系统 | 游标 / 版本 | 顺序保证 | 变更通知 | 写路径 |
|---|---|---|---|---|
| Replicache | cookie = 全局或每空间版本号 | 推送串行(读版本 FOR UPDATE,+1) | poke 不带数据,加 60 s `pullInterval` | 变更日志 `{id, name, args}`,服务端重跑 mutator,`lastMutationID` 原子记账 |
| Zero | cookie 加服务端 CVR | 行版本,无全局锁 | poke 带 patch(多段原子) | mutator;服务端判冲突 |
| Linear | `lastSyncId`(全局,有空洞) | Postgres 权威,CDC 进 live feed | WebSocket 推完整 delta 行 | 持久化事务队列;服务端校验每次写 |
| CloudKit / CKSyncEngine | 每 zone 一个不透明 change token | 批内不保证顺序 | 静默推送 → 拉 | 按状态(pending record IDs,发送时取当前内容);change tag CAS |
| PowerSync | checkpoint(op_id,由 WAL 位置得出) | WAL 提交序 | 流推数据 | `ps_crud` 阻塞 FIFO 操作队列,经你自己的后端 |
| ElectricSQL | shape offset(LSN) | WAL | 长轮询 / live | 写走你自己的 API |
| CouchDB / PouchDB | `since=<seq>` checkpoint,源和目标两端都存 | 集群 feed 可回卷重放 | `_changes` 连续流 | `_rev` CAS,修订树 |
| Couchbase Lite + Sync Gateway | checkpoint | — | WebSocket | 修订树 |
| Atlas Device Sync(2025-09-30 停服) | 服务端历史版本 | 服务端 | 推 | OT changeset |
| Firestore | resume token | — | listen 流带文档快照 | 每用户持久 mutation 队列 |
| Figma | 每文件 journal seq | 服务端顺序 | WebSocket | 每 (对象, 属性) 服务端 LWW |
| Supabase 社区(RxDB、WatermelonDB、Legend-State) | 时间戳 | 无(会漏行) | `postgres_changes` 直接应用并推进游标 | 各异 |
| **Done** | 每用户一个整数游标 `syncHashes.<uid>.cursor` | 用户级 advisory 锁 → seq 序 = 提交序(I5) | 门铃 `{table, seq}` + 游标拉取 + 60 s 轮询 | 整表 hash 差分;条件 `PATCH seq=eq.<基线>`、ignore-duplicates POST、`PATCH deleted_at` |

### B.2 冲突、删除与异常

| 系统 | 冲突粒度 | 败方 | 删除 | 墓碑回收 | 服务端倒退 / 过期 | 永久拒绝 | 验证做法 |
|---|---|---|---|---|---|---|---|
| Replicache | 操作级(服务端重跑) | 不留;文档建议「做历史以便撤销合并」 | soft delete | 无指引 | 「cookie from the future」→ 中止(检测信号;文档例子是开发态服务器重启,恢复靠手动清浏览器数据);未知 cookie → 清空重置 | 必须推进 `lastMutationID`,否则「永远卡住」 | — |
| Zero | 操作级 | — | CVR 推断 | — | CVR 丢失 → 清空重置 | — | soak harness 每个混沌动作后静止对账(杀的是服务端 view-syncer 与复制管理器,对客户端同步只是类比) |
| Linear | 字段级 LWW(服务端顺序) | 丢 | delete / archive 动作 | 30 天 | — | 回滚 + toast(约 15 处手写例外) | shadow mode 对比 sync action id |
| CloudKit | 每记录,应用合并 | 样例丢 | 私库有墓碑 | — | `changeTokenExpired` → 丢缓存重拉(原页由 JS 渲染,未能取回,未证实) | — | 官方样例:两个引擎对真开发容器,冲突两种顺序都测 |
| PowerSync | 字段级 LWW(服务端收到顺序) | 默认丢(可选 `write_conflicts` 表) | delete wins | MOVE / CLEAR 压缩 | 每 bucket checksum + CLEAR | 22 / 23 / 42501 视为致命(demo 丢弃余下事务) | Jepsen 套件 |
| Electric | —(写走你的 API) | — | — | 压缩 | PITR / 换 system id → 409 must-refetch | — | oracle 测试、Antithesis |
| CouchDB | 文档修订树,确定性胜者 | 留作叶子,复制到每个副本 | 墓碑修订 | 压缩时保留叶子 | session_id checkpoint 不一致 → 全量 | 401 / 403 / 409 / 412 不重试 | PouchDB 对真 CouchDB 跑套件 |
| Couchbase | — | — | delete wins | 默认 3 天 purge | — | — | — |
| Atlas Device Sync | 字段 | — | delete wins | 超过 client 最大离线时长 → client reset | 服务端从备份恢复 → client reset | — | TLA+ 模型生成 4,913 条测试 |
| Firestore | 文档 | — | — | — | existence filter + bloom → 重置 target 重查 | 规则拒绝 → 移出队列、本地回滚 | spec tests 伪造异步事件源 |
| Figma | 属性 LWW | 丢 | — | — | — | — | — |
| **Done** | 整行三方比较;settings 按顶层键 | 进本机 shelf | tombstone 总胜,服务端触发器保证 | 不回收 | **无**(G1;M2 补 epoch + floor) | **无**(G7;S1 补) | Lean 模型 + fixtures、FakeServer 引擎测试、台架 S1–S15 |

### B.3 共识:业内有、我们有意不要的

各报告在这些点上结论一致,都认为我们的选择更适合我们,所以不进建议清单。理由只记一句:

- **操作日志 + 服务端 mutator**(Replicache、Linear、PowerSync):要有能跑业务逻辑的地方;我们只有 SQL。Linear 的「重复删除 toast」恰好是不幂等重放的代价。
  - **但我们的状态式出站和 CKSyncEngine 不是同一种**(第三轮订正,Q2.3)。CKSyncEngine 持久化一个 pending record ID 集合,服务端确认之前不删,发送时再读当前内容。我们没有这样的集合:脏不脏是每次拿 hash 和基线现算的,所以把一行改回基线值,就抹掉了发送意图。
  - 只要还没发出去,这没有问题:服务端上本来就是基线那一版,CKSyncEngine 这时发出去的也是同样的内容。差别只出现在「已经发出、结果未知」的时候,G10、G23 都出在这里。
  - S4 的 `?` 标记是在发送时写下、确认之后才清掉,相当于一个只覆盖在途写的待发送集合。
  - 备选是一个持久的 pending-ID 集合,要在九张表的每个本地写入点都挂钩子。它多覆盖的只是「还没发出就改回」这一种情形,而这种情形本来就无害,所以不做。如果以后出现第三种因此丢意图的情形,再重新评估。
- **带数据的推送**(Zero、Linear、Firestore、PowerSync):iOS 后台必断,拉取本来就要有;只推门铃,则只有一条应用路径、每次拉取过一次 RLS、每条语句一帧。
- **CVR、xid8 水位、逻辑复制槽**(Zero、Electric、PowerSync):要么要常驻服务,要么免费层的磁盘扛不住复制槽积压的 WAL;`pg_snapshot_xmin` 是全集群的,dashboard 或 MCP 上一个长事务就会冻住每台设备的 feed。用户级锁在 3 个用户的规模下零可测成本。
- **墓碑压缩与 purge**(PowerSync、Couchbase、Linear):有了它就必须有重置信号;我们一年的删除以百计。
- **原子 checkpoint 应用**(PowerSync、Replicache):我们的服务端事务都是单表的;applier 本来就容忍跨表乱序(事件缺席时 log 按 key 插入、子行 tombstone 走本地级联)。
- **按 sender 过滤回声**(CloudKit):D5 的「回声由三方比较吸收」更省。
- **引导模式、懒加载集合、sync groups**(Linear):13k 行、3 个用户,用不上。

### B.4 矛盾与裁决

报告之间,以及报告与代码之间,有十处不一致。逐条裁决如下,依据都是对工作树的复核或算术。

**C1 domino 能不能「到 head 后再跑就收敛」**。综合调研报告说:把 `dominoPushTodosPastHorizon` 挪到首次拉到 head 之后再跑,两台算出的字节相同,PATCH 回 `[]`,不会冲突。Linear 报告说:它是基于差值的,会复利。**代码支持 Linear 报告**。`EventStore.swift:502-575` 里 `delta = now − dominoLastPushEffective`(本机心跳),这个差值加在**此刻数组里**每个 horizon 之后的待办上;`DoneApp.swift:943-944` 在前台每 900 s 跑一次,`:913` 在启动 / 前台时各跑一次。A 采用了 B 推过的行之后,会用自己的差值再推一遍。这里根本没有「同一个 horizon 日」,所以 §9.22 的前提不成立,综合报告的建议对这段代码也无效。第三轮又补了一个顺序问题:`:913` 在切前台时是同步调用,而切前台触发的拉取是异步的,所以即便按行锚定,也是先推、后拉到别台的推移(Q1.1)。见 G5、M4。

**C1b Linear 报告给的修法 (a) 有窗口**。它的修法是:把锚点做成账号级 settings 键、按 max 合并、到 head 后再跑。问题在于 settings 和 events 是两张表、两次 flush:settings 防抖 5 s,events 防抖 2 s。A 可能在 B 的 settings 还没上传时就已经拉到 head,这时 A 手里是 B 推过的行和旧锚点,于是再推一遍,而且这个错不会自己愈合。所以 M4 只推荐「按行锚定」或「单写者」两种在构造上正确的方案,(a) 列为不推荐。

**C2 字段级合并现在做还是先量**。综合报告判「业内对、该做」,其余报告都判「看情况、先量」。前者的主要论据是 domino 每天制造整行冲突,而这个场景对现行代码的描述是错的(C1);M4 修好之后,这个驱动就没了。按减法原则**先量**(S7),触发条件见 L1。

**C3 恢复后的运行手册**。PowerSync 和 CouchDB 报告建议恢复后 `setval sync_seq` 抬到所有游标之上;验证报告建议只写手册、不做检测;Replicache 报告建议加 epoch。**`setval` 抬高是错的**:恢复回来的行带着比设备基线小的 seq,设备的下一次编辑会回 `[]`,pending-verify 看不到这一行,于是判「相同」,编辑就丢了。抬高 seq 修不了基线,反而让写响应检查(原 M2 触发器 1,现 L10)永远不触发。**只写手册也不够**:手册得靠设备上事先装好的检测代码才能执行,事故发生以后再发版来不及。裁决(第三轮修订):用 epoch 当手册的远程开关,手册写成脚本,在恢复的同一个事务里换 epoch;在线设备靠「pending-verify 判相同之前查一次 epoch」(M2(c))发现倒退。写响应检查(原触发器 1)降为 L10:恢复从未发生过,脚本之后它唯一的消费者是绕开脚本的运维者(Q1.7)。

**C4 重置成什么形状**。有四份报告建议检测到倒退后,把基线改写成旧的 `<hash>` 形状(seq 未知)。按 §6 规则表算一遍:基线 `<hash>` = 本机最后同步过的 hash h_A,本地 == h_A(干净),恢复回来的服务端行是导出时的 c_d,结果 `!dirty` → 采用 c_d。也就是说,**恢复点之后已经同步过的编辑会在每台设备上被回退**,而那些编辑在服务端已经没有了,设备上的副本是仅存的一份。上一稿的裁决是改用「hash 未知」哨兵,对所有行一律以本地为准。第三轮证明它也错了(Q2.1):一台导出之前就离线的干净设备回来后,会把别的设备在恢复之后写的新版本判成冲突,并用旧版本盖掉它。**裁决(修订)**:epoch 行带一个 `floor`(恢复时的序列值)。来件 seq ≤ floor 是恢复回来的内容,用哨兵语义;来件 seq > floor 是恢复之后写的,用保留的旧 hash 走普通三方比较。基线保留 id,本地删除仍然胜(M2)。

**C5 倒退检查跟什么比**。CouchDB 报告拿响应到达时的游标比,PG 变更流报告拿门铃 payload 的 seq 比。**两者都有误报**。前一种:PATCH 拿到 100 并提交,另一台随即提交 101,一次并发拉取拉到 101、游标推到 101,这时 PATCH 的响应(100)才到,100 ≤ 101,误判为倒退。后一种:门铃是异步到达的,60 s 轮询可能先把那一行拉到,门铃 seq ≤ 游标再正常不过。每次误报都会触发一次 27 页的全量拉取。裁决:**拿发送时记下的水位比**(PowerSync 报告的写法),只看写响应,不看门铃。这项检查第三轮降为 L10,比较对象的结论不变。

**C6 永久 4xx 是「每 2 s 一次」还是「每次本地编辑一次」**。多数报告写「每 2 s 重发」,Supabase 社区报告写「出站由 `@Published` 驱动,所以每次本地编辑才重发一次,不是紧循环」。实际情况在两者之间:sink 观察的是整个数组(`SupabaseSyncService.swift:699-745`),**同一张表里任何一行变了**,那条被拒的行就会重发。events 表因为 domino 和日常编辑,变动很频繁。另外 POST 是 20 行一块,块失败时整块回滚(`:1416-1419`),一行坏会把另外 19 行也拖住。所以它不是紧循环,但重发没有上限、毫无声息,还会连累邻居。见 G7、S1。

**C7 午夜分区会不会丢门铃**。PG 变更流报告担心 `realtime.messages` 的日分区没人建,导致门铃丢失。Supabase 社区报告复核了故障排查页:join 时会预建「昨天、今天和之后三天」的分区,并且约每 3–4 h 刷新,失败只出现在「反正也没人收」的时候。**裁决:对 Done 无害**,不单独作为风险。轮询照样保留(M5),理由是 §5.3 的 WARNING 吞错和 Supabase「不保证投递」。

**C8 要不要把 `sync_head()` 加回来**。Replicache 报告建议加回来,验证报告反对。裁决:不加函数。M2 用一张一行的表加一次普通 GET,就够 epoch 用了;「游标 > 用户 head」这项检查原本由写响应检查替代,第三轮那项检查降为 L10,在线设备改由 M2(c) 在 pending-verify 处查 epoch 覆盖。v1 的减法(§13)保持不变。

**C9 `[]` 之后要不要显式读一次当前 seq**。Replicache 报告提了这个可选项。pending-verify 的推理在 Lean `Inv` 下已经证明;打破 `Inv` 的三条路径(TRUNCATE、硬删、恢复)分别由 M1 和 M2 关掉。加这次读要重写 `pullVerify` 模型和 §8 的三条交错测试,还会逆转「不加额外 GET」这项减法。**驳回**(X1)。

**C10 复核时没站住或没能核实的引文**。
- Replicache 的 poke 页**没有**把周期拉取写成「漏掉 poke 时的兜底」。M5 的依据是我们自己的 §5.3,加上 Supabase Realtime README 里「The server does not guarantee that every message will be delivered」。
- Linear 演讲里「bootstrap 期间把 socket 包排队」那段转录没能取到。M3 只建立在我们自己的算术和 `staleOrSeen none = false` 上。
- Atlas「输家被丢弃」那一半在原页上没有明说。
- Couchbase 文档里「约 30 天」的建议值没有找到,原页只举了「a week, or a month」两个例子。
- (第三轮,Q2.13 重新取证)Replicache dynamic-pull 的「from the future」是服务端中止,原文说「This can happen in development if the server restarts」,修法是手动清浏览器数据,不是自动的客户端重置。Zero 那句「a final-only comparison is nearly worthless」原文确实如此,但它出自服务端副本的 soak 测试,对我们只是类比。Apple 样例的 `handleAccountChange`:`.switchAccounts` 和 `.signOut` 删本地数据,`.signIn` 把本地数据重新上传;这支持 S5 的方向,但不是「accountChange 时强制重置」。`changeTokenExpired` 页面由 JS 渲染,未能取回,未证实。复核属实的有:PostgREST max-rows;Supabase 备份页(Free 计划自行 `db dump`);Realtime README 的「不保证投递」;Linear EU 宕机复盘;Electric PITR 后 409;Replicache poke(不带数据、60 s);PouchDB TESTING.md;Apple 样例的两个数据库对真容器;Apple DataModel 关于 last-uploader-wins 的注释。

---

## C. 缺口清单(合并去重,按严重度)

严重度:**data-loss** = 某个版本在任何设备、服务端和 shelf 上都不复存在;**divergence** = 设备之间、或设备与服务端之间静默不一致;**ux** = 用户看得到但不丢数据;**cost** = 请求或电量;**minor** / **test** 如字面意思。

### G1 服务端倒退没有检测 [data-loss]
**提出者**:Electric(PITR 后 409 must-refetch)/ PowerSync(CLEAR)、CouchDB(session_id)/ Atlas(client reset)、PG 变更流、验证;旁证:Replicache dynamic-pull「from the future」(只是检测信号,恢复靠手动)、CloudKit changeTokenExpired(未证实)。

**场景**:Free 计划没有平台备份,官方建议用 `supabase db dump` 自己导出,所以恢复就是重放一份旧 dump。照 Supabase 文档的恢复方式(`psql --single-transaction`、`session_replication_role = replica`、`--file data.sql`),触发器一个都不触发:恢复回来的行保留旧 seq,data.sql 的 `setval` 让 `sync_seq` 回到导出时的 N0,`sync_epoch` 那一行也被恢复成旧值。设备 A 的游标是 N1 > N0。
1. X 是 A 在导出之后新建的,基线 X@s(s > N0),服务端没有 X。A 编辑 X → `PATCH seq=eq.s` → `[]` → pending-verify → 有资格的拉取看不到 X → `base.seq == sentSeq` → 判「相同」。X 被标干净,从此只活在 A 上。
2. B 写 Y,拿到 N0+5 < N1。A 拉 `seq > N1`,看不到 Y;(N0, N1] 区间里的号被永久跳过。
3. 服务端还在的行,seq 比 A 的基线小,A 对它们后续的版本会因为 `seq ≤ base.seq` 而跳过。

全程不写日志,也不进 shelf。

**根因**:Lean `Inv` 里的 `BaseAnchored` 和「游标 ≤ 计数器」在运行时没人检查。一次恢复同时打破这两条,而 skip 规则和 pending-verify 的「没见到 ⇒ 相同」恰好只在这两条成立时才正确。

**开发态变体**:D8 让 DEBUG 模拟器指向本地栈,`supabase db reset` 会把序列重置为 1,也会清空 `auth.users`。如果模拟器的测试账号 uid 在重置前后不变(取决于模拟器怎么登录,未确认;台架脚本是按 email 重新注册,uid 会变),`syncHashes.<uid>.cursor` 会活下来,模拟器从此静默地收不到行。这件事在本地测试期就会发生,不是假想中的生产恢复,所以 §E.4 把它列为层 3 的前置条件(Q2.14)。注意 `db reset` 测到的是「用户消失」,不是倒退;倒退要照文档做导出与恢复(§E.3)。

**设计引用**:§4 I1 / I5;§6 规则表 skip 行与 `[]` 收口;§6.3;§8 Lean Inv;§13 v1 减法(`sync_head()` 已删)。**关闭**:M2。

### G2 物理删除路径让 pending-verify 误判「相同」[divergence]
**提出者**:PG 变更流、CouchDB(`_purge` 不复制)、Supabase 社区、验证、PowerSync。

**三条路径**:
- (a) `TRUNCATE`:不触发 ON DELETE 触发器,也不受 RLS 约束。015 没有 BEFORE TRUNCATE 守卫,迁移目录 grep `truncate` 零命中。在 SQL editor 或 Supabase MCP `execute_sql` 里「清一下测试数据」就能触发。
- (b) 015:143 和 §5.4 里我们自己写的管理员流程:「先 disable `trg_<t>_tombstone`,再硬删」。
- (c) 恢复(G1)。恢复时的 `session_replication_role = replica` 同样会绕过 M1(a) 的 TRUNCATE 守卫。

**共同签名**:某行在设备上有基线,在服务端却物理消失了。

**场景**:A、B 都持有 X (h0, s0),服务端的 X 没了。A 把 X 改成 c1 → `PATCH ?id=eq.X&seq=eq.s0` → `[]`(Supabase RLS 文档原话:零行时「raises nothing, matches zero rows」)→ 拉取看不到 X → `base.seq == sentSeq` → 标干净。此后 A 的每次编辑都这样被吞掉;B 留着自己那份 X;新设备从 0 拉,永远见不到 X。直到换机时,这才以「数据丢了」的样子暴露出来。

还有后续:之后某次 `markRestoreCompleted` 对服务端不认识的行写旧 `<hash>` 形状(§6.3),X 会被 POST 回去。这正是 CouchDB 文档说的「purge 掉的文档会从任何还持有它的副本回来」。

**关闭**:M1(a)(b)、M2(c)。

### G3 PostgREST `max_rows` 比 I1 写的上界小,造成假 head [潜伏:常量错配]
**提出者**:Supabase 社区。

`done-mcp/supabase/config.toml:18` 设了 `max_rows = 1000`,托管环境的默认值也是 1000;PostgREST 的 `db-max-rows` 对函数结果同样截断。I1 却写着「`page_limit` ≤ 2000」;015:271 夹紧到 2000;`SyncGatewayLimits.maxPageLimit = 2000` 及其注释、FakeServer 的夹紧也都照抄了这个错的上界。当 1000 < page_limit ≤ 2000 时,一整页回来只有 1000 行,小于 page_limit,被读成短页,也就是假 head。

**场景**:A 的 X 是脏的 c1,基线 (h0, s0)。B 大批量重推,X 拿到 s1,而 s1 排在第 1000 行之后。A 的 PATCH 回 `[]` → 有资格的拉取返回 1000 行(被截断)→ 判为 head,X@s1 不在其中 → `base.seq == sentSeq` → 判相同 → 基线写 h1、行变干净 → 下一次拉取见到 X@s1,A 不脏,采用 c2 → c1 从此哪里都没有。

今天客户端发的是 500,不会触发,所以这是一个潜伏的常量错配,不是现行风险(Q1.10);一旦被触发,后果是上面这条 data-loss。反方向也一样:max_rows 是 dashboard 设置,有人把它调到 500 以下,今天的 500 一页就会变成假 head(Q2.12)。**关闭**:M1(b)(夹紧 + 每次对账都跑的探针)。

### G4 重叠拉取:旧页在 tombstone 之后应用,导致复活 [divergence → data-loss]
**提出者**:Linear(Linear 公开过同一种顺序 bug,用排队修)。

设计没有规定拉取单飞(single-flight),也没有规定游标只增不减。§4 Triggers 里只有门铃会合并,而门铃、轮询、前台、join 四种触发源彼此独立。(上一稿在这里引用了 `EventStore.swift:512-515`,那段注释说的是 domino 的启动双触发,不是同步拉取,puller 还没写;只能说「引擎若接到同一组启动钩子上,也会双触发」,Q2.6。)

**场景**:游标在 s4。B 改 X → s5,A 发出拉取 P1;B 删 X → s6,A 发出拉取 P2。P2 先回来:tombstone 分支删掉 X、移除基线、游标 := s6。P1 后回来,带着 [X@s5 活行]:本地 absent、基线 absent → 「插入」→ X 复活,基线 (h5, s5),判干净。
- 如果游标写成 max(),X 就永远活在 A 上。A 之后编辑 X → `PATCH seq=eq.s5` → `[]` → 有资格的拉取看不到 X(s6 ≤ 游标)→ 判相同 → 这次编辑消失,连 shelf 里都没有。
- Lean `SyncMerge.lean` 里 `staleOrSeen none = false`(基线缺席时永不跳过),放行的正是这一行。

**测试缺口**:现有 FakeServer 的 `holdWhen` 在**释放时**才读服务端状态,表达不了「请求时的快照、迟到交付」,所以今天写不出这类交错的测试。**关闭**:M3、M6。

### G5 domino 跨设备复利,改了用户的日期 [divergence]
**提出者**:Linear;综合调研报告结论相反,裁决见 §B.4 C1。

**场景**:两台都在前台。10:00,B 把 X 推后 15 min 并上传;A 拉到,行是干净的,采用 X+15m。10:00:30,A 的计时器触发;A 上次推是 9:45,所以 delta = 15.5 min,加在已经被 B 推过的行上 → X+30.5m;B 再采用这个值。

**后果**:两台设备时,未来待办以大约 2 倍墙钟速度漂移,N 台就是 N 倍。后台停了几小时的设备回来时,会把整段间隔再加一遍,与已经拉到的 B 的推移重复计算。每一步都是干净采用,`sync.conflict` 不会响,§9.22 依赖的那个计数器测不到。这违背 Calendar Design Bedrock 第 1 条「不动用户日期」:自动推迟本身是用户认可的语义,但推 N 倍不是。

**顺序问题**(Q1.1):即便按行锚定,切前台时 `DoneApp.swift:913` 也是先同步推一遍,然后才异步拉到别台已经推过的行。两版内容不同(start 和锚点都不同),本地又是脏的,于是每个未来待办进一次 shelf,每切一次前台就是 N 条。

**关闭**:M4。

### G6 门铃静默失效没人发现,计划还要删掉唯一的兜底;join 窗口 [ux]
**提出者**:Replicache(60 s `pullInterval` 常驻)、Linear(EU 宕机复盘:pod 显示健康却不发包,「lacked reliable alerts for missing sync traffic」)、Supabase 社区(Broadcast 至多投递一次、没有重放)、PG 变更流、验证。

**矛盾点**:§5.3 自己写了一种静默失败(`realtime.send` 的错误被吞成 WARNING),§9.11 还有 token 过期;而 §7 却规定「60 s 兜底轮询,一个 build 内 rows>0 为零就删掉」。健康的 build 按构造就会是零。

**join 窗口**:`SupabaseRealtimeDoorbell` 已经暴露了 `onStateChange(.joined)`(`:320-330`),但设计里没说 join 成功后要拉一次。前台拉取的快照和 `phx_reply ok` 之间提交的写,门铃帧发给了一个还没 join 的 socket,只能等 60 s 轮询。

**关闭**:M5。

### G7 永久拒绝没有分类 [divergence]
**提出者**:Replicache、Linear、PowerSync、CouchDB、综合。

**现状**:上传形状只定义了 `[]`、`[row]`、40P01 和抛错四种情况。4xx 和网络错误走同一个分支:单行在 `record(.failure)`(`SupabaseSyncService.swift:1342-1346`),POST 块失败时是 `tally.failed += chunk.count`(`:1416-1419`)。

**后果**(频率订正见 §B.4 C6):该表每次 flush,这一行都会重发;20 行一块的 POST 里只要一行违反约束,另外 19 行也永远上不去;只记 `logger.error`,不进 `DiagnosticTrail`,Fix Watch 看不到。

**已发生的实例**:台架 S13 的 `agent_preferences`。**下一个可能的来源**:后加的 CHECK / NOT NULL;或者某列已经被 drop,旧 build 还在发它(PostgREST 对未知列报错)。**关闭**:S1。

### G8 撤销一个已经 flush 的删除 [divergence / ux]
**提出者**:PowerSync(「deletes always win … The row may be created again with the same ID」,而我们因为 I6 禁止这样做)、Supabase 社区。

**代码**:`mergeEvents` 末尾是 `update(merged); delete(source)`(`EventStore.swift:3694-3695`);`undoMerge` 是 `update(targetEvent); add(sourceEvent)`(`:3701-3706`);`undoSmartSplit`(`:3652`)同理。撤销提示的时长:merge 4 s(`EventGridView.swift:423`),split 6 s(`:406`)。出站防抖 2 s(`SupabaseSyncService.swift:24`)。

**场景**:合并 → 2 s 后 tombstone PATCH 返回 2xx,S 移出基线 → 第 3 s 用户点撤销 → `add(S)`,UUID 不变 → 没有基线 → POST ignore-duplicates → 服务端那一行已存在(而且已 tombstone)→ `[]` → 等回声 → 拉取看不到它(tombstone 的 seq ≤ 游标)→ 之后每次 flush 记一条 `sync.push.orphan`。
- B 永远看不到 S。
- A 下一次游标缺失的全量拉(比如重装)会走 tombstone 分支把 S 删掉。这时 S 没有基线(tombstone 2xx 移除了它,POST 又回 `[]`),按 §6 的 `dirty = h_loc != h_base.hash`,基线缺席即为脏,所以 S 会在级联之前进 shelf;服务端那条 tombstone 行也还保留着 S 的内容(015:38「Content is kept」)。所以这是分叉加撤销失效,不是本文定义的丢数据(第三轮订正,Q2.4;上一稿写成「不脏、不进 shelf」,错了)。

§6「冲突行的基线」情形 (c) 只覆盖了**还没 flush** 的删除被撤销。**关闭**:S2。

### G9 本机 tombstone 遇上在途拉取:刚删的条目闪回 [ux]
**提出者**:Linear。

**场景**:一页拉取在 tombstone PATCH 之前取回、在 2xx(移除基线)之后才应用 → 本地 absent、基线 absent → 插入,刚删的条目又出现了。通常过约 300 ms 加一次 RPC,本机自己的门铃会把 tombstone 拉回来,条目再次消失。如果用户在这个窗口里点开它并编辑:产生一次假冲突、进 shelf,然后条目第二次消失。

第八轮的陈旧页分析只覆盖更新 PATCH(`[row]` 会写 base.seq);删除会移除基线,同一道守卫用不上。M3 的单飞关不掉它:这一页是在本机 tombstone 2xx **之后**才应用的。但有了 M3,本机 tombstone 的门铃会置 rerun,下一条链一定会把 tombstone 拉回来,窗口不到一秒,窗口内的编辑进 shelf,不丢数据。**关闭**:L8(原 S3,第三轮降级;先只记 `sync.apply.resurrect_flash`)。

### G10 PATCH 响应丢失后改回原值 [data-loss]
**提出者**:PowerSync(op 在 `.complete()` 之前一直重试,意图的先后顺序得以保留)。§9.35 接受了这个洞,没有建机制。

**场景**:基线 (h0, s0),用户改成 c1;PATCH 在服务端提交为 c1@s5,但 app 切到后台或断网,响应丢了;`record(.failure)` 不动基线。用户接着改回 c0 → h0 == base.hash → 判干净,不发。下一次拉取拿到 X@s5:h_in = h1 ≠ base,本地干净 → 采用 c1。用户最后的意图 c0 在任何设备和 shelf 上都不存在。

「原样写回」最常见的来源就是撤销按钮(`undoMerge` 里的 `update(targetEvent)`)。同一类问题还出现在 POST 和 tombstone PATCH 上,见 G23。**关闭**:S4。

### G11 本地数据属于另一个账号 [divergence]
**提出者**:CloudKit(Apple 样例 `handleAccountChange`:`.switchAccounts` 和 `.signOut` 删除本地数据,`.signIn` 把本地数据重新上传;复核过)。

**现状**:普通登出只清会话(`AccountView.swift:66` → `AuthService.signOut()` `:878`);D9 规定交互式登录即开同步;新 uid 没有游标也没有基线(`syncHashes.<uid2>.*`),所以账号 1 的每一行看起来都是新建的。

**场景一**:iPad 上退出 Apple 登录的 U1,改用 Google 登录,GoTrue 把它当成另一个用户 U2。全量拉把 U2 的行混进本地;flush 用 ignore-duplicates POST 把 U1 的每一行发出去。U1 下已存在的行撞上全局唯一主键,DO NOTHING,变成 `sync.push.orphan`。orphan 是每次 flush 都重发的永久状态(§6),约 13k 行。U1 从未同步过的行则被插进 U2 的账号。

**场景二**:A 上擦除了账号 → B 收到 401 → 用户重新登录(新 uid)→ B 把已被擦除的数据传进新账号。

**关闭**:S5。

### G12 Restore 里 keepLocal 的基线写错 [divergence]
**提出者**:CloudKit(同类:Core Data「导出前清 history 会丢本地编辑」);设计 §13 第九轮表末行自己也标了「未端到端核实」。

**现状**:`markRestoreCompleted` / `replayBaseline` 写的是 `(hash(本地行), 旧 seq)`,所以 keepLocal 的碰撞行被判干净,永远不 PATCH;服务端和其它设备留着云端版本,本机则一直显示本地版本。这与 §6 上传形状末条「只有 keepLocal 的碰撞行变脏」正好相反。**关闭**:S6。

### G13 混版本写回 [data-loss,未来]
**提出者**:Linear(schemaHash)、CloudKit(只发 changedKeys;schema 只增不改)、综合(jsonb 嵌套键)、CouchDB / Atlas(重命名和改类型都是破坏性变更)。

Phase 1 是第一个「读到什么就整行写回什么」的 build。此后任何改动同步投影的 build,在 TestFlight 逐台更新的混版本窗口里,都会抹掉数据。有三种形状:

- **(a) 未知枚举值被降级**。旧 build 把不认识的枚举原始值解码成默认值:`SupabaseSyncService+Restore.swift:327` `behavior_kind … ?? .event`、`:345` `status ?? .active`、`:363` `display_kind ?? .regular`。h_in 是在 `rowToX` 之后算的,有损解码对 hash 不可见,行被判干净;下一次本地编辑整行 PATCH,把默认值写了回去。例:N+1 新增了 Kind `habit`(gh#115 的方向),iPad 还在 N,改一下标题,`habit` 就变回了 `event`;两台都采用,没有冲突,也没有 shelf。
- **(b) 新列被抹成 null**。iPad 先升到 N+1 并写了新列 k;iPhone 还在 N 时拉到这些行,投影里没有 k,判为「只更新 base.seq」;iPhone 升到 N+1 后,新投影里 k = nil,与旧编码的基线不等 → 每行都脏 → `PATCH seq=eq.<当前>` 命中 → k := null。
- **(c) jsonb 新嵌套键丢失**。jsonb 列里新增的嵌套键(`time_ranges`、`interrupt_relation` 等),被旧 build 解码、再整列写回时丢掉。

§9.3 只覆盖了 settings 键这一种情况。**关闭**:S9(先写规则)、S13(快照绊线测试,让 L3 的触发条件由测试执行)、L3(机制)。

### G14 冲突粒度是整行 [ux]
**提出者**:所有报告。

两台改同一行的不同字段时,一方整行进 shelf;shelf 没有 UI(§7 已知缺口),对用户来说就是「我的改动没了」。例:iPhone 离线时改了事件时间,iPad 改了 effort(它镜像到 `Event.colorDepth`)→ iPhone 上线后整行胜出 → effort 的改动只留在 iPhone 的 shelf 文件里。频率尚未测量。**关闭**:S7(测量)、L1。

### G15 后上传者胜 [ux]
**提出者**:CloudKit 官方样例(按 `userModificationDate` 裁决,源码注释专门写了 last-uploader-wins 会选中过期数据)、综合。

I1 让重新连上的一方做裁决,它本地的脏版本胜出。例:周一 iPad 离线改成「Draft」;周二 iPhone 改成「Final」;周三 iPad 上线 → 所有设备都显示「Draft」,「Final」只在 iPad 的 shelf 里。§7 的 Phase 1 验收把这个结果写成了期望行为。今天量不出它有多常见:`updated_at` 是上传时刻,陈旧的离线编辑上线时会拿到新鲜的时间。**关闭**:L2(前提是先有 `Event.updatedAt`)。

### G16 shelf 副本落在赢家设备上 [ux]
**提出者**:CouchDB(败方叶子复制到所有副本,应用「at minimum, have to present the conflicting versions」)、PowerSync(不建议客户端死信队列,因为开发者没法查看)。

常见的两机冲突是这样走的:B 推 c2(B 干净);A 是脏的 c1,A 把 c2 放进自己的 shelf,然后推 c1;B 采用 c1。用户手里拿着 B,看着 c2 消失,B 的 shelf 却是空的。Phase 2 如果做成「每台设备一个列表」的 UI,在输家设备上什么也看不到。**关闭**:L4。

### G17 没有「本地 == 服务端」的真栈 / 真机断言 [divergence:无法发现]
**提出者**:Replicache / Zero(oracle)、Linear(shadow mode)、PowerSync(每 bucket checksum)、Firestore(existence filter)、验证。

今天的 A == B == server 只在 FakeServer 和 Lean 里成立。模型之外的 applier bug(I2 重播漏了一张表、级联的落盘顺序不同)会留下一条「相对基线干净、但内容陈旧」的行:它不会被再次拉取(seq ≤ 游标),也不写日志,几周后以「iPad 显示的是旧标题」的形式出现。如果对账也复用同一套 rowHash 和投影,一列在编码和解码两边一起丢掉时,对账同样看不见。**关闭**:S8(含独立比较器和 schema 完整性测试)。

### G18 测试层的结构性缺口 [test]
**提出者**:Zero soak、Apple 样例、Jepsen、PouchDB、Dropbox、FoundationDB、验证。

- **只在最后对账**:「分叉到下一次编辑 X 为止」这一类,在随机序列里会被后面的随机编辑治好,最终相等照样绿。这恰好是评审五、六、九找出的大多数 bug 的形状。Zero 的原话是「a final-only comparison is nearly worthless」,不过那是服务端副本 soak 测试里的话,对我们是类比。反过来,每一步都先 stabilize 再查,又会在每一步释放所有扣留,深交错根本走不到(Q3.2)。所以 §E.2 把 oracle 拆成两类。
- **FakeServer 表达不了**:「服务端已应用但响应丢了」(`failWhen` 在任何状态变更之前就抛错);「请求时取快照、迟到交付」的拉取(`holdWhen` 在释放时才读状态);`max_rows` 截断;对不存在的行 PATCH 回 `[]`;服务端倒退;永久 4xx。
- **回显不真实**:FakeServer 原样回显客户端发来的字符串(只把 uuid 转成小写);PostgREST 会按 Postgres 类型重新渲染(timestamptz 的偏移与精度、numeric、jsonb 规范化),MCP 和 edge function 写入的行尤其如此。
- **对齐只靠文字**:FakeServer 和台架之间的一致性只写在文字里;如果假服务器说错了,没有任何东西会变红。评审七已经抓到过一次。
- **没有两个真引擎对真栈的运行,也没有活性断言**:ping-pong 类问题每一刻都相等,但永远不停地发请求。现有的三个实例(`skillAnalyzedEventIds` 的顺序、单行表死行、哈希编码风暴)各自只靠一条定点变异体守着。
- **台架只有正对照**:S1 没有负对照,把锁挪到 `nextval` 之后,「B 在等 advisory 锁」照样成立;I8 依赖的并发 CAS(EvalPlanQual)只有文档依据,没有并发台架。
- **层 1 没有决定论**(第三轮,Q3.6):出站 11 个 sink 的防抖走 `RunLoop.main` 的真实时钟(`SupabaseSyncService.swift:701-842`);同步设置默认用 `UserDefaults.standard`(`SyncedSettings.swift:152`、`:258`),同进程的两台虚拟设备共用一份。
- **没有认证故障**(Q3.3):四层里都没有 401 或 token 刷新;同 uid 刷新也会让 `$session` 发射,§6.4 规定每次发射都要接到引擎上。

**关闭**:M6、M7、§E。

### G19 启动期的本地写入者在追平之前判断页混合态 [minor,潜伏]
**提出者**:Replicache(拉取结果原子揭示)。

首次同步共 27 页,在第 12 页被杀进程。下次启动时,`load()` 里的清理器(`sweepZombieRecurringSeries`、按 title 去重)在页混合的数组上做判断。今天 zombie sweep 的删除分支是停用的,所以风险还是潜伏的;但任何会删除有基线的行的清理器,到 head 之后都会经集合差分变成全账号的 tombstone。修法是启动期的本地写入者等到本 session 到 head 再动。**关闭**:L9(第三轮从 M4 移出,触发条件是任何清理器的删除分支被重新启用)。

### G20 shelf 追加没有真正落盘就返回 [minor]
**提出者**:验证(ALICE 类崩溃一致性问题)。

shelf 是败方版本的唯一副本。§6.1 的顺序是「先追加 shelf,再做级联和写 slot」。进程崩溃不需要 fsync,page cache 还在;断电时要在 Apple 平台上真正落盘,得用 F_FULLFSYNC,普通 fsync 不够。输家版本在服务端的那一份,要等我们推送胜方的 PATCH 落地才会被覆盖,所以真正需要落盘的时刻,是这个 PATCH 发出之前。iOS 上很少见。**关闭**:S10。

### G21 文档和注释漂移 [minor]
- 门铃文件头写的 payload 是 `{table, id, seq, device_id, deleted}`(`SupabaseRealtimeDoorbell.swift:7`、`:18`),`:327-328` 写着「engine filters by deviceId」,两者都和 D1 / D5 矛盾。
- §9.11 说「token 过期前没有主动推」,但 `credentialsDidChange()` 在 join 状态下已经在带内推送新 token 了(`:376-383`)。
- 「Restore 永不推进游标」没有写进设计。
- `realtime.messages` 上如果有人粘贴了一条 `USING (true)` 的示例 policy,宽松 policy 之间按 OR 合并,所有人的 topic 都会被打开;P0.3 验后检查 (4) 只查「我们的 policy 在」,不查「只有它」。

**关闭**:S9。

### G22 基线与游标的崩溃顺序没测过 [divergence,未测]
**提出者**:验证。

基线和游标都存在 UserDefaults 里(§6.3);I3 规定的顺序只是 MainActor 上的调用顺序。如果崩溃后出现「游标是新的、基线是旧的」:A 应用了 B 的 c2@s1,slot 里有 c2,但基线 (h2, s1) 丢了,游标 ≥ s1 却保存下来。重启后 A 把 X 改成 c3 → 基线还是 (h0, s0) → `PATCH seq=eq.s0` → `[]` → 拉取看不到 → `base.seq == sentSeq` → 标干净 → c3 永远不上传。

同一个 domain 的 plist 由 cfprefsd 整体写出,丢失更可能是「丢掉一段后缀」,那样这个状态就造不出来。但这个论证没有来源确认,也测不出来:`kill -9` 只杀 app 进程,造不出这种乱序;可能乱序的是断电、内核 panic、cfprefsd 崩溃。用户记忆里已有一条「cfprefsd 刷盘脱节无可靠上界」。**关闭**:S11(用构造保证,第三轮从 L6 提上来,不再等测量)。

### G23 结果未知的写,以及等回声期间的删除 [divergence,现行代码]
**提出者**:第三轮质疑二;复核 `SupabaseSyncService.swift:1188-1192`、`:1203`。同类见 G10。

- **(a) 删除被静默丢掉**。新建一行,POST 之后它在 `awaitingEcho` 里等回声(服务端已经有这一行);或者 POST 的响应丢了(服务端可能已经有)。这时本地删掉它:
  - `:1188-1192` 把 key 从 awaitingEcho 移除,注释写着「has no baseline entry to tombstone from」;
  - `deletedIds = previous − current`(`:1203`)只看基线,永远不含这个 key。

  结果没有任何东西给它发 tombstone:服务端和 B 上它一直活着,A 也再看不到它(seq ≤ 游标)。今天的 slice-1 代码就是这样。
- **(b) 撤销被丢掉**。tombstone PATCH 已提交、响应丢了:「抛错保留基线」让基线停在 (h0, s0)。用户点撤销,内容原样回来,读成干净;之后拉到的 tombstone 再删一次,撤销丢失(与 G8 同形)。

**关闭**:S4(泛化)。

### G24 另一台设备擦除账号之后的 token 窗口 [divergence / ux]
**提出者**:第三轮质疑三。

A 删除账号:九张表被物理清空,这是 M1(c) 允许的唯一物理删除;门铃一帧也不发(台架 S6)。B 的 access token 在 exp 之前照样有效,最长 3600 s(`config.toml:158`)。在这段时间里:
- B 的拉取回空页,被判为 head(无害);
- B 的 PATCH 回 `[]`,pending-verify 判「相同」并标干净,也就是 G2 的形状;
- B 的新行 POST 撞 user_id 外键,得到 23503,按 S1 会被静默记成 rejected。

设计稿 §9.13 写的「下一次拉取吃 401」,在 token 过期之前不成立。**关闭**:S12。

---

## D. 建议清单

**类别定义**:
- **must-before-local-test**:本地测试战役开始之前,必须先改进设计、代码或测试夹具。否则本地测试测的是错误的规则,或者测不出该测的东西。
- **should**:部署到生产之前要做;可以在本地测试期间并行实现,并由本地测试覆盖。
- **later**:有明确触发条件的 Phase 2 项,或测量驱动的项。
- **reject**:不做,写明理由。

减法原则:凡是新增机制的条目,都写明它防住的、我们这里的具体失败。每个新机制都配一个日志令牌(harness「开启后有对应的 log」是硬要求)。凡是承重的触发条件,都尽量交给一条测试或一项验后检查来执行,不只写在文档里(用户记忆「注释腐烂」)。

### must-before-local-test

**M1 015 定稿前的修改(合并成一次台架重跑)**
- **改什么**:
  - (a) 九张表各加一个语句级 `BEFORE TRUNCATE` 触发器,`raise exception 'use DELETE: rows become tombstones'`。注意:`session_replication_role = replica` 下这个守卫和其它触发器一样不触发(台架 S16 的 replica 变体把这一点记成事实);恢复路径归 M2 管。
  - (b) 015:271 的 `least(page_limit, 2000)` 改为 `least(page_limit, 1000)`;I1 改写为「`page_limit` ≤ min(1000, PostgREST max_rows),全文用 500」;`SyncGatewayLimits.maxPageLimit`、它的注释和 FakeServer 的夹紧一起改。max_rows 是 dashboard 设置,也可能被调到 500 以下,所以检查不能只做一次:P0.3 验后检查和 `sync.audit`(S8)每次都跑同一个探针,即对行数 ≥ 1000 的表 GET `?limit=1000` 并带 `Prefer: count=exact`,返回行数 < min(1000, count) 就判 max_rows 被调低,记 `sync.audit.max_rows_low`。§9 写一句:max_rows 低于 page_limit 会静默地让 G3 回来。
  - (c) 删掉 015:143 和 §5.4 里「先 disable `trg_<t>_tombstone` 再硬删」的说明,换成新规则:
    - 任何设备可能持有的行,永不物理删除;
    - 管理员删除就是一次普通 DELETE,会变成 tombstone;
    - 要抹掉内容,就对已 tombstone 的行 UPDATE 内容列,这次更新会取号并传播;
    - 单行表要重置,用 UPDATE,不用 DELETE;
    - 物理删除只发生在账号擦除(深度 2 的级联)里。

    §6 的 `[]` 收口补一句:「没见到 ⇒ 相同」的前提是每条有基线的行都还在服务端,而且 seq ≥ base.seq;TRUNCATE、硬删、恢复是打破这个前提的三条路,前两条由本条关闭,第三条见 M2。
  - (d) 验后检查加一项,台架和每次部署后各跑一次:对九张表查 `pg_trigger.tgenabled`,三个同步触发器(`trg_<t>_sync_meta`、`trg_<t>_tombstone`、语句级门铃触发器)必须都是 `'O'`。设计稿 §7 里「015 之后的数据修复必须保持触发器启用」这条规则只写一句「见验后检查」,由这项检查执行。
- **为什么**:G2、G3(潜伏)。015 还没上生产,现在改的成本最低,以后再改就得写 016。本地测试的真栈层要对着定稿的 015 跑,改一次就得重跑一次台架,所以和 M2 的 epoch 表一起改、一起重跑。上一稿的 (d)「两参数 advisory 锁命名空间」删掉,见 X9。
- **代价**:SQL 约 15 行;台架新增 S16(TRUNCATE 抛错、行数不变,另加 replica 变体)和 S10b(变更超过 1000 条时 `page_limit=1500` 只回 1000 行:先证明截断真的发生,再证明夹紧有道理);客户端两个常量和一个探针;文档三处。
- **证据**:https://www.postgresql.org/docs/current/sql-truncate.html · https://github.com/PostgREST/postgrest/blob/main/docs/references/configuration.rst(`db-max-rows`:「A hard limit to the number of rows PostgREST will fetch from a view, table, or function」,复核过)· https://supabase.com/docs/guides/database/postgres/row-level-security · https://docs.couchdb.org/en/stable/api/database/misc.html

**M2 检测「服务器倒退」;重置时按恢复点分两段处理**
- **改什么**:
  - **纪元表**(015 里加,不加函数):`public.sync_epoch(epoch uuid not null default gen_random_uuid(), floor bigint not null default 0)`,authenticated 角色只读。`supabase db reset` 或重跑迁移会生成新 epoch,floor = 0。
  - **恢复脚本**:手册写成入库的脚本(例如 `done-mcp/supabase/restore.sh`),不只写成文字。脚本照 Supabase 文档的恢复方式执行:`psql --single-transaction`、`SET session_replication_role = replica`、`--file data.sql`。在**同一个事务**的最后一条语句执行 `update public.sync_epoch set epoch = gen_random_uuid(), floor = (select last_value from public.sync_seq)`。data.sql 里的 `setval` 已经把序列放回导出时的值 N0,所以 floor = N0,而且客户端看不到「数据已经恢复、epoch 还没换」的中间态。不要用 `setval` 抬高 `sync_seq`(§B.4 C3)。
  - **客户端什么时候查 epoch**,每次都是一次普通 GET,存进 `syncHashes.<uid>.epoch`(擦除时的前缀扫描顺带清掉):
    - (a) 每个 session 第一次拉取之前;
    - (b) 门铃每次转到 `.joined` 时;
    - (c) pending-verify 准备把一行判成「相同」之前。这一步就是 G1 场景 1 里丢数据的那一步;恢复时还在线的设备,靠它在写入路径上发现倒退。

    值不等就记 `sync.epoch.changed old=… new=… floor=…`,然后重置。
  - **重置**(`sync.reset reason=epoch floor=F`):
    - 丢掉游标,清空 pending-verify,记下 F;
    - 每条基线**保留旧 hash**,把 seq 标为未知;
    - 走 I1 全量拉。

    在每一行的 seq 重新已知之前,按来件的 seq 分两段处理:
    - **来件 seq ≤ F(恢复回来的内容)**:哨兵语义。本地有行且与来件不同 → 按脏处理,本地胜,来件进 shelf,base := (h_in, seq),推送本地版本;本地与来件相同 → 「相同」;本地 absent 而基线有 id → 本地删除胜。
    - **来件 seq > F(恢复之后某台设备写的)**:用保留的 hash 走普通三方比较,跳过规则停用(seq 未知)。
    - 本地有基线、到 head 都没在服务端见到的行(导出之后新建的),走 POST ignore-duplicates 插回去。

    代价明示:恢复点之后在本机被删除、并且删除已经落地的行(它的基线已移除),会以活行回来。这是复活,不是丢失。
  - `sync_head()` 仍然不加。原来的「触发器 1」(拿写响应 seq 与发送时水位比较)降为 L10。
- **为什么**:G1。上一稿的「一律哨兵」有错(质疑二):一台落后的干净设备 B(导出之前就离线,持有 c0,基线 h0)回来以后,会把 A 在恢复之后推上去的 c1 判成冲突,自己胜出,把 c0 推上去;c1 只剩在 B 那个没有 UI 的 shelf 里。按普通规则,B 本来会采用 c1。哨兵扔掉了唯一能区分这两种情况的事实,也就是 B 相对自己的基线是干净的。floor 把这个事实找了回来:恢复之后写的行,seq 一定大于 F。
  - 只有当恢复绕开了这个脚本时,检测才会失效。这时只读设备永远察觉不到倒退,写入设备在 (c) 也察觉不到。这个残余风险写进 §9,由 L10 的触发条件兜底。
  - 服务端倒退是业内都有重置信号的地方:Electric 的 409 must-refetch(PITR 后)、CouchDB 的 session_id、Atlas 的 client reset 都有原文。Replicache 的「cookie from the future」只是一个检测信号,它文档里的恢复办法是手动清除浏览器数据。
- **代价**:SQL 约 12 行(表、两列默认值、grant、policy);恢复脚本约 15 行;Swift 约 60 行(三处 GET、两段规则、重置函数);基线编解码加一个「seq 未知」标记(降级到旧 build 时它被当作普通 hash 读,判脏,重推一次,与 §9.26 同类);FakeServer 加 `rewind(to: snapshot, floor:)`。
  - 测试三条:恢复后 X 被重新 POST、Y 被拉到、导出点之后的编辑出现在服务端;落后设备场景(上面的 A / B)里 c1 最终胜出,c0 不进任何 shelf;恢复时在线的设备,在 (c) 处发现倒退。
  - 变异体三个,都必须红:「不检查」;「所有行一律哨兵」(落后设备场景);「所有行一律保留 hash」(即 X5 的旧 `<hash>` 重置,导出点之后的编辑被回退)。
  - Lean:把 `serverRestore(floor)` 写成一个操作,证明重置之后 Inv 重新成立;做不到的部分写进 §8「模型未覆盖」。
  - 运行时:每个 session 多一次 GET,每次 join 多一次 GET,每次 pending-verify 判「相同」前多一次 GET(这条路径很少走到)。
- **证据**:https://supabase.com/docs/guides/platform/backups(「free tier plan projects regularly export their data using … db dump」,复核过)· https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore.md · https://electric.ax/docs/sync/guides/shapes · https://docs.couchdb.org/en/stable/replication/protocol.html · https://www.mongodb.com/docs/atlas/app-services/sync/error-handling/client-resets.md · https://doc.replicache.dev/byob/dynamic-pull(检测信号;恢复靠手动)

**M3 拉取单飞,游标只增不减**
- **改什么**:
  - SyncPuller 同一时刻最多只有一条 RPC 链;拉取进行中收到的触发只置一个 `rerun` 标志,当前链结束后再发一条新链(拿新的 pullIssue)。
  - 游标的写入 = max(旧值, 页末 seq)。
  - §6 写明:Restore(`fetchAll`)永不推进游标。
  - 测试:FakeServer 扣住 P1 的响应(按请求时的快照),先交付 P2 的 tombstone → X 必须保持删除。变异体「允许两条链」必须红。
- **为什么**:G4。只有一条链时,每一页都比上一页新(第 n+1 页只包含大于第 n 页末尾的 seq),「基线已移除的 tombstone 被旧页复活」就不可能发生。触发源本来就不止一个(门铃、轮询、前台、join);如果引擎接到和 domino 同一组启动钩子上,这组钩子会在几百毫秒内各触发一次(这组钩子的双触发见 `EventStore.swift:512-515` 注释,那段注释说的是 domino 路径,不是同步)。M3 不关闭 G9:G9 的陈旧页是在本机自己的 tombstone 2xx **之后**才应用的,那一处见 L8。
- **代价**:一个 Bool、一个标志位、一个 max();一条引擎测试加一个变异体。需要 M6 的「请求时快照」钩子。puller 属于 slice 2,还没写,规则要先进设计。
- **证据**:建立在我们自己的交错算术和 Lean `staleOrSeen none = false` 上。https://raw.githubusercontent.com/wzhudev/reverse-linear-sync-engine/main/README.md 只作旁证;Linear 演讲转录未能复核。

**M4 domino 跨设备只推一次,并且只在本 session 到 head 之后推**
- **改什么**:
  - (1) 改写 §9.22 和 §6 的 domino 段:「同一个 horizon 日」这个前提对 `EventStore.swift:502-575` 不成立。上线双向同步之前,**请用户在下面两种方案里选一种**:
    - (i) **按行锚定**:每个待办行带上 `domino_anchor`,即它的 timeRanges 最后一次对齐的时刻。推移量 = now − 该行的锚点,推完把锚点写成 now。锚点跟着行一起同步,所以采用了别台推过的行,下一次只会推剩下的那一小段。构造上不会重复计数。代价:一列,加三条 Codable 路径和一个迁移。
    - (ii) **单写者**:账号里只有一台被指定的设备跑 domino,其它设备只采用、不推;归属写进同步 settings。构造上同样正确,不加列;代价是写者设备长期不开时,别的设备上「未来」组不会漂移。
    - 不推荐 Linear 报告的 (a)「账号级锚点」,它有窗口,见 §B.4 C1b。
  - (2) **两种方案都要遵守的顺序规则**(质疑一):
    - domino 只在本 session 到 head 之后运行,门控用 I1 的同一个 flag;`DoneApp.swift:913` 在 `.active` 时的即时补推,挪到本 session 第一次到 head 之后。
    - 每次 900 s tick 之前,如果有在途的拉取链或者没处理完的门铃,先等它跑完,也就是「先拉到 head 再推」。

    原因:切前台触发的拉取是异步的,而 `:913` 是同步调用。B 在后台期间,A 已经推过一轮(行锚点 t1);B 回前台时手里还是旧行(锚点 t0),会算出 start0+(now−t0)、锚点 now。这个值与 A 的结果推到 now 相同,但行内容不同(start 和 anchor 都不同)。B 的行是脏的,来件也不同,于是每个未来待办都进一次 shelf,每切一次前台就是 N 条。
  - (3) 残余代价明示:方案 (i) 下,两台都在前台、tick 落在门铃延迟(约 1 s)之内时,两台都会在看到对方之前推送,走普通冲突,每个未来待办一条 shelf 行和一条 `sync.conflict`。两版只差计算时刻,哪一版胜出都正确。tick 间隔是 900 s,两台独立计时,一对 tick 撞上的概率约为 2 × 延迟 / 900 s,即百分之零点几。方案 (ii) 没有这项残余。
  - (4) 测试:
    - 两个 store、两个计时器交替触发,模拟一小时后,每个未来待办的总推移恰好是一小时;变异体「现行的 delta 逻辑」得到两小时,必须红。
    - A 推过一轮之后 B 切回前台,B 的 shelf 增量为 0,`sync.conflict` 为 0;变异体「切前台先推后拉」得到 N 条,必须红。
    - 冷启动跨日界,同时有远端改名 → 零 `sync.conflict`。
  - 上一稿的「启动期清理器等到 head」降为 L9:清理器的删除分支今天是停用的,风险是潜伏的(质疑二)。
- **为什么**:G5。Linear 的副作用只在服务端跑一次;我们没有服务端逻辑,每个客户端自动写入者都会在每台设备上各跑一次。基于差值的写入者会复利,而且 `sync.conflict` 永远不响。不先改,两台模拟器的每一次运行都会被漂移和 shelf 噪声污染,别的失败也就读不清了。
- **代价**:(i) 一列,加迁移和三条 Codable 路径,加 `DoneApp.swift:913`、`:944` 两处调用改为「等 head」,加测试;(ii) 一个 settings 键,加 §9.3 的未知键透传(要先建),加一个归属判断和测试。两者都比让用户的待办日期以 N 倍速漂移便宜。
- **证据**:代码 `EventStore.swift:502-575`、`DoneApp.swift:913`、`:943-944`(复核过:`.active` 时同步调用 `dominoPushTodosPastHorizon`,随后才启动 900 s 计时器)· https://doc.replicache.dev/concepts/how-it-works

**M5 保留 60 s 轮询当门铃看门狗;join 成功立刻拉一次**
- **改什么**:
  - §7 删掉「一个 build 内 rows>0 为零就删掉」,轮询在前台常驻(以后可以拉长间隔,但不删)。
  - `sync.doorbell.missed rows=… max_seq=…`:一次 `reason=poll` 的拉取应用了 seq 为 s 的行,只有同时满足下面两条时才算一次漏铃,并进 Fix Watch:
    - s > max(最后一次门铃宣告值, 本机自己写响应里拿到的 seq);
    - 轮询之后 5 s 的宽限期内,没有任何宣告 ≥ s 的帧到达。

    这样排除了 D5 下「本机自己的回声帧还在路上」和 300 ms 合并窗口的正常竞态(质疑二)。harness 在门铃健康的场景里断言它为 0。
  - 门铃 `onStateChange` 每次转到 `.joined`(包括启动、切前台后的第一次 join、token 过期后的重连)都触发一次拉取,并按 M2(b) 查一次 epoch;§4 Triggers 里的「reconnect」指的就是这个。
  - 测试:
    - fake transport 下 100% 丢帧 → 一个轮询周期内收敛,`sync.doorbell.missed` > 0;
    - 门铃健康、本机写入的回声与轮询竞态 → `sync.doorbell.missed` = 0;
    - join ack 之前发出的帧收不到,但由 `.joined` 触发的拉取能追平。
- **为什么**:G6。
- **代价**:净减一条规则;加一个比较、一个宽限计时、一个日志令牌,约 15 行代码。每台前台设备每分钟约一次空 RPC,每次切前台多一次通常为 0 行的拉取。
- **证据**:https://cdn.jsdelivr.net/gh/supabase/realtime@main/README.md(「does not guarantee that every message will be delivered」,复核过)· https://linear.app/docs/eu-sync-outage(「lacked reliable alerts for missing sync traffic」,复核过)· https://doc.replicache.dev/byob/poke(poke 不带数据、60 s `pullInterval`,复核过)· https://supabase.com/docs/guides/troubleshooting/realtime-warn-sending-broadcast-message

**M6 先给 FakeServer、测试 oracle 和可注入接缝补牙**
- **改什么**:
  - (1) FakeServer 新增钩子,每个钩子配一个变异体:
    - `holdResponseWhen`:请求时取快照,释放时交付,用来表达在途拉取的陈旧页;扣留可以跨任意多个测试步存活;
    - `dropResponseWhen`:执行并改状态,然后抛错,用来表达「已应用但响应丢了」,覆盖 PATCH、POST 块和 tombstone PATCH;
    - `maxRows = 1000`:截断 RPC 和 GET;
    - 对不存在的行 PATCH 回 `[]`;
    - `rewind(to: snapshot, floor:)`:服务端倒退;
    - `physicallyDelete`:硬删 / TRUNCATE 的形状;
    - 对指定行返回 4xx(带 PostgREST 形状的 `code`):永久拒绝;
    - 对第 k 个请求返回 401。
  - (2) `stabilize()` 测试助手:放开所有扣留,循环「每台设备 flush + 拉到 head」,直到某一轮零请求;超过 R 轮即失败。之后再跑一轮,断言 0 个 PATCH / POST / tombstone 请求、0 次 slot 写。它只在**收敛检查点**调用,不在每一步调用(§E.2)。
  - (3) 安全性 oracle 与收敛 oracle,见 §E.2。
  - (4) **可注入的时钟和设置存储**(质疑三)。今天层 1 的「一个种子决定一切」做不到:
    - 出站的 11 个 sink 用 `.debounce(for: .seconds(2 或 5), scheduler: RunLoop.main)`(`SupabaseSyncService.swift:701-842`),走真实时钟;
    - 同步设置的读写默认用 `UserDefaults = .standard`(`SyncedSettings.swift:152`、`:258`),所以两台同进程的虚拟设备共用一份设置,「settings 按键相等」按构造恒真。

    所以要做到:全部防抖、轮询、300 ms 门铃合并和撤销提示计时器改走可注入的 scheduler 或 clock;同步路径上的每个 UserDefaults 都可注入,用一份 grep 清单核对(清单入库,随测试检查),不靠记忆。没做完之前,settings 收敛只在层 2 / 层 3 断言,层 1 不对这一项下结论。正对照:同一个种子跑两次,请求日志逐字节相同。
  - (5) **与层 3 共用的接缝名**。重启点用同一组名字:`after_slot`、`after_baseline_before_cursor`、`patch_committed_before_baseline`、`after_page:k`。层 1 在这些点模拟重启,层 3 在这些点 `kill(getpid(), SIGKILL)`(§E.4),两层测的是同一个位置。
- **为什么**:G18。不补这些,G2、G3、G4、G10、G23 在测试里写不出来,本地测试的「绿」就没有区分力;不做 (4),层 1 连决定论都没有。
- **代价**:FakeServer 约 100–140 行;stabilize 约 40 行;(4) 是生产代码里的注入改动,11 个 sink 加 4 类计时器,再加同步路径上的 UserDefaults 清单,约一天;合计 1.5–2 天。
- **证据**:https://github.com/rocicorp/mono/blob/main/apps/zbugs/scripts/rmv2-soak/chaos.ts · https://www.cis.upenn.edu/~bcpierce/papers/mysteriesofdropbox.pdf · https://raw.githubusercontent.com/jepsen-io/jepsen/main/doc/tutorial/03-client.md · https://www.foundationdb.org/files/fdb-paper.pdf(决定论模拟)

**M7 本地测试必须有真栈一层**
- **改什么**:用环境变量门控(`SYNC_LIVE_STACK=1`),不进默认 CI。
  - (1) **LiveGateway 对拍(must;零差异才可上生产)**:同一份请求脚本(复用 `SyncOutboundTests` 的场景)分别打给 FakeServer 和本地 `supabase start`。PostgREST 会重新渲染 timestamptz、numeric、jsonb,而 FakeServer 原样回显客户端的字符串,逐字节比较永远不会相等,所以比较项定义为:
    - 状态码类别;
    - `[]` 还是 `[row]`;
    - `deleted_at` 和 seq 是否存在;
    - seq 的相对顺序(不比字面值,ON CONFLICT 会烧掉两个号,§9.16);
    - 经 `rowToX → xToRowForHashing` 解码之后的 rowHash。这一项就是 §6 依赖的 hash 往返。

    原始字节的差异只记录下来作为信息,不作门槛。
  - (2) **四条脚本化核心场景**:不跑随机种子,每条一个确定的脚本:
    - 服务端提交后丢掉响应(URLProtocol);
    - 40P01(照台架 S15 的加锁顺序配方);
    - 永久 4xx(临时加一个 CHECK);
    - `docker pause` realtime 容器(门铃断,REST 通)。

    随机种子只在层 1 跑。§E.3 另列五条脚本化场景,服务于 S1 / S12 / M5 等条目。
- **为什么**:G18 要解决的问题是「FakeServer 编码的是我们的理解」,(1) 正面解决它。上一稿的「两个真引擎回放随机种子」与层 1、层 3 大面积重叠,还要每个测试建删 GoTrue 用户、管 JWT,会变成一个长期维护的 target(质疑一),所以缩成脚本。Apple 的样例在真开发容器上用两个引擎跑场景(复核过);PouchDB 对真 CouchDB 跑套件,并说替身服务器「no longer reliable」(复核过)。
- **代价**:(1) 半天;(2) 半天到一天;共用一个测试 target 和一个本地 JWT 助手。
- **证据**:https://github.com/apple/sample-cloudkit-sync-engine/blob/main/Tests/SyncTests.swift · https://github.com/apache/pouchdb/blob/master/TESTING.md · https://github.com/nurturenature/jepsen-powersync

### should

**S1 永久拒绝分类**
- **改什么**:上传响应分五类处理:
  - **401** → 交给 AuthService(同 uid 的刷新不算会话变化,§E.2 有专门的故障)。
  - **重试类**:网络错误、5xx、408、429、40P01、57014 / 55P03(语句超时、锁超时;PostgREST 映射成什么 HTTP 状态未核实,由 §E.3 的锁超时场景实测并抄成 fixture),按现行规则重试。
  - **表结构缓存类**:`PGRST2xx` 的表结构缓存码(如 PGRST204、PGRST202),迁移之后 NOTIFY 重载之前会出现。按退避重试;持续超过一个窗口(例如 3 轮退避、跨度 ≥ 10 min)仍出现,才按拒绝处理并带上原 code。旧 build 发送已被 drop 的列,最终会落到这里。
  - **块大小类**:413 / 414,通常是长 `id=in.(…)` tombstone URL 或大 POST 块。把块对半拆开重发,不判拒绝。
  - **拒绝类**:22xxx / 23xxx / 42501。user_id 外键上的 23503 例外,归 S12。即便是这类,也要先逐行重发一次才判定:
    - (a) POST 块失败时,把这一块逐行重发一次,只让真正违规的行留脏;
    - (b) `(table, id, sentHash)` 记进内存里的 `rejected` 表,在本地 hash 变化或下次启动之前不再发送;
    - (c) 每个 `(table, id, sentHash)` 记一次 `DiagnosticTrail` 行 `sync.push.rejected table=… id=… code=…`,进 Fix Watch 计数;
    - (d) 本地值和基线都不动,绝不丢弃。这一点不同于 PowerSync demo connector 丢弃余下事务,也不同于 Firestore 回滚。

  tombstone PATCH 分支用同一套规则。
- **为什么**:G7。
- **代价**:约 60–80 行。
  - FakeGateway 测试:20 行的块里有一行违反 CHECK → 19 行上去、1 行留脏、一条日志,之后零重发,直到这行被改(变异体「没有 rejected 表」→ 每次 flush 一次请求,必须红);PGRST204 先出现两次再消失 → 不进 rejected;414 → 拆块后全部上去。
  - 台架加一项:确认 PostgREST 的错误体带 `code`。
- **证据**:https://doc.replicache.dev/reference/server-push · https://docs.couchdb.org/en/stable/replication/protocol.html · https://github.com/powersync-ja/powersync-swift/blob/main/Demos/PowerSyncExample/PowerSyncExample/PowerSync/SupabaseConnector.swift

**S2 撤销窗口内不发 tombstone**
- **改什么**:merge 或 smart split 删掉的行,在撤销提示还在的时候(4 s / 6 s),不进入出站的 tombstone 差分:id 留在基线里、不进 `deletedIds`,等撤销计时器触发后再发。在窗口内点撤销就是一次空操作,行带着原来的基线回来;进程在窗口内死掉也无妨,这个集合只在内存里,重启后 tombstone 照常发出。§6「冲突行的基线」加情形 (d);§8 的种子 / 撤销测试加一条。备选方案:为撤销路径提前做 #140 的显式 undelete RPC。它机制更多,但能覆盖以后所有的撤销 UI;按减法原则先选前者。
- **为什么**:G8(已改标为 divergence / ux)。
- **代价**:一个 `undoPendingDeletes` 集合,从 `EventGridView` 传到出站 sink,约 30 行;撤销计时器走 M6(4) 的可注入时钟;一条引擎测试:合并、flush、第 3 s 撤销 → S 在服务端和 B 上都活着,没有 orphan 日志。
- **证据**:https://docs.powersync.com/handling-writes/handling-update-conflicts

**S4 结果未知的写一律写「?」标记(泛化)**
- **改什么**:下面三种情形,都给这一行写一个基线条目 `?`(与 M2 共用的「hash 未知」标记),seq 不知道就标为未知:
  - 写的结果未知:PATCH、POST 块或 tombstone PATCH 抛出「请求可能已到达服务端」的错误,也就是 URLError 超时或连接中断。已经收到 HTTP 状态码的 4xx / 5xx 不算;
  - 一个 key 在 `awaitingEcho` 里;
  - tombstone 的结果未知、而这一行又经撤销回来了(内容原样),也标 `?`,让它读成脏的。

  然后:
  - **改动**:`?` 永远不等于本地 hash,所以这一行无论用户接下来做什么都是脏的。seq 已知就重发 `PATCH seq=eq.s0`:丢失的 PATCH 若其实已提交 → `[]` → pending-verify → 拉到 X@s5 → 三方比较:c1 作为本机自己的旧版本进 shelf,改回的 c0 以 `seq=eq.s5` 推上去;若没提交 → 直接落地,或者短路成 `[]`,由现有的 `base.seq == sentSeq ⇒ hash := sentHash` 规则清掉标记。seq 未知就走 POST ignore-duplicates 加 awaitingEcho,回声到达时按三方比较落定。
  - **删除**:本地删除一行,而它的条目是 `?`,或者没有 seq(包括 awaitingEcho 里的 key),照样发 `PATCH id=in.(…)&deleted_at=is.null`;服务端没有这一行时回 `[]`,无害。这条替换掉 `SupabaseSyncService.swift:1188-1192` 现在「直接丢掉 key」的行为。

  这条取代 §9.35 的「不建机制」。
- **为什么**:G10、G23。我们的「脏」是 hash ≠ 基线推出来的,不是 CKSyncEngine 那种持久的待发送集合(§B.3)。差别只在「发出去了、结果未知」这一处显形;`?` 就是只覆盖在途写的待发送集合,不用建 outbox。
- **代价**:约 25 行,加基线编解码(与 M2 共用)。测试用 M6 的 dropResponse,每种形状一条:
  - PATCH 已提交、响应被丢、用户改回 → c0 出现在服务端和两台设备上;
  - POST 已提交、响应被丢、本地删除 → 服务端 tombstone,B 删除;
  - 新行在 awaitingEcho 期间被删 → 同上;
  - tombstone 已提交、响应被丢、撤销 → 读成脏,服务端行为符合 S2 / #140 的规则,并写明结果。

  变异体「基线不动」「awaitingEcho 删除被丢掉」必须红。Lean 补 `writeLost` 规则并重新生成 fixtures。每次丢响应,可能多一条本机自己版本的 shelf 行。
- **证据**:代码 `SupabaseSyncService.swift:1188-1192`、`:1203`(复核过)· https://docs.powersync.com/configuration/app-backend/client-side-integration · https://raw.githubusercontent.com/jepsen-io/jepsen/main/doc/tutorial/03-client.md

**S5 同步所有者守卫**
- **改什么**:第一次到 head 时写 UserDefaults `syncHashes.ownerUid`(放在 `syncHashes.` 前缀下,擦除时的前缀扫描顺带清掉,不需要新的 purge)。session uid 与它不等时,引擎不拉也不推,记 `sync.blocked.owner_mismatch owner=… session=…`,账户卡片显示一行状态。擦除,或者一个显式的「把本机数据用于新账号」动作,会清掉它。可选:本 session 已经记过 orphan 的 id 不再重复 POST。
- **为什么**:G11。Apple 样例的 `handleAccountChange` 在 `.switchAccounts` 和 `.signOut` 时删除本地数据,在 `.signIn` 时把本地数据重新上传(复核过)。我们的普通登出保留数据,恰好是 CloudKit 会删的那一种,所以用「停止同步并提示」代替删除,方向与样例一致,不删任何东西。
- **代价**:一个键、一次比较、两条测试(换账号:零请求;擦除后再登录:被拦下)。
- **证据**:https://developer.apple.com/documentation/cloudkit/cksyncengine/event/accountchange · https://github.com/apple/sample-cloudkit-sync-engine(`SyncedDatabase.swift` 的 `handleAccountChange`)

**S6 Restore 的基线重播指名服务端**
- **改什么**:`markRestoreCompleted` / `replayBaseline` 对云端认识的行,写 `hash(云端行)@云端 seq`。这和第九轮「基线指名服务端」是同一个原则。这样 keepLocal 的碰撞行会判脏,被 PATCH 上去。测试:keepLocal 了 X → 下一次 flush 以 `seq=eq.<云端 seq>` PATCH X;变异体「hash(本地)」必须红。
- **为什么**:G12。在 Phase 1 接 restore 时做。
- **代价**:规则改一行,一条测试,一个变异体。
- **证据**:https://developer.apple.com/forums/thread/764080

**S7 冲突日志记下不同的列名**
- **改什么**:每条 `sync.conflict` 加 `cols=<不同的列名>`:本地投影与来件投影做一次字典 diff,不需要基线内容,确实零存储。L1 的触发条件只看这个计数。
  - 上一稿还有 `local_dirty_since_ms` 和 `remote_age_ms` 两个字段,删掉。前者要记下每一行第一次变脏的时刻,而整表 hash 差分是无状态的,没有这个信息,得新建一张表,要撑过重启还得落盘。后者依赖 `updated_at`,而 §1.1 实测 events / event_types 的 `updated_at` 是上传时刻:一份陈旧的离线编辑上线时会拿到新鲜的时间,恰好在 L2 关心的情形里失真(质疑一)。
- **为什么**:G14。
- **代价**:冲突路径上多一次字典 diff。
- **证据**:设计稿 §1.1(`updated_at` 是上传时刻,复核过)· https://docs.powersync.com/handling-writes/handling-update-conflicts

**S8 对账:`sync.audit` 加独立比较器(真机与真栈的 oracle)**
- **改什么**:
  - (1) harness 动作 `sync.audit`:在 head、没有脏行、pending-verify 为空时,从 0 开始分页拉 `sync_changes`,对每个活的 `(table, id)` 算 rowHash 并与本地比较,记 `sync.audit table=… rows=… mismatches=N first=<table>:<id>`。同一次动作跑 M1(b) 的 max_rows 探针。服务端一侧再用 psql(本地栈)或 MCP `execute_sql`(生产)按表算 count(*) 与 sum(seq),交叉核对。
  - (2) **独立比较器**(质疑三):`sync.audit` 和 applier 共用 rowHash 与同一套投影 / 解码代码,所以一列在编码和解码两边一起丢掉时是看不见的:两边一起丢,hash 照样相等。往返测试只证明投影稳定,不证明投影完整。为此加一个不复用 Swift rowHash 的 Python 脚本(放在 `done-mcp/supabase/tests/`):读设备 slot 的 JSON(模拟器从容器取;真机用 devicectl 拉取)和 psql 导出的服务端活行,按一张入库的显式列映射表逐字段比较。
  - (3) **schema 完整性测试**:`information_schema.columns` 里九张表的列,减去客户端投影的列,结果必须等于一份入库的排除清单;服务端加列时这条测试变红。
  - 上一稿的「影子模式」删掉,见 X10。部署门槛改为 §E.6:打开 apply 之后立刻在两台设备上跑 (1) 和 (2),结果为 0。
  - 不新增 RPC;`sync_digest()` / `sync_counts()` 留作 L7。
- **为什么**:G17。§F 的部署门槛依赖它。
- **代价**:(1) 约 40–60 行 Swift,复用 puller 的解码;(2) 约 100–150 行 Python 加一张列映射表;(3) 一条测试加一份排除清单。主账号每次约 27 次 RPC,只在按需时跑。
- **证据**:https://github.com/rocicorp/mono/blob/main/apps/zbugs/scripts/rmv2-soak/oracle.ts · https://docs.powersync.com/architecture/powersync-protocol · https://github.com/firebase/firebase-ios-sdk/blob/main/Firestore/core/src/remote/remote_event.cc

**S9 文档与运行手册**
- **改什么**:
  - (a) §7 的 015 交接单加部署规则:
    - 先扩后缩:expand 迁移先于客户端;contract 迁移晚于客户端,而且要等每台设备都跑上不再发送该列的 build;
    - 触发器必须启用:见验后检查 M1(d);
    - 新的同步表要在同一个迁移里加进 `sync_changes` 的 union 和触发器循环;
    - 恢复只走 M2 的恢复脚本;绕开脚本属于 §9 的残余风险。
  - (b) §9.3 从「settings 键」扩成「混版本写回」规则:任何改动同步投影的 build(新列、新枚举原始值、jsonb 新嵌套键、列重命名或改类型)发布之前,必须先有 L3 的机制;重命名和改类型一律走 expand / contract。触发由 S13 的测试执行。
  - (c) P0.3 验后检查 (4) 和台架 S12:`pg_policies` 里 `realtime.messages` 的 policy 恰好一行(`own sync topic`,SELECT)。
  - (d) 订正门铃文件头和 `:327-328` 关于 `device_id` 的注释;§9.11 写明 `credentialsDidChange()` 已经在 join 状态下带内推送新 token。
  - (e) §6 写明 Restore 永不推进游标(配合 M3)。
  - (f) §7 Phase 2 记一句:shelf 的 UI 必须是账号级的(L4);Phase 1 的 shelf 行格式 `{uid, table, id, seq, reason, row}` 保持可以原样上传。
  - (g) §9 记残余风险:绕开恢复脚本的手工恢复(M2);max_rows 低于 page_limit(M1b)。
- **为什么**:G13、G16、G21,以及 Replicache「版本机制之外的改动永远到不了客户端」这个坑。
- **代价**:文档若干段。
- **证据**:https://zero.rocicorp.dev/docs/schema · https://docs.powersync.com/maintenance-ops/implementing-schema-changes · https://github.com/mongodb/docs-app-services/blob/master/source/sync/data-model/update-schema.txt · https://supabase.com/docs/guides/realtime/subscribing-to-database-changes · https://docs.couchdb.org/en/stable/replication/conflicts.html

**S10 shelf 在推送胜方之前落盘(F_FULLFSYNC)**
- **改什么**:在一个 apply 批次里,只要追加过 shelf 行,就在发出推送本地胜方的 PATCH 之前,对 shelf 文件调用一次 `fcntl(fd, F_FULLFSYNC)`。目标写明是断电;写进 §6.3。
- **为什么**:G20。进程崩溃不需要 fsync,page cache 还在。Apple 平台上普通的 `fsync` / `FileHandle.synchronize()` 不保证断电后数据还在,要用 F_FULLFSYNC(质疑二)。真正需要落盘的时刻也很具体:输家版本在服务端的那一份,直到我们的 PATCH 落地才被覆盖,所以只需要在这个 PATCH 发出之前落盘。M2 重置会一次写出成千条 shelf 行,所以按批落盘,不按行。
- **代价**:约 5 行;每个有冲突的批次一次 F_FULLFSYNC(几到几十毫秒)。
- **证据**:https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai · Apple `fsync(2)` man page(F_FULLFSYNC)

**S11 游标代次校验(原 L6,提为 should,用构造保证)**
- **改什么**:基线按表存成 UserDefaults 的一个键(`syncHashes.<uid>.<table>`,`SyncBaseline.swift:6-17`)。单个键的值是整体写出的,不同键之间的落盘顺序才没有保证。所以把代次放进每张表基线的同一个值里:每次推进游标的那一批,把本批触碰的每张表基线的代次写成 g+1,再写游标键 `{cursor, gen: {table: g+1, …}}`,记下它期望的每张表的代次。加载时,只要有一张表的基线代次与游标期望的不一致,就丢掉游标、全量重拉;三方比较保证重拉是安全的。这一条不依赖键与键之间的落盘顺序,所以不需要先去测 cfprefsd 怎么排序。备选:把游标和触碰的基线放进同一次原子文件写(仓库已有 AtomicValueFile 的先例)。
- **为什么**:G22。上一稿说「先测量 UserDefaults 崩溃顺序,出现过才做」。可是 `kill -9` 只杀 app 进程,cfprefsd 还活着,已经交出去的写不会丢,造不出「游标新、基线旧」;真正可能乱序的是断电、内核 panic、cfprefsd 自己崩溃,200 次 kill 一次都碰不到。用户记忆里本来就有「cfprefsd 刷盘脱节无可靠上界」。测出 0 对要不要做 L6 没有区分力,而后果是静默丢数据(c3 永不上传),修法本身约 30 行,比测量还便宜(质疑一、三)。
- **代价**:约 30 行。层 1 的 UserDefaults 回滚模型加「逐键回滚」(游标新、基线旧),变异体「不校验代次」必须红。
- **证据**:G22 的推演;用户记忆 reference_userdefaults_device_measurement

**S12 另一台设备擦除账号后的处置**
- **改什么**:
  - user_id 外键上的 23503(按约束名判断)不进 S1 的 rejected,当作「账号可能已不存在」:停止本表上传,调用 `forceRefreshToken()`。刷新终态失败,走现有的 gh#234 终态路径;刷新成功,说明是别的原因,按 S1 的拒绝处理。
  - §6.4 写清 B 本地数据的处置规则。推荐做法:本地数据保留,同步停止,由 S5 的所有者守卫拦住「推进新账号」。**这一条需要用户拍板。**
  - 明示接受:擦除到 B 的 token 过期之间(最长 3600 s,`config.toml:158`),B 的 PATCH 回 `[]` 会被 pending-verify 判「相同」。这些编辑本来就属于用户要求抹掉的账号,不再单独建机制。设计稿 §9.13「下一次拉取吃 401」改成「token 过期后的下一次请求吃 401」。
- **为什么**:G24。
- **代价**:约 20 行;§E.3 一条脚本化场景;§6.4 一段规则。
- **证据**:https://supabase.com/docs/guides/auth/sessions(access token 在 exp 之前一直有效)

**S13 混版本写回的绊线测试(L3 的触发条件交给测试执行)**
- **改什么**:随 Phase 1 加一条快照测试,钉住每张表 `xToRow` 投影的键集合,以及同步路径上每个枚举的 rawValue 集合。快照一变,测试就红,失败信息写「先做 L3,见 02-industry-survey L3」;更新快照必须在同一个提交里带上 L3 的机制或用户的明示豁免。
- **为什么**:G13。投影改得很频繁:`SupabaseSyncService.swift` 自 2026-06 起有 12 次提交,其中至少两次改动了线上字段(b3b43f0 #50 的字段漂移、05a3565 #127 的 keys ride the wire),Event 有 212 个字段。L3 的触发条件很可能在 Phase 1 上线后一两个月内成立,到那时没人会记得去看 §L3(质疑一)。
- **代价**:一条测试和一份快照文件。
- **证据**:`git log -- Done/Services/SupabaseSyncService.swift`(复核过)

### later(都有明确的触发条件)

- **L1 按列组的三方合并**。**触发条件**:M4 修好 domino 之后,S7 的 `cols=` 显示「不相交字段的冲突」是 shelf 的显著来源。**形状**:一张静态的列组表,例如 {start, end, is_all_day, time_ranges}、{repeat_*}、{recurrence_exception_*}、{is_done, complete_at, status, state}、{suggested_log_template_*},其余列各自成组;合并基底取自「脏行第一次被看到时的干净投影」快照,存在 `Sync/` 目录的新文件里;缺快照时退回整行规则。不要把每列的 hash 存进 UserDefaults:47 列 × 4.7k 行会让基线 plist 涨大约 40 倍。**代价**:约 250–350 行,Lean 的 `decideRow` 加一层,fixtures 重新生成。
- **L2 冲突分支内按编辑时刻裁决**。**前提**:没有编辑时刻,就测不出这一条的触发条件(`updated_at` 是上传时刻,S7)。所以先做 D4 已经计价的 `Event.updatedAt`(三条 Codable 路径),之后在 `sync.conflict` 上加 `local_edit_age` / `remote_edit_age`。**触发条件**:有了编辑时刻以后,「远端比本地新 1 h 以上」的冲突占比显著;或者用户报告「旧版本盖掉了新版本」。**形状**:只在冲突分支里按列组用编辑时刻 tie-break,另一方进 shelf;时钟偏差的代价只是多一条 shelf 行,不会丢数据。
- **L3 混版本写回守卫**。**触发条件**:S13 的快照测试变红,也就是 Phase 1 之后第一个改动同步投影的 build。两种机制二选一:
  - (a) 有损解码守卫:来件的原始 `data`(只看投影认识的键)与 `xToRow(rowToX(data))` 不同的列,记 `sync.apply.lossy_decode`,并把这些列从该行的 PATCH 体里排除,排除集随基线存成 `<hash>@<seq>!cols`;
  - (b) 投影版本:每张表的投影带一个版本号;新版本第一次启动时,用上一版投影重新判脏,并重置游标、重拉这张表,干净行采用带新列的服务端行。
- **L4 账号级 shelf**。Phase 2 做 UI 时实现;现在只写一句话(S9f)。
- **L5 协议版本门 `min_client_build`**。**触发条件**:第一次 contract 迁移(drop 或 rename)。
- **L6**:已提为 S11。
- **L7 `sync_digest()` / `sync_counts()` RPC**。**触发条件**:S8 的对账发现过一次不一致,需要在生产上常驻检测。
- **L8 本机 tombstone 遇上在途拉取的守卫(原 S3)**。**为什么降级**:按 G9 自己的推演,陈旧页把行插回来时,本机 tombstone 的门铃会在单飞链上置 rerun(有 M3 之后),下一条链从低于 tombstone seq 的游标开始,一定会拉到 tombstone 并把行删掉,窗口不到一秒。用户在窗口内编辑,编辑进 shelf,不丢数据。这只是 ux 级的闪回,而原方案要一张内存表、一条依赖 M6 的交错测试和一条 Lean 引理(质疑一)。**现在只做**:一个只存本 session 已收到 tombstone 2xx 的 id 的内存集合(不参与 apply 判定,所以不是质疑者说的「零状态」,但比原守卫小得多);applier 插入一个在这个集合里的 id 时,记 `sync.apply.resurrect_flash table=… id=…`。**触发条件**:这个令牌在真机或模拟器上出现过,而且用户报告看到了闪回。**形状**:原 S3 的 `recentOwnTombstones` 守卫。
- **L9 启动期清理器等到 head 再删(原 M4 第二部分)**。**触发条件**:任何启动期清理器(`sweepZombieRecurringSeries` 等)的删除分支被重新启用,或者新增一个会删除有基线的行的启动期写入者。**形状**:本 session 到 head 之前只记录候选,不删除有基线的行。
- **L10 写响应倒退检查(原 M2 触发器 1)**。**为什么降级**:免费层没有平台备份,恢复只可能是有意导入一份自制的 dump。这件事从未发生过,有了 M2 的恢复脚本之后,唯一的消费者是「绕开脚本手工恢复的运维者」。它却要挂在每一条写路径上,还要单独的测试和变异体(质疑一)。**触发条件**:第一次真的从 dump 恢复;或者出现了任何不经 M2 脚本的恢复流程。**形状**:每次发送写请求时记下本机此刻观测到的最高 seq(游标与此前所有写响应 seq 的最大值);2xx 响应里只要有一个新分配的 seq ≤ 这个值,就记 `sync.cursor.rewind` 并重置,用揭示倒退的那个 seq 作为 floor。它是上界,所以只会让「空档里的写」偏向本地胜(质疑二)。比较对象的选择见 §B.4 C5。

### reject

- **X1 `[]` 之后显式 GET 读一次当前 seq,取代 pullIssue 资格判断**:见 §B.4 C9。M2(c) 在同一个位置加的是读 epoch,不是读 seq,不改 pending-verify 的推理。
- **X2 语句级 BEFORE 触发器预取用户锁,消除 40P01**:40P01 的单次重试分支已经实现并有测试(`testDeadlockVictimIsResentOnceWithTheSameSeq`),牺牲者总是单行那一侧(台架 S15);预取锁加了一个机制,却删不掉任何一个。上一稿写的理由「PostgREST 从不发两语句事务」是错的:§9.17 和 015 文件头描述的死锁就是多行 tombstone `PATCH id=in.(X,Y)` 这一条语句对单行 PATCH,PostgREST 正好会发这两种形状;台架里的两语句批量只是一种模拟手段(质疑二)。
- **X3 现在就做字段合并**:见 §B.4 C2。改为 S7 测量 + L1。
- **X4 恢复后用 `setval` 抬高 `sync_seq`**:见 §B.4 C3。
- **X5 用旧 `<hash>` 形状对所有行做倒退重置**:见 §B.4 C4。M2 只对 seq > floor 的来件保留 hash。
- **X6 拿门铃 payload 的 seq 或「响应到达时的游标」当倒退信号**:见 §B.4 C5。
- **X7 给 shelf 设上限或修剪**:shelf 是败方版本唯一的副本,设上限就等于按设计丢数据。M4 落地之后重新估算 shelf 的来源:
  - 真实冲突:未测量,估计每年百行量级;
  - M4(i) 的同时 tick 残余:每次撞上 N 条,概率见 M4(3);
  - §6.3 升级时的一次性 shelf 行;
  - S4 的本机自己版本:每次丢响应 0–1 条;
  - M2 重置:每次恢复一次性成千条。

  按每行 1–2 KB 算,最坏情况是一次恢复之后多出 10–20 MB,随设备备份,没有可省的成本。增长由 `sync.conflict` 的计数看着。
- **X8 B.3 列出的业内机制**(操作日志、带数据推送、CVR、xid8、复制槽、压缩、原子 checkpoint、引导模式、按 sender 过滤回声):理由见 §B.3。
- **X9 两参数 advisory 锁命名空间**(上一稿 M1(d)):调研自己标了「是否有组件在用小整数单键 advisory 锁,未证实」。这是一个没有证据的碰撞,留在 015 定稿清单里,只会给台架重跑多加一个变量(质疑一)。
- **X10 生产「影子模式」**(上一稿 S8(2)):它只让两台设备用一次,打开 apply 之后就没有消费者了。它要验证的东西已经有别的环节覆盖:feed 分页由 LiveGateway 对拍和层 1 的 oracle 负责,与本地 store 一致由层 3 的对账负责。打开 apply 之后,「立刻对账 + 已演练的回滚」就是同一道门(质疑一)。按原来的写法它也不成立:如果上传照常走条件 PATCH 而 puller 不应用,基线 seq 永远不前进,每次 flush 都会重发,形成请求风暴;如果总闸关着,iPad 从来不是同步源,它的本地 vs 服务端不可能是 0(质疑二、三)。
- **X11 UserDefaults 崩溃顺序测量**(上一稿 §E.5 / F8):见 S11。
- **X12 把 3/N 写成失败率「上界」**:它是种子生成器分布上的失败率上界,不是生产失败率,写成「上界」会被读成置信度。§F 只记 N 和 commit;真正有区分力的,是「只靠随机套件抓红变异体」和触达计数的下限(质疑一、三)。

---

## E. 本地测试计划

**前置**:slice 2(puller / applier)落地之前,能跑的只有 E.2 的出站部分,以及 E.3 的台架与对拍;端到端随机套件要等 applier。先完成 M1–M6(包括 M6(4) 的可注入时钟和 UserDefaults),再写 E.2 的随机套件,否则测试编码的是旧规则,而且连决定论都没有。

### E.1 层 0:Lean 模型与 fixtures
- 在 `verification/` 下 `lake build`;`sync-fixtures.json` 只由 `decideRow` 生成,Swift 逐用例回放(§8 已有)。
- M2(floor 两段规则、重置)、S4(`writeLost`,含 awaitingEcho 删除)、S11(代次)引入的新规则,先进模型、证明保持 `Inv`(或者明写为模型外事件),再重新生成 fixtures。

### E.2 层 1:XCTest + FakeServer(独立 test plan `DoneSyncFuzz`,不进默认全量)
- **被测对象**:
  - 两台虚拟设备(随机套件偶尔用三台),每台是 `EventStore` + 同步引擎,各有隔离的存储目录(TestHost 重定向)、独立注入的 `UserDefaults(suiteName:)`,以及注入的 clock / scheduler(M6(4));共用一个 M6 之后的 FakeServer;故障按设备注入。
  - **擦除只在单设备套件里出现**:`LocalDataEraseEpoch` 是进程级全局变量(`LocalDataEraseEpoch.swift:95-97`),两台设备在同一个进程里时,A 的擦除会让 B 的写也被判为过期。这是一种虚假耦合,会掩盖跨设备擦除的真实行为。跨设备擦除放到 §E.3。
- **决定论**:
  - 全部由一个 SplitMix64 种子决定;失败时打印种子和 commit;测试 scheme 设 `SWIFT_DETERMINISTIC_HASHING=1`。
  - **正对照先行**:同一个种子跑两次,请求日志逐字节相同。这一项不过,随机套件的其它结论一律不算。
  - 动作序列在开头一次性生成,方便事后删减到最小复现。
- **动作词表**:
  - 本地数据:新建;改随机一列;改回此前持有过的某个值;删除(含新建后在 awaitingEcho 期间删除);merge + 撤销(窗口内和窗口外各有);smart split + 撤销;吸收 todo;同名 event_types;settings 改键(含 `skillAnalyzedEventIds`);domino tick(注入时钟);
  - 跨设备:两台设备对同一行并发编辑;
  - 网络与同步:离线;上线;flush;拉取(门铃、轮询、前台、join 四种触发);
  - 认证:拉取第 k 页回 401,随后 AuthService 发射同 uid 的新 session;pull 和 flush 同时 401;
  - 外部:「第三方」直接写服务端(模拟 MCP 或另一台设备)。
- **调度**:所有 verb 都可以被扣留,按种子决定的顺序释放,扣留可以跨任意多步存活。拉取可以按请求时快照扣留,PATCH 在释放时求值。
- **故障**:请求前抛错;执行后丢响应(PATCH、POST 块、tombstone PATCH);40P01;某一行永久 4xx;PGRST204 暂时出现;401;门铃帧丢弃或迟到;slot 冻结;shelf 追加失败;服务端倒退(带 floor)。
- **进程「重启」**:丢掉 EventStore、引擎、pending-verify 和所有内存表,从同一目录和同一个 UserDefaults suite 重建。重启点用 M6(5) 的命名接缝:`after_slot`、`after_baseline_before_cursor`、`patch_committed_before_baseline`、`after_page:k`。UserDefaults 回滚有两种模型:回滚到某个写入前缀;逐键回滚(游标新、基线旧)。后者用来测 S11。
- **安全性 oracle(每一步都查,不调 stabilize)**:
  1. **因果账本**。每个写事件记 `(device, table, id, contentHash, base_seq)`,其中 base_seq 是写入时这台设备上该行的基线 seq;服务端接受时再记它分到的 seq。在任何时刻,每个写 W 都必须满足下面之一:
     - 它是某台设备或服务端上该行的当前内容;
     - 它在某个 shelf 里;
     - 存在一个已被服务端接受的写 W',W' 的 base_seq ≥ W 分到的 seq,也就是 W' 看见过 W;
     - W 从未上传,而同一台设备之后又写了同一行(本机覆盖)。

     其余情况一律判红。正对照:关掉 shelf 追加,账本必须红。反向对照:正常的顺序覆盖(A 写 c1 并同步,B 拉到之后改成 c2)不能红。上一稿的「每个确认的写要么是终值、要么在 shelf」按字面在这条反向对照上就是红的,所以改成了这个版本(质疑三)。
  2. **不复活**:一个 tombstone 被确认之后,这个 id 在任何设备上都不再以活行出现。例外只有 M2 写明的「恢复点之后被删的行会回来」。
  3. **运行时 Inv**:游标 ≤ 服务端计数器;id 表的基线 seq ≤ 服务端该行的 seq,且不指向死行;游标单调;本 session 第一次到 head 之前,请求日志里没有任何 PATCH / POST(I1),也没有 domino 写(M4(2))。
- **收敛与活性 oracle(只在种子决定的静止点上查,大约每 k 步一次,k 也由种子决定)**:
  1. `stabilize()` 在 R 轮之内停下;之后一轮 0 个写请求、0 次 slot 写;pending-verify 为空;除 `rejected` 表里的行之外,没有永远脏着的行。
  2. **收敛**:每台设备的活行,按 `(table, id)` 取 rowHash 组成的多重集,与 FakeServer 的活行相等。settings 按键相等这一项,只在 M6(4) 的 UserDefaults 注入清单全部完成之后才在层 1 断言。
  3. **领域不变量**:模拟时长 T 之后,每个未来待办的总推移 = T(M4);时区规则(§6.2)。
  4. **请求预算**:两个静止点之间的请求数有上界,用来抓风暴类问题。
- **触达计数器**:每一项都有一个最低次数(例如 ≥ 50),由测试根据语料规模推导出来并打印,不写进注释。项目包括:
  - 冲突进 shelf;tombstone 撞脏行;`[]` → 相同;`[]` → 过期;陈旧页被跳过;页被拒;
  - 响应丢失(三种写各自计数);awaitingEcho 期间删除;永久拒绝;PGRST204 暂时出现;
  - 倒退重置(≤ F 和 > F 两段各自计数);撤销窗口内的删除;
  - 拉取途中 401;pull 与 flush 同时 401;
  - 四个重启点各自命中;同一行并发写;扣留存活 ≥ 3 步之后才释放。
- **变异体**:
  - §8 已经列出的全部;
  - M3:两条拉取链;游标用普通赋值;
  - M2:不做检查;所有行一律哨兵;所有行一律保留 hash;
  - S4:没有「?」;awaitingEcho 删除被丢掉;
  - S2:不延迟 tombstone;
  - S1:没有 rejected 表;
  - M5:没有轮询(配合 100% 丢帧);join 后不拉;
  - M4:现行的 delta 逻辑;切前台先推后拉;
  - S6:写 hash(本地);
  - S11:不校验代次;
  - M6:FakeServer 各钩子关掉。

  **每个变异体都必须被至少一条测试抓红**。另外,交错类变异体(两条拉取链、游标普通赋值、不延迟 tombstone、所有行一律哨兵、没有「?」、join 后不拉、现行 domino、切前台先推后拉)要**只开随机套件、关掉定向测试**逐个跑一遍,记下第一次失败出现在第几个种子。判据:每个都在每次提交的种子预算内被抓红。做不到的,就承认随机套件对这一类没有区分力,改用一个定向生成的交错枚举器覆盖,并记录下来(质疑三)。
- **预算**:先实测单个种子的墙钟时间(中位数和 p95),再按时间预算倒推种子数:每次提交 ≤ X 分钟(例如 20 个种子左右),一夜 8 小时。不预设 5k–20k。只记录实际的 N 和 commit,不把 3/N 写成「上界」(X12)。默认全量测试只跑少量固定种子的冒烟版,避免计时类测试在 CPU 争用下假红,污染「全量绿」这道 gate(用户记忆)。

### E.3 层 2:本地 Supabase 栈(`done-mcp/` 下 `supabase start`)
- **台架重跑**:对 M1 / M2 之后的 015 重跑 S1–S15。新增:
  - **S16**:TRUNCATE 抛错、行数不变;replica 变体:`SET session_replication_role = replica` 下 TRUNCATE 成功,把「守卫被绕过」记成事实。
  - **S10b**:截断证明。
  - **S1 负对照**:用 dblink 做确定性交错,在一个事务里 `create or replace set_sync_meta` 去掉加锁那一行;在交错末尾补一步,A 提交之后,C 从自己的游标继续拉,断言 A 的行缺失。这才算真正观察到跳行。恢复原函数后同一交错不缺失。
  - **「锁在 nextval 之后」变异体**:在 nextval 和加锁之间加 `pg_sleep` 把窗口撑开,否则现有交错下根本走不到这个窗口(G18)。
  - **S-CAS**(dblink):T1 改 X 但不提交;T2 执行 `update … where id=X and seq=s0`,被阻塞;T1 提交 → T2 更新 0 行。
  - **缩小版压测**:4 个写连接,以插入为主,每个版本用新 id、都是终值;一个读连接推进游标;断言读者看到的 seq 集合 ⊇ 终表的全部 seq。正式跑之前,先在去锁的变体上跑一次,确认它真能抓红。上一稿的「读到的并集 == 终表」在 upsert 混合负载下检测不到跳行:被跳过的版本只要后来又被写一次,这个等式照样成立(质疑三)。
  - **40P01**:照 S15 的反向加锁顺序配方(先拿用户 advisory 锁再碰行,对面是先锁元组、在触发器里拿 advisory 锁)。只持有行锁造不出死锁。
  - **锁超时**:psql 持有行锁,客户端 PATCH 等到 `statement_timeout` / `lock_timeout`,断言它被分到 S1 的重试类,并把实测的 HTTP 状态和 code 抄成 fixture。
  - **S12b**:policy 唯一性。
  - **触发器启用检查**:M1(d)。
  - **epoch 行**:存在;`db reset` 之后 epoch 改变、floor = 0。
- **照文档的导出与恢复**(质疑三):`db reset` 会连 `auth.users` 一起清空,测到的是「用户消失加 401」,不是倒退,所以倒退场景要照 Supabase 文档原样做:
  1. 本地栈上用 `supabase db dump` 导出三份(roles、schema、data);
  2. 两台设备继续编辑;
  3. 用文档里的 `psql --single-transaction … SET session_replication_role = replica … --file data.sql` 恢复。

  跑两个变体:
  - (a) 走 M2 恢复脚本(同一事务里换 epoch 和 floor):期望在线设备在 M2(c) 发现,离线设备回来后在 M2(a) 发现,并且 M2 的「落后设备」场景里 c1 胜出;
  - (b) 绕开脚本(忘了换):把实测行为如实记录下来(期望是只读设备察觉不到,写入设备在 pending-verify 处判「相同」),作为 §9 残余风险的证据,也作为 L10 的触发依据。

  另外记下事实:恢复回来的行保留旧 seq;data.sql 的 `setval` 让计数器回到旧值;replica 模式下所有触发器都不触发。`db reset` 只保留为 epoch 行存在性的台架检查。
- **真实页 fixture**:从本地栈抓每张表一页 `sync_changes`(包括 iOS 编码器写的行,以及 service_role / psql 写的行),作为 JSON fixture 入库;拿它跑 §8 的往返 hash 测试,同时作为 FakeServer 的种子数据,让 FakeServer 不再只回显客户端自己的写法。
- **schema 完整性测试**:S8(3)。
- **LiveGateway 对拍**:M7(1),按其中定义的比较项。
- **脚本化场景**(`DoneSyncLiveTests`,`SYNC_LIVE_STACK=1`,每条一个确定脚本,不跑随机种子;每条开头 `supabase db reset` 并用 GoTrue 建测试用户):
  - M7(2) 的四条核心场景;其中 realtime 容器暂停那一条要量两样东西:检测到断开的时延(容器被 pause 后 TCP 不断、不发 RST,客户端要等 Phoenix 心跳超时才知道),以及这段时间里 B 是否在一个轮询周期内经 M5 追平;并断言 `sync.doorbell.missed` 被记录。URLProtocol 拦截不到 `URLSessionWebSocketTask`,门铃帧级的丢弃和迟到只在层 1 用 fake transport 测(质疑三);
  - **同一行并发 PATCH**:用 `async let` 让两个引擎对同一行同时发 `PATCH seq=eq.s0`,经真实 PostgREST 断言一个回 `[row]`、一个回 `[]`。重复 N 次,直到两种到达顺序都出现过。这是 I8 并发 CAS 在真 PostgREST 上的唯一测试;
  - **跨设备擦除**:B 扣住一页的时候,用 GoTrue admin 删掉这个用户;之后在 B 的 token 有效期内继续驱动 B 的 flush 和 pull。断言:user_id 外键上的 23503 走 S12 的「账号已不存在」路径,不进 rejected;B 本地数据的处置符合 §6.4 写明的规则;接受的窗口行为(`[]` 判相同)如实记录;
  - **token 刷新**:本地 `config.toml` 的 `jwt_expiry` 改为 360(Supabase 文档建议不低于 5 分钟;客户端在剩余 300 s 时刷新,`AuthService.swift:262`,所以约 60 s 后自然刷新一次)。断言:用同一个 since_seq 重发第 k 页;拉取没有被取消;pending-verify 和游标都没丢;门铃用新 token 重新 join;pull 和 flush 同时 401 时只发出一次 `grant_type=refresh_token`(在途去重见 `AuthService.swift:245-277`);
  - **第三方写者与回声静止**:用 service_role 或 edge function 的写入路径写出 MCP 形状的时间戳和 jsonb,然后对 A、B 做 §E.4 同款的静止断言。
- **收尾**:停止故障 → 两个引擎都零脏行、pending-verify 为空、游标 == 服务端 max seq,超过上界就判为卡死(即 Jepsen 的「appears to be stuck」)→ S8 的 `sync.audit` 和独立 Python 比较器都为 0,并且 shelf 里有操作轨迹中每一个败方版本。

### E.4 层 3:两台模拟器跑真 app(iPhone + iPad 模拟器,DEBUG 构建,指向本地栈,D8)
- **前置**:
  - 每轮 `supabase db reset` 之后,模拟器上活下来的 `syncHashes.<uid>.cursor` 会让它静默收不到行(质疑二)。所以要么 build 里已经有 M2 的 epoch 检查,要么 harness 在每次 db reset 之后清掉模拟器的 `syncHashes.` 键(改容器 plist,再 flush cfprefsd)。正对照:db reset 之后,下一个 session 必须记 `sync.epoch.changed`。
  - 本地 `jwt_expiry` = 360,每个场景至少经历一次真实的 token 刷新,并给它一个触达计数器。
- **DEBUG 接缝**(用启动参数或 harness 开关控制;两台模拟器共用宿主机的网络栈,Network Link Conditioner 作用于整台宿主机,所以不能从外面只让一台离线,质疑三):
  - 每台设备一个「离线」开关:打开后网关层直接抛 `URLError.notConnectedToInternet`;也可以每台设备走一个独立的 Toxiproxy 端口;
  - `SYNC_CRASH_AT=after_slot | after_baseline_before_cursor | patch_committed_before_baseline | after_page:k`,到达时 `kill(getpid(), SIGKILL)`。名字与层 1 一致。本地栈拉 27 页只要毫秒级时间,从宿主机发 `kill -9` 卡不准「第 k 页之后」;
  - `SYNC_DROP_RESPONSE=next_patch | next_post | next_tombstone`:请求照发、服务端照常提交,网关丢掉响应并抛超时。「响应丢失后改回」没法从 app 外面注入。
- **驱动方式**:
  - #197 形态的 harness 场景,加 idb(`~/.local/bin`);
  - 每一步一条结构化日志,写在 DiagnosticTrail 的容器文件里;terminate 之后从容器读 plist,不用 `simctl spawn defaults read`;
  - Simulator 保持在前台;
  - 每个就绪判据都选目标层独有的标签(正断言)。
- **场景**:§7 Phase 1 的全部验收,加上本文新增的:
  - A 离线改、B 在线改(用离线接缝);
  - 两台在 2 s 内改同一行。**断言与分支无关**:败方版本在某个 shelf 里;服务端的 seq 链显示两次写都基于当时的当前版本;两台的 `sync.audit` = 0;走了哪条分支(PATCH 回 `[]` 后 pending-verify,还是拉取时三方比较)只记日志并计数。确定性的 `[]` 分支放在 §E.3;
  - 合并后第 3 s 撤销;
  - domino 双机(注入时钟或缩短间隔的 DEBUG 开关)→ 总推移 = 时长;A 推过一轮后 B 切回前台 → B 的 shelf 增量为 0;
  - 暂停 realtime 容器 → 出现 `sync.doorbell.missed`,一个轮询周期内收敛;
  - 刚切到前台就让对端写入(join 窗口);
  - 首次同步时在四个命名崩溃点各杀一次 → 重启后追平,`sync.audit` 为 0;
  - 响应丢失后改回原值(`SYNC_DROP_RESPONSE`);新建行在等回声时删除;
  - 换账号登录 → `sync.blocked.owner_mismatch`;
  - `supabase db reset` 之后 → `sync.reset reason=epoch`;
  - 临时加 CHECK → 只有一条 `sync.push.rejected`,其余行都上去了。
- **每个场景结束时**:
  - 两台各跑一次 `sync.audit`,mismatches = 0;独立 Python 比较器对 slot JSON 和 psql 导出逐字段比较,不一致 = 0。
  - **静止窗口** ≥ 150 s(覆盖两个以上轮询周期)。断言用两个不依赖客户端代码的服务端读数:`select max(seq)` 不变;`pg_stat_user_tables` 的 `n_tup_ins + n_tup_upd` 不变。客户端侧 PATCH / POST 计数为 0。回声循环(B 按 PostgREST 重新渲染的字段算 hash、对不上就判脏再推)只有在带真门铃、真渲染的这一层才走得到,`sync.audit` 在每一刻都相等,看不出 ping-pong(质疑三)。
- **延迟**:每个场景 ≥ 20 个样本,取门铃路径 `latency_ms` 的 p95,只作回归基线。localhost 上的 ≤ 2 s 说明不了生产;2 s 验收移到 §E.6。

### E.5 层 4:只有真机能测的
- 真机后台:socket 被系统杀掉之后,切回前台能追平。
- 上一稿的 UserDefaults 崩溃顺序测量删掉(X11),改由 S11 的构造保证。

### E.6 层 5:生产(本地有信心之后)
- 在安静窗口里应用 015(总闸 OFF)→ 三个 edge function 在同一窗口重新部署 → 验后检查:S9c 的 policy 唯一性、epoch 行存在、九表三触发器 `tgenabled = 'O'`(M1d)、max_rows 探针(M1b)→ 在两台自用设备上打开 apply → **立刻**在两台上跑 `sync.audit` 和独立比较器(生产侧用 MCP `execute_sql` 导出),结果都为 0 → 之后一周每天对一次账,并用 count 与 sum(seq) 交叉核对。任何一次不为 0,就走回滚。
- **延迟验收**:两台真机走真实网络,每个方向 ≥ 20 个样本,门铃路径 p95 ≤ 2 s(§2 目标 1)。
- **回滚**:drop 三类触发器(D8)并关掉总闸。重新启用时用 M2 恢复脚本里同一条 epoch / floor 语句,让每台设备自动重置。这条回滚路径要先在本地栈上演练一次。

---

## F. 部署信心判据(全部满足才把 015 应用到生产并打开 apply)

1. M1–M7 全部落地;S1、S2、S4–S13 要么落地,要么由用户明示延期,并写进设计稿 §7 / §9;M4 的方案和 S12 的本地数据处置由用户拍板。
2. `lake build` 绿;fixtures 由模型重新生成,Swift 回放全绿。
3. 随机套件:
   - 决定论正对照通过;单种子耗时已实测;
   - 一整夜零失败,记录实际种子数 N 和 commit;
   - 每个触达计数器都达到测试推导出的最低次数;
   - §E.2 的每个变异体都被抓红,其中交错类变异体只靠随机套件、在每次提交的预算内被抓红,做不到的有枚举器覆盖并已记录。
4. 台架:S1–S16 和新增项全部 PASS;S1 负对照观察到 C 缺失 A 的行;压测已先在去锁变体上抓红;截断证明成立;触发器启用检查通过;照文档的导出与恢复两个变体都已跑过,结果写进 §9。
5. LiveGateway 对拍:按 M7(1) 定义的比较项零差异。
6. 真栈脚本化场景:M7(2) 和 §E.3 的五条全部通过;同一行并发 PATCH 的两种到达顺序都出现过。
7. 两台模拟器:全部场景都通过;`sync.audit` 和独立比较器都为 0;每个静止窗口里 `max(seq)` 和写入计数都不变;每个场景都经历过一次 token 刷新;延迟 p95 已记录为基线。
8. S11 已落地,「不校验代次」变异体被抓红。
9. 生产:
   - 验后检查全部通过;
   - 打开 apply 后立刻对账为 0,之后一周每天对账都为 0;
   - 每条 `sync.push.rejected` 都有解释;`sync.epoch.changed` 只出现在有意触发的时候;`sync.doorbell.missed` 有计数(不要求为 0,但每一条都能解释);
   - 两台真机上门铃路径 p95 ≤ 2 s。
10. 任何一条不满足,都不扩大到第三台设备或其他用户。

---

## G. 来源

**Replicache / Zero**
- https://doc.replicache.dev/strategies/global-version
- https://doc.replicache.dev/byob/dynamic-pull
- https://doc.replicache.dev/byob/poke
- https://doc.replicache.dev/reference/server-push
- https://doc.replicache.dev/concepts/how-it-works
- https://trunk.doc.replicache.dev/strategies/reset
- https://zero.rocicorp.dev/docs/schema
- https://github.com/rocicorp/mono/blob/main/apps/zbugs/scripts/rmv2-soak/chaos.ts
- https://github.com/rocicorp/mono/blob/main/apps/zbugs/scripts/rmv2-soak/oracle.ts

**Linear**
- https://raw.githubusercontent.com/wzhudev/reverse-linear-sync-engine/main/README.md
- https://linear.app/now/rebuilding-delta-sync-read-path
- https://linear.app/docs/eu-sync-outage
- https://www.youtube.com/watch?v=Wo2m3jaJixU
- https://www.youtube.com/watch?v=VLgmjzERT08
- https://www.youtube.com/watch?v=WxK11RsLqp4

**Apple CloudKit / CKSyncEngine / Core Data**
- https://developer.apple.com/documentation/cloudkit/ckerror/code/serverrecordchanged
- https://developer.apple.com/documentation/cloudkit/ckerror/code/changetokenexpired
- https://developer.apple.com/documentation/cloudkit/cksyncengine/event/stateupdate
- https://developer.apple.com/documentation/cloudkit/cksyncengine/event/accountchange
- https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit
- https://github.com/apple/sample-cloudkit-sync-engine(`SyncEngine/DataModel.swift`、`SyncEngine/SyncedDatabase.swift`、`Tests/SyncTests.swift`)
- https://developer.apple.com/forums/thread/764080

**PowerSync / ElectricSQL**
- https://docs.powersync.com/architecture/consistency
- https://docs.powersync.com/architecture/powersync-protocol
- https://docs.powersync.com/handling-writes/handling-update-conflicts
- https://docs.powersync.com/configuration/app-backend/client-side-integration
- https://docs.powersync.com/maintenance-ops/implementing-schema-changes
- https://github.com/powersync-ja/powersync-swift/blob/main/Demos/PowerSyncExample/PowerSyncExample/PowerSync/SupabaseConnector.swift
- https://github.com/nurturenature/jepsen-powersync
- https://electric.ax/docs/sync/guides/shapes

**经典复制系统**
- https://docs.couchdb.org/en/stable/replication/protocol.html
- https://docs.couchdb.org/en/stable/replication/conflicts.html
- https://docs.couchdb.org/en/stable/api/database/misc.html
- https://github.com/apache/pouchdb/blob/master/TESTING.md
- https://docs.couchbase.com/sync-gateway/3.1/managing-tombstones.html
- https://github.com/mongodb/docs-app-services/blob/master/source/sync/details/conflict-resolution.txt
- https://github.com/mongodb/docs-app-services/blob/master/source/sync/data-model/update-schema.txt
- https://www.mongodb.com/docs/atlas/app-services/sync/error-handling/client-resets.md
- https://github.com/firebase/firebase-ios-sdk/blob/main/Firestore/core/src/remote/remote_event.cc
- https://www.figma.com/blog/how-figmas-multiplayer-technology-works/

**Supabase / PostgREST**
- https://supabase.com/docs/guides/platform/backups
- https://supabase.com/pricing
- https://supabase.com/docs/guides/realtime/broadcast
- https://supabase.com/docs/guides/realtime/authorization
- https://supabase.com/docs/guides/realtime/subscribing-to-database-changes
- https://supabase.com/docs/guides/troubleshooting/realtime-warn-sending-broadcast-message
- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://cdn.jsdelivr.net/gh/supabase/realtime@main/README.md
- https://github.com/PostgREST/postgrest/blob/main/docs/references/configuration.rst

**Postgres 与变更流**
- https://www.postgresql.org/docs/current/sql-truncate.html
- https://www.postgresql.org/docs/current/transaction-iso.html
- https://www.postgresql.org/docs/current/functions-sequence.html
- https://www.postgresql.org/docs/current/functions-admin.html
- https://raw.githubusercontent.com/postgres/postgres/master/src/backend/access/transam/xact.c
- https://raw.githubusercontent.com/postgres/postgres/master/src/backend/commands/trigger.c
- https://blog.sequinstream.com/postgres-sequences-can-commit-out-of-order
- https://cassandra.apache.org/doc/latest/cassandra/managing/operating/compaction/tombstones.html

**验证方法**
- https://www.foundationdb.org/files/fdb-paper.pdf
- https://www.cis.upenn.edu/~bcpierce/papers/mysteriesofdropbox.pdf
- https://dropbox.tech/infrastructure/-testing-our-new-sync-engine
- https://raw.githubusercontent.com/jepsen-io/jepsen/main/doc/tutorial/03-client.md
- https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai

---

## H. 质疑与处置

三位独立质疑者(下表记作 Q1 / Q2 / Q3)对上一稿共提出 45 条质疑。凡涉及代码的,都对工作树复核过,带「复核」字样的是复核时重新看过的位置。处置分三种:**采纳**,按质疑者的修法改;**部分采纳**,改了,但做法或落点与质疑者的建议不同,理由写在本行;**驳回**,本轮没有。

| # | 目标 | 处置 | 一句话理由 / 落点 |
|---|---|---|---|
| Q1.1 | M4 / X7:切前台先跑 domino、后到 head | 采纳 | 复核 `DoneApp.swift:913`:`.active` 时同步调用,拉取是异步的;M4(2) 加「到 head 之后才推、tick 前先拉」,并加测试「B 切回前台 shelf 增量为 0」;X7 已重算 |
| Q1.2 | L6 与层 4 的 UserDefaults 崩溃顺序测量 | 采纳 (a) | kill -9 造不出这种故障,测量没有区分力;L6 提为 S11,按每键代次用构造保证;删掉 E.5 测量和原 F8(X11) |
| Q1.3 | L3 的触发条件只写在文档里 | 采纳 | 复核:自 2026-06 起这个文件有 12 次提交,b3b43f0、05a3565 都改了线上字段;新增 S13 快照测试,L3 的触发由测试执行 |
| Q1.4 | S3 付不起成本 | 部分采纳 | 降为 L8;计数器需要一个本 session 的 id 集合,不是质疑者说的「零状态」,但它不参与 apply 判定 |
| Q1.5 | S8 影子模式 | 采纳 | 删除(X10);部署门槛改为打开 apply 后立刻对账为 0,之后每天对账一周,不为 0 就回滚 |
| Q1.6 | M7(2) 两个真引擎跑随机种子 | 采纳 | M7(1) 对拍为 must;M7(2) 缩成四条脚本化核心场景;随机种子只在层 1 跑 |
| Q1.7 | M2 触发器 1 | 部分采纳 | 降为 L10。另外加了 M2(c):pending-verify 判「相同」之前查一次 epoch,并把恢复手册写成同一事务里换 epoch 的脚本,补上触发器 1 原本覆盖的在线写入设备;绕开脚本的手工恢复记为残余风险 |
| Q1.8 | S7 的「零存储」不成立 | 采纳 | 只保留 `cols=`;L2 写明前提是先做 `Event.updatedAt`(复核设计稿 §1.1:`updated_at` 是上传时刻) |
| Q1.9 | 退出标准 3 的 rule-of-three 上界;全量耗时 | 采纳 | 只记 N 和 commit(X12);随机套件放进独立 test plan,默认全量只跑冒烟版 |
| Q1.10 | M1(d) 与 G3 严重度 | 采纳 | (d) 移入 X9;G3 标为「潜伏」,修法不变 |
| Q1.11 | S9 承重规则只写在文档里 | 采纳 | M1(d) 验后检查九表三触发器 `tgenabled = 'O'`,台架和每次部署后各跑一次;文档只写「见验后检查」 |
| Q2.1 | M2 哨兵让落后设备覆盖新数据 | 采纳 | 纪元表加 `floor`;seq ≤ floor 用哨兵语义,> floor 保留旧 hash 走普通规则;加落后设备测试和「所有行一律哨兵」变异体。「由触发器 1 发现时用揭示倒退的 seq 作 floor」随触发器 1 一起移到 L10 |
| Q2.2 | S4 太窄;awaitingEcho 删除被丢 | 采纳 | 复核 `SupabaseSyncService.swift:1188-1192`、`:1203`:现行代码确实丢掉这次删除;新增 G23,S4 泛化到 PATCH / POST / tombstone 三种写和 awaitingEcho |
| Q2.3 | 结论与 B.3「和我们一样」说过头 | 采纳 | A.1、A.3、B.3 改为逐项写清对上的是哪几家;写明我们的脏是 hash 推出来的,不同于 CKSyncEngine 的持久待发送集合,`?` 标记就是只覆盖在途写的待发送集合 |
| Q2.4 | G8 严重度与「不进 shelf」一句 | 采纳 | 按 §6 第 127 行 `dirty = h_loc != h_base.hash` 重算,基线缺席时判脏,所以会进 shelf;015 第 38 行写明 tombstone 保留内容;G8 改标为 divergence / ux |
| Q2.5 | M4(2) 启动期清理器不该是 must | 部分采纳 | 移出 must;按本文的类别定义,带触发条件的条目进 later(L9),不进 should。同时写出方案 (i) 下同时 tick 的残余代价(M4(3)) |
| Q2.6 | M3 引用的 `EventStore.swift:512-515` 说的是 domino | 采纳 | 复核属实;M3 和 G4 都改写了这处引用,并写明 M3 不关闭 G9 |
| Q2.7 | `sync.doorbell.missed` 会误报 | 采纳 | 比较对象加上本机自己写响应里的 seq,再加 5 s 宽限期;另加「健康时为 0」的测试 |
| Q2.8 | X2 的理由错 | 采纳 | 复核 §9.17:死锁形状是多行 tombstone 单语句对单行 PATCH;改为「重试已存在,牺牲者总是单行侧」 |
| Q2.9 | 影子模式不自洽 | 采纳 | 随 Q1.5 整体删除,X10 记下了它的两种失效形状 |
| Q2.10 | LiveGateway「零差异」不可能通过 | 采纳 | M7(1) 定义了比较项(状态类别、`[]` / `[row]`、`deleted_at` 与 seq 是否存在、seq 相对顺序、解码后的 rowHash);原始字节差异只作信息 |
| Q2.11 | S1 把暂时的 400 当成永久 | 采纳 | 加表结构缓存类(PGRST2xx 退避,持续超过窗口才判拒绝)和块大小类(413 / 414 拆块);拒绝类只认 22xxx / 23xxx / 42501,并且先逐行重发一次 |
| Q2.12 | max_rows 被调到 500 以下时没人发现 | 采纳 | max_rows 探针进 `sync.audit`,每次都跑;§9 记一句(S9g) |
| Q2.13 | 若干证据说过头 | 采纳 | Replicache 改写为「检测信号,文档例子里恢复靠手动」;Zero 那句标为服务端 soak 的类比;S5 引用 `handleAccountChange` 的实际分支;changeTokenExpired 标为未证实(A.3、B.2、G1、G11、G18、M2、S5、C10) |
| Q2.14 | db reset 在本地测试期就会让游标静默失效 | 采纳 | E.4 前置:要么 build 里有 epoch 检查,要么 harness 在每次 reset 后清掉 `syncHashes.` 键;正对照为 reset 之后记 `sync.epoch.changed` |
| Q2.15 | X7 漏了重置突发;S10 的 fsync 不对 | 采纳 | X7 计入 M2 重置突发,驳回结论不变;S10 改为在推送胜方之前、按批次做一次 F_FULLFSYNC,目标写明是断电 |
| Q3.1 | 「保存账本」在正常路径上就是假的 | 采纳 | 改为因果账本(base_seq ≥ W 的 seq 才算正当覆盖),配正对照和反向对照 |
| Q3.2 | 每步 stabilize 与并发深度冲突 | 采纳 | oracle 拆成两类:安全性每一步都查;收敛和活性只在种子选定的静止点查;加计数器「扣留存活 ≥ 3 步」 |
| Q3.3 | 没有 401 / token 刷新 | 采纳 | 层 1 加 401 故障和同 uid 的 session 重发;层 2 / 3 把 `jwt_expiry` 设为 360(复核 `AuthService.swift:262`:剩余 300 s 时刷新) |
| Q3.4 | 跨设备擦除没测;擦除 epoch 是进程级全局 | 采纳 | 新增 G24、S12(23503 视为账号已不存在;B 本地数据的处置待用户拍板);层 1 的擦除只在单设备套件里出现(复核 `LocalDataEraseEpoch.swift:95-97`) |
| Q3.5 | db reset 测不到倒退;replica 模式绕过守卫 | 采纳 | §E.3 照文档做导出与恢复,分「走脚本」和「绕开脚本」两个变体;S16 加 replica 变体;M2 恢复脚本在同一事务里换 epoch |
| Q3.6 | 层 1 做不到决定论 | 采纳 | 复核 `SupabaseSyncService.swift:701-842` 的 `RunLoop.main` 防抖和 `SyncedSettings.swift:152`、`:258` 的 `.standard`;M6(4) 加可注入时钟和 UserDefaults 清单,配决定论正对照;清单完成之前,层 1 不断言 settings |
| Q3.7 | 种子预算没有算术依据 | 采纳 | 先实测单种子耗时,再按时间预算倒推 N;N 不够时改用枚举器 |
| Q3.8 | 层 3 的离线、kill 第 k 页、响应丢失跑不起来 | 采纳 | DEBUG 接缝:每台设备单独的离线开关、`SYNC_CRASH_AT` 命名崩溃点、`SYNC_DROP_RESPONSE`;名字与层 1 共用 |
| Q3.9 | E.5 测量必然通过 | 采纳 | 同 Q1.2:S11 无条件落地,F8 改为「S11 已落地并有变异体」 |
| Q3.10 | S1 负对照与压测检测不到跳行 | 采纳 | 负对照末尾加「C 从游标继续拉、断言 A 缺失」;「锁在 nextval 之后」用 `pg_sleep` 撑开窗口;压测改为以插入为主,断言 seq 集合 ⊇,并先在去锁变体上校准 |
| Q3.11 | 回声循环没有活性检查 | 采纳 | 层 3 每个场景后静置 ≥ 150 s,用服务端 `max(seq)` 和 `n_tup_ins + n_tup_upd` 断言不变;层 2 加第三方写者场景 |
| Q3.12 | 「2 s 内同改一条」会时绿时红 | 采纳 | 层 3 的断言改为与分支无关;确定性的 `[]` 分支放到层 2,用 `async let` 重复执行,直到两种到达顺序都出现过 |
| Q3.13 | 只持行锁造不出 40P01 | 采纳 | 40P01 复用 S15 的加锁顺序;另加锁超时场景,断言进重试类,并把实测状态码抄成 fixture |
| Q3.14 | `sync.audit` 与被测代码共用 rowHash | 采纳 | S8(2) 加独立 Python 比较器和显式列映射表;S8(3) 加 schema 完整性测试 |
| Q3.15 | 变异体只被定向测试抓红,说明不了随机套件有牙 | 采纳 | 交错类变异体只开随机套件逐个跑,记下第一次失败的种子序号;预算内抓不到的改由枚举器覆盖 |
| Q3.16 | 触达计数器「> 0」太低 | 采纳 | 每项一个由测试推导并打印的最低次数;补上点名的几种情形 |
| Q3.17 | localhost 上的 ≤ 2 s 没有意义 | 采纳 | 层 3 只记 p95 回归基线;2 s 验收移到生产,两台真机、每方向 ≥ 20 个样本、看 p95 |
| Q3.18 | URLProtocol 拦截不到 WebSocket | 采纳 | 层 2 的 pause 场景量断开检测时延和轮询追平情况;帧级故障只在层 1 用 fake transport 测 |
| Q3.19 | 影子模式「差异为 0」定义不清 | 采纳 | 随 Q1.5 删除影子模式 |

**本轮之后仍待用户拍板的**:M4 选 (i) 还是 (ii);S12 里 B 本地数据的处置;S2 先用延迟方案还是直接做 #140 的 undelete RPC。
