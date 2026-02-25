# freekill-asio-sengoo

Sengoo rewrite workspace for `freekill-asio`.

This directory is intentionally isolated from the current C++ server and has its own Git history at `freekill-asio-sengoo/.git`.

## Current Status

- Isolated rewrite workspace and independent git history are active
- cpp-to-sg migration mapping is complete for current legacy `src/**/*.cpp`
- Contract-layer Sengoo modules and smoke checks are in place
- Unified completion gate available at `tests/smoke/rewrite_completion_smoke.ps1`
- Milestone contract gates M1-M6 are wired and executable via smoke scripts
- Runtime parity tooling chain (scaffold/builder/pipeline/harness) is in place with placeholder-evidence guard
- Live runtime probe collection and acceptance entrypoint are available for endpoint-based evidence capture
- Runtime host e2e execution stack is available (real TCP I/O, protobuf regression, persistence/thread-routing, lua hot reload path)

## Directory Layout

- `src/network_sg/`: network listener/socket/router/http skeleton
- `src/server_sg/`: server orchestration skeleton
- `src/core_sg/`: shared utility and runtime helper migration target
- `src/codec_sg/`: protobuf/packet codec migration target
- `src/entity_sg/`: player/entity migration target
- `src/ffi_bridge_sg/`: C/Lua/FFI bridge migration target
- `docs/`: migration map and milestone gates
- `docs/RUNTIME_PARITY_CHECKLIST.md`: runtime equivalence acceptance checklist
- `docs/RUNTIME_EVENT_SCHEMA.md`: runtime collector input schema and examples
- `docs/LIVE_RUNTIME_ACCEPTANCE.md`: live endpoint probe flow and manifest schema
- `docs/RUNTIME_HOST_E2E_ACCEPTANCE.md`: runtime host orchestration and report contract
- `docs/MAINLINE_MIGRATION.md`: dry-run/apply runbook for promotion into mainline tree
- `tests/smoke/`: milestone and completion smoke checks
- `tests/runtime/`: runtime artifact parity harness scripts

## Local Checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/bootstrap_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/rewrite_completion_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/run_all_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_acceptance_entry_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_artifact_builder_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_case_scaffold_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_case_collector_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_parity_harness_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_parity_pipeline_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_live_evidence_collector_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_live_acceptance_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/runtime_host_e2e_smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/smoke/mainline_migration_plan_smoke.ps1
```

If `sgc` is available locally:

```powershell
sgc check src/main.sg
```
