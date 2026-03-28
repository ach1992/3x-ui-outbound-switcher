# 3X-UI Outbound Switcher

Version: v1.0.19

Switch between 3x-ui outbounds by priority derived from outbound tags such as:

- `A-Main-Out`
- `B-Backup-Out`
- `C-Node-3`

The switcher runs on the **same server** as 3x-ui and uses the **3x-ui panel API** instead of editing the generated runtime config as the primary switch path.

## Supported platforms

- Ubuntu 22 / 24 / 25
- Debian 11 / 12 / 13

## How priority works

Priority is derived from the outbound tag prefix:

- `A-...` = highest priority
- `B-...` = next priority
- `C-...` = next priority
- and so on

Any outbound without this prefix is ignored by the automatic switch logic.

## Main behavior

The switcher does all of the following:

1. Logs in to the 3x-ui panel
2. Downloads the current runtime config from the panel
3. Reads the editable panel xray state from the UI API
4. Detects prioritized outbounds from tags like `A-...`, `B-...`, `C-...`
5. Tests outbounds by panel probe mode by default
6. Chooses the best healthy outbound by priority
7. Updates only the routing rule target outbound in editable `xraySetting`
8. Saves the change through the panel update API
9. Restarts Xray through the panel restart API
10. Waits for the panel/API to become reachable again
11. Verifies the selected outbound persisted
12. Runs a post-switch health check
13. Restores the previous xray setting if the final outcome is not healthy

## Important design choice

This version does **not** use direct local `config.json` editing as the main switch path.

It uses the same panel flow used by the UI:

- `POST /panel/xray/`
- extract editable `xraySetting`
- patch `routing.rules[last].outboundTag`
- `POST /panel/xray/update`
- restart Xray through panel API

This avoids the earlier issue where 3x-ui could rebuild its own runtime config after restart.

## Files in this repository

- `install.sh`
- `uninstall.sh`
- `xui-switcher.sh`
- `README.md`

## Install

Run on the same server where 3x-ui is installed:

```bash
sudo bash install.sh
```

The installer copies files to:

- `/opt/3x-ui-outbound-switcher`
- `/etc/3x-ui-outbound-switcher`
- `/var/lib/3x-ui-outbound-switcher`
- `/var/log/3x-ui-outbound-switcher`

And creates this command:

```bash
3x-ui-outbound-switcher
```

## Upgrade from an older version

From inside the repo directory:

```bash
cd ~/3x-ui-outbound-switcher
sudo cp -f xui-switcher.sh /opt/3x-ui-outbound-switcher/xui-switcher.sh
sudo cp -f install.sh /opt/3x-ui-outbound-switcher/install.sh
sudo cp -f uninstall.sh /opt/3x-ui-outbound-switcher/uninstall.sh
sudo chmod +x /opt/3x-ui-outbound-switcher/*.sh
sudo cp -f xui-switcher.sh /usr/local/bin/3x-ui-outbound-switcher
sudo chmod +x /usr/local/bin/3x-ui-outbound-switcher
```

Then run the CLI and choose **Install / Reconfigure** once so the environment file is refreshed.

## Uninstall

```bash
sudo bash uninstall.sh
```

This removes:

- service and timer
- install directory
- env/state/log directories
- symlink
- known legacy paths from earlier broken naming attempts

## First-time setup

During **Install / Reconfigure**, the script asks for:

- 3x-ui panel base URL
- 3x-ui username
- 3x-ui password
- `config.json` path
- xray binary path
- fail threshold
- recover threshold
- minimum seconds between switches
- probe timeout
- seconds to wait after restart
- panel/API ready timeout after restart
- auto-run timer interval
- probe mode

### Recommended values

A stable default set is usually:

- Fail threshold: `3`
- Recover threshold: `3`
- Minimum seconds between switches: `60`
- Probe timeout: `8`
- Seconds to wait after restart: `5`
- Panel/API ready timeout after restart: `90`
- Auto-run timer interval: `20`
- Probe mode: `panel`

## Probe modes

### panel
Uses the same outbound test endpoint used by 3x-ui.

This is the recommended mode.

### tcp
If panel probe is unavailable or you prefer a raw socket-level check, the script can fall back to TCP connection testing.

## CLI menu

The script provides these actions:

1. Install / Reconfigure
2. Show current config
3. Validate current Xray config
4. Start one check now
5. Run self-test
6. Start service once
7. Stop auto-run timer
8. Restart auto-run timer
9. Show status
10. Show logs
11. Enable auto-run timer
12. Disable auto-run timer
13. Uninstall
0. Exit

## Logging

Main log file:

```bash
/var/log/3x-ui-outbound-switcher/switcher.log
```

Action log file:

```bash
/var/log/3x-ui-outbound-switcher/actions.log
```

If the log file does not exist yet, the CLI can fall back to `journalctl`.

## Service and timer

Service:

```bash
3x-ui-outbound-switcher.service
```

Timer:

```bash
3x-ui-outbound-switcher.timer
```

The timer uses `OnUnitInactiveSec`, which helps avoid overlap better than fixed calendar scheduling for this use case.

## Health and switch logic

The switcher keeps per-outbound success/fail counters.

### It switches away when:
- the current outbound reaches the configured fail threshold
- and a higher-priority healthy candidate is available

### It switches back upward when:
- a higher-priority outbound becomes healthy again
- and it reaches the configured recover threshold
- and the minimum switch gap has passed

## Self-test

Self-test checks:

- panel login
- runtime config fetch
- editable `xraySetting` fetch from panel UI API
- prioritized outbound discovery
- current routing outbound detection
- outbound health by priority
- timer/service status

If the timer is active, self-test still runs with the switcher lock so it does not overlap with a background check.

## What counts as a successful switch

A switch is considered successful only if the final outcome is healthy:

- panel login works again
- panel config can be fetched again
- selected outbound persisted in panel config
- post-switch probe on the selected outbound succeeds

The script does **not** treat `getXrayResult` as the only source of truth, because some panels may report non-fatal messages such as metrics-port conflicts while the final working state is actually acceptable.

## Known note about `getXrayResult`

On some installations, `GET /panel/xray/getXrayResult` may report messages like:

```text
Failed to start: listen tcp 127.0.0.1:11111: bind: address already in use
```

This may appear even when the final routing change is practically applied and the panel is reachable again.

For that reason, this project uses **final outcome verification** instead of treating that endpoint as a hard-fail decision by itself.

## Troubleshooting

### No prioritized outbound tags found
Make sure your outbound tags start with capital-letter prefixes such as:

- `A-...`
- `B-...`
- `C-...`

### Panel login failed
Check:

- base URL
- username
- password
- local firewall / reverse proxy behavior

### No healthy prioritized outbound found
Possible reasons:

- all panel outbound probes are failing
- the timer/service is overlapping with manual testing on a busy panel
- the panel itself is temporarily unstable during restart/reload

Try again with the timer disabled and run self-test manually.

### Switch did not persist
This usually means the panel rejected the change or the restart sequence did not settle into a healthy final state.

Check:

```bash
sudo tail -n 200 /var/log/3x-ui-outbound-switcher/switcher.log
sudo tail -n 200 /var/log/3x-ui-outbound-switcher/actions.log
```

## Offline installation

If you copy these four files to a server manually:

- `install.sh`
- `uninstall.sh`
- `xui-switcher.sh`
- `README.md`

you can install without Git by simply running:

```bash
sudo bash install.sh
```

## Repository

GitHub repository:

```text
https://github.com/ach1992/3x-ui-outbound-switcher
```

## License

MIT
