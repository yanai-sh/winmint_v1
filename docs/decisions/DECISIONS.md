# WinMint Decision Audit Matrix

Snapshot of audited decisions. Verdict vocabulary: **Keep**, **Revisit**, **Reverse**, **Defer**.

| Decision | Verdict | ADR | Area |
|----------|---------|-----|------|
| PowerShell 7.6 engine for DISM/WIM | Keep | [003](ADR-003-powershell-engine-boundary.md) | — |
| Dot-source engine load (no per-area .psm1 sprawl) | Revisit | [003](ADR-003-powershell-engine-boundary.md) | Engine / schema |
| Staged setup `#Requires 5.1` floor | Revisit | [003](ADR-003-powershell-engine-boundary.md) | Engine / schema |
| GPUI/Rust native GUI | Reverse | [001](ADR-001-gpui-to-webview2-wizard.md) | Wizard / UI |
| WebView2 + HTML wizard on build host | Keep | [001](ADR-001-gpui-to-webview2-wizard.md) | Setup shell |
| Direct2D AOT splash on installed ISO | Keep | [002](ADR-002-dual-setup-shell-hosts.md) | Setup shell |
| Single exe + MB size heuristic | Reverse | [002](ADR-002-dual-setup-shell-hosts.md) | Setup shell |
| `tools/ui-bridge/` PowerShell boundary | Keep | [003](ADR-003-powershell-engine-boundary.md) | Contracts / bridge |
| JSON Schema contracts | Keep | [004](ADR-004-contract-schema-first.md) | Contracts / bridge |
| BuildDelta standalone file | Revisit | [004](ADR-004-contract-schema-first.md) | Contracts / bridge |
| uiintent intermediate schema | Reverse | [004](ADR-004-contract-schema-first.md) | Contracts / bridge |
| control + status + agent state JSON files | Revisit | [004](ADR-004-contract-schema-first.md) | FirstLogon |
| User ISO is truth | Keep | [005](ADR-005-user-iso-truth.md) | — |
| Source ISO legally user-supplied (no silent download) | Keep | [010](ADR-010-source-iso-legal.md) | — |
| WinMint v2 greenfield (C# orchestrator, guest Supervisor Shell, host Servicing pwsh, clean-sheet contracts) | Keep | [011](ADR-011-winmint-v2-greenfield.md) | v2 |
| WebView2 wizard for v2 | Reverse | [011](ADR-011-winmint-v2-greenfield.md) | v2 |
| BuildProfile v4 as v2 contract | Reverse | [011](ADR-011-winmint-v2-greenfield.md) | v2 |
| Subtractive defaults + keep flags | Keep | — | — |
| DMA Ireland internal region | Keep | [006](ADR-006-dma-interop.md) | — |
| No maintenance daemon | Keep | — | Validate.ps1 scan |
| Package source policy (winget/Scoop/Store) | Keep | [007](ADR-007-package-source-policy.md) | — |
| Profile schema v4 | Keep | [008](ADR-008-profile-schema-v4.md) | Engine / schema |
| Smoke WSL skip via `profileName` | Revisit | — | Smoke WSL |
| Diagnostics in user BuildProfile | Revisit | — | Diagnostics / polish |
| InstallPlan wrapper functions in Unattend.ps1 | Revisit | [004](ADR-004-contract-schema-first.md) | Contracts / bridge |
| WinMintAgent\\BuildProfile.json misname | Revisit | [004](ADR-004-contract-schema-first.md) | Contracts / bridge |
| FirstLogon transaction framework | Revisit | — | FirstLogon |
| Agent mode matrix (5+ paths) | Revisit | — | FirstLogon |
| VM harness monolith (VmConsole.ps1) | Revisit | [009](ADR-009-acceptance-strategy.md) | VM acceptance |
| VM acceptance in CI | Defer | [009](ADR-009-acceptance-strategy.md) | — |
| Ephemeral `irm \| iex` bootstrap | Keep | — | — |
| Per-file tweak modules + tweaks.json mirror | Revisit | — | Diagnostics / polish |
| HTML mockups beside shipping splash assets | Reverse | — | Wizard / UI |
| C# JsonContracts hand-written DTOs | Revisit | [004](ADR-004-contract-schema-first.md) | Diagnostics / polish |
