# freekill-asio-sengoo

- 原项目仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库：上述项目的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

当前仓库公开历史仅保留核心实现代码与必要脚本。  
文档资产、OpenSpec 资产与测试资产不在当前发布历史中。

## 当前状态

当前默认生产路径为 **native 常驻服务**，不依赖 Python 进程托管。

已落地能力（核心）：
- 原生运行入口（常驻循环）
- TCP/UDP 监听与回显处理（9527/9528）
- 构建、健康检查、验收、soak、release gate 脚本
- Windows 计划任务 / Linux systemd 安装脚本

## 目录

- `src/`：Sengoo 业务与运行时入口
- `scripts/`：构建、启动、健康检查、验收、发布脚本
- `release/`：本地构建产物输出目录

## 快速开始（Windows）

1. 构建 native 产物

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_native_release.ps1
```

2. 后台启动（常驻）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_runtime_host_native.ps1 -Detached
```

3. 健康检查（进程 + 端口）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/healthcheck_runtime_host_native.ps1
```

4. 停止进程

```powershell
Get-Process -Name "freekill-asio-sengoo-runtime" -ErrorAction SilentlyContinue | Stop-Process -Force
```

## 验收与闸门

- Native 验收：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance_native.ps1
```

- Native soak：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_soak_native.ps1 -DurationSeconds 60
```

- Release gate：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60
```

## 发布产物

默认输出：
- `release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe`
- `release/native/windows-x64/config/runtime_host.config.json`
- `release/native/windows-x64/scripts/start_runtime_host.ps1`
- `release/native/windows-x64/scripts/healthcheck_runtime_host.ps1`
- `release/native/windows-x64/scripts/install_runtime_host_service.ps1`
- `release/native/windows-x64/scripts/uninstall_runtime_host_service.ps1`
- `release/native/windows-x64/manifest.json`
- `release/native/windows-x64/checksums.sha256`

## 服务化部署

- Windows（计划任务）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_runtime_host_windows_task_native.ps1 -StartNow -Force
```

- Linux（systemd）：

```bash
sudo bash scripts/install_runtime_host_systemd_native.sh
```

## 构建前提

- `clang` 可用（native 链接需要）
- `sgc` 可用（默认路径：`C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe`）
- 若 `sgc` 无法定位正确 runtime C 文件，可设置：

```powershell
$env:SENGOO_RUNTIME = "绝对路径\\runtime.c"
```

## 已知限制

- `sgc build` 当前无 `--target`，跨平台构建需在目标平台执行
- Lua/SQLite/Protobuf 端到端生产链路仍需按环境逐步扩展
