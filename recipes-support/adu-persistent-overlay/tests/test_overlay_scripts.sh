#!/usr/bin/env bash
# Hermetic unit tests for adu-persistent-overlay scripts.
#
# These tests do NOT require root, do NOT touch the host /adu, and do NOT
# call the real `mount` system call. They exercise the seed/skip logic of
# setup-overlay-dirs.sh and the per-entry decision flow of
# mount-critical-binds.sh against a sandbox rootfs.
#
# Run:  bash tests/test_overlay_scripts.sh
# CI:   exits 0 on success, non-zero on first failure.

set -u
MOCK_MOUNT_LOG=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$(cd "${SCRIPT_DIR}/../files" && pwd)"

PASS=0
FAIL=0
FAILED_TESTS=()

color() { tput setaf "$1" 2>/dev/null || true; }
reset() { tput sgr0 2>/dev/null || true; }

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" = "$actual" ]; then return 0; fi
    echo "    ASSERT_EQ failed: ${msg}"
    echo "      expected: ${expected}"
    echo "      actual:   ${actual}"
    return 1
}
assert_file_exists() {
    local f="$1" msg="${2:-}"
    if [ -f "$f" ]; then return 0; fi
    echo "    ASSERT_FILE_EXISTS failed: ${f} (${msg})"
    return 1
}
assert_file_absent() {
    local f="$1" msg="${2:-}"
    if [ ! -e "$f" ]; then return 0; fi
    echo "    ASSERT_FILE_ABSENT failed: ${f} (${msg})"
    return 1
}
assert_perms() {
    local f="$1" expected="$2"
    local got
    got=$(stat -c "%a" "$f" 2>/dev/null)
    if [ "$got" = "$expected" ]; then return 0; fi
    echo "    ASSERT_PERMS failed: ${f} expected ${expected} got ${got}"
    return 1
}
assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if grep -qF "$needle" <<< "$haystack"; then return 0; fi
    echo "    ASSERT_CONTAINS failed: ${msg}"
    echo "      expected substring: ${needle}"
    echo "      actual: ${haystack}"
    return 1
}

run_test() {
    local name="$1"
    shift
    SANDBOX="$(mktemp -d)"
    MOCK_MOUNT_LOG="$SANDBOX/mount.log"
    export MOCK_MOUNT_LOG
    trap 'rm -rf "$SANDBOX"' RETURN
    if "$@"; then
        color 2; echo "  ok   ${name}"; reset
        PASS=$((PASS + 1))
    else
        color 1; echo "  FAIL ${name}"; reset
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
    rm -rf "$SANDBOX"
    trap - RETURN
}

# -------------------------------------------------------------------------
# Fixture: build a sandbox that mimics the runtime layout
# -------------------------------------------------------------------------
make_sandbox_rootfs() {
    # $SANDBOX/rootfs simulates "/" at boot (where /etc/passwd lives)
    # $SANDBOX/adu simulates the persistent /adu partition (initially empty)
    mkdir -p "$SANDBOX/rootfs/etc" "$SANDBOX/rootfs/etc/adu"
    mkdir -p "$SANDBOX/adu" "$SANDBOX/adu/conf"

    # Seed a "rootfs" passwd/shadow with a known root password hash so we can
    # test that it survives a simulated A/B swap.
    cat > "$SANDBOX/rootfs/etc/passwd" <<EOFROOTFS
root:x:0:0:root:/home/root:/bin/sh
adu:x:800:800::/home/adu:/bin/false
EOFROOTFS
    chmod 644 "$SANDBOX/rootfs/etc/passwd"

    cat > "$SANDBOX/rootfs/etc/shadow" <<EOFROOTFS
root:\$6\$ROOTFSseed\$rootFsHashFromImage:19700:0:99999:7:::
adu:!:19700:0:99999:7:::
EOFROOTFS
    chmod 640 "$SANDBOX/rootfs/etc/shadow"

    cat > "$SANDBOX/rootfs/etc/group" <<EOFROOTFS
root:x:0:
adu:x:800:
shadow:x:42:
EOFROOTFS
    chmod 644 "$SANDBOX/rootfs/etc/group"

    cat > "$SANDBOX/rootfs/etc/gshadow" <<EOFROOTFS
root:::
adu:!::
EOFROOTFS
    chmod 640 "$SANDBOX/rootfs/etc/gshadow"

    echo "qemu-test-hostname" > "$SANDBOX/rootfs/etc/hostname"
    echo "UTC" > "$SANDBOX/rootfs/etc/timezone"
    echo "ffffffffffffffffffffffffffffffff" > "$SANDBOX/rootfs/etc/machine-id"
    chmod 444 "$SANDBOX/rootfs/etc/machine-id"

    mkdir -p "$SANDBOX/rootfs/etc/ssh"
    echo "fake-host-key" > "$SANDBOX/rootfs/etc/ssh/ssh_host_rsa_key"
    chmod 600 "$SANDBOX/rootfs/etc/ssh/ssh_host_rsa_key"

    mkdir -p "$SANDBOX/rootfs/var/lib/adu" "$SANDBOX/rootfs/var/log/adu"
    mkdir -p "$SANDBOX/rootfs/etc/adu"
    echo '{}' > "$SANDBOX/rootfs/etc/adu/du-config.json"

    # Deliberately omit /etc/apt/* — this simulates the qemu/imx8ulp case
    # where apt is not installed. The new skip logic must NOT seed those.

    # Install our overlay.conf into the simulated /adu/conf so the scripts
    # can source it. Use $SANDBOX-prefixed paths so we don't touch the host.
    cat > "$SANDBOX/adu/conf/overlay.conf" <<EOFCONF
PERSIST_BASE="${SANDBOX}/adu"
OVERLAY_BASE="\${PERSIST_BASE}/overlay"
WORK_BASE="\${PERSIST_BASE}/work"
SYSTEM_DIR="\${PERSIST_BASE}/system"

OVERLAY_DIRS=(
    "${SANDBOX}/rootfs/var/log"
    "${SANDBOX}/rootfs/var/lib/adu"
)

BIND_MOUNTS=(
    "passwd:${SANDBOX}/rootfs/etc/passwd"
    "shadow:${SANDBOX}/rootfs/etc/shadow"
    "group:${SANDBOX}/rootfs/etc/group"
    "gshadow:${SANDBOX}/rootfs/etc/gshadow"
    "hostname:${SANDBOX}/rootfs/etc/hostname"
    "timezone:${SANDBOX}/rootfs/etc/timezone"
    "machine-id:${SANDBOX}/rootfs/etc/machine-id"
    "ssh:${SANDBOX}/rootfs/etc/ssh"
    "apt-sources.list.d:${SANDBOX}/rootfs/etc/apt/sources.list.d"
    "apt-trusted.gpg.d:${SANDBOX}/rootfs/etc/apt/trusted.gpg.d"
)

AUTO_MIGRATE="no"
VERIFY_MOUNTS="no"
EOFCONF

    # Pre-create /adu/data per filesystem-layout contract.
    mkdir -p "$SANDBOX/adu/data/states" "$SANDBOX/adu/data/downloads" "$SANDBOX/adu/data/extensions"
    # Mock /etc/overlay/overlay.conf (setup-overlay-dirs reads from here)
    mkdir -p "$SANDBOX/etc-overlay"
    cp "$SANDBOX/adu/conf/overlay.conf" "$SANDBOX/etc-overlay/overlay.conf"
}

# Run setup-overlay-dirs.sh against the sandbox.
# The script hardcodes /etc/overlay/overlay.conf so we use a wrapper that
# substitutes the path on the fly.
run_setup_in_sandbox() {
    sed "s|/etc/overlay/overlay.conf|${SANDBOX}/etc-overlay/overlay.conf|g" \
        "${FILES_DIR}/setup-overlay-dirs.sh" > "$SANDBOX/setup.sh"
    chmod +x "$SANDBOX/setup.sh"
    bash "$SANDBOX/setup.sh" 2>&1
}

# Run mount-critical-binds.sh with mocked mount/mountpoint commands.
run_binds_in_sandbox() {
    # Mocked mount: log invocations to a file, always succeed.
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/mount" <<'EOFMOUNT'
#!/usr/bin/env bash
echo "MOUNT_CALLED $@" >> "$MOCK_MOUNT_LOG"
exit 0
EOFMOUNT
    # mountpoint always returns "not a mountpoint" so the script proceeds
    cat > "$SANDBOX/bin/mountpoint" <<'EOFMP'
#!/usr/bin/env bash
exit 1
EOFMP
    chmod +x "$SANDBOX/bin/mount" "$SANDBOX/bin/mountpoint"

    sed "s|/adu/conf/overlay.conf|${SANDBOX}/adu/conf/overlay.conf|g" \
        "${FILES_DIR}/mount-critical-binds.sh" > "$SANDBOX/binds.sh"
    chmod +x "$SANDBOX/binds.sh"

    PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/binds.sh" 2>&1
}

# -------------------------------------------------------------------------
# Tests
# -------------------------------------------------------------------------

test_setup_seeds_existing_targets() {
    make_sandbox_rootfs
    local out
    out=$(run_setup_in_sandbox) || { echo "$out"; return 1; }

    assert_file_exists "$SANDBOX/adu/system/passwd"   "passwd should be seeded"   || return 1
    assert_file_exists "$SANDBOX/adu/system/shadow"   "shadow should be seeded"   || return 1
    assert_file_exists "$SANDBOX/adu/system/group"    "group should be seeded"    || return 1
    assert_file_exists "$SANDBOX/adu/system/gshadow"  "gshadow should be seeded"  || return 1
    assert_file_exists "$SANDBOX/adu/system/hostname" "hostname should be seeded" || return 1

    # Seeded content matches rootfs source
    diff -q "$SANDBOX/rootfs/etc/passwd" "$SANDBOX/adu/system/passwd" > /dev/null || {
        echo "    seeded passwd does not match rootfs"; return 1; }
    diff -q "$SANDBOX/rootfs/etc/shadow" "$SANDBOX/adu/system/shadow" > /dev/null || {
        echo "    seeded shadow does not match rootfs"; return 1; }
}

test_setup_seeds_ssh_directory() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    [ -d "$SANDBOX/adu/system/ssh" ] || { echo "    /adu/system/ssh should be a dir"; return 1; }
    assert_file_exists "$SANDBOX/adu/system/ssh/ssh_host_rsa_key" "host key seeded" || return 1
}

test_setup_skips_missing_apt_targets() {
    make_sandbox_rootfs
    local out
    out=$(run_setup_in_sandbox) || { echo "$out"; return 1; }

    # The skip log should mention the apt targets
    assert_contains "$out" "[skip] Target ${SANDBOX}/rootfs/etc/apt/sources.list.d" "apt-sources skip msg" || return 1
    assert_contains "$out" "[skip] Target ${SANDBOX}/rootfs/etc/apt/trusted.gpg.d"  "apt-trusted skip msg" || return 1

    # CRITICAL: no placeholder file/dir should have been created for the
    # apt entries (the bug we are fixing).
    assert_file_absent "$SANDBOX/adu/system/apt-sources.list.d" "no apt-sources placeholder" || return 1
    assert_file_absent "$SANDBOX/adu/system/apt-trusted.gpg.d"  "no apt-trusted placeholder"  || return 1
}

test_setup_shadow_perms_640() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    assert_perms "$SANDBOX/adu/system/shadow"  640 || return 1
    assert_perms "$SANDBOX/adu/system/gshadow" 640 || return 1
}

test_setup_passwd_perms_644() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    assert_perms "$SANDBOX/adu/system/passwd" 644 || return 1
    assert_perms "$SANDBOX/adu/system/group"  644 || return 1
}

test_setup_machine_id_perms_444() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    assert_perms "$SANDBOX/adu/system/machine-id" 444 || return 1
}

test_setup_idempotent() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    # Mutate seeded shadow (simulate user changing password)
    sed -i 's/ROOTFSseed/USERchanged/' "$SANDBOX/adu/system/shadow"
    local checksum_before
    checksum_before=$(sha256sum "$SANDBOX/adu/system/shadow" | cut -d' ' -f1)
    # Run setup again with SAME rootfs (no image change). The seeded shadow
    # must NOT be overwritten — that would clobber the user's password.
    run_setup_in_sandbox > /dev/null || return 1
    local checksum_after
    checksum_after=$(sha256sum "$SANDBOX/adu/system/shadow" | cut -d' ' -f1)
    assert_eq "$checksum_before" "$checksum_after" "shadow must persist across re-runs" || return 1
}

test_setup_refresh_on_image_password_change() {
    # When the IMAGE ships a non-default root password (rootfs shadow has a
    # real hash), setup must refresh the persistent shadow so a deployed
    # update can rotate credentials. This is the existing logic — keep it.
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    # Now simulate an A/B swap: rootfs ships a *new* hash, but the persistent
    # shadow has the OLD seed.
    sed -i 's/ROOTFSseed/IMAGEnewSeed/' "$SANDBOX/rootfs/etc/shadow"
    run_setup_in_sandbox > /dev/null || return 1
    # The persistent shadow should now contain the new hash.
    grep -q "IMAGEnewSeed" "$SANDBOX/adu/system/shadow" || {
        echo "    expected IMAGEnewSeed in /adu/system/shadow"
        cat "$SANDBOX/adu/system/shadow"
        return 1
    }
}

test_setup_preserves_user_password_when_image_unchanged() {
    # The KEY scenario for this feature: user changes password at runtime;
    # an A/B update is applied; user's password must survive.
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1

    # Simulate runtime password change: edit persistent shadow (this is what
    # the bind-mounted file would look like after `passwd root` on the device).
    sed -i 's|root:[^:]*:|root:\$6\$USER\$userChosenHash:|' "$SANDBOX/adu/system/shadow"

    # Now simulate A/B swap to a NEW rootfs that has the same factory empty
    # (or default) root password — i.e. no intentional image-level rotation.
    # rootfs shadow keeps the original ROOTFSseed (no change).
    run_setup_in_sandbox > /dev/null || return 1

    grep -q "userChosenHash" "$SANDBOX/adu/system/shadow" || {
        echo "    user-chosen password was clobbered by A/B swap (regression!)"
        cat "$SANDBOX/adu/system/shadow"
        return 1
    }
}

test_binds_calls_mount_for_seeded_files() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    local out
    out=$(run_binds_in_sandbox) || { echo "$out"; return 1; }

    grep -q "MOUNT_CALLED --bind ${SANDBOX}/adu/system/passwd ${SANDBOX}/rootfs/etc/passwd" "$MOCK_MOUNT_LOG" \
        || { echo "    expected bind mount for passwd"; cat "$MOCK_MOUNT_LOG"; return 1; }
    grep -q "MOUNT_CALLED --bind ${SANDBOX}/adu/system/shadow ${SANDBOX}/rootfs/etc/shadow" "$MOCK_MOUNT_LOG" \
        || { echo "    expected bind mount for shadow"; cat "$MOCK_MOUNT_LOG"; return 1; }
}

test_binds_skips_unseeded_apt_targets() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    local out
    out=$(run_binds_in_sandbox) || { echo "$out"; return 1; }

    # mount must NOT be called for apt-* entries because their source was
    # never seeded (setup skipped them).
    if grep -E "MOUNT_CALLED.*apt-sources.list.d" "$MOCK_MOUNT_LOG"; then
        echo "    bind mount for apt-sources.list.d should be skipped"; return 1
    fi
    if grep -E "MOUNT_CALLED.*apt-trusted.gpg.d" "$MOCK_MOUNT_LOG"; then
        echo "    bind mount for apt-trusted.gpg.d should be skipped"; return 1
    fi

    # Script must have logged the skip
    assert_contains "$out" "Source missing"        "skip log present"        || return 1
}

test_binds_creates_rootfs_original_backup() {
    make_sandbox_rootfs
    run_setup_in_sandbox > /dev/null || return 1
    run_binds_in_sandbox > /dev/null || return 1
    assert_file_exists "${SANDBOX}/rootfs/etc/passwd.rootfs-original" "passwd backup" || return 1
    assert_file_exists "${SANDBOX}/rootfs/etc/shadow.rootfs-original" "shadow backup" || return 1
}

test_overlay_conf_shipped_in_recipe_well_formed() {
    # Sanity check the recipe's overlay.conf file itself (the one that gets
    # installed into /etc/overlay/overlay.conf). It must source cleanly and
    # define the variables the scripts depend on.
    local conf="${FILES_DIR}/overlay.conf"
    assert_file_exists "$conf" "recipe overlay.conf present" || return 1
    ( source "$conf"
      [ -n "${PERSIST_BASE:-}" ]  || { echo "    PERSIST_BASE unset";  exit 1; }
      [ -n "${SYSTEM_DIR:-}" ]    || { echo "    SYSTEM_DIR unset";    exit 1; }
      [ "${#BIND_MOUNTS[@]}" -gt 0 ] || { echo "    BIND_MOUNTS empty"; exit 1; }
      # Passwd / shadow / group / gshadow must be in the bind mount list —
      # that's what makes password persistence work.
      printf '%s\n' "${BIND_MOUNTS[@]}" | grep -q '^passwd:/etc/passwd$'   || { echo "    passwd missing from BIND_MOUNTS"; exit 1; }
      printf '%s\n' "${BIND_MOUNTS[@]}" | grep -q '^shadow:/etc/shadow$'   || { echo "    shadow missing from BIND_MOUNTS"; exit 1; }
      printf '%s\n' "${BIND_MOUNTS[@]}" | grep -q '^group:/etc/group$'     || { echo "    group missing from BIND_MOUNTS"; exit 1; }
      printf '%s\n' "${BIND_MOUNTS[@]}" | grep -q '^gshadow:/etc/gshadow$' || { echo "    gshadow missing from BIND_MOUNTS"; exit 1; }
    ) || return 1
}

# -------------------------------------------------------------------------
# Runner
# -------------------------------------------------------------------------
echo "Running adu-persistent-overlay unit tests..."
echo "  FILES_DIR: ${FILES_DIR}"
echo

run_test "setup: seeds existing targets"                   test_setup_seeds_existing_targets
run_test "setup: seeds ssh directory"                      test_setup_seeds_ssh_directory
run_test "setup: skips missing apt targets (no placeholder)" test_setup_skips_missing_apt_targets
run_test "setup: shadow/gshadow mode 640"                  test_setup_shadow_perms_640
run_test "setup: passwd/group mode 644"                    test_setup_passwd_perms_644
run_test "setup: machine-id mode 444"                      test_setup_machine_id_perms_444
run_test "setup: idempotent (no clobber on re-run)"        test_setup_idempotent
run_test "setup: refresh on image password change"         test_setup_refresh_on_image_password_change
run_test "setup: user password survives A/B swap"          test_setup_preserves_user_password_when_image_unchanged
run_test "binds: mount called for seeded files"            test_binds_calls_mount_for_seeded_files
run_test "binds: skips unseeded apt targets"               test_binds_skips_unseeded_apt_targets
run_test "binds: backs up original rootfs file"            test_binds_creates_rootfs_original_backup
run_test "conf:  recipe overlay.conf well-formed"          test_overlay_conf_shipped_in_recipe_well_formed

echo
echo "================================================================"
echo "  passed: ${PASS}    failed: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
    echo "  failed tests:"
    printf "    - %s\n" "${FAILED_TESTS[@]}"
    exit 1
fi
echo "================================================================"
exit 0