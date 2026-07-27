# WinMint Roadmap

> **v2 scope:** Prefer [ADR-011](../decisions/ADR-011-winmint-v2-greenfield.md) and [`seed-for-new-repo/`](seed-for-new-repo/) (`docs/ARCHITECTURE.md`, `docs/WORKFLOW.md`). Track I matches that plan: orchestrator-first dual hosts (Avalonia wizard after Smoke; Native AOT splash). Image quality: test/Smoke = fast lane; release = Max + cleanup.

## Purpose

This roadmap is a living project document.

It has two jobs:

1. clearly state the **next development priorities**
2. keep the **broader strategic backlog** visible so WinMint does not optimize one area while neglecting the rest of the product

It is intentionally broader than a short-term sprint plan. It should still be readable as an execution document: the highest-priority tracks come first, each track is phased, and lower-priority tracks remain visible without pretending they are next.

## Current State

WinMint is no longer primarily blocked on backend architecture.

The project now has:

- a PowerShell module-first backend runtime under `src/runtime/modules/`
- explicit build contracts: `BuildProfile.json`, `BuildManifest.json`, `BuildDelta.json`, and `state.json`
- a headless engine that owns profile normalization, install-plan derivation, ISO/WIM servicing, setup payload staging, FirstLogon orchestration, reporting, and audit generation
- a WebView2 wizard frontend that can create intent, generate profiles, invoke builds, and render backend-generated review data
- a stronger contract and validation spine around setup payloads, FirstLogon, profile invariants, bootstrap behavior, and release boundaries
- a native fullscreen **setup shell** (`WinMintSetupShell.exe`) for default FirstLogon presentation, with JSON IPC, desktop guard, OOBE stage/item progress, accessibility (reduced motion / high contrast / Narrator), and VM smoke evidence gates
- **SetupComplete Autologon** stamp-before-toolchain (and final restamp) so Local+autoLogon never leaves `defaultuser0` for first interactive logon
- `needsReboot` scheduled under the provisioning lock; presenter/host surfaced in VM acceptance plumbing
- Edge stays installed (`keep.edge` always true) with noise/ADMX debloat only — no uninstall product path
- baseline Microsoft Coreutils host CLI; managed WSL `wsl.conf` + default user per distro; Raycast/Everything product paths purged
- dual-channel Spectre One Half Dark build logging + verbose file mirror; WinUtil-inspired Max-cache resume / PE drivers / tweak undo lessons
- network device-metadata prompts blocked by default (`PreventDeviceMetadataFromNetwork`) with WU driver delivery preserved
- global offline removal of legacy Windows Media Player and Extended Wallpapers capabilities, plus a smoke **removal drift** gate for AppX/capability regressions
- an ephemeral default bootstrap path: `irm | iex` downloads and verifies a release in a unique temp session, launches from that session, and removes it afterward instead of installing into `%LOCALAPPDATA%\WinMint\versions`
- bootstrap failure handling that reports the active operation, failure category, reason, recovery guidance, and retry safety instead of surfacing only raw PowerShell errors
- a release readiness contract in `config/release-readiness.json`, with `docs/Release-Readiness.md` and validation checks keeping the public launch path, host requirements, and release gates aligned
- a hardware acceptance inventory in `config/hardware-acceptance.json`, with Surface Laptop 7 ARM64 first, tracked amd64 follow-up targets, profile links, driver requirements, destructive-install flags, and required evidence
- Hyper-V **SL7 smoke** profiles alongside lean plumbing smoke; WSL runtime mocked on smoke profiles

The main project risk has shifted.

The hard problem is less "can the backend do the work?" and more:

- can acceptance be proven systematically
- can the GUI become the normal product surface
- can the live desktop result be made deliberate and polished

## Next Priorities

These are the current top priorities for continued development.

1. **Greenfield Project Reconstruction (Track I - WinMint v2)**
   New repo: C# Orchestrator + CLI, elevated thin host Servicing, **C# Provisioning Supervisor** (machine-setup + Shell + in-process splash + jobs; **guest pwsh-free**) for Smoke; Avalonia wizard **after** Smoke. Same settle/executor/reboot/lock on Smoke and metal. Image quality lanes + Smoke harness caching — not a DISM speed miracle from C#. See ADR-011 + seed `ARCHITECTURE.md` / `STACK.md` / ADR-004.

2. **FirstLogon and desktop experience maturity**
   Shell layers, launcher behavior, package installs, and live-user setup need stronger end-state validation and refinement. VM acceptance should prove the common live-user path before hardware installs begin.

3. **Live hardware acceptance**
   VM testing is necessary but not sufficient, and it has now passed the acceptance gate for ARM64. The hardware inventory exists and the evidence loop is intentionally lightweight; we are now ready to begin real Surface Laptop 7 and x64 hardware installs.

4. **Release and bootstrap regression discipline**
   The core public launch path is now defined and guarded. Keep it green through release readiness validation, clean-host smoke, and docs consistency as other product areas change.

5. **Hyper-V VM test architecture**
   Hyper-V is the acceptance gate before physical installs, not the highest product priority. The VM work should stay focused: prove unattended install, FirstLogon completion, evidence capture, and result evaluation well enough to safely move into real hardware acceptance.

The order above is deliberate:

- **Greenfield reconstruction is first** because the orchestrator-first C# boundary + thin Servicing kernels remove the PowerShell monolith and UI-engine bridge debt before more product depth piles on
- **FirstLogon and desktop maturity is second** because the installed system is the product outcome; if this is unreliable or visually unfinished, the ISO builder has not succeeded
- **live hardware acceptance is third** because WinMint must ultimately prove itself on real Surface and x64 machines, and VM acceptance has now unblocked physical testing
- **release/bootstrap remains visible** because regressions in the public launch path can still block adoption
- **Hyper-V architecture is fifth in product priority but still gates physical installs** because it is a safety mechanism and regression loop, not the product outcome itself

The order is still not rigid. If VM acceptance or release testing shows a higher-severity failure, that track should jump ahead.



## Track A — Release and Bootstrap Hardening

Phase A1, **Ephemeral Bootstrap and Clean Host Footprint**, is complete and no longer active roadmap work. The active code path is `winmint.ps1`; the regression guard is `tools/release/Test-WinMintReleaseLaunch.ps1`, which verifies SHA256 enforcement, packaged runtime shape, temp-session execution, cleanup, and the absence of a default `%LOCALAPPDATA%\WinMint\versions` release cache. Durable release caching remains an explicit opt-in through `-InstallRoot` or `-CacheRelease`.

Phase A2, **Failure and Recovery UX**, is complete and no longer active roadmap work. The bootstrapper now wraps failures with operation, failure kind, reason, recovery guidance, and retry safety. Release smoke covers the bad-checksum integrity path and verifies cleanup still happens after failure.

Phase A3, **Public Usage Readiness**, is complete and no longer active roadmap work. The release readiness bar is documented in `docs/Release-Readiness.md`, backed by `config/release-readiness.json`, checked by repository validation, and exercised by release smoke. Future release work is regression discipline unless a concrete launch failure reopens Track A.

## Track B — Live Hardware Acceptance

### Phase B1 — Acceptance Inventory

Phase B1, **Acceptance Inventory**, is complete and no longer active roadmap work. The inventory is `config/hardware-acceptance.json`; the runbook is `docs/Hardware-Acceptance.md`; repository validation enforces profile existence, architecture matching, SurfaceCatalog use for Surface Laptop 7, and required evidence/check coverage.

### Phase B2 — Evidence Loop

Goal: make live installs produce reusable evidence.

Status: active. The runbook now defines a manual evidence folder, required copied artifacts, and `notes.md` contents. VM acceptance has proven credible on ARM64, and physical installs are unblocked. Do not add a collector or evidence-package schema until real Surface and x64 runs show repeated manual collection pain.

Work:

- ~~complete the VM acceptance path in Track D before the first real-machine install~~ (Done)
- collect the first Surface Laptop 7 evidence folder after a real install
- collect at least one x64 evidence folder after a real install
- use live install audit output as structured feedback rather than incidental diagnostics
- convert repeated findings into focused contract tests or product fixes

Exit criteria:

- VM acceptance has passed enough to make physical installs a hardware-specific validation step, not the first end-to-end test
- hardware acceptance produces comparable evidence instead of one-off observations

### Phase B3 — Ongoing Regression Coverage

Goal: make hardware acceptance sustainable over time.

Work:

- decide which profiles are recurring regression profiles
- decide which checks are release-gating versus occasional deep validation
- keep the matrix realistic for available hardware

Exit criteria:

- hardware validation remains practical and deliberate

## Track C — FirstLogon and Desktop Experience Maturity

### Phase C1 — FirstLogon Reliability

Goal: strengthen live-user setup as a product surface rather than a best-effort script chain.

Status (2026-07): Autologon stamp-before-toolchain + final restamp; OOBE splash stages with item-level progress and accessibility; `needsReboot` under lock; presenter/host acceptance plumbing; Track A/B polish must items shipped (pins under lock, winget catch-up honesty, DMA restore completeness, OOBE rehydration / live AppX exempts, Home quiet UX, Edge ADMX refresh). Remaining: keep smoke green and fold durability regressions into contract tests.

Work:

- continue hardening resumability and idempotency
- improve optional-module isolation and diagnostics
- refine retryable and reboot-requiring flows
- ensure module success means real end-state success, not only command completion
- keep setup-shell splash plumbing green on managed smoke (`setupShell.plumbingOk`, `control.phase=complete`)

Exit criteria:

- FirstLogon failures are narrower, clearer, and easier to recover from
- default FirstLogon feels like native post-install setup, not a terminal or a broken overlay

### Phase C2 — Shell-Layer Maturity

Goal: make shell selections produce a polished desktop, not just installed packages.

Work:

- improve `windhawk` preset confidence and lifecycle handling
- improve `yasb` + `thide` combined behavior and end-state ergonomics
- improve `komorebi` + `whkd` defaults and workspace behavior
- refine `nilesoft` integration
- align the actual installed desktop with UI preview intent

Exit criteria:

- selected desktop layers result in a desktop that feels deliberate and finished

### Phase C3 — Launcher and Desktop Integration

Goal: finish the user-facing experience around Search key binding, tray behavior, and shell coexistence.

Status: third-party launcher product paths (Raycast / Everything) purged in v1 — launcher selection stays `None`; Copilot hardware key → Search.

Work:

- verify Copilot hardware-key → Search binding with no third-party launcher
- refine status icons and startup behavior
- ensure desktop layers coexist predictably without a separate launcher product

Exit criteria:

- shell behavior feels like one product, not separate features stitched together

## Track D — Hyper-V VM Test Architecture

Track D is the current acceptance gate before Track B physical installs. It is
not the highest product priority, but it must be credible before real machines
are used for destructive ISO testing.

### Phase D1 — VM Testing Model

Goal: turn the current collection of scripts into an explicit test system.

Status: the explicit model now exists. `tools/vm/Invoke-WinMintVmAcceptance.ps1`
is a single orchestrator (build + boot → wait for FirstLogon → inspect → evidence)
delegating to the existing single-purpose scripts, and `docs/VM-Acceptance.md`
documents what each script owns and the Pro/unattended invariant. Remaining D1
work is mostly proving the model by running a real green pass and folding the Edge
experiment / future test classes into it deliberately.

Work:

- define VM test classes: install smoke, unattended install, first-logon completion, shell/app acceptance, audit runs, diagnostics
- define the boundaries between profile fixture, ISO build, VM provisioning, guest execution, evidence collection, and result evaluation
- make the Pro-for-Hyper-V invariant a first-class design rule

Exit criteria:

- VM testing has named layers and responsibilities — **met** (`docs/VM-Acceptance.md`)
- maintainers can explain what each script owns — **met** (phase/ownership table)

### Phase D2 — Harness Restructure

Goal: make VM testing composable and repeatable.

Status: partially met. The orchestrator supports attaching to a running VM
(`-SkipBuild`) and writes a standardized evidence directory
(`output/vm-acceptance/<vm>-<stamp>/` with `acceptance-result.json`). Remaining
work is reducing ad hoc coupling between the underlying build/VM/guest/rerun/log
helpers rather than adding more orchestration surface.

Work:

- restructure the harness into explicit phases
- reduce ad hoc coupling between build, VM creation, guest mutation, rerun, and log collection helpers
- standardize output layout and evidence directories
- support partial reruns at deliberate boundaries

Exit criteria:

- VM runs can be resumed and inspected by phase
- the harness no longer feels like a loose collection of convenience scripts

### Phase D3 — Scenario Matrix

Goal: stop overloading one VM profile with too many product concerns.

Work:

- define a small matrix of VM acceptance profiles by purpose
- split browser/editor/WSL checks from shell-layer checks where useful
- decide which desktop-layer and launcher scenarios belong in VM acceptance versus live hardware
- keep scenarios narrow enough that failures are attributable

Exit criteria:

- VM scenarios are intentional and diagnosable

### Phase D4 — Evidence and Evaluation

Goal: make VM outcomes machine-readable and comparable across runs.

Status: partially met — `acceptance-result.json` records `setupShell`, `removalDrift`, plumbing vs evidence verdicts, and standardized evidence directories. Formal schema still deferred.

Work:

- define required evidence artifacts
- evaluate success/failure from `BuildManifest`, `BuildDelta`, setup logs, and `state.json`
- standardize result summaries
- prepare the harness for future gated automation, even if full VM runs stay local for now

Exit criteria:

- VM acceptance outcomes are systematic, not mostly manual interpretation

## Track E — Avalonia Wizard (late; not early after Smoke)

Avalonia is **not** in v1 and is **not** the next v2 vertical after Smoke. CLI stays the authoring surface. Track E is backlog until product depth warrants a GUI. ISO guest UI stays the Provisioning Supervisor’s **in-process** Native AOT splash — never Avalonia on the ISO.

### Phase E1 — Avalonia wizard foundation

Goal: profile-authoring UI against Orchestrator ports once Smoke is green.

Work:
- Main window shell, navigation, design system
- Native AOT publish targets for the wizard host (separate from splash)

Exit criteria:
- Wizard shell launches and talks to Orchestrator ports without owning Servicing

### Phase E2 — Interactive wizard view

Goal: author and review a Profile visually.

Work:
- Configure screen mapped to clean-sheet Profile schema
- Review screen for build report / delta evidence
- Save Profile and invoke CLI/Orchestrator build

Exit criteria:
- A complete Profile can be configured, reviewed, and saved without WebView2

### Phase E3 — Splash remains in-process Native AOT

Goal: keep ISO splash as the Provisioning Supervisor’s in-process Direct2D/GDI presenter (Shell tenure), with optional evidence snapshots — not Avalonia, not a peer Splash.exe.

Work:
- Presenter cues (stages, a11y, reboot terminal) inside `WinMint.Provisioning`
- Do **not** move splash into Avalonia or split a peer Splash.exe for Smoke

Exit criteria:
- Splash launches fullscreen under Shell tenure; Avalonia is not on the ISO

### Phase E4 — Build execution UX (wizard client)

Goal: clean progress presentation while the unelevated CLI/Orchestrator drives elevated Servicing.

Work:
- Progress/status from Orchestrator job/report streams (not an in-process DISM runspace)
- UAC elevation prompting for Servicing only
- Error screens with recovery guidance

Exit criteria:
- Users can run, monitor, and troubleshoot builds from the wizard without the wizard mounting WIMs


## Track F — Reporting and Audit Polish

### Phase F1 — Human-Facing Summaries

Goal: make backend-generated outputs more useful to humans.

Work:

- improve manifest and delta summaries
- ensure CLI and GUI review surfaces align
- make reports more useful after real builds and installs

Exit criteria:

- reports are useful as evidence, not only as raw artifacts

### Phase F2 — Audit Usefulness After Install

Goal: make audit output a real feedback mechanism for product refinement.

Work:

- refine live-install audit output
- better connect audit findings to profile/setup/first-logon behavior
- define which warnings matter most for release readiness

Exit criteria:

- audit results feed roadmap prioritization directly

## Track G — CLI and Product Surface Polish

### Phase G1 — CLI Ergonomics

Goal: keep the CLI coherent even if the Avalonia UI wizard becomes the default path.

Work:

- improve help text and failure messages
- ensure `new`, `build`, `validate`, `list`, and `clean` remain coherent
- keep JSON and human output predictable

Exit criteria:

- CLI remains a strong headless interface, not a neglected fallback

### Phase G2 — Cross-Surface Consistency

Goal: ensure CLI, GUI, reports, and docs all describe the same product.

Work:

- align wording and behavior across surfaces
- keep contract-driven behavior authoritative
- prevent UI/CLI drift on defaults and option meanings

Exit criteria:

- the product reads as one system, not multiple competing surfaces

## Track H — Documentation and README Maturity

### Phase H1 — Documentation Boundaries

Goal: reduce both under-documentation and over-documentation.

Work:

- tighten what belongs in `README.md`, `AGENTS.md`, and `docs/`
- remove stale or duplicative detail
- keep executable truth in contracts and tests, not documentation drift

Exit criteria:

- docs are clearer, smaller where possible, and more trustworthy

### Phase H2 — Root README Maturity

Goal: make the repo front page feel like a mature GitHub-facing project.

Work:

- improve the product pitch and current-status framing
- explain what WinMint is, who it is for, and what its safety/product stance is
- present realistic setup and usage paths
- improve architecture and roadmap summaries for readers

Exit criteria:

- the root README looks intentional, credible, and current

## Track I — Greenfield Project Reconstruction (WinMint v2)

Canonical plan: [ADR-011](../decisions/ADR-011-winmint-v2-greenfield.md) + [`seed-for-new-repo/`](seed-for-new-repo/). Phases below match that decision (not the older unified Avalonia draft).

### Phase I1 — Seed repo + Orchestrator / CLI scaffold

Goal: New GitHub repo from the seed; buildable `WinMint.slnx` (Orchestrator, Cli, Provisioning); docs/ADRs; no Avalonia yet.

Work:
- Copy seed → new repo initial commit ([`COPY-INTO-NEW-REPO.md`](COPY-INTO-NEW-REPO.md))
- `/setup-matt-pocock-skills` → `/to-spec` (Smoke) → `/to-tickets`
- Keep **image quality** as a `build` run override (test/Smoke fast lane vs release Max+cleanup)

Exit criteria:
- Seed compiles/tests green; Smoke tickets exist; quality-lane contract is in the Smoke/imaging tickets

### Phase I2 — Servicing adapters + Payload Smoke spine

Goal: Unelevated CLI drives elevated thin `servicing/*.ps1`; stage Payload; guest pwsh-free Provisioning Supervisor on the ISO; DMA settle evidence.

Work:
- Implement Servicing kernels (mount/stage/hive/export) with quality-lane export/cleanup behaviour
- Guest control plane: C# Provisioning Supervisor (`--machine-setup` + Shell + in-process splash + jobs); DMA settle; Shell-tenure lock; checkpoint reboot; in-memory status + evidence snapshots — see seed ADR-004 / STACK.md
- Smoke harness: fingerprint/SmartBuild-style ISO reuse, checkpoint, push-only FirstLogon iteration (`tools/vm`)

Exit criteria:
- Profile → ISO → Hyper-V unattend → FirstLogon complete with splash + DMA evidence; Smoke uses fast image lane by default

### Phase I3 — Wizard + product depth (after Smoke)

Goal: Avalonia wizard; debloat/keep matrix and other product depth; release-quality ISO path as the published default.

Work:
- Avalonia wizard against the same Orchestrator ports
- Release builds default to Max + component cleanup; document clearly vs Smoke/fast
- Bootstrap/release packaging for the C# CLI (BitLocker / passwordless stay out of Smoke unless reopened by ADR)

Exit criteria:
- Wizard authors a Profile and invokes a real build; release ISO lane is the documented bare-metal path


## Lower-Priority / Future Tracks

These are not unimportant. They are simply not the most urgent right now.

### Distribution & Execution Variants

- **Fully In-Memory ISO Servicing: Rejected.** Serving a Windows ISO requires mounting WIM files, loading offline registry hives, and packaging boot files. Windows native APIs (`DISM`, `Mount-WindowsImage`, `oscdimg`) require physical filesystem NTFS mount points and ACL paths. Using virtual RAM disks is resource-heavy and fragile.
- **Post-Install Live Tweaking Mode: Future Backlog.** Explore running the FirstLogon agent scripts directly on an already-installed live system using an ephemeral bootstrap memory execution (`irm | iex`), bypassing ISO mounting entirely for quick post-install adjustments (similar to the live GUI utility path of WinUtil).

### Broader Automation

- more CI-friendly validation where Windows host restrictions permit it
- stronger automated release verification

### Additional UX Surfaces

- first-logon status/demo UI maturation
- future visual/reporting helpers if they stay aligned with the headless backend

## Roadmap Maintenance Rules

When this roadmap changes:

- keep **Next Priorities** short and explicit
- keep each major track phased
- do not pretend lower-priority tracks are unimportant; keep them visible
- promote a lower-priority track when evidence says it is blocking adoption, correctness, or user trust
- remove completed phases instead of letting the roadmap become a graveyard

## Definition of Wider Readiness

WinMint is not ready for broader real-user usage merely because one area looks polished.

Wider readiness requires credible progress across:

- release and bootstrap trust
- VM acceptance structure
- live hardware evidence
- FirstLogon and desktop-layer maturity
- a product-quality GUI or clearly acceptable CLI/bootstrap fallback
- trustworthy docs and project presentation

That is why this roadmap is broader than only the Avalonia UI wizard and VM testing, even though those remain important tracks.

