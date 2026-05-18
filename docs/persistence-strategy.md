# Persisting Mutable State Across A/B Rootfs Updates

> **Reference implementation — provided as-is.**
> This document and the accompanying scripts in
> `recipes-support/adu-persistent-overlay/` are published as a reference
> implementation for community use. Microsoft does **not** provide support,
> warranty, or guarantees of any kind — express or implied — about the source
> code, the design, fitness for any particular purpose, security, or
> correctness. You are responsible for validating the design against your
> own product's threat model, update flow, hardware, kernel configuration,
> and regulatory requirements before using it on real devices.

---

## TL;DR

On an A/B-updatable Linux device, the rootfs is replaced wholesale on every
update. Mutable state that the user/admin sets at runtime (passwords, SSH
host keys, hostname, application config) must therefore live **outside** the
rootfs. A naive bind-mount-per-file approach breaks `rename(2)`-based tools
(`chpasswd`, `usermod`, `passwd`). A whole-`/etc` overlay loses image-side
updates (new system users introduced by a new image).

This reference implementation persists a small, explicit set of files on a
dedicated `/adu` partition and applies them back to `/etc` at boot using a
**3-way line merge** for `passwd`/`shadow`/`group`/`gshadow`, and a
plain copy for other managed files. Runtime mutations are mirrored to
`/adu/system` by an `inotify`-driven watcher. Directory persistence
(`/var/log`, `/var/lib/connman`, …) is delivered separately via
overlayfs + a few directory bind mounts.

---

## 1. Why — the problem

Edge devices typically need to preserve at least the following across an
A/B update or rollback:

| Category | Example | Why it has to survive |
|---|---|---|
| Credentials | `/etc/shadow` root password, app user passwords | Locking the operator out after an OTA is unacceptable |
| Identity   | `/etc/ssh/ssh_host_*`, `/etc/machine-id`, `/etc/hostname` | Avoid client-side "host key changed" alerts; keep cloud identity stable |
| App config | `/etc/adu/du-config.json` | Connection / tenant info set at provisioning |
| App state  | `/var/lib/adu/states`, `/var/lib/adu/downloads` | In-flight update progress, downloaded payloads |
| OS state   | `/var/log`, `/var/lib/connman`, `/var/lib/bluetooth` | Logs and learned network/Bluetooth pairings |

Three approaches that **don't** work in isolation:

1. **Persist `/etc` wholesale on a separate partition.**
   Image updates can no longer add or remove system users/groups (e.g. a
   new daemon's service account), because the rootfs `/etc/passwd` is
   never seen by the running system. Slow drift, hard to migrate.

2. **Bind-mount individual files** (`/etc/passwd`, `/etc/shadow`, …)
   from a persistent location.
   This is what the previous version of this layer did. It fails because
   shadow-utils tools (`chpasswd`, `passwd`, `usermod`, `useradd`,
   `pwconv`, …) all write a temp file in `/etc/` and then call
   `rename(2)` over the target. `rename(2)` over a bind-mount target
   returns `EBUSY`. Every password / user change failed with
   *"unexpected failure: Device or resource busy"*, and any change that
   appeared to succeed actually wrote to the underlying rootfs file (not
   the persistent copy), so it was lost on the next A/B swap.

3. **Overlay the whole of `/etc`.**
   Once a file is written via the overlay, the corresponding rootfs
   version is masked permanently for that path. Image updates that
   change `/etc/passwd` (e.g. add a new system user) silently have no
   effect at runtime.

The reference implementation therefore uses a **per-file strategy** —
explicit list of files, copy-restore at boot, 3-way merge for the
auth-related ones, and a watcher that mirrors runtime changes back to the
persistent partition.

---

## 2. Implementation invariants

A short, load-bearing mental model. Everything else in this document flows
from these.

- **`/adu/system/<file>`** is the **canonical persisted copy** of a
  managed file. Writes here happen only via the watcher or the
  shutdown safety net.
- **`/etc/<file>`** is the **live runtime copy**. It is a plain regular
  file on the rootfs; no bind mount is ever placed over a managed file.
  All writes by shadow-utils and other tools land here, so
  `rename(2)`-over-target works correctly.
- **`/adu/system/baseline/<file>`** is a **snapshot of the rootfs
  `/etc/<file>` from the moment of the last successful merge**. Used by
  the 3-way merge to distinguish "image changed" from "user changed".
- A **boot-time restore** service writes the merged content to
  `/etc/<file>` before any service that consumes it starts.
- A **runtime watcher** (`inotify`) mirrors changes in `/etc/<file>` to
  `/adu/system/<file>` within ~1 second (debounced).
- The configured set of managed files is fixed at the configuration
  level (`/etc/overlay/overlay.conf` → `SYNC_FILES` array). Anything
  not in that list is not persisted by this mechanism.

---

## 3. What — architecture and layout

### 3.1 Storage layout (on `/adu`, a dedicated ext4 partition)

The `/adu` partition is shared between **two cooperating recipes**:

- `adu-filesystem-layout` (in `meta-azure-device-update`) owns the directories that hold
  ADU agent state — `conf/`, `data/`, `logs/`, `tools/`.
- `adu-persistent-overlay` (in this layer, the subject of this document) adds
  the directories used by the persistence mechanism itself — `system/`,
  `overlay/`, `work/`, `.backups/`.

```
/adu/                                <-- ext4 partition, mount point. Owned adu:adu 0770.
│
├── conf/                            <-- [adu-filesystem-layout]  adu:adu 0750
│   │                                    Symlinked from /etc/adu  (so /etc/adu/du-config.json
│   │                                    is the same file as /adu/conf/du-config.json).
│   ├── du-config.json               <-- ADU agent connection / tenant config
│   ├── du-diagnostics-config.json   <-- ADU diagnostics config
│   └── certs/                       <-- [adu-persistent-overlay] X.509 device certs
│       │                                Exposed as /etc/adu/certs/ via the symlink above.
│       │                                Matches the upstream ADU X.509 docs verbatim.
│       ├── client.pem               <-- 0644 adu:adu
│       ├── client.key               <-- 0600 adu:adu
│       └── ca.pem                   <-- 0644 adu:adu (optional)
│
├── data/                            <-- [adu-filesystem-layout]  adu:adu 0770
│   │                                    Symlinked from /var/lib/adu.
│   ├── downloads/                       Update payloads downloaded by the agent
│   ├── extensions/                      ADU extension binaries & metadata
│   │   ├── sources/
│   │   ├── component_enumerator/
│   │   ├── content_downloader/
│   │   ├── update_content_handlers/
│   │   └── download_handlers/
│   ├── states/                          Workflow state machine snapshots
│   ├── sdc/                             Step-deployment-content
│   └── api/                             Agent IPC sockets / API state
│
├── logs/                            <-- [adu-filesystem-layout]  adu:adu 0774
│                                        Symlinked from /var/log/adu.
│                                        ADU agent stdout/stderr & rotated logs.
│
├── tools/                           <-- [adu-filesystem-layout]  root:root 0755
│                                        Root-owned helper scripts (factory-test, etc.).
│
├── system/                          <-- [adu-persistent-overlay]  adu:adu 0770
│   │                                    Canonical persisted copies of /etc files.
│   │                                    Written by the watcher / shutdown sync.
│   │                                    Read by restore-persistent-files.sh at boot.
│   ├── passwd
│   ├── shadow                       <-- mode 0640 (preserved from /etc/shadow)
│   ├── group
│   ├── gshadow                      <-- mode 0640
│   ├── hostname
│   ├── timezone
│   ├── machine-id                   <-- mode 0444
│   ├── du-config.json               <-- (redundant copy; see note below)
│   ├── ssh/                         <-- persisted SSH host keys (NOT sshd_config)
│   │   ├── ssh_host_rsa_key{,.pub}
│   │   ├── ssh_host_ecdsa_key{,.pub}
│   │   └── ssh_host_ed25519_key{,.pub}
│   └── baseline/                    <-- rootfs snapshot at last successful merge
│       ├── passwd
│       ├── shadow
│       └── ...
│
├── overlay/                         <-- [adu-persistent-overlay]  adu:adu 0770
│   │                                    overlayfs upper layers (one per OVERLAY_DIRS entry).
│   ├── var-log/
│   ├── var-lib-connman/
│   ├── var-lib-bluetooth/
│   └── var-cache-apt/
│
├── work/                            <-- [adu-persistent-overlay]  adu:adu 0770
│   └── ...                              overlayfs work dirs (kernel scratch).
│
├── .backups/                        <-- [adu-persistent-overlay]  adu:adu 0770
│                                        One-shot migration / pre-flight backups.
│
└── .filesystem-layout-version       <-- version marker written by setup-adu-filesystem.sh
```

#### Where configs live

| File | Path on disk | Symlinked from | Persisted because |
|---|---|---|---|
| `du-config.json` (ADU agent) | `/adu/conf/du-config.json` | `/etc/adu/du-config.json` | Lives directly on `/adu`. Also mirrored to `/adu/system/du-config.json` by the watcher — see redundancy note below. |
| `du-diagnostics-config.json` | `/adu/conf/du-diagnostics-config.json` | `/etc/adu/du-diagnostics-config.json` | Lives directly on `/adu`. |
| `overlay.conf` (this layer's config) | `/etc/overlay/overlay.conf` | — | **Shipped on the rootfs**. Edit-and-deploy via a new image, not at runtime. |
| `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow` | rootfs `/etc/` | — | Mirrored to `/adu/system/` at runtime; line-merged on boot (§4). |
| `/etc/hostname`, `/etc/timezone`, `/etc/machine-id` | rootfs `/etc/` | — | Mirrored to `/adu/system/`; persist-wins on boot. |

#### Where certificates and keys live

This layer follows the upstream **Azure Device Update agent** convention
documented in
[`how-to-x509-authentication.md`](https://github.com/Azure/iot-hub-device-update/blob/main/docs/agent-reference/how-to-x509-authentication.md)
verbatim — operators copy-paste the install steps from the official ADU
docs and they Just Work on our images.

The directory `/adu/conf/certs/` is pre-created by this layer's
`setup-overlay-dirs.sh` (mode `0750`, owner `adu:adu`). Because
`adu-config-setup` symlinks `/etc/adu -> /adu/conf`, the upstream path
`/etc/adu/certs/` resolves to that same directory on disk.

| Asset | Path documented to users | Physical location on `/adu` | Mode | Owner |
|---|---|---|---|---|
| Device X.509 cert | `/etc/adu/certs/client.pem` | `/adu/conf/certs/client.pem` | `0644` | `adu:adu` |
| Device private key | `/etc/adu/certs/client.key` | `/adu/conf/certs/client.key` | `0600` | `adu:adu` |
| CA bundle (optional) | `/etc/adu/certs/ca.pem` | `/adu/conf/certs/ca.pem` | `0644` | `adu:adu` |
| SSH host keys | `/etc/ssh/ssh_host_*` | `/adu/system/ssh/ssh_host_*` | (preserved) | `root:root` |
| System CA store | `/etc/ssl/certs/` (rootfs) | n/a — ships in image | — | — |

`du-config.json` references these files via the upstream JSON keys:

```json
"connectionSource": {
    "connectionType":                   "X509",
    "connectionData":                   "HostName=...;DeviceId=...;x509=true",
    "connectionX509CertFilePath":       "/etc/adu/certs/client.pem",
    "connectionX509PrivateKeyFilePath": "/etc/adu/certs/client.key",
    "connectionX509CaCertFilePath":     "/etc/adu/certs/ca.pem"
}
```

Operators provision certs with the standard upstream commands; the only
BSP-specific detail is that the destination is on `/adu` and therefore
automatically survives A/B rootfs updates:

```bash
# Standard upstream steps — work as-is on this BSP
sudo cp client.pem /etc/adu/certs/
sudo cp client.key /etc/adu/certs/
sudo cp ca.pem     /etc/adu/certs/
sudo chmod 644     /etc/adu/certs/client.pem /etc/adu/certs/ca.pem
sudo chmod 600     /etc/adu/certs/client.key
sudo chown -R adu:adu /etc/adu/certs/
```

> **Threat-model note.** Anything on `/adu` is stored unencrypted by
> default. Private keys, password hashes, and persisted SSH host keys
> are all readable to anyone with block-level access to the device.
> If that matters for your product, enable disk encryption for `/adu`
> (e.g. dm-crypt + TPM-bound key) outside the scope of this layer.

#### Symlinks created by `adu-config-setup` / `adu-persistence-symlinks`

| Symlink | Target | Effect |
|---|---|---|
| `/etc/adu` | `/adu/conf` | Application code that opens `/etc/adu/du-config.json` actually reads `/adu/conf/du-config.json` |
| `/var/lib/adu` | `/adu/data` | ADU agent runtime state survives A/B updates by living on `/adu` |
| `/var/log/adu` | `/adu/logs` | ADU agent log files survive A/B updates |

#### Note on the redundant `du-config.json` copy

`du-config.json` appears twice on `/adu`:

- The **primary** copy at `/adu/conf/du-config.json` (visible as `/etc/adu/du-config.json`)
  is what the agent reads. It lives on `/adu` and so already survives A/B updates.
- A **mirror** at `/adu/system/du-config.json` is maintained by this layer's
  watcher because `du-config.json` is listed in `SYNC_FILES`.

The mirror is harmless but redundant. If you want to remove it for
clarity, drop the line `"du-config.json:/etc/adu/du-config.json"` from
`SYNC_FILES` in `overlay.conf`. The agent will continue to work because
the symlink already provides persistence.

### 3.2 Categories of managed state

| Mechanism | What it covers | How conflicts are resolved |
|---|---|---|
| **Line-merged file restore** | `passwd`, `shadow`, `group`, `gshadow` | Per-entry 3-way merge (see §4) |
| **Whole-file restore (persist-wins)** | `hostname`, `timezone`, `machine-id`, `du-config.json` | Persist always replaces rootfs |
| **SSH host key restore** | `/etc/ssh/ssh_host_*` (private + public) | Persist wins per file |
| **Directory bind mount** | `/etc/apt/sources.list.d`, `/etc/apt/trusted.gpg.d`, `/etc/apt/preferences.d` | Backing dir on `/adu/system/`; rename targets land *inside* the dir, so no EBUSY |
| **OverlayFS upper** | `/var/log`, `/var/lib/connman`, `/var/lib/bluetooth`, `/var/cache/apt`, `/var/lib/adu` | Standard overlayfs whiteout semantics; image is lower, persist is upper |
| **ADU subdir bind mounts** | `/var/lib/adu/{downloads,extensions,states,sdc,api}` | Direct bind on `/adu/data/<subdir>` |

> **Do not nest a bind mount inside an overlay covering the same path.**
> The directory bind mounts on `/var/lib/adu/<subdir>` are layered
> *underneath* (i.e. happen after) the `/var/lib/adu` overlay mount and
> intentionally shadow the overlay for those subpaths. Adding more
> nested mounts under `/var/lib/adu/` requires care.

### 3.3 Components

| File | Role |
|---|---|
| `adu-persistent-overlay.service` | `oneshot` boot unit: restore → overlay → bind |
| `adu-persistent-watcher.service` | `simple` long-running unit: inotify-mirror |
| `setup-overlay-dirs.sh` | Creates `/adu/{overlay,work,system,.backups}` and refreshes baseline on image rotation |
| `restore-persistent-files.sh` | Boot-time restore + 3-way merge + SSH key restore |
| `mount-overlays.sh` | Mounts overlayfs on each `OVERLAY_DIRS[]` entry |
| `mount-critical-binds.sh` | Bind-mounts the persisted `apt-*` directories |
| `adu-persistent-watcher.sh` | `inotifywait` loop + 1-second debounce |
| `sync-persistent-files.sh` | Atomic temp+rename write of a single file (or all files in shutdown mode) into `/adu/system/` |
| `umount-overlays.sh` | Best-effort unmount during shutdown |
| `factory-reset.sh` | Operator tool: clears `/adu/system/`, `/adu/overlay/`, `/adu/work/` |
| `verify-overlays.sh` | Operator tool: prints current mount state and persist sources |

---

## 4. How — runtime flow

### 4.1 Boot sequence

```
local-fs.target
   │
   ▼
adu.mount                          <-- /adu ext4 partition mounted
   │
   ▼
adu-filesystem-layout.service      <-- creates /adu/{conf,data,logs,system,...}
   │
   ▼
adu-persistent-overlay.service     <-- this layer's oneshot
   │   ExecStartPre: setup-overlay-dirs.sh
   │   ExecStart:    restore-persistent-files.sh   (writes merged /etc files)
   │   ExecStart:    mount-overlays.sh             (overlayfs upper dirs)
   │   ExecStart:    mount-critical-binds.sh       (apt-* directory binds)
   │
   ▼
sshd.service, systemd-user-sessions.service, deviceupdate-agent.service, ...
   (all start AFTER /etc/passwd, /etc/shadow, ssh host keys are in place)
   │
   ▼
adu-persistent-watcher.service     <-- WantedBy=multi-user.target
   (inotify mirror; running for the lifetime of the boot)
```

### 4.2 Systemd ordering requirements (normative)

The ordering below is **not optional** for correctness:

- **`After=adu.mount adu-filesystem-layout.service`** —
  the partition must be mounted and `/adu/system/` must exist.
- **`Requires=adu-filesystem-layout.service`** —
  if layout setup fails, persistence must not run.
- **`Before=sshd.service systemd-user-sessions.service deviceupdate-agent.service`** —
  consumers of `/etc/passwd`, `/etc/shadow`, and ssh host keys must
  observe the merged content, not the rootfs defaults.
- **`WantedBy=multi-user.target`** — the service is part of normal boot,
  not part of early `sysinit.target`.
- **Do NOT** add `Before=sysinit.target`, `Before=basic.target`, or
  `Before=sshd.socket`. Combined with `Requires=adu-filesystem-layout.service`
  (which defaults to `After=basic.target`), those create the cycle
  `sockets.target → sshd.socket → us → adu-filesystem-layout →
  basic.target → sockets.target`. Systemd silently breaks the cycle,
  leaving one of the units off the boot transaction. The symptom is a
  boot that hangs at the sockets stage and never reaches multi-user.

### 4.3 The 3-way merge (passwd / shadow / group / gshadow)

For each managed auth file, the merge has three inputs:

- **rootfs** — `/etc/<file>` from the booting image (the candidate from the
  new A/B slot).
- **persist** — `/adu/system/<file>` (the last known persisted copy).
- **baseline** — `/adu/system/baseline/<file>` (snapshot of the rootfs
  `/etc/<file>` from the previous successful merge).

Entries are matched by their first field (username for `passwd`/`shadow`,
groupname for `group`/`gshadow`).

#### Per-key resolution table

| Rootfs | Persist | Baseline | Outcome | Intent |
|:---:|:---:|:---:|---|---|
| present | absent | * | **emit rootfs** | New system user/group introduced by the image |
| absent  | present | * | **emit persist** | Runtime-added entry, image doesn't know about it |
| present | present | persist == rootfs | **emit unchanged** | No conflict |
| present | present | persist == baseline (≠ rootfs) | **emit rootfs** | Image changed it, user didn't |
| present | present | rootfs == baseline (≠ persist) | **emit persist** | User changed it, image didn't |
| present | present | all three differ — `shadow`/`gshadow` | **emit persist** | Preserve user-set password hash |
| present | present | all three differ — `passwd`/`group` | **emit rootfs** | Align UID/GID/membership with new image |

Output order: rootfs entries in rootfs order, then persist-only entries
appended.

After a successful merge, **`/adu/system/baseline/<file>` is refreshed to
the pre-merge rootfs snapshot** so that the next A/B update can again
detect image-side changes.

#### Worked examples

1. **Image B adds a system user `foo`.**
   `rootfs(B)` has `foo`; `persist` does not; `baseline (from A)` does not.
   Outcome: rootfs-only → emit `foo`. After merge, `baseline ≡ rootfs(B)`,
   `persist` now also contains `foo`.

2. **Operator changes the root password at runtime.**
   `chpasswd` writes `/etc/shadow`; watcher syncs to `/adu/system/shadow`.
   On next boot: `rootfs == baseline` (image unchanged for `root`),
   `persist != baseline` (operator changed hash) → emit persist. Password
   survives.

3. **Image changes the UID of an application user.**
   `rootfs.passwd['app']` has the new UID; `persist.passwd['app']` and
   `baseline.passwd['app']` have the old UID. Rule "image changed,
   user didn't" → emit rootfs. UID stays aligned with the image.

4. **All three differ for `shadow` of an account both updated by image
   policy and by the operator.**
   Tie-break: persist wins for `shadow`. The image's password policy
   change is **silently overridden** by the operator's runtime change.
   See §6.2 for the security implication.

5. **Rollback from B (which added `foo`) back to A.**
   `rootfs(A)` lacks `foo`; `persist` still has `foo` (synced while
   running B); `baseline ≡ rootfs(B)` from the last merge.
   - For `passwd`: `foo` is persist-only → **emitted from persist**.
     `foo` lingers in the running `/etc/passwd` even though image A
     never knew about it. (See §6.1 — this is a documented limitation,
     not a feature.)

#### Deletion semantics

Deletion is **not modeled** in this merge. Consequences:

- **Operator deletes a user (`userdel`).** The watcher syncs the new,
  shorter `/etc/passwd` to `/adu/system/passwd`. On next boot,
  `rootfs` still has the user (image unchanged), `persist` does not.
  Rule "rootfs-only key" → user is re-emitted. **The deletion is lost
  on next boot.** Document this for operators; if needed, delete the
  user from `/adu/system/passwd` *and* perform a factory-reset of the
  baseline, or extend the merge to record tombstones.

- **Image B adds user, then rollback to A.** As shown in example 5:
  the persist-only entry lingers. Operators who care about a clean
  rollback must manually prune the persisted file or use
  `factory-reset.sh`.

### 4.4 Runtime mirroring (the watcher)

```
inotifywait /etc /etc/ssh
   --event close_write,moved_to,create,delete
   --format '%w%f'
        │
        ▼  basename matches a managed file?
        │   yes
        ▼
   sleep $WATCHER_DEBOUNCE (default 1s)
        │
        ▼
   sync-persistent-files.sh <basename>
   (atomic temp+rename into /adu/system/[ssh/]<basename>)
```

`sync-persistent-files.sh`:

1. Routes `ssh_host_*` basenames to `/adu/system/ssh/`.
2. Routes everything else to `/adu/system/<basename>`.
3. Writes via `mktemp -p <dst_dir>` + `mv -f` (atomic on ext4).
4. Preserves the source file's mode and owner.

If the watcher dies, `Restart=on-failure` brings it back. As a final
safety net, `ExecStop=` on `adu-persistent-overlay.service` calls
`sync-persistent-files.sh` with no argument, which performs an
"all-files" pass at shutdown.

### 4.5 A/B update walkthrough

```
T0  Running on slot A.
    /etc/shadow has operator's password.
    /adu/system/shadow has the same hash (watcher).
    /adu/system/baseline/shadow is the pristine slot-A image hash.

T1  OTA installs slot B (different image) and reboots.

T2  Slot B kernel + rootfs come up. /etc/shadow has the pristine
    slot-B image hash. /adu is mounted and contains the slot-A
    operator state plus the slot-A baseline.

T3  adu-persistent-overlay.service runs restore-persistent-files.sh:
       rootfs = pristine slot-B shadow
       persist = operator-modified hash
       baseline = pristine slot-A shadow
    For the `root` entry: rootfs != baseline, persist != baseline,
    all three differ. Rule "shadow/gshadow all-differ" -> emit persist.
    Operator's hash is written to /etc/shadow. Baseline is refreshed
    to the slot-B pristine snapshot.

T4  sshd, systemd-user-sessions, deviceupdate-agent start, all see
    the merged /etc. Operator logs in with their existing password.
```

---

## 5. File permissions and ownership

`atomic_install` in `restore-persistent-files.sh` preserves the destination
file's mode and owner via `chmod --reference` / `chown --reference` when the
destination already exists. The reference implementation does **not**
explicitly enforce modes if the destination is missing — it relies on the
rootfs having shipped the correct defaults.

Expected modes after a successful boot:

| Path | Mode | Owner |
|---|:---:|---|
| `/etc/passwd` | `0644` | `root:root` |
| `/etc/group` | `0644` | `root:root` |
| `/etc/shadow` | `0640` | `root:shadow` (or `root:root` on Yocto core) |
| `/etc/gshadow` | `0640` | `root:shadow` |
| `/etc/ssh/ssh_host_*_key` | `0600` | `root:root` |
| `/etc/ssh/ssh_host_*_key.pub` | `0644` | `root:root` |
| `/etc/machine-id` | `0444` | `root:root` |
| `/etc/adu/du-config.json` | `0644` | `root:root` (or as set by application) |

> Persisted private SSH host keys and persisted password hashes live on
> the `/adu` filesystem in cleartext. If your threat model includes
> attackers with physical or block-level access to the device storage,
> enable disk encryption for `/adu` (e.g. dm-crypt + a TPM-bound key)
> outside the scope of this layer.

---

## 6. Known limitations and security implications

### 6.1 Functional limitations

- **`/adu` corruption or missing partition** is fatal for persistence:
  the service has `ConditionPathIsMountPoint=/adu` and will not run.
  The system boots with pristine rootfs `/etc` content (no operator
  password, fresh SSH host keys, etc.). There is no automatic recovery.
- **Deletions are not preserved.** `userdel` at runtime is undone on next
  boot (§4.3). Operators who need to delete an account must also clear
  the corresponding entry from `/adu/system/passwd`, `/adu/system/shadow`,
  `/adu/system/group`, `/adu/system/gshadow`.
- **Rollback leaves image-introduced state behind.** An A/B rollback does
  not automatically prune accounts/groups that the newer image
  introduced (§4.3 example 5). Use `factory-reset.sh` for a clean state.
- **Line-merge is only suitable for the colon-separated auth files.**
  Other config files use plain `persist-wins`. Do not add arbitrary
  config files to the line-merge code path without understanding their
  syntax.
- **`/home/<user>/`, `~/.ssh/authorized_keys`, and per-user state are
  not persisted by this layer.** They live on the rootfs and are lost
  on every A/B swap unless your image places them on a separate
  partition (e.g. via a `/home` mount).
- **Watcher shutdown gap.** A change made between the last watcher
  debounce and the call to `ExecStop=sync-persistent-files.sh` is
  captured by the shutdown safety net; a change made *after* that
  ExecStop and before final umount is not. In practice this is
  microseconds and only matters for adversarial scenarios.
- **OverlayFS requires `CONFIG_OVERLAY_FS=y` in the kernel.** When the
  kernel lacks overlay support (e.g. the default qemuarm64 kernel),
  `mount-overlays.sh` fails gracefully (the unit has `-` prefixed
  `ExecStart`) and `/var/log` etc. are **not** persisted across reboot.
  Auth-file persistence is unaffected and continues to work.

### 6.2 Security implications

- **`shadow`/`gshadow` persist-wins on all-three-differ tie-break (§4.3
  rule 4).** If an image update tries to enforce a new password policy
  for a system account that the operator has also touched, the operator's
  copy wins. This is the right answer for *user* accounts (`chpasswd`
  must survive an update); it is the wrong answer for *fleet-wide
  rotation of a system service's secret*. Two mitigations:
  1. Ship service-account secret rotations as part of the image and
     accept that they only take effect on devices where the operator
     has never touched that account.
  2. Bundle a one-shot post-update script that explicitly removes the
     stale entry from `/adu/system/shadow` before
     `adu-persistent-overlay.service` runs.
- **Cleartext at rest.** As above (§5).
- **A persistent SSH host key prevents legitimate "host key changed"
  alerts.** This is the *point*, but it also means a compromised device
  cannot be re-keyed by an OTA alone — operators must rotate the keys
  on the persistent partition explicitly.

### 6.3 Non-goals

- This layer does not implement integrity or rollback protection of
  `/adu` itself (no dm-verity on the persistent partition, no signed
  state). If you need that, layer it on top.
- This layer does not synchronize state to a remote (cloud / fleet
  manager). Cloud state is the responsibility of higher-level services
  (e.g. ADU agent itself).

---

## 7. Configuration reference

All configuration lives in **`/etc/overlay/overlay.conf`** (installed from
`recipes-support/adu-persistent-overlay/files/overlay.conf`).
This file is shipped on the rootfs and read by every script. It is
intentionally not persisted — changes to it ship with the image.

```bash
# Persistent base partition (mount point).
PERSIST_BASE="/adu"

# Subdirectories of PERSIST_BASE.
OVERLAY_BASE="${PERSIST_BASE}/overlay"
WORK_BASE="${PERSIST_BASE}/work"
SYSTEM_DIR="${PERSIST_BASE}/system"

# Files copy-restored (and watched). Form: <persist_basename>:<rootfs_path>
SYNC_FILES=(
    "passwd:/etc/passwd"
    "shadow:/etc/shadow"
    "group:/etc/group"
    "gshadow:/etc/gshadow"
    "hostname:/etc/hostname"
    "timezone:/etc/timezone"
    "machine-id:/etc/machine-id"
    "du-config.json:/etc/adu/du-config.json"
)

# Directories bind-mounted from /adu/system/<basename>.
BIND_MOUNTS=(
    "apt-sources.list.d:/etc/apt/sources.list.d"
    "apt-trusted.gpg.d:/etc/apt/trusted.gpg.d"
    "apt-preferences.d:/etc/apt/preferences.d"
)

# SSH host key basenames restored from /adu/system/ssh/ into /etc/ssh/.
SSH_HOST_KEYS=(
    "ssh_host_rsa_key"      "ssh_host_rsa_key.pub"
    "ssh_host_ed25519_key"  "ssh_host_ed25519_key.pub"
    "ssh_host_ecdsa_key"    "ssh_host_ecdsa_key.pub"
)

# Directories backed by overlayfs (lower = rootfs, upper = /adu/overlay/<safe-name>).
OVERLAY_DIRS=(
    "/var/log"
    "/var/lib/connman"
    "/var/lib/bluetooth"
    "/var/cache/apt"
    "/var/lib/adu"
    "/var/lib/adu/downloads"
    "/var/lib/adu/extensions"
    "/var/lib/adu/states"
    "/var/lib/adu/sdc"
    "/var/lib/adu/api"
)

# Watcher debounce window (seconds).
WATCHER_DEBOUNCE=1
```

### 7.1 Extending the set of persisted files

To add a new whole-file persistent state (`persist-wins`):

1. Add a `"<basename>:<rootfs path>"` entry to `SYNC_FILES` in
   `overlay.conf`.
2. Rebuild the image.
3. On first boot under the new config, the file is seeded from the
   rootfs.

To add a new directory:

1. If the directory is mostly read-only with overlay semantics (logs,
   caches), add it to `OVERLAY_DIRS`.
2. If it contains config files that other tooling will `rename(2)`
   over, prefer a bind mount: add to `BIND_MOUNTS`, ensure
   `/adu/system/<basename>/` exists at first boot, and that the
   rootfs `<rootfs path>` is empty (or is wholesale replaced) — bind
   mounts hide the rootfs content.

**Do not** add config files with novel syntax to the line-merge code
path. Extend the merge engine in `restore-persistent-files.sh` only
after writing matching unit tests.

---

## 8. Testing

### 8.1 Hermetic unit tests

`recipes-support/adu-persistent-overlay/tests/test_persistence_scripts.sh`
covers the merge engine and sync engine in isolation (no Yocto build, no
real partition):

- `overlay.conf` shape (arrays defined, no syntax errors).
- First-boot seed (rootfs → persist + baseline).
- Persisted-wins on second boot for plain files.
- Image rotation with same persist (baseline refresh).
- 3-way conflict resolution for `shadow` (all rules in §4.3).
- 3-way conflict resolution for `passwd` (uid-alignment branch).
- New rootfs user pickup on image update.
- Baseline correctly refreshed after merge.
- Runtime-added user preserved across reboot.
- Whole-file persist for `hostname`/`machine-id`.
- Single-file `sync-persistent-files.sh` mode.
- All-files `sync-persistent-files.sh` mode.
- SSH host key basename routing.
- Atomic temp+rename for both restore and sync.

Run them on a developer host with `bash`/`awk`:

```bash
cd recipes-support/adu-persistent-overlay/tests
./test_persistence_scripts.sh
```

### 8.2 Manual / end-to-end validation (required before claiming a port works)

Run these on the real target, or a faithful qemu of it:

| # | Test | Pass criterion |
|---|---|---|
| 1 | Set root password (`echo root:s3cret ǀ chpasswd`) | Command exits 0; no EBUSY |
| 2 | Within 5 s, `/adu/system/shadow` hash matches `/etc/shadow` | Watcher fired |
| 3 | Reboot. Log in with new password | Login succeeds |
| 4 | `/etc/ssh/ssh_host_*` fingerprints | Unchanged across reboots |
| 5 | A/B update to a new image, reboot to other slot, log in | New password still works |
| 6 | A/B rollback to original slot | Same password still works |
| 7 | Power-cut during a `chpasswd` (10× iterations) | `/etc/shadow` is always a valid syntactically-complete file (atomic install holds) |
| 8 | Factory reset (`/usr/lib/adu/factory-reset.sh`) and reboot | Image defaults restored |

---

## 9. Porting checklist for a new BSP

When adding this reference design to a new board layer:

1. **WIC / partition layout.** Add a 4th ext4 partition labeled `adu`,
   sized for your retention needs (≥ 256 MiB is comfortable).
2. **fstab / mount unit.** Mount the `adu` partition at `/adu` with
   `nofail` and ensure it happens before `adu-filesystem-layout.service`.
3. **Image install.** Add `adu-persistent-overlay` to
   `IMAGE_INSTALL` for the board.
4. **Kernel.** If you want `/var/log` etc. to persist, enable
   `CONFIG_OVERLAY_FS=y` in your kernel fragment. (Auth persistence
   does not require it.)
5. **Required runtime packages.** `bash`, `coreutils` (`mv`, `mktemp`,
   `chmod --reference`), `inotify-tools`, `awk`, `systemd`,
   `shadow` (or equivalent shadow-utils). These are pulled in by
   `RDEPENDS` of `adu-persistent-overlay`.
6. **Boot ordering.** Verify the unit names of your distro's
   `sshd.service`, user-sessions unit, and ADU agent match the
   `Before=` clauses in `adu-persistent-overlay.service`. Adjust if
   your distro renames them.
7. **Tests.** Run the hermetic unit tests (§8.1) in CI. Run the manual
   matrix (§8.2) at least once per board.
8. **Smoke test the dependency cycle.** Boot once with a serial
   console attached and confirm `multi-user.target` is reached and
   `systemctl list-jobs` is empty within 60 s. The previous bind-mount
   approach silently hung at sockets stage on boot.

---

## 10. References and history

- Replaced the per-file bind-mount design that shipped in commit
  `5030581` of this repo. See commit `6b8805c` for the rewrite.
- The 3-way merge rules are deliberately conservative: they do not
  attempt to merge inside a single line (only whole-entry replacement
  by user/group key). This keeps the implementation auditable in
  ~50 lines of `awk`.
- For broader context on the A/B update flow that this design plugs
  into, see [`architecture-decision.md`](architecture-decision.md).
- For the steps to wire up a new board, see
  [`porting-guide.md`](porting-guide.md).
