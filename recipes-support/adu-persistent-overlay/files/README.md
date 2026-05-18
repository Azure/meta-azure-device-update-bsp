# adu-persistent-overlay

Operator-level reference for the `adu-persistent-overlay` recipe. For the
*why* and the design rationale, see
[`docs/persistence-strategy.md`](../../../docs/persistence-strategy.md) at
the repo root.

> **Reference implementation — provided as-is.**
> No support, warranty, or guarantees of any kind. Validate against your
> own product requirements before using on real devices.

---

## What this recipe installs

| Path | Purpose |
|---|---|
| `/lib/systemd/system/adu-persistent-overlay.service` | Boot-time `oneshot`: restore `/etc` from `/adu/system/`, then overlay/bind mount. Ordered before `sshd.service`, user sessions, and the ADU agent. |
| `/lib/systemd/system/adu-persistent-watcher.service` | Long-running `simple` unit: `inotify` mirror of `/etc` → `/adu/system/`. |
| `/usr/lib/adu/setup-overlay-dirs.sh` | Creates `/adu/{overlay,work,system,.backups}` if absent. |
| `/usr/lib/adu/restore-persistent-files.sh` | Boot-time merge engine (3-way for passwd-family, persist-wins for others, copy for SSH host keys). |
| `/usr/lib/adu/mount-overlays.sh` | Mount overlayfs upper dirs (best-effort; needs `CONFIG_OVERLAY_FS=y`). |
| `/usr/lib/adu/mount-critical-binds.sh` | Bind-mount `apt-*` config directories. |
| `/usr/lib/adu/umount-overlays.sh` | Best-effort unmount during shutdown. |
| `/usr/lib/adu/adu-persistent-watcher.sh` | `inotifywait` loop, 1 s debounce. |
| `/usr/lib/adu/sync-persistent-files.sh` | Atomic temp+rename writer to `/adu/system/`. Supports single-file or shutdown all-files mode. |
| `/usr/lib/adu/factory-reset.sh` | Operator tool: clears persisted state. |
| `/usr/lib/adu/verify-overlays.sh` | Operator tool: prints active mounts and persist sources. |
| `/etc/overlay/overlay.conf` | Configuration (file lists, debounce). |

Both services are enabled via `SYSTEMD_SERVICE:${PN}`. The recipe adds
`inotify-tools` and `coreutils` to `RDEPENDS`.

---

## What is persisted (out of the box)

- **Line-merged files** (`/etc/{passwd,shadow,group,gshadow}`).
  Image-side additions of system users *and* operator-set passwords
  both survive an A/B update.
- **Whole-file persist** (`/etc/{hostname,timezone,machine-id}`,
  `/etc/adu/du-config.json`). Persisted copy replaces rootfs copy on boot.
- **SSH host keys** (`/etc/ssh/ssh_host_*`). Persisted, so SSH clients
  do not see "host key changed" warnings across updates.
- **APT config directories** (`/etc/apt/{sources.list.d,trusted.gpg.d,preferences.d}`),
  bind-mounted from `/adu/system/`.
- **OverlayFS upper layers** for `/var/log`, `/var/lib/connman`,
  `/var/lib/bluetooth`, `/var/cache/apt`, `/var/lib/adu` — when the
  kernel supports `CONFIG_OVERLAY_FS`.
- **Direct bind mounts** for `/var/lib/adu/{downloads,extensions,states,sdc,api}`
  on top of `/adu/data/<subdir>`.

What is **not** persisted by this recipe:
- `/home/<user>/` and `~/.ssh/authorized_keys`.
- `/etc/ssh/sshd_config`, `/etc/ssh/moduli` (image-owned by design).
- Anything not listed in `/etc/overlay/overlay.conf`.

---

## Common operator tasks

### Inspect active state

```bash
sudo /usr/lib/adu/verify-overlays.sh
mount | grep -E 'adu|overlay'
ls -la /adu/system/
```

### Change a password and confirm it persisted

```bash
sudo passwd root
# wait ~2 s for the watcher
sudo diff /etc/shadow /adu/system/shadow   # should be empty
sudo reboot
# log back in with the new password
```

### Add a new persistent user

```bash
sudo useradd -m newuser
sudo passwd newuser
# /etc/{passwd,shadow,group,gshadow} all change → watcher syncs them.
# Home directory under /home/newuser/ is NOT persisted unless your image
# places /home on a separate partition.
```

### Factory reset

```bash
sudo /usr/lib/adu/factory-reset.sh
sudo reboot
```

This removes `/adu/system/`, `/adu/overlay/`, `/adu/work/`, and any
backups. On the next boot, the rootfs `/etc` is taken as the new baseline
and seeded into `/adu/system/`.

### Delete a user (with caveat)

```bash
sudo userdel olduser
# Also remove the entry from the persisted copies so the next boot
# doesn't resurrect them from the rootfs.
sudo sed -i '/^olduser:/d' /adu/system/passwd /adu/system/shadow \
                            /adu/system/group  /adu/system/gshadow
```

See [`docs/persistence-strategy.md`](../../../docs/persistence-strategy.md) §4.3
for why this extra step is needed (deletion is not modeled in the merge).

### Override the watched-file set

Edit `/etc/overlay/overlay.conf` (shipped on the rootfs — to persist a
change to it, ship a new image), then:

```bash
sudo systemctl restart adu-persistent-overlay.service adu-persistent-watcher.service
```

---

## Troubleshooting

### "Password change failed: unexpected failure: Device or resource busy"

This is the symptom that the **old** (bind-mount-per-file) design had.
On this version it should not occur. If it does:

```bash
mount | grep /etc/
```

If anything is bind-mounted directly on a file in `/etc/` (e.g.
`/etc/shadow`), then either an older version of this recipe is still
installed or a custom mount unit is overriding our design. Remove the
stale mounts and reinstall this recipe.

### `/etc/shadow` reverts on every boot

Check the watcher:

```bash
sudo systemctl status adu-persistent-watcher.service
sudo journalctl -u adu-persistent-watcher.service --no-pager -n 50
sudo journalctl -u adu-persistent-overlay.service --no-pager -n 50
```

Verify the file is in `SYNC_FILES` in `/etc/overlay/overlay.conf` and
that `inotify-tools` is installed (`which inotifywait`).

### Boot hangs at "Listening on … socket"

Indicates a unit-ordering cycle. The shipped service file does **not**
have `Before=sysinit.target`, `Before=basic.target`, or
`Before=sshd.socket`. If you edited it locally, remove those clauses.
See `docs/persistence-strategy.md` §4.2 for the rationale.

### Overlay mounts say "Failed to mount overlay"

Your kernel is missing `CONFIG_OVERLAY_FS=y`. Auth persistence still
works; only `/var/log` / connman / bluetooth / apt cache will not
survive reboot. Enable overlay in your kernel fragment to fix.

### Inspect the line merge

```bash
sudo journalctl -u adu-persistent-overlay.service --no-pager \
    | grep -E '\[merge\]|\[seed\]|\[restore\]|\[warn\]'
```

Compare:

```bash
sudo diff /etc/shadow                  /adu/system/shadow
sudo diff /adu/system/shadow           /adu/system/baseline/shadow
```

---

## Configuration knobs

All in `/etc/overlay/overlay.conf` (see
[`docs/persistence-strategy.md`](../../../docs/persistence-strategy.md) §7).

| Array | Meaning |
|---|---|
| `SYNC_FILES` | `<persist-basename>:<rootfs-path>` entries copy-restored at boot and watched at runtime |
| `BIND_MOUNTS` | `<persist-basename>:<rootfs-path>` directory bind mounts |
| `SSH_HOST_KEYS` | Basenames under `/adu/system/ssh/` to restore into `/etc/ssh/` |
| `OVERLAY_DIRS` | Paths to cover with overlayfs (best-effort) |
| `WATCHER_DEBOUNCE` | Seconds the watcher waits before syncing a burst of changes |

---

## Tests

Hermetic unit tests live in
`recipes-support/adu-persistent-overlay/tests/test_persistence_scripts.sh`
and can be run on a developer host without bitbake:

```bash
cd recipes-support/adu-persistent-overlay/tests
./test_persistence_scripts.sh
```

End-to-end test matrix (manual): see
[`docs/persistence-strategy.md`](../../../docs/persistence-strategy.md) §8.2.

---

## Related documentation

- [`docs/persistence-strategy.md`](../../../docs/persistence-strategy.md) —
  Why, How, What of the overall design.
- [`docs/architecture-decision.md`](../../../docs/architecture-decision.md) —
  A/B update architecture that this layer plugs into.
- [`docs/porting-guide.md`](../../../docs/porting-guide.md) —
  Steps to add a new BSP.
