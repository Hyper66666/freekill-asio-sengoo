# freekill-asio-sengoo

## 项目来源与定位

- 原项目仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库定位：`freekill-asio` 的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

本仓库在目录与 git 历史上与原 C++ 项目隔离，目标是把 `freekill-asio` 的服务端能力迁移为可验证、可对比、可落地替换的 Sengoo 实现，并保留从契约到运行时再到主仓迁移的完整证据链。

## 重写完成状态（摘要）

- `src/**/*.cpp` 到 `src/**/*_sg/*.sg` 的迁移映射已完成
- M1-M6 契约层模块与烟测门禁已完成
- Runtime parity 工具链已完成（collector/scaffold/builder/pipeline/harness）
- 真实端点 live probe 验收链路已完成
- runtime-host 端到端执行链已完成（TCP I/O、protobuf 回归、sqlite 持久化、线程路由、Lua 热加载路径）
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

### 3. 运行时对齐工具链（`tests/runtime/`）

- `collect_runtime_cases.ps1`：从 JSON/JSONL 事件流采集里程碑 case
- `scaffold_runtime_cases.ps1`：初始化双运行时 case 结构
- `build_runtime_artifact.ps1`：构建统一 artifact 报告
- `runtime_parity_harness.ps1`：legacy vs sengoo 比对核心
- `run_runtime_parity_pipeline.ps1`：一键 pipeline
- `run_runtime_acceptance.ps1`：离线证据入口
- `run_live_runtime_acceptance.ps1`：在线探针入口
- `run_runtime_host_e2e_acceptance.ps1`：host 级端到端验收入口

### 4. 验收门禁与证据

- 契约/模块门禁：`tests/smoke/*`
- 全量门禁：`tests/smoke/run_all_smoke.ps1`
- 重写完成门禁：`tests/smoke/rewrite_completion_smoke.ps1`
- runtime host e2e 门禁：`tests/smoke/runtime_host_e2e_smoke.ps1`
- 迁移计划门禁：`tests/smoke/mainline_migration_plan_smoke.ps1`

## 文档索引（建议阅读顺序）

- `docs/MILESTONES.md`：里程碑状态与门禁
- `docs/RUNTIME_PARITY_CHECKLIST.md`：M2-M6 运行时对齐清单
- `docs/LIVE_RUNTIME_ACCEPTANCE.md`：live probe 采证规范
- `docs/RUNTIME_HOST_E2E_ACCEPTANCE.md`：runtime-host 端到端验收
- `docs/MAINLINE_MIGRATION.md`：迁移到主仓的 dry-run/apply 操作手册
- `docs/MIGRATION_MAP.md`：cpp->sg 映射总表

## 本地验证命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/run_all_smoke.ps1
```

可选单项：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_host_e2e_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/rewrite_completion_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/mainline_migration_plan_smoke.ps1
```

如本机已安装 `sgc`，可直接检查入口模块：

```powershell
sgc check src/main.sg
```
