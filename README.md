# 3X-UI Outbound Switcher

**Version:** v1.0.0

Switch between outbound by your priority on 3X-UI.

## What it does

`3x-ui-outbound-switcher` runs on the same server where **3x-ui** is installed and automatically switches the active Xray outbound based on your outbound tag priority.

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
