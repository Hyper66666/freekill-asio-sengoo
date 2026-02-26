# freekill-asio-sengoo

- 原项目仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库：以上项目的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

当前仓库公开历史仅保留核心实现代码与必要脚本。  
文档资产、OpenSpec 资产与测试资产不在当前发布历史中。

## 当前状态

当前主线已提供原生（native）发布路径，生产闸门默认走 native，不再依赖 Python 数据面进程。

已落地能力：
- 原生 runtime 入口（确定性退出码）
- TCP/UDP 连接管理与事件循环状态路径
- async 调度与 backpressure 限流路径
- codec/Lua/SQLite/路由稳定性指标接入 native 执行流
- 原生 acceptance + dependency audit + soak + release gate
- Windows/Linux 原生安装脚本（计划任务 / systemd）

## 目录

- `src/`：Sengoo 业务与运行时逻辑
- `scripts/`：构建、验收、发布与安装脚本
- `release/`：发布范围、布局、弱机基线、迁移清单

## 快速开始（Native）

1. 构建原生产物

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_native_release.ps1
```

2. 运行原生验收

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance_native.ps1
```

3. 运行发布闸门（含 native soak）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60
```

4. 一键完整验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_native_release.ps1 -SoakDurationSeconds 60
```

## 原生发布产物

默认输出目录：
- `release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe`
- `release/native/windows-x64/config/runtime_host.config.json`
- `release/native/windows-x64/scripts/start_runtime_host.ps1`
- `release/native/windows-x64/scripts/healthcheck_runtime_host.ps1`
- `release/native/windows-x64/scripts/install_runtime_host_service.ps1`
- `release/native/windows-x64/scripts/uninstall_runtime_host_service.ps1`
- `release/native/windows-x64/manifest.json`
- `release/native/windows-x64/checksums.sha256`

## 服务化部署

Windows（计划任务）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_runtime_host_windows_task_native.ps1 -StartNow -Force
```

Linux（systemd）：

```bash
sudo bash scripts/install_runtime_host_systemd_native.sh
```

健康检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/healthcheck_runtime_host_native.ps1
```

## 回滚（到旧 Python 托管路径）

1. 卸载 native 服务
- Windows：`scripts/uninstall_runtime_host_windows_task_native.ps1`
- Linux：`scripts/uninstall_runtime_host_systemd_native.sh`

2. 恢复旧服务
- Windows：`scripts/install_runtime_host_windows_task.ps1`
- Linux：`scripts/install_runtime_host_systemd.sh`

3. 运行旧闸门

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -UseLegacyPythonAcceptance
```

## 已知限制

- `sgc build` 当前 CLI 无 `--target` 参数，因此跨平台（尤其 Linux 目标）需要在对应平台或具备交叉工具链能力的环境执行构建验证。
- 旧 Python 脚本仍保留用于迁移期诊断，但不再是默认生产闸门路径。
