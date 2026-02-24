# freekill-asio-sengoo

Sengoo rewrite workspace for `freekill-asio`.

This directory is intentionally isolated from the current C++ server and has its own Git history at `freekill-asio-sengoo/.git`.

## Current Status

- Isolated rewrite workspace and independent git history are active
- cpp-to-sg migration mapping is complete for current legacy `src/**/*.cpp`
- Contract-layer Sengoo modules and smoke checks are in place
- Unified completion gate available at `tests/smoke/rewrite_completion_smoke.ps1`
- Milestone contract gates M1-M6 are wired and executable via smoke scripts

## Directory Layout

- `src/network_sg/`: network listener/socket/router/http skeleton
- `src/server_sg/`: server orchestration skeleton
- `src/core_sg/`: shared utility and runtime helper migration target
- `src/codec_sg/`: protobuf/packet codec migration target
- `src/entity_sg/`: player/entity migration target
- `src/ffi_bridge_sg/`: C/Lua/FFI bridge migration target
- `docs/`: migration map and milestone gates
- `docs/RUNTIME_PARITY_CHECKLIST.md`: runtime equivalence acceptance checklist
- `tests/smoke/`: milestone and completion smoke checks
- `tests/runtime/`: runtime artifact parity harness scripts

## Local Checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/bootstrap_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/rewrite_completion_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/run_all_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_artifact_builder_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_case_scaffold_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_parity_harness_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_parity_pipeline_smoke.ps1
```

If `sgc` is available locally:

```powershell
sgc check src/main.sg
```
