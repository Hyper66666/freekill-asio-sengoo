# freekill-asio-sengoo

## 项目说明
- 原仓库（C++ 基线）：<https://github.com/Qsgs-Fans/freekill-asio>
- 本仓库：以上项目的 **Sengoo 重写版本**
- Sengoo 语言仓库：<https://github.com/Hyper66666/Sengoo>

本仓库用于承载服务端重写实现，目标是将关键运行时能力迁移到 Sengoo 版本并保持可验证的行为一致性。

## 当前重写进度（截至 2026-02-26）

### 已完成（P0）
- 网络 I/O 状态机主干（TCP/UDP 连接管理、收发计数、事件循环相关状态）
- 主程序入口主干（启动/停止、配置归一化、信号处理状态）
- runtime-host 执行链主干（host adapter、ack replay、acceptance 脚本）

### 已完成（P1）
- 数据包编解码器：`src/codec_sg/packet_codec.sg`
  - JSON/Protobuf 编解码状态转换
  - frame build/parse 与错误码路径
- Lua FFI 桥接：`src/ffi_bridge_sg/lua_ffi.sg`
  - VM/FFI 生命周期
  - 函数注册、同步/异步调用、回调、热重载
- SQLite 持久化：`src/server_sg/sqlite_store.sg`
  - 连接、事务、查询、upsert/delete、commit/rollback
- 主流程接入：`src/main.sg`
  - 新增 P1 bridge 状态流并纳入退出码收口

## 目录结构
- `src/main.sg`：服务主流程与运行时收口
- `src/network_sg/`：网络与 socket/路由相关状态机
- `src/codec_sg/`：协议常量、packet wire、packet codec
- `src/ffi_bridge_sg/`：C wrapper、RPC bridge、Lua FFI bridge
- `src/server_sg/`：服务编排、runtime host、sqlite store
- `scripts/runtime_host_acceptance.ps1`：核心验收脚本（可选包含 soak）
- `scripts/runtime_host_server.py`：可部署 runtime-host 进程
- `scripts/start_runtime_host.ps1`：启动封装（支持 `--config-json`）
- `scripts/runtime_host.config.example.json`：配置模板

## 启动方式

### 命令行直启

```powershell
python scripts/runtime_host_server.py --host 0.0.0.0 --tcp-port 9527 --db-path .tmp/runtime_host/runtime.sqlite
```

### 配置文件启动

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_runtime_host.ps1 -ConfigJsonPath scripts/runtime_host.config.example.json
```

## 本地验证与验收

```powershell
sgc check src/main.sg
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance.ps1 -IncludeSoak -SoakDurationSeconds 60
```

验收通过标志：
- `Type check passed`（目标文件全部通过）
- `ACCEPTANCE_OK=True`
