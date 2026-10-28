# 遥测线上契约(wire contract)— 客户端与服务端的共同边界

版本 1.2(2026-10-27;1.1 / 1 均为 2026-10-24)。设计见 `00-telemetry-chassis-design.md` §4 / §7 / §9。两边实现者只认本文件;改动须同时改两边并升版本号。

变更:1.2(2026-10-27)— 新增 §7 读回路径(迁移 017 `v_my_spike_runs`,观察站读本账号云端行);§5 同意水位按整秒比较;TestFlight 包水位为 `.distantPast`(只补传带账号的记录),App Store 包水位=同意时刻。1.1 — `value_schema` 增 `number_list`;§3 补「同 revision 重传 = 跳过、戳不动」;§5 边沿 daily 不分今日、metricKitDaily 不随边沿;§2 补 owner 盖戳位置。

## 1. 端点与请求

- `POST {rest}/rest/v1/spike_runs?on_conflict=user_id,run_id`
- 头:`apikey`、`Authorization: Bearer <用户 JWT>`(复用 `SupabaseREST.send` 的鉴权与 401 重试)、`Content-Type: application/json`、`Prefer: resolution=merge-duplicates,return=minimal`
- 体:JSON 数组,1–32 行;每行是一条记录(下表)。
- 不带 `X-Sync-Epoch`;该表不在 015 的触发器循环里。
- 成功 = 2xx。客户端对 2xx 推进游标到该行的 `revision`;服务端对旧 `revision` 的更新静默跳过(对客户端仍是 2xx,语义正确:本地更高的 revision 迟早会发)。
- 失败分类复用 `SyncWriteFailure.classify`;游标不动。

## 2. 行(列名 = JSON 键名,snake_case)

| 列 | 类型 | 来源(SpikeRun 字段) | 必填 |
|---|---|---|---|
| `user_id` | uuid | 当前登录 uid;RLS `with check user_id = auth.uid()` | 是 |
| `run_id` | uuid | `id` | 是 |
| `install_id` | uuid | `installID`(本机随机,`spike-runs/.install-id`,擦除轮换) | 是 |
| `kind` | text | `kind`:`daily_rollup` / `window` / `manual_run` / `verdict_snapshot` / `metrickit_daily`(`user_report` 预留) | 是 |
| `spike_id` | text | `spikeID` | 是 |
| `scenario_id` | text | `scenarioID` | 是 |
| `day_key` | date | `dayKey`(yyyy-MM-dd,按日界时区在铸 id 时算一次) | 是 |
| `day_tz_offset_min` | smallint | `dayTZOffsetMin`(日界时区当日偏移分钟) | 是 |
| `app_build` | integer | `Int(appBuild)` | 是 |
| `app_version` | text | `appVersion` | 是 |
| `build_configuration` | text | `buildConfiguration`:`debug` / `release`(客户端 DEBUG 包不会向 production 发;staging 收 debug 行) | 是 |
| `device_model` | text | `deviceModel`(硬件标识,如 `iPhone17,2`) | 是 |
| `os_version` | text | `osVersion` | 是 |
| `revision` | integer | `revision`(同 id 每次 append 递增,从 1 起) | 是 |
| `started_at` | timestamptz | `startedAt`(ISO8601) | 是 |
| `ended_at` | timestamptz | `endedAt` | 否 |
| `outcome` | text | `outcome.rawValue`:`completed` / `aborted` / `interrupted` | 否 |
| `metrics` | jsonb | `metrics`:对象,值为 number / string(仅注册表允许的固定格式)/ bool | 是(可为 `{}`) |
| `context` | jsonb | 对象:`{"co_active_spike_ids": [..], "abort_reason": "<枚举 rawValue>", "variant_id": "..", "app_commit": ".."}`,缺省键省略 | 是(可为 `{}`) |
| `note` | text | `note`,**仅当备注开关开**;否则键不出现 | 否 |
| `client_updated_at` | timestamptz | 序列化时刻 | 是 |

不上传的本地字段:`localeIdentifier`、`timeZoneIdentifier`(用 `day_tz_offset_min` 代替)、`ownerUID`(等于 `user_id`,不重复传;由 `SpikeRunStore.appendLine` 对**每条**记录盖戳,手动 run / 窗口 / daily 一致;owner 为 nil 的记录永不上传)。
客户端脱敏规则:NOT NULL 的文本列(`kind / spike_id / scenario_id / day_key / app_version / build_configuration / device_model / os_version`)值不合白名单时发 `"unknown"`,不删列;可空列与自由文本不合白名单时删除。被服务端按行拒绝的记录由客户端按 `(run_id, revision)` 隔离,不再重发该 revision:触发隔离的是分类为 `rejected`(4xx 含 PostgREST 23502 / 23514 / 22007 / 42501 等)或 `tooLarge`(413 / 414)的整批失败;`retryable`、`unauthorized`、`schemaCache`(PGRST204 暂态)不隔离,留给下次触发。
服务端专有列:`first_uploaded_at timestamptz default now()`、`last_uploaded_at timestamptz`(触发器维护)。客户端不发。

## 3. 服务端行为

- 主键 `(user_id, run_id)`;`on_conflict` 必须是复合键,单列会与生产分叉。
- BEFORE UPDATE:`new.revision <= old.revision` → `return null`(跳过;**同 revision 重传也是跳过,`last_uploaded_at` 不动**);否则 `new.last_uploaded_at = now()`,`first_uploaded_at` 钉回 old。BEFORE INSERT:`new.last_uploaded_at = now()`。
- RLS(authenticated):`select / insert / update` 自己的行;**无 delete**。`revoke all` 后精确 `grant select, insert, update`。
- 不进 `sync_changes`、不进 snapshots、无 `trg_*_sync_*` 触发器。
- `user_id references auth.users(id) on delete cascade`。
- 视图一律 `where build_configuration = 'release'`。

## 4. 键注册表(0 vs NULL 的依据)

文件 `done-mcp/supabase/telemetry/key_registry.json`(由 Swift 测试导出,不手抄):

```json
[
  {"key": "commitCount", "kind": "counter", "family": "fixwatch", "value_schema": "number",
   "since_build": 5, "retired_build": null, "liveness_key": null,
   "spike_id": "resident-daily", "description": "..."}
]
```

- `kind`:`counter` / `histogram` / `gauge`;`value_schema`:`number` / `fixed_string` / `bool` / `number_list`(空格分隔的数字串,如 `"12.3 45.6"`,只允许 kind = gauge;histogram 固定用 fixed_string)。
- `family`:`fixwatch` / `usage` / `incident` / `metrickit` / `self`。
- 表 `public.key_registry(key text primary key, kind, family, value_schema, since_build int, retired_build int, liveness_key text, spike_id text, description text)`;加载 SQL 由脚本从 JSON 生成(`key_registry_load.sql`,幂等 upsert);checks 断言 JSON 行数与键集合 == 表。
- 视图 `counter_long` 对每 `(行, 键)`:`app_build` 在 `[since_build, retired_build)` 内 → `coalesce((metrics->>key)::numeric, 0)`,否则 NULL。

## 5. 预算与节流(客户端义务)

- 每批 ≤32 行;同一时刻只有一个在途批次(单写者)。
- 退后台边沿:只带 `window / verdict_snapshot / manual_run`,以及距上次 daily 上传 ≥15 分钟(≥900 s)的 `daily_rollup`(任何一天的,不按今日区分);`metrickit_daily` 不随边沿;整段包 `beginBackgroundTask`。
- 启动:`didBecomeActive` +2s,`.utility`;跨天与打开观察站:flush 后调度同一任务。
- 同意水位:只发 `started_at ≥ floor(consent_at, 1 s)` 且 `ownerUID == 当前 uid` 的记录(客户端存储以整秒保存 `started_at`)。

## 6. 变更规则

列只增不删;`metrics` 键只增不改义(改义 = 新键 + 旧键填 `retired_build`);本文件版本号与 016 之后的迁移号一起走。

## 7. 读回(1.2,迁移 017)

- `GET {rest}/rest/v1/v_my_spike_runs?select=*&build_configuration=eq.release&spike_id=in.(resident-daily,fix-effort-path)&day_key=gte.<今天-60>&order=day_key.desc,run_id.asc`,翻页用 `limit` / `offset`(或 `Range`),排序必须含唯一键 `run_id`,否则翻页会漏行或重行;PostgREST 单次上限为 `max_rows`。
- 鉴权同 §1(`apikey` + 用户 JWT),不带 `X-Sync-Epoch`。只返回本人行(`security_invoker` + `where user_id = auth.uid()` 双防线);anon 401,读任何共享视图 403。
- 列 = §2 去掉 `note`、`first_uploaded_at`、`last_uploaded_at`,共 20 列,snake_case。
- 客户端按 `run_id` 与本机记录合并,`revision` 高者胜,平局取本机;离线 / 未登录 / 读失败 / 云端为空 → 回退本机,并在界面标注来源。
