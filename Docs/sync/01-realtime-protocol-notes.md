# Supabase Realtime — 裸客户端实现笔记

来源:Supabase 文档(Protocol / Broadcast / Authorization / Postgres Changes / Reports / Benchmarks),2026-10-08 摘录;2026-10-14 按本地台架实测修订(`done-mcp/supabase/tests/sync_feed_checks.sh` S12,裸 websocket 对 `supabase start` 栈的 realtime v2.82.0,`6f293a8`)。只留实现 `RealtimeDoorbell` 需要的 wire shape;标「**未载明**」的字段文档里没有,要实测;标「**台架**」的是实测值,不是文档。

## 连接

- URL:`wss://<PROJECT_REF>.supabase.co/realtime/v1/websocket?apikey=<API_KEY>&vsn=1.0.0`
  - `vsn` 取 `1.0.0`(JSON 对象信封)或 `2.0.0`(JSON 数组 `[join_ref, ref, topic, event, payload]` + 二进制帧)。**用 1.0.0**:只有文本帧,`URLSessionWebSocketTask` 直接 JSON 编解码。
  - `apikey` 用 `sb_publishable_…`。**它不能当 `access_token`**:「Tokens with the `sb_*` prefix are silently ignored」;私有 channel 必须带用户 JWT(需含 `role` 与 `exp` claim,GoTrue 的都有)。
- 连上后必须先 `phx_join` 才会收到任何东西。
- **Heartbeat**:topic `phoenix`,event `heartbeat`,payload `{}`,**至少每 25 s 一次**,否则连接超时。实现取 20 s。
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
- DB 发起的广播**所有订阅者都收**,包括引起写入的那台设备(`broadcast.self` 只管客户端自发的 push)→ v2 不做发送者标识:自己的写回拉下来后与本地内容一致,被设计稿 §6 的三方比较判为「无事」。

## Token 续期

- event `access_token`,payload `{ "access_token": "<new jwt>" }`,带 join_ref。成功**无回复**;失败来一条 `system` error 然后 `phx_close`。
- 「If a new JWT is never received on the Channel, the client will be disconnected when the JWT expires」→ 在 `AuthService` 每次 `installSession` 后推一次,且在 `exp - 5 min` 前主动推。

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
- `realtime.messages` 按天分区,**3 天后删除**;广播消息存在那里。
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
