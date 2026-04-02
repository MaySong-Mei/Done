# Topics

## P0 — Bug / 体验阻塞（必须优先）

- [ ] 【performance】点击事件弹出表单速度很慢
- [ ] 【bug】横屏模式的黑白切换和系统不一致
- [ ] 【bug】横屏模式排版有显示 bug
- [ ] 【bug】type 拖拽不丝滑
- [ ] 【calendar】small event drag logic 有问题，可能和调整 time range 产生竞态
- [ ] 【calendar】30min minimum bug
- [ ] 【calendar】创建事件后，AI 解析前移动事件时间会被 AI 解析覆盖
- [x] 【calendar】extended drag creation 会导致结束 extension 直接跳转
- [ ] 【calendar】横屏状态下会自动熄屏
- [x] 【search】搜索系统现在都反馈 no result，主要搜 note

## P1 — 核心架构问题（必须尽早决定）

- [ ] 【calendar】event 发送到 calendar 是否需要 end time，还是只需要日期
- [ ] 【calendar】预加载逻辑重构 + event modal + 存储逻辑重新设计
- [ ] 【calendar】创建事件时用 API 自动判断类型，并且取消 agentic creation
- [ ] 【calendar】并行事件快捷创建 / UI 显示逻辑
- [ ] 【calendar】event 子事件（由母事件 extend 出来的事件）
- [ ] 【calendar】interrupt 交互改时间、改 type 很困难
- [ ] 【calendar】calendar tool 的 create 是否换成 range
- [ ] 【calendar】tool capsule 内容需要重新规划（部分应合并到设置）

## P2 — 核心功能（MVP 完整性）

- [ ] 【calendar】recording 模式
- [ ] 【calendar】recording 模式记录 effort 影响颜色深度
- [ ] 【calendar】快捷 log 系统
- [ ] 【calendar】照片等应该集成在 log 中
- [ ] 【task】快速录入（语音 / 拍照）
- [ ] 【calendar】todo 载入逻辑，上翻滚进入加载
- [ ] 【calendar】AI suggestion 定时消失
- [ ] 【calendar】记录模板设计（是否需要 template store）

## P3 — UI / 交互体验优化

- [ ] 【calendar】过度收缩释放弹性特效
- [ ] 【calendar】事件点击进入小 modal（类似 Apple Calendar）
- [ ] 【calendar】Pinch 缩小范围需要更小
- [ ] 【calendar】single event 高亮逻辑（区分 single / recurrent）
- [ ] 【calendar】事件块外观优化（1 级标题 / 2 级标题适配 small event）
- [ ] 【calendar】all day event 永久占位问题
- [ ] 【calendar】private 模式（隐藏具体内容方便分享）
- [ ] 【calendar】横屏进入是否需要自动切换
- [ ] 【calendar】设置中增加黑白模式 / 跟随系统
- [ ] 【calendar】haptic 提醒用户开启

## P4 — 系统能力 / 平台能力

- [ ] 【app】memory 系统设计
- [ ] 【calendar】token 系统试用并设计
- [ ] 【calendar】MCP 接入
- [ ] 【system】耳机 / watch 兼容
- [ ] 【app】没有手表模式

## P5 — 产品策略 / 方向思考

- [ ] 【analysis】today 可以包含 ongoing 事件
- [ ] 【analysis】你是谁的基础设定
- [ ] 【calendar】可选记录内容
- [ ] 【calendar】是否允许用户自定义颜色
- [ ] 【calendar】取消 streak

## Notes

- 优先从更高优先级分组中选择 topic，再在该分组内挑选更适合当前推进的项。
- 每个 topic 完成后创建或更新对应的 `topics/<slug>.md` 总结文件。
- topic 完成后同步更新 `topics/understanding.md`，并将 `- [ ]` 改为 `- [x]`。
