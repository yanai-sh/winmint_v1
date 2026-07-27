# Architecture Decision Records (ADR)

Numbered, durable records of significant WinMint decisions. Each ADR captures **context**, **options**, **choice**, and **consequences** so future changes do not rely on chat history or stale docs.

## Status vocabulary

| Status | Meaning |
|--------|---------|
| **Proposed** | Under discussion; not yet binding |
| **Accepted** | Current team decision; code and docs should align |
| **Superseded** | Replaced by a newer ADR (link the successor) |

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](ADR-001-gpui-to-webview2-wizard.md) | GPUI/Rust GUI → WebView2 wizard | Accepted (supersedes GPUI) |
| [002](ADR-002-dual-setup-shell-hosts.md) | Dual setup-shell hosts (native splash + WebView2 wizard) | Accepted |
| [003](ADR-003-powershell-engine-boundary.md) | PowerShell as Windows imaging boundary | Accepted |
| [004](ADR-004-contract-schema-first.md) | JSON Schema-first contracts | Accepted |
| [005](ADR-005-user-iso-truth.md) | User-provided ISO as source of truth | Accepted |
| [006](ADR-006-dma-interop.md) | DMA interop fixed internal region | Accepted |
| [007](ADR-007-package-source-policy.md) | Fixed package source policy | Accepted |
| [008](ADR-008-profile-schema-v4.md) | BuildProfile schema v4 breaking migration | Accepted |
| [009](ADR-009-acceptance-strategy.md) | Contract tests in CI; VM smoke manual | Accepted |
| [010](ADR-010-source-iso-legal.md) | Source ISO legally user-supplied | Accepted (extends 005) |
| [011](ADR-011-winmint-v2-greenfield.md) | WinMint v2 greenfield rewrite | Accepted (v2 project; updated 2026-07-27 grill: guest pwsh-free Supervisor) |

## Related documents

- [DECISIONS.md](DECISIONS.md) — one-page audit matrix (verdict → area)
- [AUDIT-WORKSHEET.md](AUDIT-WORKSHEET.md) — template for new decisions

## Adding an ADR

1. Copy [AUDIT-WORKSHEET.md](AUDIT-WORKSHEET.md) into `ADR-NNN-short-title.md`.
2. Assign the next number; set status to Proposed.
3. Add a row to this index and [DECISIONS.md](DECISIONS.md).
4. On acceptance, update [AGENTS.md](../../AGENTS.md) or product docs if the decision changes agent contracts.
