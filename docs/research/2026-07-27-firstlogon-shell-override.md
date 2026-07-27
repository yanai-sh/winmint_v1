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
