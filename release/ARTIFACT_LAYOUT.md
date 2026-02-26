# Native Release Artifact Layout

## Target Matrix
- Windows x64: `release/native/windows-x64/`
- Linux x64: `release/native/linux-x64/`

## Package Structure (Per Platform)
```
release/native/<platform>/
├── bin/
│   └── freekill-asio-sengoo-runtime[.exe]
├── config/
│   └── runtime_host.config.json
├── scripts/
│   ├── start_runtime_host[.ps1|.sh]
│   └── healthcheck_runtime_host[.ps1|.sh]
├── manifest.json
└── checksums.sha256
```

## Manifest Fields
- `version`
- `platform`
- `build_time_utc`
- `binary_path`
- `binary_sha256`
- `config_template_path`
- `smoke_exit_code`

## Operational Notes
- Single-file release is optional; multi-file release is the default model.
- Runtime package MUST be runnable on clean host without Python or `sgc`
  preinstall.
