# First-logon Shell override (splash before desktop)

**Date:** 2026-07-27  
**Status:** Implemented

## Goal

After auth, the first session UI is the WinMint provisioning splash — never stock Explorer — until FirstLogon reaches a terminal desktop phase. Fail-open restores `explorer.exe`.

## Mechanism

1. **DefaultUser** stamps `Winlogon\Shell` = `C:\Windows\Setup\Scripts\WinMintLogonShell.cmd`.
2. **WinMintLogonShell** starts `WinMintSetupShell` immediately, waits for status phase `complete`/`failed` or 90 minutes, then unlocks to `explorer.exe`. Phase `reboot` keeps the custom Shell.
3. **FirstLogon** release/finalize calls `Unlock-WinMintProvisioningLogonShell` (not on `reboot`).
4. **PreLock** remains as adopt + chrome under cover.

## Fail-open

| Trigger | Action |
|---------|--------|
| No pwsh 7 | cmd starts explorer, sets Shell |
| Splash host missing | Unlock |
| 90 min timeout | Unlock |
| phase failed/complete | Unlock |
| phase reboot | Hold Shell |

## Not covered

Logon UI (password). Stamp failure leaves Explorer as shell (PreLock race again).

## Deadlock lesson (2026-07-27 smoke)

Unattend `FirstLogonCommands` are parked in `HKLM\...\RunOnce` and normally fire when **Explorer** starts. With `WinMintLogonShell` as Shell, Explorer never starts → RunOnce never runs → FirstLogon.ps1 never advances phase → LogonShell waits forever / FirstLogonAnim “Just a moment”.

**Mitigation:** `WinMintLogonShell.ps1` self-starts FirstLogon whenever it owns Shell and FirstLogon is not already running (PreLock only on first drive). Clears `Unattend*` / `WinMintFirstLogon` RunOnce values so Explorer does not double-run after unlock. Reboot-resume must not depend on Explorer-triggered RunOnce.
