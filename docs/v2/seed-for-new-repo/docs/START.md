# Start from this seed

This tree is the **entire day-one WinMint v2 repository**. Extract the seed zip so these files are the repo root (`README.md`, `WinMint.slnx`, …), then:

```powershell
git init
git add .
git commit -m "chore: initial winmint-v2 starter"
git branch -M main
# git remote add origin … && git push -u origin main
```

WinMint **v1** is a separate clone/folder for reference only. It is **not** required on disk for commit 1, `just check`, or Smoke planning.

## Companion shelf (not commit 1)

If you also have `winmint-v2-future-assets-*.zip`, keep it **outside** this repo (e.g. sibling `../future-assets/`). Shell presets matter when desktop layers land; `ui/` picker icons are placeholders only — Avalonia is not early v2 work. See that zip’s `README.md`. Do not merge it into the initial commit.

## Host prerequisites

| Tool | Notes |
|------|--------|
| Windows | Development and all product scripts run on Windows |
| .NET SDK | Version pinned in [`global.json`](../global.json) (preview OK) |
| PowerShell 7.6.2+ | `pwsh` for **host** Servicing stubs / analyzer — not a guest FirstLogon runtime |
| [Just](https://github.com/casey/just) | `winget install Casey.Just` |

```powershell
just check   # format-check + build + test + analyze-ps
```

## Next product work

1. Set the real GitHub slug in [`agents/issue-tracker.md`](agents/issue-tracker.md) when the new repo exists.
2. Grow the root [`README.md`](../README.md) as the product matures.
3. Smoke planning: see [`specs/2026-07-27-smoke.md`](specs/2026-07-27-smoke.md) and [`WORKFLOW.md`](WORKFLOW.md).
4. **Until this tree is its own GitHub repo:** local Smoke tickets may live in the v1 monorepo at `.scratch/winmint-v2-smoke/issues/` (gitignored). After copy, move that folder into the new repo’s `.scratch/` or re-run `/to-tickets`.
5. `/implement` one ticket per session from the unblocked frontier.
6. When a ticket needs proven v1 behaviour, clone v1 beside this repo and harvest per [`PORT-FROM-V1.md`](PORT-FROM-V1.md).

## Read order

1. [`../CONTEXT.md`](../CONTEXT.md) · [`../AGENTS.md`](../AGENTS.md)
2. [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`STACK.md`](STACK.md) · [`specs/2026-07-27-smoke.md`](specs/2026-07-27-smoke.md) · [`WORKFLOW.md`](WORKFLOW.md)
3. [`decisions/`](decisions/) · [`STRUCTURE.md`](STRUCTURE.md)
