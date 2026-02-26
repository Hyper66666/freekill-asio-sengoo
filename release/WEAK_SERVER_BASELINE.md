# Weak Server Baseline (Native Runtime)

## Target Profile
- CPU: 2 vCPU
- RAM: 2 GB
- OS: Windows Server 2019+ or Linux x64 with glibc
- Network: public TCP/UDP exposed for runtime ports

## Acceptance Thresholds
- Native smoke exit code: `0`
- Native soak failure rate: `<= 1%`
- Native soak throughput: `>= 0.5 runs/s`
- Native soak p95 process latency: `<= 2000 ms`
- Release gate: `RELEASE_GATE_OK=True`

## Gate Commands
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance_native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_soak_native.ps1 -DurationSeconds 60
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60
```

## Resource Controls in Native Defaults
- Max TCP connections: `2`
- Max UDP peers: `2`
- Max packet bytes: `65536`
- Async inflight cap: `64`
- Error budget: `32`
- Endpoint backpressure threshold: `3`
