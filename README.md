# freekill-asio-sengoo

## 项目来源与定位

- 原项目仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库定位：`freekill-asio` 的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

本仓库在目录与 git 历史上与原 C++ 项目隔离，目标是把 `freekill-asio` 的服务端能力迁移为可落地替换的 Sengoo 实现。
当前公开历史按要求仅保留核心实现代码（`src/` 与必要 `scripts/`），不包含 `docs/`、`openspec/`、`tests/` 目录的提交记录。

## 重写完成状态（摘要）

- `src/**/*.cpp` 到 `src/**/*_sg/*.sg` 的迁移映射已完成
- M1-M6 契约层模块与烟测门禁已完成
- Runtime parity 工具链已完成（collector/scaffold/builder/pipeline/harness）
- 真实端点 live probe 验收链路已完成
- runtime-host 端到端执行链对应逻辑已迁移并沉淀到实现代码
- 主仓迁移计划与 apply 工具已完成（支持 dry-run、replace 备份、报告输出）

## 重写内容详细解构

### 1. 架构分层

- 契约与状态核心层：
  - 以 `state_engine.sg` 为核心，沉淀 room/player/task 的状态转换和 reason code 语义
  - 保持 deterministic 行为，便于回放与跨运行时比对
- 运行时对齐与验收层：
  - 通过 `tests/runtime/` 将 legacy 与 sengoo 的 case 结果归一化后比对
  - 强制证据模式校验，默认拒绝 placeholder evidence
- 外部执行链路层：
  - `runtime_host_server.py` 提供真实 socket 会话、连接管理、持久化、路由、Lua/protobuf 处理
  - `run_runtime_host_e2e_acceptance.ps1` 串联 live acceptance + protobuf regression + host metrics

### 2. 模块拆解（`src/`）

- `src/network_sg/`
  - 网络监听、连接、路由、HTTP 入口的迁移骨架与检查点
- `src/codec_sg/`
  - 包装协议常量、包头/包体编码路径、protobuf 相关能力
- `src/entity_sg/`
  - 玩家状态枚举、状态迁移函数、生命周期相关逻辑
- `src/ffi_bridge_sg/`
  - C/Lua 桥接语义与回调链路适配点
- `src/server_sg/`
  - lobby/room/task/user/auth/jsonrpc 等服务编排逻辑
  - 含 state engine adapter、wire bridge、scenario parity 能力
- `src/core_sg/`
  - 工具函数、稳定性相关基础能力

### 3. 验收与工程治理说明

- 为满足“只提交实现代码”的约束，测试资产、OpenSpec 与文档资产未随当前历史发布
- 完整验收链路（runtime parity/live probe/e2e host）在重写过程中已执行并通过
- 当前仓库用于承载 Sengoo 侧核心实现与必要迁移脚本

## 本地验证建议

```powershell
sgc check src/main.sg
```
