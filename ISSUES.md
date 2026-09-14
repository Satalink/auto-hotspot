# Planned issue drafts

## 1) Failover Wi-Fi can report connected while internet still does not work

Title: Failover Wi-Fi reports connected but no internet path

Problem:
- Laptop connected to a failover Wi-Fi SSID at wake-up.
- The adapter reported network connectivity, but outbound internet access did not work.
- A network reset was required to restore operation.
- VPN was fully disabled, so it was not a factor.

Expected behavior:
- The script should only consider a connection healthy after the network stack verifies true internet access.

Acceptance criteria:
- Add connectivity validation after Wi-Fi connect or hotspot restore.
- Check default route, DNS resolution, and outbound reachability.
- If validation fails, retry or reset and log the condition.

## 2) Verify laptop hotspot lifecycle and kill/restart behavior

Title: Confirm laptop hotspot lifecycle after phone hotspot disappears

Problem:
- The user disabled the phone hotspot overnight.
- The laptop may have started its own hotspot, failed to start it, or started it and later lost it.
- The app needs stronger validation to confirm the hotspot state during and after transitions.

Expected behavior:
- The app should confirm actual hotspot state before declaring success.
- If the hotspot is expected to be on, verify that it is active and reachable.

Acceptance criteria:
- Log the hotspot state before and after toggles.
- Detect a dead or missing hotspot even when the Wi-Fi adapter still reports association.

## 3) Add real internet health checks before declaring a tier successful

Title: Add connectivity health checks to tier-switch success path

Problem:
- The current logic appears to treat Wi-Fi association as success instead of verifying real connectivity.

Expected behavior:
- After switching to a hotspot or fallback SSID, the app should confirm Internet availability before returning success.

Acceptance criteria:
- Use a lightweight external reachability check (DNS and TCP test).
- Retry on failure.
- Only mark a tier as active after health checks pass.

## 4) Investigate stale route/DNS state after failover reconnect

Title: Investigate stale route or DNS state after reconnect

Problem:
- The laptop reported being connected but did not actually reach the internet.
- Resetting the network connection restored access.

Expected behavior:
- The app should recover from stale route or DNS state automatically.

Acceptance criteria:
- Flush DNS and refresh network state when needed.
- Detect route mismatch or stale connection state after a failed transition.
