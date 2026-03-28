# 3X-UI Outbound Switcher

Version: v1.0.18

Switch between 3x-ui outbounds by priority derived from tags like `A-...`, `B-...`, `C-...`.

## What this version does

- uses the 3x-ui panel login
- reads runtime config from `getConfigJson`
- reads editable panel state from `POST /panel/xray/`
- patches only `xraySetting.routing.rules[last].outboundTag`
- saves using `POST /panel/xray/update`
- restarts using the panel restart endpoint
- polls `GET /panel/xray/getXrayResult` only as a diagnostic signal
- decides final success by the real outcome:
  - panel becomes reachable again
  - config persists the selected outbound
  - post-switch outbound probe succeeds

## Notes

- direct switching through local `config.json` is not used in the main switch path
- `xray run -test` is diagnostic only in self-test / validation, not in the final switch decision
- self-test uses a lock so the timer does not overlap with it

## Install

```bash
sudo bash install.sh
```

## Uninstall

```bash
sudo bash uninstall.sh
```
