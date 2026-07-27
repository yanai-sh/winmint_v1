# Hyper-V VM Acceptance

This runbook is the WinMint acceptance gate **before** real hardware (see
`docs/Hardware-Acceptance.md`). It proves that a build goes end to end — build the
ISO, install it unattended in a Hyper-V VM, and let FirstLogon complete — and that
the run leaves reusable evidence behind.

It is deliberately thin. The harness sequences small, single-purpose scripts; it is
not a framework. Do not add an evidence-package schema or a phase-journal engine
until repeated real runs show concrete pain (roadmap Track B2/D4).

## Which command when?

| Change type | Command |
|-------------|---------|
| Engine/profile/setup/autounattend (no guest) | `Validate.ps1` + `Invoke-WinMintPesterContract.ps1` (includes install-plan, agent state, CLI matrix, autounattend dry-run) |
| FirstLogon/agent/runtime only | Existing VM + `Push-WinMintSetupScripts.ps1` (does **not** re-validate diskpart/unattend) |
| Staging/autounattend/WIM servicing | Smoke or full VM acceptance (build required; `-ForceBuild` when image fingerprint changed) |
| Opt-in Dev Drive (`VhdDynamic`) | `hyper-v-smoke-devdrive-arm64.json` managed run (not the weekly default) |
| Pre-release | Full `hyper-v-install-arm64.json` acceptance, then hardware collector |

**Release policy (local, not CI):** run smoke weekly or after engine/setup staging
changes; run full before tagging or hardware acceptance. ADR-009 keeps Hyper-V out of GitHub CI.

### Test pyramid

| Layer | Proves | Does **not** prove |
|-------|--------|-------------------|
| Contract suite (CI) | Profile/plan, autounattend dry-run (incl. Partition diskpart + 259-char Path), agent state machine, CLI matrix | Live install, autologon, real winget |
| Push-to-guest | Setup/agent code on a running Windows guest | Fresh ISO install, SetupComplete path, disk layout |
| Smoke VM | ISO → Setup → FirstLogon plumbing, setup shell, DMA restore report, required agent steps, disk probe, removal drift | Full product matrix; WSL runtime; Dev Drive (default Off) |
| Smoke Dev Drive | Same as smoke + `VhdDynamic` 64 GB Dev Drive evidence | Partition Dev Drive (needs large disk / Setup diskpart) |
| Full VM | Complete Hyper-V profile + inspect + live install audit | Physical hardware quirks |
| Hardware collector | SL7/ThinkPad/Alienware coded signals from guest+host evidence | Copilot key / Wi‑Fi / sleep (notes only) |

Speed comes from **narrower scenarios**, **phase skipping**, and **checkpoints** —
not from test-only fast-wait hooks in acceptance guests.

## One-command acceptance

```powershell
# Elevated PowerShell. Full release gate (slowest).
pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-install-arm64.json

# Lean plumbing gate (~10–25 min faster guest time).
pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json

# Opt-in Dev Drive VhdDynamic smoke (64 GB expandable VHDX at FirstLogon).
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-devdrive-arm64.json
```

Smoke lists WSL distros in `development.wsl.distros` but sets `diagnostics.wslRuntimeValidation = skip` so the FirstLogon agent skips WSL runtime
update/distro validation (no nested virt required in typical Hyper-V guests).
The smoke wait phase also holds acceptance until **45s** of FirstLogon activity
(breadcrumb or agent state) so setup-shell OOBE polling is not cut short.
**Smoke Wait timeout defaults to 90 minutes** (agent under splash routinely exceeds
the old 35‑minute cap); the soft time budget warns at **60 minutes** but does not
fail the run. **Stall fail-fast** cuts Wait early when splash/control is live for
**~12 minutes** (Smoke) / **~15 minutes** (Full) with no `state.json` or FirstLogon
breadcrumb — Shell↔RunOnce deadlocks and similar hangs no longer wait out the full
timeout. AutoLogon to `defaultuser0` also fail-fasts. Override with `-StallMinutes`.
Full `hyper-v-install-arm64.json` still attempts real WSL when nested virt is available.

The pass requires a **Pro**, fully-unattended **Local-account** profile (the VM
invariant): PowerShell Direct must be able to sign in, so the profile needs
`identity.accountName` and `identity.password`. The guest architecture follows the
host, so run on the same architecture as the ISO.

Output: an evidence folder under `output\vm-acceptance\<VMName>-<stamp>\` containing
`run.log` (the full transcript, written from the first line), the pulled guest
logs, the agent `state.json`, the host build artifacts, and a single
`acceptance-result.json` with **`plumbingVerdict`** and **`evidenceVerdict`**
(`pass`/`fail`). **Smoke** tier passes on plumbing alone (FirstLogon + native
shell control/logs); **Full** tier requires evidence checks too (screenshot,
inspect signals). Failed plumbing exits 1; smoke evidence gaps are recorded in
`warnings` only.

`acceptance-result.json` also records `acceptanceTier` (`Full` or `Smoke`) and
the overall `verdict` (smoke: plumbing; full: plumbing + evidence).

Every line is written to `run.log` as it prints (orchestrator lines via the
`Say` helper, the noisy build teed through `Invoke-WinMintVmLoggedCommand`), with
UTC timestamps, log levels (`PHASE`, `PROG`, `SUB`, `WARN`, `ERROR`, `DONE`),
and ANSI stripped from the file. A companion `run-events.jsonl` in the same
evidence folder records machine-readable phase, progress, milestone, and verdict
events for `Get-WinMintVmAcceptanceStatus.ps1` polling.

```powershell
Get-Content output\vm-acceptance\<vm>-<stamp>\run.log -Wait -Tail 30
pwsh -NoProfile -File .\tools\vm\Get-WinMintVmAcceptanceStatus.ps1
```

## Agent/Cursor orchestration

Cursor and other coding agents must use the **managed, pollable** entry points —
not a foreground `Invoke-WinMintVmAcceptance.ps1` from an IDE terminal (cwd, WT
relaunch, and non-detached output are unreliable there).

**Skill (full workflow):** `.agents/skills/vm-acceptance-orchestration/SKILL.md`

### Managed run (agents)

Requires an **already-elevated** PowerShell at the repo root (no UAC relaunch).

```powershell
# Start smoke (detached; writes output/vm-acceptance/managed-run.json)
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json

# Poll until complete
pwsh -NoProfile -File .\tools\vm\Get-WinMintVmAcceptanceStatus.ps1

# Fast FirstLogon/agent iteration through managed acceptance (~2-8 min)
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json -PushOnly

# Replace a stale run (kills prior process tree)
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json -Force

# Headless host / no VMConnect window (default is already -NoObserve)
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json -NoObserve

# ForceBuild SL7 smoke (explicit 90‑min Wait; do not rely on stale muscle memory)
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-sl7-smoke-arm64.json `
    -ForceBuild -SmartBuild:$false -TimeoutMinutes 90 -Force -NoLogViewer -NoObserve
```

By default, managed acceptance opens **one Windows Terminal window** running the
worker: Spectre build chrome and harness Wait/Inspect/Evidence lines share that
session (the invoking shell still prints the JSON handle). Full build detail also
lands in `output/WinMint-Build.verbose.log`. Pass `-NoLogViewer` for a minimized
headless worker (no live console). Default is `-NoObserve` (no VMConnect); pass
`-Observe` for **VMConnect Basic** only. Do **not** use Hyper-V Enhanced Session
to judge AutoLogon: an Enhanced Session password prompt is expected for the
session channel and is not proof that Winlogon AutoAdminLogon failed. Prefer
Basic VMConnect or headless (`-NoObserve`); the Wait phase soft-logs
`autologon-ok` / `autologon-mismatch` from live Winlogon keys once PowerShell
Direct is reachable. Poll JSON includes `consoleMode`,
`observePid` / `observeMode`, and `logViewerOpened`. Attach VM manually:
`tools\vm\Start-WinMintVmObserve.ps1`.

**Green:** `complete = true`, `status = passed`, `verdict = pass`, and (smoke/full)
`acceptance-result.json` → `setupShell` OK. Advisory `warningSteps` (e.g. a failed
live-user sub-step inside an advisory module) are recorded in `warnings` and do
**not** fail smoke plumbing when `firstLogon.status = ok`. **Not green:** `running`,
`stopped`, or `complete = false` at timeout.

### Subagent roles

| Role | Responsibility |
|------|----------------|
| Coordinator (parent) | Route intent; one run at a time; no fix before evidence |
| Run operator | Start managed run; poll to completion |
| Evidence collector | Gather logs, screenshot, classify failure layer (read-only) |
| Root-cause debugger | One hypothesis, one primary layer; no code yet |
| Harness implementer | Fix `tools/vm/*` or contract tests per diagnosis |
| Spec / Quality reviewers | Verify contract + reliability before retry |

Prompt templates: `.agents/skills/vm-acceptance-orchestration/references/subagent-prompts.md`

### Failure layers

`start` · `build` · `install` · `firstlogon` · `setupshell` · `strict` · `timeout`

### VMConnect shows a black screen (guest still running)

Hyper-V often opens VMConnect during early Setup with a **black framebuffer**, then
**reuses** that broken session. The harness now defers VMConnect until acceptance
attaches the observer (after boot) and **closes/reopens** VMConnect by default.

If you still see black while `run.log` shows `shell=running`:

```powershell
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmObserve.ps1 -VMName WinMint-ARM-Test
```

Or close the Virtual Machine Connection window manually and re-run the command above.

Use the **Windows Terminal** tab tailing `run.log` for progress regardless; poll with
`Get-WinMintVmAcceptanceStatus.ps1`.

See `.agents/skills/vm-acceptance-orchestration/references/failure-taxonomy.md`.

### Interactive maintainer

Use `Invoke-WinMintVmAcceptance.ps1` directly in an elevated Windows Terminal tab
at repo root. Add `-WindowsTerminal` only when intentionally opening a new tab.

## Composable phases

`-Phase` splits the orchestrator without changing verdict rules:

| Phase | Requires | Does |
|-------|----------|------|
| `All` (default) | — | Build + boot + wait + inspect + evidence |
| `BuildBoot` | — | Build ISO and boot VM only |
| `Wait` | Running VM | Poll guest `state.json` until terminal |
| `Inspect` | Running VM + terminal agent | Live desktop signals |
| `Evidence` | Running VM | Pull logs, write verdict |

Reuse evidence across phases with `-EvidenceDir` (optional; otherwise a stamp dir
is created on the first phase). `-SkipBuild` remains shorthand for `All` minus
`BuildBoot`. Each phase prints the **next recommended command** at exit.

```powershell
# Build and boot, then resume later on the same evidence folder.
pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json `
    -Phase BuildBoot

pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 `
    -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json `
    -Phase Wait -SkipBuild -EvidenceDir output\vm-acceptance\<vm>-<stamp>
```

## FirstLogon iteration (no reinstall)

After one full install, amortize Windows Setup time with checkpoints and push:

```powershell
# Once: save a post-Setup checkpoint while agent has not finished.
pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmCheckpoint.ps1 -Action Save -Name PostSetup

# Iterate on FirstLogon/agent (~2–5 min per loop).
pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmCheckpoint.ps1 -Action Restore -Name PostSetup
pwsh -NoProfile -File .\tools\vm\Start-WinMintVmObserve.ps1 -VMName WinMint-ARM-Test
pwsh -NoProfile -File .\tools\vm\Push-WinMintSetupScripts.ps1 -RerunFirstLogon -WaitForAgent -AgentMode Auto

# Or push only (default Headless for fast agent-only iteration):
pwsh -NoProfile -File .\tools\vm\Push-WinMintSetupScripts.ps1 -RerunFirstLogon -WaitForAgent
```

**Visual splash rerun:** restore `PostSetup`, attach Basic VMConnect (`Start-WinMintVmObserve.ps1`),
then push with `-AgentMode Auto` so `WinMintSetupShell.exe` runs fullscreen. The native
shell writes `C:\Windows\Temp\winmint-setup-shell-guest.png` on first paint; smoke
evidence copies it to `oobe-splash.png` when present.

```powershell
pwsh -NoProfile -File .\tools\vm\Push-WinMintSetupScripts.ps1 -RerunFirstLogon -WaitForAgent -AgentMode Headless
```

**Integrity boundary:** checkpoint restore does **not** re-validate autounattend,
WIM servicing, or setup staging. Any change there requires a fresh ISO install.

## Build cache warm-up

Fresh machines may fail ISO build preflight when GitHub-hosted font caches are
empty and the API probe fails. Warm caches without a full build:

```powershell
pwsh -NoProfile -File .\tools\vm\Warm-WinMintBuildCache.ps1
```

## Time budgets (warm host, ARM64 Hyper-V)

| Workflow | Target |
|----------|--------|
| Contract suite | 1–5 min |
| Push + wait | 1–3 min |
| Smoke acceptance (ISO cached) | 15–30 min |
| Smoke acceptance (full rebuild, -FastImage) | 25–50 min (Wait allows up to 90) |
| Full acceptance | 40–60 min |
| Restore checkpoint + push | 2–5 min |

## Steps and ownership

`Invoke-WinMintVmAcceptance.ps1` is the orchestrator. It runs four steps,
delegating to the existing single-purpose scripts. Pass `-SkipBuild` to attach to
an already-running VM (wait/score/collect evidence without rebuilding); the wait
step is idempotent and returns fast when FirstLogon has already completed.

### Build reuse (skip / tweak / full rebuild)

Managed acceptance resolves a **build plan** at start (`buildStrategy` in poll JSON
and `kind=build-plan` in `run-events.jsonl`). Default **SmartBuild** ignores
`-ForceBuild` when the image fingerprint still matches the cached ISO.

| Strategy | When | Typical time |
|----------|------|--------------|
| `push-only` | `-PushOnly` + usable PostSetup checkpoint | 2–8 min |
| `checkpoint-push` | Checkpoint + agent/runtime changed | 3–12 min |
| `checkpoint-reuse` | Checkpoint + agent unchanged | 3–12 min |
| `iso-cached-install` | Cached ISO, no checkpoint | 15–25 min |
| `iso-build-install` | Image layer changed | 25–35 min |
| `force-rebuild` | `-ForceBuild` + image changed (or `-SmartBuild:$false`) | 25–35 min |

The build step is fingerprint-gated, so re-running acceptance only does as much
work as the change warrants:

- **No change** → the build is skipped entirely and the existing ISO is booted.
  The fingerprint (in `output\.vm-build-fingerprint.json`) covers the profile,
  the whole build engine + staged payload (`src\runtime`), and the base ISO's
  identity; if it matches and that ISO is still on disk, nothing is rebuilt.
- **Minor change (e.g. a FirstLogon edit)** → a fast rebuild. The engine's
  serviced-`install.wim` cache key excludes FirstLogon/payload, so the 5 GB
  serviced WIM is restored from cache (skipping the 30-60 min DISM loop) and only
  the changed payload is re-staged + the ISO reassembled.
- **Servicing change (drivers, appx, features, locale, edition)** → a full
  rebuild, because those *are* in the serviced-WIM cache key.

Pass `-ForceBuild` to ignore the fingerprint and always rebuild from scratch.

### PostSetup checkpoint (skip Windows Setup)

After the first successful install, the Wait phase auto-saves a Hyper-V
`PostSetup` checkpoint in the **pre-agent** window: `setupcomplete.log` exists and
guest `%LOCALAPPDATA%\WinMint\state.json` does **not** yet (avoids freezing the VM
mid-winget). Up to three save attempts on Hyper-V errors; events are
`postsetup-checkpoint` or `postsetup-checkpoint-skipped` with reason in `run.log` /
`run-events.jsonl`. Validity is recorded in `output\.vm-postsetup-checkpoint.json`
alongside the same build fingerprint used for ISO reuse. After a ForceBuild smoke,
confirm that sidecar exists before relying on `-PushOnly`.

On later runs, pass `-UseCheckpoint` (or `-UseCheckpoint` through managed
acceptance) to restore that snapshot and skip ISO build + Windows Setup when the
fingerprint still matches. Pass `-ForceBuild` to discard reuse and reinstall.
Disable auto-save with `-SavePostSetupCheckpoint:$false` on `Build-And-TestVm.ps1`.

Manual checkpoint control:

```powershell
pwsh -NoProfile -File tools\vm\Invoke-WinMintVmCheckpoint.ps1 -Action Save -Name PostSetup
pwsh -NoProfile -File tools\vm\Invoke-WinMintVmCheckpoint.ps1 -Action Restore -Name PostSetup
```

| Step | Owns | Delegates to |
|------|------|--------------|
| Build + boot | Validate the profile, free host RAM, build the ISO, offline WIM removal verify, create + boot a Gen 2 (UEFI + Secure Boot + vTPM) VM | `Build-And-TestVm.ps1` → `Test-WinMintHyperVProfile.ps1`, `WinMint-CLI.ps1 build`, `Test-WinMintOfflineImageRemovals.ps1`, `New-WinMintTestVm.ps1` |
| Wait | Poll guest `%LOCALAPPDATA%\WinMint\state.json` over PowerShell Direct until `run.status` is terminal (`ok`/`failed`); the first reachable call confirms install + autologon | PowerShell Direct (in-script) |
| Inspect | Capture live desktop / Terminal acceptance signals (read-only, best-effort) | `Invoke-WinMintGuestPesterAcceptance.ps1` |
| Evidence | Pull guest logs + `state.json`, copy host `BuildManifest`/`BuildDelta`/`BuildProfile`, write `acceptance-result.json`, print the verdict | PowerShell Direct (in-script) |

### Supporting scripts (not phases)

| Script | Owns |
|--------|------|
| `New-WinMintHyperVProfile.ps1` | Author a Hyper-V-valid profile (`-Tier Full\|Smoke`; Pro, Pro generic key, unattended local account) |
| `Test-WinMintHyperVProfile.ps1` | Validate a profile for VM acceptance (`-Tier Full\|Smoke`) |
| `Warm-WinMintBuildCache.ps1` | Populate font/payload caches under `%LOCALAPPDATA%\WinMint\cache` without a full ISO build |
| `Push-WinMintSetupScripts.ps1` | Fast-iterate `setup`/`firstlogon` into a **running** guest over PowerShell Direct; `-RerunFirstLogon`, `-WaitForAgent` (uses `-AgentMode Headless` — no setup shell UI) |
| `Invoke-WinMintGuestPesterAcceptance.ps1` | Pester guest desktop inspect via PowerShell Direct |
| `Test-WinMintOfflineImageRemovals.ps1` | Post-build offline WIM provisioned AppX/capability drift gate |
| `Invoke-WinMintVmCheckpoint.ps1` | Save/restore/list Hyper-V checkpoints at the post-Setup boundary (shared helpers in `WinMint-VmConsole.ps1`) |
| `Invoke-WinMintPesterContract.ps1` | Pester 5 wrapper for `tests\contract\WinMint.Contract.Tests.ps1` (includes legacy `Test-ProfileInvariants.ps1`) |
| `Start-WinMintVmAcceptanceManaged.ps1` | Agent entry: detached acceptance + `managed-run.json` state |
| `Get-WinMintVmAcceptanceStatus.ps1` | Poll managed run (`complete`, `status`, `verdict`, `observePid`, log tail) |
| `Start-WinMintVmObserve.ps1` | Attach Basic VMConnect to a running test VM (passive view) |
| `WinMint-VmConsole.ps1` | Shared helpers (repo root, managed state, OOBE poll, VMConnect Basic observe) |

## FirstLogon presentation

Shipped ISOs default to the **provisioning lock** (native `WinMintSetupShell.exe`
fullscreen host + `ProvisioningGuard` desktop guard). The lock engages before
region restore and live-user defaults so the user never sees a naked desktop; the
desktop is revealed only after `release-provisioning-lock`. VM maintainer loops
and `Push-WinMintSetupScripts.ps1` use `-AgentMode Headless` or
`WINMINT_FIRSTLOGON_MODE=headless` so automation is not blocked by the UI. Legacy
Windows Terminal + Spectre remains available via `-AgentMode Console` or
`WINMINT_FIRSTLOGON_MODE=console`.

**Provisioning lock acceptance (ISO / `-AgentMode Auto`):**

| Scenario | Pass |
|----------|------|
| Primary monitor | Fullscreen host + foreground; no usable taskbar |
| Secondary monitors | Black covers (startup-style), no desktop bleed |
| Win key / Start | Blocked or immediately dismissed for provisioning duration |
| Alt+Tab | Blocked via `DisableTaskSwitching` + foreground reclaim; not a security boundary (Ctrl+Alt+Del still wins) |
| Agent failure | Lock remains until `failed` phase + dwell; guard always cleared on exit |
| Success path | Guard cleared, taskbars restored, explorer reload only after host exits |
| VMConnect / late attach | Host still paints and exits on control phase (dwell timers) |
| Headless mode | No host; no guard side effects left behind |

**Log markers** (`FirstLogon.log`): `provisioning-lock:guard-engage` before region
restore; `provisioning-lock:guard-release` and `provisioning-lock:host-exit` on
teardown. Smoke lock evidence tier: guard engage appears before DMA restore log
lines; secondary monitor blank count in `SetupShell.log` when multi-monitor.

**Presenter UX contract:**

| Concern | Behavior |
|---------|----------|
| Splash coverage | Native AOT `WinMintSetupShell.exe` Direct2D splash (GDI fallback when Direct2D unavailable); reads `setup-shell-status.json` / control JSON — no WebView2 or HTML assets on ISO |
| Desktop guard | `NoWinKeys` + hidden taskbars while lock is active; cleared on PS teardown and native exit |
| Status honesty | `prepare`/`region` groups reflect pre-agent work; `finishing` labels desktop/shell work |
| Start menu | Dismiss on shell exit; explorer reload for Start pins runs **after** lock release |
| Terminal exit | Native host closes on `complete`, `failed`, or `reboot` within dwell timers; D2D failure must not hang |

Smoke acceptance expects `SetupShell.log` to contain `host=native` from the AOT exe.
After setup-shell or FirstLogon staging edits, rebuild published binaries with
`tools/release/Build-WinMintSetupShell.ps1` and run managed smoke with `-ForceBuild`.

## Verdict contract

`acceptance-result.json` is a flat record (intentionally not a formal schema yet):

- `verdict` — `pass` only when the guest was reachable **and** FirstLogon reached
  `run.status = 'ok'`. FirstLogon warning steps are a pass with a noted reason.
- `acceptanceTier` — `Full` or `Smoke`, inferred from `profileName` or `-Tier`.
- `firstLogon` — `status`, `exitCode`, `completedAt`, `failedSteps`, `warningSteps`,
  `rebootPending`, mirrored from the guest agent `state.json`.
- `inspect` — the live desktop signals from the inspector (best-effort; a failure
  here is non-fatal and recorded in `reasons`).
- `setupShell` — OOBE splash evidence: live `running`/`finishing` phase poll,
  desktop-guard observation, `oobe-splash.png` screenshot, and pulled
  `SetupShell.log` / `FirstLogon.log` / `setup-shell-control.json` (`complete`).
  Failures here fail the verdict.
- `setupComplete` — pulled ProgramData SetupComplete channel counts
  (`errorLineCount` / `warningLineCount`). See hard/soft channels below.
- `removalDrift` — post-FirstLogon AppX/capability drift gate (smoke plumbing):
  fails when a profile keep-derived AppX removal prefix matches a removable
  installed or provisioned package, or when `Media.WindowsMediaPlayer` /
  `Microsoft.Wallpapers.Extended` capabilities are still installed. Records
  `systemRemnants` (System/NonRemovable catalog matches) and `rehydratedPresent`
  (e.g. Edge Game Assist) as informational only — not plumbing failures.
- `liveInstallAudit` — **Full tier only:** pulled `LiveInstallAudit.json` from
  the guest; `evidenceVerdict` fails when `summary.error > 0` (warnings are advisory).
- `reasons` — human-readable notes explaining the verdict.

### SetupComplete hard vs soft channels

| Artifact | Product writer | Smoke plumbing |
|----------|----------------|----------------|
| `SetupComplete_errors.log` | `Write-ScError` / action dispatch catch | Non-empty → **plumbing fail** (no harness allowlist) |
| `SetupComplete_warnings.log` | `Write-ScWarn` | Non-empty → `warnings` only; does not fail plumbing alone |

### Regression nets (do not reintroduce)

| Failure class | Prevention |
|---------------|------------|
| SetupComplete winget install/upgrade of Windows Terminal under SYSTEM (timeout / hang) | Toolchain is inbox presence-check only; contract forbids winget/`Start-Process` in `Toolchain.ps1` |
| WU history / noisy restore → false plumbing fail | `WindowsUpdate.ps1` only restores policy/service Start via `reg.exe` `Start-Process`; no history APIs |
| Soft SetupComplete noise failing Smoke | Soft issues go to `SetupComplete_warnings.log`; harness classifies via `Test-WinMintVmSetupCompleteLogEvidence` |
| Local+autoLogon left on `defaultuser0` (FirstLogonAnim hang) | Early + final Autologon stamp fail-closed; Wait probe writes `vm.autologon` plumbing into `acceptance-result.json` |
| Stale ISO after `src/runtime/setup` edits | Image fingerprint `schema=image-v2` includes `setupRuntime`; `Build-And-TestVm` prefers `Final ISO:` from the verbose build log |

## When acceptance is "green enough"

Per the roadmap, physical installs (Track B) stay deferred until this pass is
credible: a clean `pass` for the ARM64 VM profile, FirstLogon completing without
blocking failures, and an evidence folder a maintainer can read. Promote to
hardware only after that.
