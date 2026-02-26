# Production Scope: Native Runtime

## Goal
Production deployment MUST run native runtime executables and MUST NOT depend on
Python processes in the runtime data plane.

## In Scope (Production)
- Native runtime executable built from Sengoo source.
- Native process supervision and service integration.
- Native healthcheck and release gate evidence.

## Out of Scope (Production)
- Python-hosted runtime server (`scripts/runtime_host_server.py`) as data-plane
  runtime.
- Python watchdog/acceptance scripts as required runtime dependencies.

## Transitional Policy
- Python scripts remain allowed for development diagnostics and migration
  validation until native runtime parity gates are fully green.
- Release candidate status requires native runtime gate pass.

## Required Gates Before Production Claim
1. Native build success (`sgc build` -> runnable executable).
2. Native runtime acceptance pass (network/codec/ffi/persistence/stability).
3. Release package smoke pass on clean host (no Python/sgc preinstall).
