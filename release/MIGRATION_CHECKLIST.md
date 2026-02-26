# Migration Checklist: Python Runtime -> Native Runtime

## Preconditions
- Native artifact built:
  - `release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe`
  - `release/native/windows-x64/manifest.json`
  - `release/native/windows-x64/checksums.sha256`
- Native verification passed:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_native_release.ps1 -SoakDurationSeconds 60`

## Cutover Steps
1. Stop existing Python-hosted service:
   - Windows Task Scheduler: disable/remove old watchdog task.
   - Linux systemd: stop old `freekill-runtime-host` service.
2. Install native service:
   - Windows:
     - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_runtime_host_windows_task_native.ps1 -StartNow -Force`
   - Linux:
     - `sudo bash scripts/install_runtime_host_systemd_native.sh`
3. Run native healthcheck:
   - Windows:
     - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/healthcheck_runtime_host_native.ps1`
   - Linux:
     - `bash scripts/healthcheck_runtime_host_native.sh`
4. Run release gate:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60`
5. Confirm `RELEASE_GATE_OK=True`.

## Rollback Plan
1. Stop native service:
   - Windows:
     - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/uninstall_runtime_host_windows_task_native.ps1`
   - Linux:
     - `sudo bash scripts/uninstall_runtime_host_systemd_native.sh`
2. Restore Python-hosted service:
   - Windows:
     - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_runtime_host_windows_task.ps1 -StartNow -Force`
   - Linux:
     - `sudo bash scripts/install_runtime_host_systemd.sh`
3. Run legacy acceptance once:
   - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 -UseLegacyPythonAcceptance`

## Success Criteria
- Native gate remains green for at least one full soak cycle in production-like environment.
- No Python runtime process required in data plane.
