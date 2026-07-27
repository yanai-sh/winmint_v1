See [AGENTS.md](AGENTS.md) for the full agent context and coding contract.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`yanai-sh/winmint_v1`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` at the repo root, ADRs in `docs/decisions/`. See `docs/agents/domain.md`.

### WinMint v2

Greenfield planning: `docs/v2/`. Copy instructions: `docs/v2/COPY-INTO-NEW-REPO.md` (seed: `docs/v2/seed-for-new-repo/`; deferred art: `docs/v2/future-assets/`). After copy, agents read the new repo’s `AGENTS.md` and `docs/WORKFLOW.md`.
