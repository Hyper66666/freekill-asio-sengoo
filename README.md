# freekill-asio-sengoo

## 项目说明
- 原仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库：以上项目的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

## 当前状态（重要）
结论：当前版本已经达到“可部署运行”状态，可以直接在服务器上运行。  
但运行形态不是单一可执行二进制，而是：
- Sengoo 模块：通过 `sgc check` 做类型/契约检查
- 运行时服务：通过 Python 进程执行（`scripts/runtime_host_server.py` 与 `scripts/runtime_host_watchdog.py`）

当前主线已通过发布闸门脚本：
- `scripts/runtime_host_release_gate.ps1`
- 包含：基础验收 + 配置验收 + watchdog 重启验收 + soak 压测验收

## 已实现能力范围
- TCP/UDP 网络 I/O 生命周期（连接、收发、关闭、计数）
- 事件循环与定时调度（tick/poll/async budget/backpressure）
- 数据包编解码路径（JSON + Protobuf 二进制回归路径）
- Lua FFI 桥接与热重载（同步/异步调用与计数）
- SQLite 持久化（事务、查询、写入、commit/rollback 指标）
- watchdog 进程守护（健康探针失败重启、异常退出重启）
- Windows/Linux 服务化部署脚本（计划任务/systemd）

## 环境要求
- Python 3.10+（建议 3.11/3.12）
- Windows PowerShell 5+（Windows 部署脚本）
- Linux `systemd` + `bash`（Linux 部署脚本）
- Sengoo 编译器 `sgc`（用于模块检查）
- 可选依赖：`protobuf`
  - 如果需要完整 Protobuf 回归路径，安装：
  - `pip install protobuf`
- 网络要求：
  - 开放配置中的 TCP/UDP 监听端口
  - 允许本机健康探针访问监听端口

## 目录结构
- `src/`：Sengoo 业务模块（网络/编解码/FFI/服务状态机）
- `scripts/runtime_host_server.py`：运行时主服务
- `scripts/runtime_host_watchdog.py`：守护进程与自动重启
- `scripts/runtime_host_healthcheck.py`：健康探针
- `scripts/runtime_host_acceptance.ps1`：验收脚本（支持 `-IncludeSoak`、`-IncludeWatchdogSmoke`）
- `scripts/runtime_host_release_gate.ps1`：发布闸门（一键综合验收）
- `scripts/runtime_host.config.example.json`：配置模板

## 快速启动
### 1. 准备配置
复制配置模板并按服务器实际值修改：

```powershell
Copy-Item scripts/runtime_host.config.example.json .\runtime_host.config.json
```

### 2. 直接启动服务（前台）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_runtime_host.ps1 -ConfigJsonPath .\runtime_host.config.json
```

### 3. 生产推荐：watchdog 启动

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_runtime_host_watchdog.ps1 -ConfigJsonPath .\runtime_host.config.json
```

## 配置项说明（`runtime_host.config.json`）
| 字段 | 类型 | 说明 |
|---|---|---|
| `host` | string | 监听地址，如 `0.0.0.0` |
| `tcp_port` | int | TCP 监听端口 |
| `udp_port` | int | UDP 监听端口 |
| `runtime_name` | string | 运行时实例名（指标中可见） |
| `db_path` | string | SQLite 数据文件路径 |
| `thread_count` | int | 路由/线程桶数量 |
| `tick_interval_ms` | int | 事件循环 tick 间隔 |
| `task_budget` | int | 异步任务预算上限 |
| `lua_script_path` | string | Lua 脚本路径 |
| `lua_command` | string | Lua 可执行命令（可空） |
| `drift_mode` | string | 漂移注入：`none/route/flow/protobuf` |

## 健康检查与运行确认
### Python 探针
```powershell
python scripts/runtime_host_healthcheck.py --host 127.0.0.1 --tcp-port 9527 --udp-port 9528 --require-udp --json-output
```

### PowerShell 探针封装
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_healthcheck.ps1 -EndpointHost 127.0.0.1 -TcpPort 9527 -UdpPort 9528 -RequireUdp
```

## 服务化部署
### Windows（计划任务）
安装并立即启动：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_runtime_host_windows_task.ps1 -ConfigJsonPath .\runtime_host.config.json -Force -StartNow
```

卸载：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/uninstall_runtime_host_windows_task.ps1
```

### Linux（systemd）
安装并启动：
```bash
sudo bash scripts/install_runtime_host_systemd.sh --config-json ./runtime_host.config.json
```

卸载：
```bash
sudo bash scripts/uninstall_runtime_host_systemd.sh
```

## 验收与发布闸门
### 基础检查
```powershell
sgc check src/main.sg
```

### 功能验收
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance.ps1
```

### 扩展验收（含 soak）
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance.ps1 -IncludeSoak -SoakDurationSeconds 60
```

### 发布闸门（推荐上线前必跑）
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60
```

通过标志：
- `Type check passed`
- `ACCEPTANCE_OK=True`
- `RELEASE_GATE_OK=True`

## 常见问题
### 1. “现在编译完了吗？”
已完成可运行交付：Sengoo 模块已通过 `sgc check`，运行时服务可直接部署。  
注意本项目当前是“脚本运行形态”，不是单文件二进制。

### 2. Protobuf 回归失败
确认安装依赖：
```powershell
pip install protobuf
```

### 3. 端口占用或 Windows 短时端口复用报错
- 检查监听端口冲突
- 稍后重试或更换端口
- 使用 watchdog 模式可提升稳定性与自恢复能力
