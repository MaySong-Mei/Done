# 【performance】点击事件弹出表单速度很慢

## Background

- backlog 记录过点击事件后弹出表单较慢的问题。
- 该项一直作为 P0 性能问题存在，但本轮没有单独展开 profiling 或架构重构。

## Discussion Summary

- 该项于 2026-04-04 在 backlog 清理中重新审视。
- 本轮没有围绕这个 topic 进行新的性能分析、benchmark 或 modal 流程改造。
- 用户确认当前 build 中点击事件打开表单的体验看起来已经恢复正常，因此该项关闭为历史问题。

## Decisions

- 该 topic 作为历史 backlog 项关闭，不做新的实现。
- 如果后续再次出现明显延迟，应以新的 topic 重新记录，并附带入口路径、设备/构建信息与大致耗时体感。

## In Scope

- backlog 清理与结论记录。

## Out of Scope

- 新的性能 profiling。
- event modal / preload / storage 相关架构改造。
- 没有明确现象前提下的预防性性能优化。

## Execution Notes

- No implementation required. Topic closed on 2026-04-04 because the issue appears fixed in the current build.
- 本次关闭依据用户确认，而不是新的 profiling 数据或自动化性能测试。

## Impact on Understanding

- 当前活跃 P0 已不再包含这个历史表单打开性能项，优先级重新集中到剩余的 calendar drag 相关问题。
