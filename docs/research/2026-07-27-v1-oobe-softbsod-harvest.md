# Harvest — v1 SL7 ForceBuild soft-BSOD / FirstLogon collapse (2026-07-27)

**Evidence:** `output/vm-acceptance/WinMint-ARM-Test-20260727-193431/`  
**Verdict:** failed (no commit). Managed worker died in Wait; OOBE soft-BSOD loop; not a green Smoke.

Use as **behaviour archaeology for v2 Supervisor / unattend**, not as a v1 patch backlog.

## What failed (stacked)

1. **OOBE soft-BSOD loop** — “Why did my PC restart?” persists after Next. Guest stayed in OOBE (`OobeInProgress=1`, `CmdLine=oobe\windeploy.exe`). Event **1074** from `taskhostw`: **Operating System: Reconfiguration (Unplanned)** `0x20004` ~2 min after SetupComplete ends. Network was up; Wi‑Fi icon lied.
2. **Autologon race** — SetupComplete stamped `dev` + `AutoAdminLogon=1` (early + final), but harness/watchdog saw `defaultuser0` or empty `DefaultUserName` across reconfigs. Stamp is not the root; OOBE reboot reverts / races Winlogon.
3. **Shell ↔ RunOnce** (prior run `…-202727`) — custom `WinMintLogonShell` prevented Explorer → Unattend RunOnce never fired. Mitigated in tree by LogonShell self-starting FirstLogon; **do not** reintroduce peer Shell + RunOnce in v2.
4. **FirstLogon elevation** — when FirstLogon did start: `schtasks /Create` **Access Denied**, `notElevated`, state `failed`. Separate from Autologon mismatch.
5. **Harness** — Autologon fail-fast during SetupComplete stamp window can false-positive; external stall watchdog had a managed-run `complete` write bug (later closed manually).

## v2 must-not-repeat

| Anti-pattern | v2 direction |
|--------------|--------------|
| Guest pwsh FirstLogon + PreLock + LogonShell + RunOnce | One AOT **Provisioning Supervisor** as Shell (`--machine-setup` + tenure) |
| Autologon stamp while OOBE still owns the machine | Finish / exit OOBE **before** Shell tenure; machine-setup verify after specialize complete |
| Treat soft-BSOD as “need network” | Diagnose **0x20004** + `SYSTEM\Setup` / pending reboot; don’t chase Wi‑Fi icon |
| Fail-fast on empty DefaultUserName mid-SetupComplete | Gate Autologon probes on SetupComplete done + OOBE not in progress |
| Peer splash exe + transaction + guard | In-process splash; Shell-tenure lock; fail-open to Explorer |

## Smoke gate implication

Do **not** spend further ForceBuild cycles on v1 FirstLogon green. Primary path: **v2 Smoke** (ADR-011). Harvest imaging/DMA/autologon *intent* only via `docs/PORT-FROM-V1.md`.
