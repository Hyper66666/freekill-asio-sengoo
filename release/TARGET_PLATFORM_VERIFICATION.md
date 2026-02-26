# Target Platform Verification

## Verified in Current Environment (Windows)
- Command:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_native_release.ps1 -SoakDurationSeconds 5`
- Result:
  - `VERIFY_NATIVE_RELEASE_OK=True`
  - Native build, acceptance, dependency audit, soak, and release gate all pass.

## Linux Target Status
- Current `sgc build` CLI in use does not expose an explicit `--target` option.
- Therefore Linux-native executable verification must run on:
  - Linux host with Sengoo toolchain, or
  - environment that provides Linux-target build support in compiler/toolchain.

## Linux Verification Plan
1. On Linux host, run native build:
   - `pwsh -File scripts/build_native_release.ps1 -PlatformTag linux-x64 -BinaryName freekill-asio-sengoo-runtime`
2. Run acceptance:
   - `pwsh -File scripts/runtime_host_acceptance_native.ps1`
3. Run release gate:
   - `pwsh -File scripts/runtime_host_release_gate.ps1 -SoakDurationSeconds 60`
4. Record evidence in CI artifact or release notes.
