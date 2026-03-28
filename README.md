# 3X-UI Outbound Switcher

**Version:** v1.0.17

Switch between outbound by your priority on 3X-UI.

## What it does

`3X-UI Outbound Switcher` runs on the same server where **3x-ui** is installed and automatically switches the active Xray outbound based on your outbound tag priority.

Priority is derived from outbound tag names that start with uppercase letters:

- `A-Primary-Out`
- `B-Backup-Out`
- `C-Node-1`
- `D-Node-2`

The switcher checks outbound health, keeps fail/success counters, and updates only the active routing rule when a switch is needed.

## Key features

- Priority from outbound tag names like `A-...`, `B-...`, `C-...`
- Reads outbound tags directly from the live 3x-ui config
- Uses 3x-ui API for login, config fetch, and Xray restart
- Uses the same 3x-ui panel outbound test endpoint as the UI in **panel** probe mode
- Falls back to `systemctl restart x-ui` if API restart fails
- Supports online install and offline install
- Interactive CLI menu after install
- Systemd timer for automatic checks every 20 seconds
- Config validation before every switch
- Backup of `config.json` before every switch
- Logs and state files for troubleshooting

## Supported systems

- Ubuntu 22
- Ubuntu 24
- Ubuntu 25
- Debian 11
- Debian 12
- Debian 13

## Important notes

- This project must be installed on the **same server** where 3x-ui is installed.
- Only outbound tags matching `^[A-Z]-` are treated as prioritized outbounds.
- The switcher does **not** rename your outbounds. You must name them yourself.
- The switcher updates only the **last routing rule** that contains both `network` and `outboundTag`.
- Default probe mode is **panel**.
- `panel` probe mode uses the same request pattern as the 3x-ui outbound test button.
- If `panel` probe has an internal API error, the switcher falls back to `tcp` for that specific check.
- `http` probe mode is still available if you want to test through external URLs.

## Priority naming example

Use generic names like these:

- `A-Primary-Out`
- `B-Backup-Out`
- `C-Node-1`
- `D-Node-2`
- `E-Node-3`

Alphabetical order defines priority.

## Probe modes

### 1) panel (default)

This is the recommended mode.

It uses the same 3x-ui endpoint used by the **Test** button in the panel UI:

```text
/panel/xray/testOutbound
```

This means health checks follow the panel's own outbound test logic and do not depend on an external probe URL.

### 2) tcp

This mode checks TCP reachability to the outbound's configured address and port.

Use it when you want a simple fallback without any external URL dependency.

### 3) http

This mode creates a temporary local SOCKS probe and tests one or more external URLs through the outbound path.

Use it only when you specifically want HTTP-level confirmation.

## Online install

After you push these files to your GitHub repository, users can install with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ach1992/3x-ui-outbound-switcher/main/install.sh)
```

The installer will:

1. install only required missing dependencies
2. avoid `apt-get update` unless package install actually fails
3. copy files into `/opt/3x-ui-outbound-switcher`
4. create `/usr/local/bin/3x-ui-outbound-switcher`
5. automatically launch the interactive setup menu

## Offline install

Offline install is supported for servers without internet access.

### Prepare the files on another machine

Download or clone the repository and place these files inside a folder named exactly:

```text
/root/3x-ui-outbound-switcher
```

Required files:

- `install.sh`
- `uninstall.sh`
- `xui-switcher.sh`
- `README.md`

### Move the folder to the target server

Copy that folder to the target server so it becomes:

```text
/root/3x-ui-outbound-switcher
```

### Run the installer

```bash
cd /root/3x-ui-outbound-switcher
bash install.sh
```

If the installer detects that offline files exist in `/root/3x-ui-outbound-switcher`, it asks whether to install **offline** or **online**.

If the offline folder does not exist, installer goes **online automatically** and does not ask.

## Interactive setup

After install, the script launches the setup wizard and asks for:

- 3x-ui panel base URL
- 3x-ui username
- 3x-ui password
- `config.json` path
- Xray binary path
- fail threshold
- recover threshold
- minimum switch gap
- probe timeout
- probe mode
- probe URLs only when `http` mode is selected

### Example panel URL

```text
http://127.0.0.1:2053/your-base-path
```

or

```text
http://your-server-ip:2090/your-base-path
```

## Menu

The installed command is:

```bash
3x-ui-outbound-switcher
```

Menu options:

1. Install / Reconfigure
2. Show current config
3. Validate current Xray config
4. Start one check now
5. Start service once
6. Stop auto-run timer
7. Restart auto-run timer
8. Show status
9. Show logs
10. Enable auto-run timer
11. Disable auto-run timer
12. Uninstall
0. Exit

## CLI commands

```bash
3x-ui-outbound-switcher
3x-ui-outbound-switcher install
3x-ui-outbound-switcher show-config
3x-ui-outbound-switcher validate
3x-ui-outbound-switcher run-now
3x-ui-outbound-switcher start
3x-ui-outbound-switcher stop
3x-ui-outbound-switcher restart
3x-ui-outbound-switcher status
3x-ui-outbound-switcher logs
3x-ui-outbound-switcher enable
3x-ui-outbound-switcher disable
3x-ui-outbound-switcher uninstall
3x-ui-outbound-switcher version
```

## Files and locations

- App directory: `/opt/3x-ui-outbound-switcher`
- Env file: `/etc/3x-ui-outbound-switcher/switcher.env`
- State file: `/var/lib/3x-ui-outbound-switcher/state.json`
- Main log: `/var/log/3x-ui-outbound-switcher/switcher.log`
- Action log: `/var/log/3x-ui-outbound-switcher/actions.log`
- CLI symlink: `/usr/local/bin/3x-ui-outbound-switcher`

## Logs

Show live logs:

```bash
3x-ui-outbound-switcher logs
```

Or directly:

```bash
tail -f /var/log/3x-ui-outbound-switcher/switcher.log
```

Switch actions are stored in:

```bash
/var/log/3x-ui-outbound-switcher/actions.log
```

## Service behavior

- A systemd timer runs every 20 seconds.
- A switch happens only if the active outbound fails enough times.
- Recovery back to a higher-priority outbound requires enough consecutive successes.
- A minimum switch gap prevents rapid flapping.

## Default values

- Fail threshold: `3`
- Recover threshold: `2`
- Minimum switch gap: `60`
- Probe timeout: `8`
- Probe mode: `panel`

Default HTTP probe URLs, used only in `http` mode:

- `https://cp.cloudflare.com/generate_204`
- `http://connectivitycheck.gstatic.com/generate_204`
- `https://www.msftconnecttest.com/connecttest.txt`

## v1.0.17 fixes and improvements

- Fixed the `jq: --arg takes two parameters` bug in state handling
- Switched the default health-check mode to **panel**
- Added support for the same 3x-ui outbound test endpoint used by the UI
- Added automatic fallback from `panel` probe to `tcp` when panel probing errors internally
- Improved config extraction from `getConfigJson` responses that are wrapped instead of raw
- Kept `tcp` and `http` modes available as fallbacks

## Uninstall

From the menu:

```bash
3x-ui-outbound-switcher
```

Choose `Uninstall`.

Or directly:

```bash
3x-ui-outbound-switcher uninstall
```

## License

MIT


## What changed in v1.0.17

- Uses consistent lowercase/hyphenated paths only
- Cleans up legacy paths from older broken builds automatically during install and uninstall
- Validates and patches the real local `config.json` during outbound switching
- Timer uses `OnUnitInactiveSec` to avoid overlap between runs


## Important behavior after install

If you enable the auto-run timer during installation, the timer may immediately start the first check.
To avoid overlap, the installer now skips the manual `Run one health check now` step whenever the timer/service is already running.

If you want to run a manual check right away, choose `N` for auto-run during install, finish setup, then run the CLI manually.



## Self-test

Version v1.0.17 adds a built-in self-test. It can be run:
- automatically at the end of install/reconfigure
- manually from the CLI menu via `Run self-test`

The self-test checks:
- 3x-ui panel login
- config fetch from panel API
- local `config.json` validation
- prioritized outbound discovery from tags like `A-...`, `B-...`
- one live probe against the first prioritized outbound
- current timer/service status


## Installer overlap protection

Version v1.0.17 fixes the installer flow so that if you enable the auto-run timer and it starts immediately, the installer skips the manual `Run one health check now` step to avoid a lock conflict.

The CLI menu also checks for an active background run before starting a manual check.



## Final overlap guard

Version v1.0.17 applies the overlap protection in both places:
- during install/reconfigure
- in the interactive CLI menu

A manual check is now blocked with a clear warning whenever the timer/service or lock file indicates that another run is already in progress.



## Local config switch validation fix

Version v1.0.17 fixes the outbound switch step to patch and validate the real local `config.json` on disk instead of the API-fetched config copy.

This resolves cases where health checks succeed, but switching fails with:
- `Modified config failed validation.`

The self-test now also includes a dry-run validation of the local switch patch.



## Switch-valid candidate filtering

Version v1.0.17 adds a second safety gate for outbound selection:

An outbound is now eligible for switching only if:
1. its probe succeeds
2. a dry-run patch of the real local `config.json` with that outbound also passes `xray run -test`

This prevents repeated loops where probing succeeds but switching keeps failing with:
- `Modified config failed validation.`

Validation stderr is now also written to the switcher log for easier debugging.



## Panel-truth switching mode

Version v1.0.17 changes the switch decision model:

- panel outbound test is the primary source of truth
- `xray run -test` is now diagnostic only and no longer blocks a switch
- after each switch, the script:
  1. restarts Xray/panel
  2. waits for the panel to become ready
  3. logs in again
  4. runs a post-switch health check on the selected outbound
  5. restores the backup automatically if the service does not come back healthy

This better matches real 3x-ui behavior where panel testing and manual switching may succeed even when strict `xray run -test` validation does not.



## Restart readiness fix

Version v1.0.17 improves post-switch readiness detection:

- readiness is no longer based on a simple HTTP status check against `/login`
- the script now waits until both of these succeed again after restart:
  1. panel login
  2. `getConfigJson` from the panel API

This better matches real 3x-ui recovery behavior after restart and avoids premature rollback when the panel or API needs more time to come back.
Default values were also updated to:
- `Seconds to wait after restart`: `5`
- `Panel/API ready timeout after restart`: `90`



## Panel update API switching

Version v1.0.17 removes direct switching through local `config.json` edits.

The switch flow now uses the same panel endpoint used by the 3x-ui UI when you press **Save**:

- `POST /panel/xray/update` with form field `xraySetting=<full json>`

Then it:
1. restarts Xray through the panel/API flow
2. waits for panel login + `getConfigJson` readiness
3. fetches the panel config again
4. verifies the requested outbound actually persisted in panel state
5. runs a post-switch health check
6. restores the previous panel config automatically if any of those checks fail

This is safer and more correct than editing `/usr/local/x-ui/bin/config.json` directly, because 3x-ui rebuilds and manages its own Xray config state.


## v1.0.17 fixes

- fixes `RESTART_WAIT_SECONDS: unbound variable` during install/reconfigure
- saves restart timing defaults into the environment file even on first install
- creates/touches log files during save so the log viewer works immediately
- tries both known 3x-ui restart endpoints:
  - `/panel/api/server/restartXrayService`
  - `/panel/server/restartXrayService`
- improves self-test to evaluate all prioritized outbounds and report the highest-priority healthy one instead of failing only because the first outbound is unhealthy
- if no switcher log exists yet, the log view falls back to `journalctl`


## v1.0.17 final switch path

This version switches outbounds using the exact 3x-ui UI flow:

1. `POST /panel/xray/` to fetch the editable panel state
2. parse `obj` as JSON and extract `xraySetting`
3. patch only the target routing rule in `xraySetting`
4. `POST /panel/xray/update` with `xraySetting=<full editable json>`
5. `POST /panel/api/server/restartXrayService` (or `/panel/server/restartXrayService` if needed)
6. poll `GET /panel/xray/getXrayResult`
7. wait for panel login + `getConfigJson`
8. verify the selected outbound actually persisted
9. run a post-switch health check

Direct switching through local `config.json` is no longer used in the main flow.
`xray run -test` is no longer used in the switch decision path.
