#!/usr/bin/env bash
# Hermetic unit tests for adu-persistent-overlay's persistent-files sync model.
#
# Covers:
#   - restore-persistent-files.sh : seed, persisted-wins, image-rotation,
#     3-way merge, baseline refresh, new-user union.
#   - sync-persistent-files.sh    : single-file mode, all-files mode,
#     ssh_host_* routing, atomic temp+rename.
#   - overlay.conf shape          : SYNC_FILES present, auth files NOT in
#     BIND_MOUNTS.
#
# Tests do NOT require root or touch the host /adu — every test gets a fresh
# tmpdir-based sandbox with a mock /etc and /adu/system.
#
# Run:  bash tests/test_persistence_scripts.sh

set -u

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
assert_contains() {
    local f="$1" needle="$2" msg="${3:-}"
    if grep -qE "$needle" "$f"; then return 0; fi
    echo "    ASSERT_CONTAINS failed in $f (${msg}): needle=${needle}"
    echo "      file contents:"
    sed 's/^/        /' "$f"
    return 1
}
assert_not_contains() {
    local f="$1" needle="$2" msg="${3:-}"
    if ! grep -qE "$needle" "$f"; then return 0; fi
    echo "    ASSERT_NOT_CONTAINS failed in $f (${msg}): needle=${needle}"
    return 1
}

run_test() {
    local name="$1"; shift
    local out
    if out=$("$@" 2>&1); then
        echo "  PASS $name"
        PASS=$((PASS+1))
    else
        echo "  FAIL $name"
        [ -n "$out" ] && echo "$out" | sed 's/^/    /'
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name")
    fi
}

# Build a sandbox with a fake /etc and a fake /adu/system rooted in $1.
make_sandbox() {
    local root="$1"
    mkdir -p "${root}/etc" "${root}/etc/overlay" "${root}/etc/adu" "${root}/etc/ssh" \
             "${root}/adu/system" "${root}/adu/system/baseline" "${root}/adu/system/ssh"
    # Minimal overlay.conf overriding paths.
    cat > "${root}/etc/overlay/overlay.conf" <<EOF
PERSIST_BASE="${root}/adu"
SYSTEM_DIR="${root}/adu/system"
SYNC_FILES=(
    "passwd:${root}/etc/passwd"
    "shadow:${root}/etc/shadow"
    "group:${root}/etc/group"
    "gshadow:${root}/etc/gshadow"
    "hostname:${root}/etc/hostname"
    "timezone:${root}/etc/timezone"
    "machine-id:${root}/etc/machine-id"
    "du-config.json:${root}/etc/adu/du-config.json"
)
BIND_MOUNTS=(
    "apt-sources.list.d:${root}/etc/apt/sources.list.d"
)
SSH_HOST_KEYS=(
    "ssh_host_rsa_key"
    "ssh_host_rsa_key.pub"
)
EOF
}

# Stash & restore /etc/overlay/overlay.conf path for the scripts. The scripts
# always read /etc/overlay/overlay.conf — we replicate the sandbox config to
# that path, but to keep tests fully hermetic we instead invoke the scripts
# with a wrapper that pre-sources the sandbox config.
run_restore_in_sandbox() {
    local root="$1"
    (
        # shellcheck disable=SC1090,SC1091
        # Replace the hardcoded CONFIG_FILE path by aliasing it via a copy.
        # Easiest: copy the script to the sandbox so we control its
        # CONFIG_FILE via a sed substitution.
        cp "${FILES_DIR}/restore-persistent-files.sh" "${root}/_restore.sh"
        sed -i "s|/etc/overlay/overlay.conf|${root}/etc/overlay/overlay.conf|g" "${root}/_restore.sh"
        bash "${root}/_restore.sh"
    )
}
run_sync_in_sandbox() {
    local root="$1"; shift
    (
        cp "${FILES_DIR}/sync-persistent-files.sh" "${root}/_sync.sh"
        sed -i "s|/etc/overlay/overlay.conf|${root}/etc/overlay/overlay.conf|g" "${root}/_sync.sh"
        sed -i "s|/etc/ssh|${root}/etc/ssh|g" "${root}/_sync.sh"
        bash "${root}/_sync.sh" "$@"
    )
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test_conf_well_formed() {
    local conf="${FILES_DIR}/overlay.conf"
    [ -f "$conf" ] || { echo "missing $conf"; return 1; }
    bash -n "$conf" || { echo "syntax error in $conf"; return 1; }
    (
        # shellcheck disable=SC1090
        source "$conf"
        # SYNC_FILES must include the auth files
        [ -n "${SYNC_FILES+x}" ] || { echo "SYNC_FILES not defined"; exit 1; }
        local needed n found
        for n in passwd shadow group gshadow hostname timezone machine-id; do
            found=0
            for spec in "${SYNC_FILES[@]}"; do
                IFS=':' read -r src tgt <<< "$spec"
                if [ "$src" = "$n" ]; then found=1; break; fi
            done
            [ "$found" = 1 ] || { echo "$n missing from SYNC_FILES"; exit 1; }
        done
        # BIND_MOUNTS must NOT contain any auth file (would re-introduce
        # the rename-over-mountpoint bug).
        for spec in "${BIND_MOUNTS[@]}"; do
            IFS=':' read -r src tgt <<< "$spec"
            case "$src" in
                passwd|shadow|group|gshadow|hostname|timezone|machine-id|ssh)
                    echo "auth-related entry $src must NOT be in BIND_MOUNTS"; exit 1 ;;
            esac
        done
    )
}

test_restore_seed_first_boot() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    echo "root:x:0:0:root:/root:/bin/bash" > "${d}/etc/passwd"
    echo "root:\$6\$abc\$xxx:19000:0:99999:7:::"   > "${d}/etc/shadow"
    chmod 640 "${d}/etc/shadow"
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_file_exists "${d}/adu/system/passwd" "passwd seeded to /adu/system" || return 1
    assert_file_exists "${d}/adu/system/baseline/passwd" "baseline seeded" || return 1
    diff -q "${d}/etc/passwd" "${d}/adu/system/passwd" >/dev/null \
        || { echo "/adu/system/passwd != /etc/passwd"; return 1; }
}

test_restore_persisted_wins_image_unchanged() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    # Image / rootfs:
    echo "root:x:0:0:root:/root:/bin/bash" > "${d}/etc/passwd"
    echo "root:\$ORIG_HASH:19000:0:99999:7:::" > "${d}/etc/shadow"
    # Persisted (user changed root password at runtime):
    cp "${d}/etc/passwd" "${d}/adu/system/passwd"
    echo "root:\$USER_HASH:19000:0:99999:7:::" > "${d}/adu/system/shadow"
    # Baseline tracks original rootfs (image unchanged since last sync).
    cp "${d}/etc/passwd"  "${d}/adu/system/baseline/passwd"
    cp "${d}/etc/shadow"  "${d}/adu/system/baseline/shadow"
    # Persisted shadow differs from BOTH rootfs and baseline (=rootfs); merge
    # rule: rootfs=baseline => take persisted.
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_contains "${d}/etc/shadow" "USER_HASH" "user hash should win" || return 1
    assert_not_contains "${d}/etc/shadow" "ORIG_HASH" "original hash should not appear" || return 1
}

test_restore_image_rotates_when_user_untouched() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    # New rootfs shipped a rotated root hash.
    echo "root:x:0:0:root:/root:/bin/bash" > "${d}/etc/passwd"
    echo "root:\$NEW_IMAGE_HASH:19000:0:99999:7:::" > "${d}/etc/shadow"
    # Persisted = baseline (user never touched root).
    cp "${d}/etc/passwd"  "${d}/adu/system/passwd"
    echo "root:\$OLD_HASH:19000:0:99999:7:::" > "${d}/adu/system/shadow"
    cp "${d}/etc/passwd"  "${d}/adu/system/baseline/passwd"
    echo "root:\$OLD_HASH:19000:0:99999:7:::" > "${d}/adu/system/baseline/shadow"
    # persisted == baseline AND rootfs != baseline => take rootfs.
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_contains "${d}/etc/shadow" "NEW_IMAGE_HASH" "image hash should win when user untouched" || return 1
}

test_restore_three_way_conflict_preserves_user_hash() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    echo "root:\$NEW_IMG:19000:0:99999:7:::" > "${d}/etc/shadow"
    echo "root:\$USER_HASH:19000:0:99999:7:::" > "${d}/adu/system/shadow"
    echo "root:\$OLD_BASE:19000:0:99999:7:::" > "${d}/adu/system/baseline/shadow"
    echo "root:x:0:0:root:/root:/bin/bash" > "${d}/etc/passwd"
    cp "${d}/etc/passwd"  "${d}/adu/system/passwd"
    cp "${d}/etc/passwd"  "${d}/adu/system/baseline/passwd"
    # All three differ for shadow => take persisted (preserves password).
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_contains "${d}/etc/shadow" "USER_HASH" "user hash preserved on both-changed" || return 1
    assert_not_contains "${d}/etc/shadow" "NEW_IMG" "image hash should not overwrite user" || return 1
}

test_restore_new_user_from_rootfs_added() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    # Rootfs adds a new system user "deviceupdate".
    cat > "${d}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
deviceupdate:x:1001:1001::/var/lib/adu:/sbin/nologin
EOF
    cat > "${d}/etc/shadow" <<EOF
root:\$ORIG:19000:0:99999:7:::
deviceupdate:*:19000:0:99999:7:::
EOF
    # Persisted (older snapshot, no deviceupdate yet, root pw changed).
    cat > "${d}/adu/system/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
EOF
    cat > "${d}/adu/system/shadow" <<EOF
root:\$USER_HASH:19000:0:99999:7:::
EOF
    # Baseline = older rootfs (no deviceupdate, original root hash).
    cat > "${d}/adu/system/baseline/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
EOF
    cat > "${d}/adu/system/baseline/shadow" <<EOF
root:\$ORIG:19000:0:99999:7:::
EOF
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_contains "${d}/etc/passwd" "^deviceupdate:" "new rootfs user added" || return 1
    assert_contains "${d}/etc/shadow" "USER_HASH" "user root hash preserved" || return 1
    assert_contains "${d}/etc/shadow" "^deviceupdate:" "new shadow row added" || return 1
}

test_restore_baseline_refreshed_to_new_rootfs() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    cat > "${d}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
deviceupdate:x:1001:1001::/var/lib/adu:/sbin/nologin
EOF
    echo "root:\$IMG:19000:0:99999:7:::" > "${d}/etc/shadow"
    cat > "${d}/adu/system/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
EOF
    echo "root:\$USER:19000:0:99999:7:::" > "${d}/adu/system/shadow"
    cat > "${d}/adu/system/baseline/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
EOF
    echo "root:\$OLD:19000:0:99999:7:::" > "${d}/adu/system/baseline/shadow"
    run_restore_in_sandbox "$d" >/dev/null || return 1
    # Baseline must now reflect the NEW rootfs version (the pre-merge /etc).
    assert_contains "${d}/adu/system/baseline/passwd" "^deviceupdate:" "baseline refreshed to new rootfs" || return 1
    assert_contains "${d}/adu/system/baseline/shadow" "IMG"             "baseline shadow tracks rootfs"   || return 1
}

test_restore_runtime_added_user_preserved() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    cat > "${d}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
EOF
    echo "root:\$ORIG:19000:0:99999:7:::" > "${d}/etc/shadow"
    cat > "${d}/adu/system/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
alice:x:1100:1100::/home/alice:/bin/bash
EOF
    cat > "${d}/adu/system/shadow" <<EOF
root:\$ORIG:19000:0:99999:7:::
alice:\$ALICEPW:19000:0:99999:7:::
EOF
    cp "${d}/etc/passwd" "${d}/adu/system/baseline/passwd"
    cp "${d}/etc/shadow" "${d}/adu/system/baseline/shadow"
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_contains "${d}/etc/passwd" "^alice:" "runtime user preserved" || return 1
    assert_contains "${d}/etc/shadow" "^alice:" "runtime shadow entry preserved" || return 1
    assert_contains "${d}/etc/shadow" "ALICEPW"  "runtime shadow hash preserved"  || return 1
}

test_restore_plain_file_persisted_wins() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    echo "qemu-default"     > "${d}/etc/hostname"
    echo "my-renamed-host"  > "${d}/adu/system/hostname"
    cp "${d}/etc/hostname"    "${d}/adu/system/baseline/hostname"
    # Minimal passwd to avoid noisy errors
    echo "root:x:0:0:root:/root:/bin/bash" > "${d}/etc/passwd"
    echo "root:x:19000:0:99999:7:::"      > "${d}/etc/shadow"
    run_restore_in_sandbox "$d" >/dev/null || return 1
    assert_eq "my-renamed-host" "$(cat "${d}/etc/hostname")" "hostname persisted wins" || return 1
}

test_sync_single_file_pushes_to_persist() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    echo "root:\$FRESH:19000:0:99999:7:::" > "${d}/etc/shadow"
    chmod 640 "${d}/etc/shadow"
    run_sync_in_sandbox "$d" shadow >/dev/null || return 1
    assert_file_exists "${d}/adu/system/shadow" "sync produced persistent file" || return 1
    assert_contains "${d}/adu/system/shadow" "FRESH" "sync content matches /etc" || return 1
}

test_sync_all_files_mode() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    echo "root:x:0:0:root:/root:/bin/bash" > "${d}/etc/passwd"
    echo "root:\$X:19000:0:99999:7:::"     > "${d}/etc/shadow"
    echo "myhost"                          > "${d}/etc/hostname"
    run_sync_in_sandbox "$d" >/dev/null || return 1
    assert_contains "${d}/adu/system/passwd"   "^root:"   "passwd synced"   || return 1
    assert_contains "${d}/adu/system/shadow"   "X"        "shadow synced"   || return 1
    assert_contains "${d}/adu/system/hostname" "myhost"   "hostname synced" || return 1
}

test_sync_ssh_host_key_routing() {
    local d; d=$(mktemp -d)
    trap "rm -rf $d" RETURN
    make_sandbox "$d"
    mkdir -p "${d}/etc/ssh"
    echo "PRIVKEY-DATA" > "${d}/etc/ssh/ssh_host_rsa_key"
    chmod 600 "${d}/etc/ssh/ssh_host_rsa_key"
    run_sync_in_sandbox "$d" ssh_host_rsa_key >/dev/null || return 1
    assert_file_exists "${d}/adu/system/ssh/ssh_host_rsa_key" "host key routed to /adu/system/ssh" || return 1
    assert_contains "${d}/adu/system/ssh/ssh_host_rsa_key" "PRIVKEY-DATA" "host key content" || return 1
}

test_sync_atomic_via_temp_in_dst_dir() {
    # Verify the script's tmp file is created in the destination directory
    # (so the final mv is a rename within the same filesystem and no
    # rename-over-mountpoint happens). Inspect the script.
    local script="${FILES_DIR}/sync-persistent-files.sh"
    grep -q 'mktemp -p "\$(dirname "\$dst")"' "$script" \
        || { echo "sync_one does not mktemp inside dst dir (script may not be atomic)"; return 1; }
    grep -q 'mv -f "\$tmp" "\$dst"' "$script" \
        || { echo "sync_one does not mv tmp -> dst (atomic rename)"; return 1; }
}

test_restore_atomic_via_temp_in_dst_dir() {
    local script="${FILES_DIR}/restore-persistent-files.sh"
    grep -q 'mktemp -p "\$dst_dir"' "$script" \
        || { echo "atomic_install does not mktemp inside dst dir"; return 1; }
    grep -q 'mv -f "\$tmp" "\$dst"' "$script" \
        || { echo "atomic_install does not mv tmp -> dst"; return 1; }
}

# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------

echo "================================================================"
echo "  adu-persistent-overlay persistence-files test suite"
echo "  files dir: ${FILES_DIR}"
echo "================================================================"

run_test "conf:    overlay.conf well-formed and SYNC_FILES set"           test_conf_well_formed
run_test "restore: seed on first boot"                                    test_restore_seed_first_boot
run_test "restore: persisted wins when image unchanged"                   test_restore_persisted_wins_image_unchanged
run_test "restore: image rotation wins when user untouched"               test_restore_image_rotates_when_user_untouched
run_test "restore: 3-way conflict preserves user password hash (shadow)"  test_restore_three_way_conflict_preserves_user_hash
run_test "restore: new rootfs user is added to merged file"               test_restore_new_user_from_rootfs_added
run_test "restore: baseline is refreshed to new rootfs version"           test_restore_baseline_refreshed_to_new_rootfs
run_test "restore: runtime-added persisted user is preserved"             test_restore_runtime_added_user_preserved
run_test "restore: plain file (hostname) persisted wins"                  test_restore_plain_file_persisted_wins
run_test "sync:    single-file mode pushes /etc -> /adu/system"           test_sync_single_file_pushes_to_persist
run_test "sync:    all-files mode iterates SYNC_FILES"                    test_sync_all_files_mode
run_test "sync:    ssh_host_* routed to /adu/system/ssh/<name>"           test_sync_ssh_host_key_routing
run_test "sync:    write is atomic via temp+rename in dst dir"            test_sync_atomic_via_temp_in_dst_dir
run_test "restore: write is atomic via temp+rename in dst dir"            test_restore_atomic_via_temp_in_dst_dir

echo "================================================================"
echo "  passed: ${PASS}    failed: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
    echo "  failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "    - $t"; done
    exit 1
fi
exit 0