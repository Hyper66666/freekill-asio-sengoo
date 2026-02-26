# Native Release Artifact Layout

## Target Matrix
- Windows x64: `release/native/windows-x64/`
- Linux x64: `release/native/linux-x64/`

## Package Structure
```text
release/native/<platform>/
  bin/
    freekill-asio-sengoo-runtime[.exe]
  config/
    runtime_host.config.json
  scripts/
    start_runtime_host[.ps1|.sh]
    healthcheck_runtime_host[.ps1|.sh]
    install_runtime_host_service[.ps1|.sh]
    uninstall_runtime_host_service[.ps1|.sh]
  manifest.json
  checksums.sha256
```

## Manifest Fields
- `version`
- `runtime_mode`
- `python_required`
- `platform`
- `build_time_utc`
- `source`
- `binary_path`
- `binary_sha256`
- `smoke_exit_code`
- `config_template_path`
- `start_script_path`
- `healthcheck_script_path`
- `install_script_path`
- `uninstall_script_path`

## Release Behavior
- Native runtime is the production data plane path.
- Python scripts are optional development diagnostics and are not required in release runtime.
