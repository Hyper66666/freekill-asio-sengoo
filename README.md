# freekill-asio-sengoo

- 项目原仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库：上述项目的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

当前仓库公开历史仅保留核心实现代码与必要脚本。
文档资产、OpenSpec 资产与测试资产不在当前发布历史中。

## 当前状态

当前默认生产路径是 **native 常驻服务**（不依赖 Python 托管进程）。

已落地能力：
- Sengoo native 入口与常驻事件循环（TCP/UDP 默认端口 9527/9528）
- native 构建、健康检查、验收、soak、release gate
- Windows 计划任务 / Linux systemd 安装脚本
- 包管理兼容命令：`install/remove/pkgs/syncpkgs/enable/disable/upgrade`
- 包兼容预检：`packages/init.sql` + `packages/freekill-core/lua/server/rpc/entry.lua`
- Lua 扩展生命周期链路：`discover/load/call/hot_reload/unload`
- 原生 Protobuf/RPC 回归（PowerShell，无 Python）
- 扩展实测矩阵（逐扩展 install/enable/run/hot_reload/unload/upgrade）
- ABI/Hook 清单、映射与校验脚本（可接 release gate enforce）

## 目录结构

- `src/`：Sengoo 实现代码
- `scripts/`：构建、运行、验收、发布、包管理与兼容校验脚本
- `scripts/fixtures/`：回归/矩阵用例数据
- `packages/`：包目录（含 `init.sql`、`packages.registry.json`、`freekill-core` 结构）
- `release/`：本地构建产物

## 环境依赖

- `sgc`（Sengoo 编译器）
- `clang`（native 链接）
- `git`（包安装/升级）

说明：
- native 主路径默认不依赖 Python。
- `scripts/build_native_release.ps1` 会优先使用仓库内 `runtime/runtime.c`（包含实时 `print` 刷新修复）。
- 如果 `sgc` 不能自动定位 runtime C 文件，可设置：

```powershell
$env:SENGOO_RUNTIME = "绝对路径\\runtime.c"
```

## 快速开始（Windows）

1. 构建 native 产物。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_native_release.ps1
```

2. 初始化包目录。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_manager_native.ps1 -Command init
```

3. 安装核心包（请替换为真实仓库）。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_manager_native.ps1 -Command install -Url https://github.com/<org>/freekill-core.git
```

4. 包兼容预检。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_package_compatibility_native.ps1
```

5. 后台启动 native 服务。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_runtime_host_native.ps1 -Detached
```

前台直接看实时输出（不静默）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_runtime_host_native.ps1
```

前台日志为文本格式（接近原服风格）：
- `[YYYY-MM-DD HH:MM:SS][INFO][SERVER] server is starting`
- `[YYYY-MM-DD HH:MM:SS][INFO][NET] server is ready to listen on [0.0.0.0]:9527`
- `[YYYY-MM-DD HH:MM:SS][INFO][NET] udp is ready to listen on [0.0.0.0]:9528`
- `[YYYY-MM-DD HH:MM:SS][INFO][NET] client <ip>:<port> connected ...`
- `[YYYY-MM-DD HH:MM:SS][INFO][NET] client disconnected ...`

客户端首次 TCP 连接后，服务端会主动下发扩展同步首包：

```json
{"event":"extension_sync","registry":[{"name":"freekill-core","enabled":true,"builtin":true}]}
```

说明：
- 通过 `scripts/start_runtime_host_native.ps1` 启动时，会自动扫描扩展并生成同步注册表（默认输出 `.tmp/runtime_host/extension_sync.registry.json`）。
- 扫描根目录包含 `packages/` 与 `packages/packages/`（后者用于兼容你现在的嵌套扩展布局）。
- 发现规则（按优先级）：`lua/server/rpc/entry.lua` -> `init.lua` -> `lua/init.lua`，任一存在即纳入同步列表。
- 这允许直接同步多数原仓库包结构（如 `standard`、`maneuvering`、`standard_cards` 这类 `init.lua` 包）。
- 自动将生成的注册表路径注入 `SENGOO_EXTENSION_REGISTRY` 环境变量给 native runtime。
- 如果不走启动脚本而是直接运行 exe，默认读取 `packages/packages.registry.json`。
- 自动去除 UTF-8 BOM，避免客户端解析异常。
- 当注册表为空/缺失时，若存在 `packages/freekill-core/lua/server/rpc/entry.lua`，会回退同步 `freekill-core` 基线扩展信息。
- native runtime 会按注册表尝试执行扩展引导钩子（优先调用 `on_server_start`，其次 `bootstrap` / `init`），用于把原生 Lua 扩展接入服务启动链。
- 可通过环境变量 `SENGOO_EXTENSION_BOOTSTRAP=0` 关闭该行为；Lua 解释器路径可用 `SENGOO_LUA_EXE` 指定（默认 `lua5.4`）。

默认会写入日志文件（可直接排障）：
- 事件日志：`.tmp/runtime_host/native_runtime.events.log`
- 标准输出：`.tmp/runtime_host/native_runtime.stdout.log`
- 错误输出：`.tmp/runtime_host/native_runtime.stderr.log`

查看日志：

```powershell
Get-Content .tmp/runtime_host/native_runtime.events.log -Tail 50
Get-Content .tmp/runtime_host/native_runtime.stderr.log -Tail 50
```

6. 健康检查。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/healthcheck_runtime_host_native.ps1
```

7. 停止服务进程。

```powershell
Get-Process -Name "freekill-asio-sengoo-runtime" -ErrorAction SilentlyContinue | Stop-Process -Force
```

## 核心验收与回归脚本

- Native 验收：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance_native.ps1
```

- 包管理 smoke：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_manager_smoke_native.ps1
```

- Lua 生命周期 smoke：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/lua_extension_lifecycle_smoke_native.ps1
```

- Protobuf/RPC 原生回归：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_protobuf_rpc_regression_native.ps1 -StartRuntime
```

- 扩展实测矩阵：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_extension_matrix_native.ps1
```

真实仓库模式（推荐）：
- 编辑 `scripts/fixtures/extension_matrix_targets.json`，填入真实扩展仓库 `name/url`。
- 然后执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_extension_matrix_native.ps1 -TargetsPath scripts/fixtures/extension_matrix_targets.json
```

离线本地夹具模式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_extension_matrix_native.ps1 -UseLocalFixture
```

- ABI/Hook 校验（默认只出报告；加 `-Enforce` 才会阻断）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate_extension_abi_hook_compatibility.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate_extension_abi_hook_compatibility.ps1 -Enforce
```

- Native soak：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_soak_native.ps1 -DurationSeconds 60
```

- Release gate：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60
```

指定真实扩展矩阵目标清单：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60 -ExtensionMatrixTargetsPath scripts/fixtures/extension_matrix_targets.json
```

- 最终替换门禁（启用 ABI/Hook enforce）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_replacement_gate_native.ps1 -SoakDurationSeconds 60
```

## Release Gate 覆盖项

`runtime_host_release_gate.ps1`（native 模式）当前覆盖：
- native acceptance
- package compatibility
- ABI/Hook compatibility（支持 `-EnforceAbiHookCompatibility`）
- Lua lifecycle smoke
- Protobuf/RPC regression
- extension matrix
- dependency audit
- native soak

## 发布产物

默认输出目录：`release/native/windows-x64/`

关键产物：
- `bin/freekill-asio-sengoo-runtime.exe`
- `config/runtime_host.config.json`
- `scripts/start_runtime_host.ps1`
- `scripts/healthcheck_runtime_host.ps1`
- `scripts/install_runtime_host_service.ps1`
- `scripts/uninstall_runtime_host_service.ps1`
- `scripts/package_manager.ps1`
- `scripts/check_package_compatibility.ps1`
- `scripts/package_manager_smoke.ps1`
- `scripts/lua_extension_lifecycle.ps1`
- `scripts/lua_extension_lifecycle_smoke.ps1`
- `scripts/run_protobuf_rpc_regression.ps1`
- `scripts/run_extension_matrix.ps1`
- `scripts/runtime_host_replacement_gate.ps1`
- `scripts/build_extension_abi_hook_inventory.ps1`
- `scripts/build_extension_abi_hook_compat_map.ps1`
- `scripts/validate_extension_abi_hook_compatibility.ps1`
- `scripts/fixtures/protobuf_rpc_regression_cases.json`
- `scripts/fixtures/extension_matrix_targets.json`
- `scripts/fixtures/extension_matrix_targets.example.json`
- `packages/init.sql`
- `packages/packages.registry.json`
- `manifest.json`
- `checksums.sha256`

## 服务化部署

- Windows（计划任务）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_runtime_host_windows_task_native.ps1 -StartNow -Force
```

- Linux（systemd）：

```bash
sudo bash scripts/install_runtime_host_systemd_native.sh
```

## 当前约束

- 现阶段已经具备 native 可执行发布与无 Python 主链路运行能力。
- “可替换原服”的最终门禁仍应以：ABI/Hook、Lua 生命周期、Protobuf/RPC、扩展矩阵、性能稳定性全部达标为准。
- `packages/freekill-core/lua/server/rpc/entry.lua` 在仓库内是结构占位，生产环境应替换为真实核心包内容。
