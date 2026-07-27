# FirstLogon splash / theme / DMA audit

**Date:** 2026-07-22  
**Evidence:** `output/vm-acceptance/WinMint-ARM-Test-20260722-142745/` (freeze: `audit-freeze/`)  
**Guest:** `WINMINTVM\dev` · profile Hyper-V SL7 Smoke · `hardwareBypass` + SkipVtpm  
**Scope:** Audit only — no product fix in this change set.

## Causal timeline (local +03:00)

| Time | Source | Event | Gap notes |
|------|--------|-------|-----------|
| 14:56:51.120 | `FirstLogonCommands-fired.txt` | Autounattend FirstLogonCommands fire | |
| 14:56:55.958 | `FirstLogon.log` | `provisioning-lock:guard-engage` (PreLock) | **+4.84s** fire→guard — unexplained in-script; attributed to **pwsh 7 cold start + dot-source `ProvisioningGuard.ps1`** before first log line |
| 14:57:04.107 | `FirstLogon.log` | `host-start … early=1` pid=240 | **+8.15s** guard→host — see PreLock gap attribution |
| 14:57:05.302 | `FirstLogon.log` | `FirstLogon.ps1 start` | +1.2s after host-start (second pwsh) |
| 14:57:06.023 | `FirstLogon.log` | `host-adopt` pid=240 | PreLock host reused |
| 14:57:08.010 | `FirstLogon.log` | Language list → `en-US, he-IL` | |
| 14:57:08.124 | `FirstLogon_errors.log` | **Culture fail:** LocaleName `en-US` after Set-Culture `he-IL` | ~114ms after language list |
| 14:57:09.020 | `FirstLogon.log` | Re-applied culture `he-IL` after international copy | Intermediate fail already recorded |
| 14:57:09.280 | `FirstLogon_errors.log` | DMA restore non-compliant (hard) | Sticky error list |
| 14:57:10.395 | `FirstLogon.log` | ImmersiveColorSet broadcast (Desktop defaults) | **First theme broadcast** — ~19s after logon command fire |
| 14:57:15.849 | `FirstLogon_errors.log` | Skipping WinMintAgent (DMA hard fail) | |
| 14:57:23.885 | `FirstLogon.log` | `guard-release` / host-exit | Splash unlock failed path |
| 11:57:10Z / 11:57:19Z | `run-events.jsonl` | Harness `setupShellPhase` running→**failed** | Matches guest unlock |
| (later) | freeze `International` | LocaleName **`he-IL`** | Final hive OK despite fail-closed |
| (later) | freeze `Personalize` | Apps/System light theme = **0** | Keys dark; broadcast was late |
| — | `DefaultUser_errors.log` | `TaskbarDa` access denied | Offline Default hive noise; **not** primary light-desktop cause |

**Unexplained after freeze (resolved below):** guard→host 8.15s on first logon; culture intermediate fail while final LocaleName became he-IL.

## Symptom split

| Symptom | User-visible | Same session? | Independent RC? |
|---------|--------------|---------------|-----------------|
| Light desktop at first paint | Yes — stock Explorer before splash | Yes | **Yes** — PreLock registry-only, no ImmersiveColorSet |
| Late splash (~9–13s) | Yes | Yes | **Yes** — pwsh cold start + first native host launch cost |
| Splash failed / agent skipped | Yes | Yes | **Yes** — DMA culture race + sticky intermediate error |

## PreLock → host gap attribution

Instrumented PreLock mirror on the same guest (`tools/dev/Measure-WinMintPreLockGap.ps1` → `audit-freeze/prelock-gap-measure.txt`):

| Marker | Elapsed ms | Step ms |
|--------|------------|---------|
| prelock:enter | 4 | — |
| after-dot-source-guard | 122 | ~54 |
| after-guard-engage | 311 | ~186 |
| **after-dismiss-start** | **4512** | **~4198** |
| after-theme-reg | 4539 | ~25 |
| after-host-start | 4927 | ~147 |

Earlier micro-bench of a *different* Add-Type name was ~551ms; the real `WinMint.StartDismiss` Add-Type inside `Invoke-WinMintProvisioningDismissStartMenu` cost **~4.2s** on this guest.

**Attribution:**

1. **Fire → guard (~5s):** Autounattend launches `pwsh -File FirstLogon.PreLock.ps1`. No log until `Enable-WinMintProvisioningGuard` finishes. Dominated by **pwsh cold start + loading ProvisioningGuard**.
2. **Guard → host (~8s smoke / ~4.6s measured):** Majority is **`Add-Type` for Start Menu dismiss** (~4s), not theme regs or `Start-Process` (~147ms warm). Smoke’s extra ~3–4s on first logon fits colder first JIT/AV on that path + first native host bring-up.
3. **Ruled out as primary:** intentional sleep in PreLock (none); waiting on FirstLogon module load (host starts before FirstLogon.ps1); missing exe (host-start logged with pid); “Explorer scheduled PreLock late” as the in-script 8s (fire→guard is separate cold start).

## Theme loop (registry-only vs broadcast)

- **Code:** `FirstLogon.PreLock.ps1` writes `AppsUseLightTheme`/`SystemUsesLightTheme=0` only; ImmersiveColorSet lives in `FirstLogon.Desktop.ps1` and runs ~6s after FirstLogon start.
- **Red command:** `pwsh -NoProfile -File tools\dev\Assert-WinMintPreLockThemeBroadcast.ps1` → **fails** while PreLock lacks ImmersiveColorSet / shared broadcast helper.
- **Live guest check:** after forcing light + ImmersiveColorSet, dark **registry-only** updates hive immediately; shell chrome still depends on broadcast (product comment in Desktop.ps1; smoke observation of light taskbar until 14:57:10).
- **Disprove condition for “broadcast required”:** if assert goes green without adding broadcast to PreLock — it won’t; static gate is intentional.

## DMA `he-IL` culture isolation

**Requested:** restoreUserLocale `he-IL` after DMA setup `en-IE`.  
**Logged failure:** `LocaleName 'en-US' after Set-Culture (expected 'he-IL')` at 14:57:08.124.  
**Final freeze:** LocaleName `he-IL`, language list `en-US,he`, report `compliant: false` with that single culture error, `observed.localeName: he-IL`.

**Repro** (`Assert-WinMintDmaCultureRestoreRace.ps1`, language-list then immediate Set-Culture + one retry):

- Host session: flaky (0–1 / 8 losses) — not a reliable red loop alone.
- Smoke guest (earlier isolate): **6/8** immediate+retry misses; most settled ~100ms later.
- Guest assert artifact: `audit-freeze/dma-culture-race-guest.txt`.

**Verdict on DMA:**

- **Not** “he-IL impossible / missing language pack” (culture settles; freeze shows he-IL).
- **Not** “verify reads process culture” (`Get-WinMintFirstLogonUserLocaleName` correctly reads hive LocaleName; process culture can lag — by design).
- **Is** language-list rebuild **race** with `Set-Culture`: Region.ps1’s immediate one-shot retry is too weak; intermediate throw is **sticky** in `$errors` even when post-Copy re-pin and final observed LocaleName match → fail-closed → agent skip → splash `failed`.

Red command (prefer guest after DMA/en-IE-shaped session):  
`pwsh -NoProfile -File tools\dev\Assert-WinMintDmaCultureRestoreRace.ps1 -Trials 16`  
Exits non-zero when any trial loses the immediate-retry race.

## Root-cause matrix

| Symptom | Candidate RC | Status | Disprove if… |
|---------|--------------|--------|--------------|
| Light desktop at first paint | PreLock missing ImmersiveColorSet | **Confirmed** | Broadcast-in-PreLock assert green without broadcast (won’t); registry-only sufficient for chrome (smoke contradicts) |
| Splash late | Autounattend after Explorer / slow early host | **Confirmed split:** ~5s pwsh cold + ~4s StartDismiss Add-Type (+ colder first-logon remainder); host Start-Process ~0.15s | Markers show dismiss Add-Type dominates guard→host (observed) |
| Splash failed unlock | DMA culture hard-fail | **Confirmed** as race + sticky intermediate error | Culture restore loop green with current Region.ps1 under language-list→Set-Culture stress (assert stays red) |
| DefaultUser `TaskbarDa` | Offline hive ACL | **Ruled out** as splash/theme/DMA cause | — |
| hardwareBypass / SkipVtpm | Caused culture fail | **Ruled out** | Race reproduces on guest without VTPM involvement |
| Weaken DMA gate for green splash | — | **Rejected** | Would hide real restore bugs |

## Ruled out

- Missing PreLock / wrong unattend order (PreLock runs; early host pid adopted).
- Permanent inability to set `he-IL` LocaleName.
- Process-culture false negative as the sole bug (hive check is correct; race is real).
- Making `hardwareBypass` the product default as a fix.
- Broad FirstLogon rewrite unrelated to PreLock chrome + DMA culture settle.

## Single mature fix recommendation

**One path, two seams, one release:**

1. **UX (PreLock):** Reuse the Desktop ImmersiveColorSet broadcast helper (extract small shared function; do **not** duplicate P/Invoke) **before** `Start-WinMintProvisioningHostEarly`, so chrome is dark under the splash. Keep early host; do not wait on FirstLogon module load. **Also** shrink the dismiss gap: precompile/cache the StartDismiss Add-Type (or replace with a no-Add-Type dismiss) so guard→host is not blocked ~4s on JIT. Optional: keep high-res PreLock markers permanently — they are cheap.
2. **DMA (Region):** After language-list rebuild, settle culture with **short bounded backoff** (e.g. retry Set-Culture until LocaleName matches or ~500–1000ms), and **only fail-closed on final observed LocaleName** (do not keep intermediate race throws as sticky errors if final verify passes). Keep hard skip agent when final verify fails.
3. **Regression:** keep `Assert-WinMintPreLockThemeBroadcast.ps1` (must go green) + `Assert-WinMintDmaCultureRestoreRace.ps1` (must go green under stress) + existing provisioning-guard contract updated to require PreLock broadcast.

**Do not** ship a pile of unrelated patches; **do not** soften the DMA hard gate without final-state compliance.

## Commands used in this audit

```powershell
# Theme (expect RED until PreLock broadcasts)
pwsh -NoProfile -File tools\dev\Assert-WinMintPreLockThemeBroadcast.ps1

# DMA race (expect RED on current Region retry policy under stress)
pwsh -NoProfile -File tools\dev\Assert-WinMintDmaCultureRestoreRace.ps1

# PreLock gap measure (guest or local)
pwsh -NoProfile -File tools\dev\Measure-WinMintPreLockGap.ps1
```
