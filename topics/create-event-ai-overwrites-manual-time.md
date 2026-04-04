# 【calendar】创建事件后，AI 解析前移动事件时间会被 AI 解析覆盖

## Background

- 当前 calendar 创建链路仍保留独立的 agentic create 路径。
- 已确认产品方向是默认回到表单创建，并把 agentic create 中最有价值的 type 判断能力并回表单。
- 现有异步 autofill 会在分析完成后整包回写事件字段，导致用户在 AI 返回前手动改过的时间可能被覆盖。

## Discussion Summary

- 普通 calendar 创建默认走表单，不再把 agentic create 作为默认入口。
- 如果用户没有显式选择 type，则允许在表单保存后异步补全 type。
- 这次自动补全的主要目标是帮助用户尽快得到合理的 `type`，并同步更新 `suggested log template`。
- 推断方案改成历史 event 经验优先，冷启动时再辅以本地关键词规则，LLM 仅在本地无法可靠命中时兜底。

## Decisions

- 普通创建入口统一改成表单。
- `calendarAgenticCreateEnabled` 的用户可见语义改成控制 AI type suggestion，而不是切换创建模式。
- 表单保存后的异步补全仅在用户没有显式选择 type 时触发。
- 表单后置补全只允许自动更新 `type` 和 `suggested log template`。
- 自动选中的 `type` 必须始终来自当前 event type 模板库，不允许 AI 或本地逻辑引入库外新 type。
- 旧 agentic autofill 至少不能再覆盖事件时间。

## In Scope

- 普通创建入口改成默认表单。
- 表单保存后置 type inference。
- 历史 event 映射、本地关键词兜底和 LLM fallback。
- 防止 AI 异步结果覆盖用户手动改过的时间。
- 更新 topic backlog / understanding / per-topic summary。

## Out of Scope

- 完整删除所有 agentic create 相关代码。
- 重做 interrupt create 的整套交互。
- 新的复杂检索、向量匹配或额外的长期 type 学习持久化机制。

## Execution Notes

- `CalendarPageView` 的普通创建入口已统一改成 `CreateCalendarEventView`，不再由 `calendarAgenticCreateEnabled` 切换到独立 `CalendarAgenticCreateView`。
- `calendarAgenticCreateEnabled` 的用户可见语义已改成设置页中的 “AI type suggestions after save”；Header 不再提供这个 toggle。
- 创建表单不再展示 `Auto` tag。设置开启时，表单会在输入过程中优先根据已有 calendar events 的历史经验即时预选具体 type，并支持 title 前缀 / 半个词阶段就开始切换；历史样本不足时才退回本地关键词规则。用户一旦手动点选某个 type，本次表单就停止自动改写。
- `CalendarEventFormData` 继续显式携带 `didExplicitlySelectType`，但现在由“用户是否手动点过 type”决定。
- 新增 `CalendarEventTypeInferenceService`，在表单保存后执行 “历史 event 映射 / 本地关键词优先，LLM fallback” 的 type inference，并且只允许自动更新 `type` 与 `suggested log template` 相关字段。
- `AgenticCalendarIntakeService` 的 `generateTypeSuggestion(rawText:availableTypes:)` 现在只允许返回当前 type 模板库中的 existing type；即使旧 agentic autofill 临时保留，AI 也不能再自动产出库外新 type。
- legacy `CalendarAgenticCreateCoordinator` 的异步 autofill 回写范围已收窄为 `type + suggested log template + intake metadata`，不再覆盖 `timeRanges`，也不再改 `title / note / location / repeat* / isAllDay`。
- 已新增 `CalendarEventTypeInferenceServiceTests`，并调整 `AgenticCalendarAutofillNormalizerTests` 使其验证“时间保持不变、type 可更新”的新行为。
- 验证上，generic iOS build 已通过；focused simulator tests 多次尝试后仍在当前环境里卡在 `xcodebuild test` 启动前阶段，未拿到可用的 XCTest 完成结果。

## Impact on Understanding

- 普通 calendar 创建将以表单为默认入口。
- AI type suggestion 变成表单后的补全能力，而不是独立创建模式。
- 输入期的自动 type 预选依赖已有 calendar events 的历史经验，且结果必须落在现有 type 库内。
- AI 异步回写不应再覆盖用户已经手动确认过的时间。
- legacy agentic create 即使暂时保留，也只能安全补全 `type` 和日志模板建议，不能再反向改写用户已经确认过的核心表单字段。
