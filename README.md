# freekill-asio-sengoo

Sengoo rewrite workspace for `freekill-asio`.

This directory is intentionally isolated from the current C++ server and has its own Git history at `freekill-asio-sengoo/.git`.

## Current Status

- Isolated rewrite workspace and independent git history are active
- cpp-to-sg migration mapping is complete for current legacy `src/**/*.cpp`
- Contract-layer Sengoo modules and smoke checks are in place
- Unified completion gate available at `tests/smoke/rewrite_completion_smoke.ps1`

## Directory Layout

- `src/network_sg/`: network listener/socket/router/http skeleton
- `src/server_sg/`: server orchestration skeleton
- `src/core_sg/`: shared utility and runtime helper migration target
- `src/codec_sg/`: protobuf/packet codec migration target
- `src/entity_sg/`: player/entity migration target
- `src/ffi_bridge_sg/`: C/Lua/FFI bridge migration target
- `docs/`: migration map and milestone gates
- `tests/smoke/`: milestone and completion smoke checks

## Local Checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/bootstrap_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/rewrite_completion_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/run_all_smoke.ps1
```

If `sgc` is available locally:

```powershell
sgc check src/main.sg
```
