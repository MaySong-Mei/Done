# Supabase Realtime — 裸客户端实现笔记

来源:Supabase 文档(Protocol / Broadcast / Authorization / Postgres Changes / Reports / Benchmarks),2026-10-08 摘录;2026-10-14 按本地台架实测修订(`done-mcp/supabase/tests/sync_feed_checks.sh` S12,裸 websocket 对 `supabase start` 栈的 realtime v2.82.0,`6f293a8`)。2026-10-18 按业内调研(`Docs/sync/02-industry-survey.md`,设计稿 v1.5)补四处:至多一次投递与轮询看门狗、`.joined` 必拉、policy 恰好一行、日分区无害;token 带内续期的推送机制已实现、接线是 Phase 1 交付项。只留实现 `RealtimeDoorbell` 需要的 wire shape;标「**未载明**」的字段文档里没有,要实测;标「**台架**」的是实测值,不是文档。

## 连接

- URL:`wss://<PROJECT_REF>.supabase.co/realtime/v1/websocket?apikey=<API_KEY>&vsn=1.0.0`
  - `vsn` 取 `1.0.0`(JSON 对象信封)或 `2.0.0`(JSON 数组 `[join_ref, ref, topic, event, payload]` + 二进制帧)。**用 1.0.0**:只有文本帧,`URLSessionWebSocketTask` 直接 JSON 编解码。
  - `apikey` 用 `sb_publishable_…`。**它不能当 `access_token`**:「Tokens with the `sb_*` prefix are silently ignored」;私有 channel 必须带用户 JWT(需含 `role` 与 `exp` claim,GoTrue 的都有)。
- 连上后必须先 `phx_join` 才会收到任何东西。
- **Heartbeat**:topic `phoenix`,event `heartbeat`,payload `{}`,**至少每 25 s 一次**,否则连接超时。实现取 20 s。
- **静默断开**:realtime 容器被 pause(或中间网络静默丢包)时 TCP 不断、不发 RST,客户端只能靠心跳回复超时发现;检测时延与这段时间里轮询能否追平由设计稿 §8.3 的 `docker pause` 场景实测,不靠推断。
- 全部 text frame,JSON。`ref` 是字符串,单调递增即可;`join_ref` = 该 topic 的 join 用的 ref。

## 信封(vsn 1.0.0)

```json
{ "topic": "realtime:user:<uid>", "event": "phx_join", "payload": { … }, "ref": "1", "join_ref": "1" }
```

| 客户端事件 | ref | join_ref |
|---|---|---|
| `phx_join` | 要 | 要 |
| `phx_leave` | 要 | 要 |
| `heartbeat` | 要 | 不要(topic 为 `phoenix`) |
| `access_token` | 要 | 要 |
| `broadcast` | 要 | 要 |

## phx_join payload

```json
{
  "config": {
    "broadcast": { "ack": false, "self": false },
    "presence":  { "enabled": false },
    "postgres_changes": [],
    "private": true
  },
  "access_token": "<user jwt>"
}
```
- `private: true` 是私有 channel 的客户端半;服务端半是 `realtime.messages` 的 RLS(见下)。两边不匹配 → 收不到 DB 广播(「A private broadcast only reaches private channels」)。
- 回复:`phx_reply` payload `{ "status": "ok" | "error", "response": … }`;成功时 `response.postgres_changes` 为空数组(我们不订阅 postgres_changes)。
- 失败时 `response.reason = "<ErrorCode>: <message>"`,例如 `"InvalidJWTExpiration: Token has expired 300 seconds ago"`。**服务端在回错误前会加 backoff**,客户端不要紧跟重试。
- **台架**:用 A 的 JWT join `realtime:user:<B>` → `phx_reply` `status: "error"`,`reason` 恰为 `"Unauthorized: You do not have permissions to read from this Channel topic: user:<B>"`。code 与「token 无效」的 `Unauthorized` 相同,**按 code 分不开 topic 授权失败和坏 token**;两者都是客户端 bug(topic 拼错 / token 不是本人的),都终端处理,见下表。

## 收到的广播(来自 `realtime.send`)

```json
{ "topic": "realtime:user:<uid>", "event": "broadcast", "ref": null,
  "payload": { "event": "change", "type": "broadcast",
               "meta": { "id": "<uuid>", "replayed": false },
               "payload": { "id": "<uuid>", "seq": 123, "table": "events" } } }   // v2:语句级,一条语句一帧,seq = 该语句写入的最大 seq
```
- 外层 `payload.event` 是 `realtime.send` 的第二个参数;内层 `payload.payload` 是我们的 jsonb **加一个 `realtime.send` 自己注入的 `"id"` 键**(台架实测,`realtime.messages` 行的 id;文档未载明)。`RealtimeChange` 只解析 `table` / `seq`,多出的键忽略;解析器不得按「恰好两个键」做严格匹配。`meta` 不保证出现。
- **台架**:插入后 5 s 内帧到达;20 行一条 POST 一帧、`seq` 为最大号;账号擦除(`auth.users` 级联)零帧。
- DB 发起的广播**所有订阅者都收**,包括引起写入的那台设备(`broadcast.self` 只管客户端自发的 push)→ v2 不做发送者标识:自己的写回拉下来后与本地内容一致,被设计稿 §6 的三方比较判为「无事」。门铃文件头写的 `{table, id, seq, device_id, deleted}` 与「engine filters by deviceId」是 v1 的遗留,与此矛盾,随 Phase 1 订正(设计稿 §9.11)。
- **至多一次、不重放**(Realtime README:「The server does not guarantee that every message will be delivered」;Broadcast 没有重放):帧丢了就是丢了,`realtime.send` 的错误还会被吞成 WARNING(设计稿 §5.3)。所以门铃只是加速器,不是真相:前台 60 s 轮询**常驻**当看门狗;**每次转到 `.joined`**(启动、切前台后的第一次 join、token 过期后的 rejoin)立刻拉一次——前台拉取的快照与 `phx_reply ok` 之间提交的写,帧发给了一个还没 join 的 socket;漏铃由 `sync.doorbell.missed` 计数(设计稿 §6.5,v1.5 M5)。帧级的丢弃与迟到只能用 fake transport 测,URLProtocol 拦截不到 `URLSessionWebSocketTask`。

## Token 续期

- event `access_token`,payload `{ "access_token": "<new jwt>" }`,带 join_ref。成功**无回复**;失败来一条 `system` error 然后 `phx_close`。
- 「If a new JWT is never received on the Channel, the client will be disconnected when the JWT expires」→ 在 `AuthService` 每次 `installSession` 后推一次,且在 `exp - 5 min` 前主动推。**推送机制已实现,接线未做**(slice 1 `a95690b`):`credentialsDidChange()` 在 join 状态下、同一 uid 的 token 变了就带内推 `access_token`(`SupabaseRealtimeDoorbell.swift:376-383`);但它在 `a95690b` 上零调用者(`git grep -n credentialsDidChange a95690b -- Done` 只有定义 `:377` 与 `:406` 的一处注释),没有人订阅 `$session` 调它——这条订阅(含 nil 在内的每次发射都调)是 Phase 1 交付项(设计稿 §6.4、§9.11)。刷新本身是按需的:每个 REST 请求前剩余不足 300 s 就刷新(`AuthService.swift:262`),前台 60 s 轮询保证 exp 之前至少有一次请求。接上之后,同 uid 的发射不重建连接、不取消在途拉取(设计稿 §6.4)。

## 错误分类(照抄文档的处置)

| 类别 | code | 动作 |
|---|---|---|
| Token 过期 | `InvalidJWTExpiration` | 刷新 token 后 rejoin |
| Token 无效 **或 topic 不是本人的**(同 code,台架) | `MalformedJWT` / `JwtSignatureError` / `Unauthorized` | **不重试**;`Unauthorized` 记日志含完整 `reason`(消息文本是唯一能分开两者的东西),其余交给 AuthService 的终端判定 |
| 限流 | `ConnectionRateLimitReached` / `ClientJoinRateLimitReached` / `ChannelRateLimitReached` | backoff |
| 数据库 | `InitializingProjectConnection` / `IncreaseConnectionPool` / `DatabaseLackOfConnections` / `UnableToConnectToProject` | 指数 backoff |
| 配置 | `TopicNameRequired` / `TenantNotFound` / `RealtimeDisabledForTenant` / `RealtimeDisabledForConfiguration` | **不重试** |
| 瞬时 | `RealtimeRestarting` | backoff 重试 |

- `system` 事件 payload:`{ "message", "status": "ok"|"error"|"timeout", "extension", "channel" }`。channel 级 system error **必跟一条 `phx_close`**;`message` 里要认的:`Token has expired`(刷新后 rejoin)、`Too many messages per second`(节流)、`Server requested disconnect`。
- `phx_error` = channel 进程异常终止 → 指数 backoff 后 rejoin(JS SDK 用 `[1000, 2000, 5000, 10000]` ms,上限 10 s)。
- 没有前置 system error 的 `phx_close` 是干净关闭。
- 关闭帧在 join 前到达 = 连接级错误(apikey 错、tenant 不存在)。

## 服务端半(migration 015 要做的)

```sql
-- 发送:payload jsonb, event text, topic text, is_private boolean
-- v2:语句级触发器(referencing new table as changed),每条语句、每个 user 一帧
perform realtime.send(jsonb_build_object('table', tg_table_name, 'seq', r.seq), 'change', 'user:' || r.user_id::text, true);

-- 接收授权:只能订阅自己的 topic
create policy "own sync topic" on realtime.messages
  for select to authenticated
  using ( realtime.topic() = 'user:' || (select auth.uid())::text );
```
- `realtime.messages` 按天分区,**3 天后删除**;广播消息存在那里。join 时预建「昨天、今天和之后三天」的分区、约每 3–4 h 刷新,失败只出现在反正也没人收的时候——午夜分区**不会**丢门铃(调研 §B.4 C7)。
- **policy 恰好一行**(设计稿 v1.5,S9(c)):宽松 policy 之间按 OR 合并,`realtime.messages` 上再多一条 `USING (true)` 的示例 policy 就打开了所有人的 topic。验后检查查 `pg_policies` 里它恰好一行(`own sync topic`,SELECT),不只查「它在」。
- **Dashboard「Allow public access」——纵深防御,不是前置**(台架证伪了上一版的「否则 `private` 不被强制」):本地栈 realtime v2.82.0、`_realtime.tenants.private_only = false`(即开关 ON 的等价状态)下,`private: true` 的 channel **已经**按 `realtime.messages` 的 RLS 强制——外人 join 被拒、外人账号的插入零帧漏出。那个开关禁的是**公开** channel 的存在,不是给私有 channel 开启检查。生产上仍关掉它(我们没有公开 channel,少一个面),但 Phase 1 的正确性不依赖它。
- 授权在 **join 时**判一次(插一条再回滚);连接期间缓存,`access_token` 事件会重算。RLS 复杂度直接影响 join 延迟,所以策略只比一个字符串。
- `realtime.send` 第四参数:文档 prose 说默认私有,但示例全传 `false`(公开)。**显式传 `true`。**

## 配额(Free / Pro)

| 项 | Free | Pro |
|---|---|---|
| 并发连接 | 200 | 500 |
| 消息 / s | 100 | 500 |
| 广播 payload | 256 KB | 3 MB |
| channel join / s | 100 | 500 |
| 每连接 channel 数 | 100 | 100 |

我们的形态:每用户每前台设备 1 连接 1 channel,payload < 200 B。3 个用户离任何上限都差两个数量级。

## 不用 postgres_changes 的实测依据(D1)

- 每条变更对**每个订阅者**跑一次 RLS 读(「100 users subscribed … a single insert … 100 reads」),且「processed on a single thread」。
- 「Delete events are not filterable」;RLS 下 DELETE 的 `old_record` 只有主键。tombstone 设计下我们根本不发 DELETE,但这条说明 postgres_changes 的删除语义对带过滤的订阅是未定义的。
- 文档自己的推荐:「Broadcast. This is the recommended method for scalability and security.」

## 未载明、需实测

- `realtime.broadcast_changes(...)` 投递到客户端的 JSON 形状(我们不用它,用 `realtime.send` 自定 payload,规避)。
- ~~RLS 拒绝 join 时 `reason` 的确切字符串~~ → **已实测**(台架):`Unauthorized: You do not have permissions to read from this Channel topic: user:<uid>`,见「phx_join payload」与错误分类表。
- ~~`realtime.send` 投递到客户端的内层 payload 是否原样~~ → **已实测**:多一个 `"id"` 键,见「收到的广播」。
- 服务端对 heartbeat 的回复形状(实现上只需「25 s 内发一次」,不依赖回复;台架脚本也没断言它)。
- 以上台架值来自本地栈的 realtime 版本;生产的 realtime 版本由 Supabase 滚动,`reason` 文本与 `id` 键的存在不做硬断言,只做日志。
