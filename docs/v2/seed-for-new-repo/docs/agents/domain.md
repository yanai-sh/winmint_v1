# Domain docs

## Before exploring, read

- [`CONTEXT.md`](../../CONTEXT.md) at the repo root
- [`docs/decisions/`](../decisions/) ADRs that touch the area you are changing
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md), [`docs/STACK.md`](../STACK.md), and [`docs/WORKFLOW.md`](../WORKFLOW.md) for v2 shape, stack, and process
- [`docs/START.md`](../START.md) if you just extracted the seed zip

If a file is missing, proceed silently. `/domain-modeling` (via `/grill-with-docs`) creates glossary/ADR entries lazily when terms or decisions resolve.

## Layout

```
/
├── CONTEXT.md
├── AGENTS.md
├── assets/brand/          # identity only (picker icons = future-assets placeholders)
├── payload/               # media + setup|jobs|provisioning (staged Supervisor)
├── src/                   # Orchestrator / Cli / Provisioning (+ Wizard placeholder)
├── servicing/             # elevated thin host kernels (stubs → smoke)
├── docs/
│   ├── START.md
│   ├── ARCHITECTURE.md
│   ├── STACK.md
│   ├── WORKFLOW.md
│   ├── coding-contract.md
│   ├── agents/
│   └── decisions/
└── tests/  tools/  schemas/  config/
```

This repo uses `docs/decisions/` (not `docs/adr/`).

## Vocabulary

Use terms as defined in `CONTEXT.md` (includes **Provisioning Supervisor**, **Machine setup**, **Provisioning lock**, **Provisioning jobs**, **Provisioning status**, **DMA settle**). If you need a concept that is not there, either reuse an existing term or note it for `/domain-modeling` — do not invent silent synonyms.

When harvesting behaviour from WinMint v1, follow [`PORT-FROM-V1.md`](../PORT-FROM-V1.md) — v1 is archaeology, not authority. Do not port PreLock.ps1 as Winlogon Shell or stage guest pwsh for FirstLogon.

## ADR conflicts

If your change contradicts an Accepted ADR, say so explicitly before proceeding.
