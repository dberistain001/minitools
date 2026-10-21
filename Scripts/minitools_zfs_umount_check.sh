#!/usr/bin/env bash
# minitools_zfs_umount_check.sh
# Read-only preflight for a ZFS dataset unmount or whole-pool export.
# This script NEVER runs zfs unmount or zpool export.

set -uo pipefail

SCRIPT_NAME="${0##*/}"
MODE=""
TARGET=""
FINDINGS=0
MOUNT_CHECKS=0

usage() {
    cat <<USAGE
Usage:
  sudo ${SCRIPT_NAME} --dataset <pool/dataset>
  sudo ${SCRIPT_NAME} --pool <pool>

Read-only preflight. Inspects mounted ZFS filesystems, open files/processes,
active swap files, nested mounts, and (for a pool export) open ZFS volumes.
It prints the command that would be run but never runs it.

Examples:
  sudo ${SCRIPT_NAME} --dataset mainPool/home/shares/oakwell
  sudo ${SCRIPT_NAME} --pool backupPool
USAGE
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

# Decode the escaping used by findmnt's raw output for common whitespace.
decode_findmnt() {
    local value="$1"
    value="${value//\\x20/ }"
    value="${value//\\x09/$'\t'}"
    printf '%s' "$value"
}

while (($#)); do
    case "$1" in
        --dataset|-d)
            [[ -z "$MODE" ]] || fail 'Choose either --dataset or --pool, not both.'
            (($# >= 2)) || fail "${1} requires a target."
            MODE="dataset"
            TARGET="$2"
            shift 2
            ;;
        --pool|-p)
            [[ -z "$MODE" ]] || fail 'Choose either --dataset or --pool, not both.'
            (($# >= 2)) || fail "${1} requires a target."
            MODE="pool"
            TARGET="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1 (use --help for usage)."
            ;;
    esac
done

[[ -n "$MODE" && -n "$TARGET" ]] || { usage >&2; exit 2; }

if [[ "$EUID" -ne 0 ]]; then
    fail "Run as root so process and open-file checks are meaningful: sudo ${SCRIPT_NAME} --${MODE} '${TARGET}'"
fi

for cmd in zfs zpool findmnt awk grep swapon; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
done

if ! command -v lsof >/dev/null 2>&1 && ! command -v fuser >/dev/null 2>&1; then
    fail 'Neither lsof nor fuser is installed. On Debian, install one or both with: apt install lsof psmisc'
fi

if [[ "$MODE" == "dataset" ]]; then
    if ! zfs list -H -t filesystem -o name "$TARGET" 2>/dev/null | grep -Fxq -- "$TARGET"; then
        fail "No ZFS filesystem dataset found with exact name: ${TARGET}"
    fi
    SCOPE_ROOT="$TARGET"
    printf '\n=== ZFS dataset unmount preflight ===\n'
    printf 'Target dataset: %s\n' "$TARGET"
    printf 'Planned command (not executed): zfs unmount %q\n' "$TARGET"
else
    if ! zpool list -H -o name 2>/dev/null | grep -Fxq -- "$TARGET"; then
        fail "No imported ZFS pool found with exact name: ${TARGET}"
    fi
    SCOPE_ROOT="$TARGET"
    printf '\n=== ZFS pool export preflight ===\n'
    printf 'Target pool: %s\n' "$TARGET"
    printf 'Planned command (not executed): zpool export %q\n' "$TARGET"
fi

mapfile -t DATASETS < <(zfs list -H -r -t filesystem -o name "$SCOPE_ROOT" 2>/dev/null)
(("${#DATASETS[@]}" > 0)) || fail "Could not enumerate filesystem datasets under ${SCOPE_ROOT}."

declare -a MOUNT_POINTS=()
declare -a MOUNT_DATASETS=()
declare -A SEEN_MOUNTS=()

# Match mounted ZFS sources to the target dataset and its descendants.
while IFS=$' \t' read -r source mountpoint _; do
    [[ -n "${source:-}" && -n "${mountpoint:-}" ]] || continue
    source="$(decode_findmnt "$source")"
    mountpoint="$(decode_findmnt "$mountpoint")"
    for dataset in "${DATASETS[@]}"; do
        if [[ "$source" == "$dataset" ]]; then
            key="${source}|${mountpoint}"
            if [[ -z "${SEEN_MOUNTS[$key]+x}" ]]; then
                SEEN_MOUNTS["$key"]=1
                MOUNT_DATASETS+=("$dataset")
                MOUNT_POINTS+=("$mountpoint")
            fi
            break
        fi
    done
done < <(findmnt -rn -t zfs -o SOURCE,TARGET 2>/dev/null)

printf '\n--- Dataset inventory ---\n'
printf 'Filesystem datasets in scope: %d\n' "${#DATASETS[@]}"
printf 'Currently mounted ZFS filesystems found: %d\n' "${#MOUNT_POINTS[@]}"
for i in "${!DATASETS[@]}"; do
    printf '  %s\n' "${DATASETS[$i]}"
done

if (("${#MOUNT_POINTS[@]}" == 0)); then
    printf '\nNo mounted ZFS filesystems in the selected scope were found by findmnt.\n'
fi

# Look for swap files whose paths are inside a checked ZFS mount.
mapfile -t SWAP_PATHS < <(swapon --show=NAME --noheadings --raw 2>/dev/null || true)

for i in "${!MOUNT_POINTS[@]}"; do
    dataset="${MOUNT_DATASETS[$i]}"
    mountpoint="${MOUNT_POINTS[$i]}"
    ((MOUNT_CHECKS+=1))

    printf '\n--- Mounted dataset check %d/%d ---\n' "$MOUNT_CHECKS" "${#MOUNT_POINTS[@]}"
    printf 'Dataset:    %s\n' "$dataset"
    printf 'Mountpoint: %s\n' "$mountpoint"

    # lsof reports open files on the mounted filesystem, including deleted files
    # that remain open. Ignore stderr warnings for the summary but show actual rows.
    if command -v lsof >/dev/null 2>&1; then
        lsof_output="$(LC_ALL=C lsof -nP +f -- "$mountpoint" 2>/dev/null || true)"
        lsof_rows="$(printf '%s\n' "$lsof_output" | awk 'NR > 1 && NF { print }')"
        if [[ -n "$lsof_rows" ]]; then
            FINDINGS=1
            printf 'Possible open-file/process users reported by lsof:\n%s\n' "$lsof_output"
        else
            printf 'lsof: no open-file rows reported.\n'
        fi
    fi

    # fuser provides a second view of processes using the filesystem; its
    # non-verbose output makes it possible to distinguish PIDs from mount metadata.
    if command -v fuser >/dev/null 2>&1; then
        fuser_output="$(LC_ALL=C fuser -m -- "$mountpoint" 2>&1 || true)"
        fuser_after_colon="${fuser_output#*:}"
        if [[ "$fuser_after_colon" =~ [0-9]+ ]]; then
            FINDINGS=1
            printf 'Processes reported by fuser (verbose view):\n'
            fuser -vm -- "$mountpoint" 2>&1 || true
        else
            printf 'fuser: no process IDs reported.\n'
        fi
    fi

    # Active swap files are a special case: the kernel may hold them in use
    # without showing an ordinary userspace process in lsof/fuser output.
    for swap_path in "${SWAP_PATHS[@]}"; do
        swap_path="$(decode_findmnt "$swap_path")"
        if [[ "$swap_path" == "$mountpoint" || "$swap_path" == "$mountpoint/"* ]]; then
            FINDINGS=1
            printf 'WARNING: active swap file is inside this mount: %s\n' "$swap_path"
        fi
    done

done

# Check mounts below selected ZFS mountpoints. A non-ZFS child mount is not
# automatically removed by exporting a ZFS pool and can complicate a dataset unmount.
if (("${#MOUNT_POINTS[@]}" > 0)); then
    printf '\n--- Nested mount check ---\n'
    nested_count=0
    while IFS=$' \t' read -r nested_target nested_source nested_type _; do
        [[ -n "${nested_target:-}" && -n "${nested_source:-}" && -n "${nested_type:-}" ]] || continue
        nested_target="$(decode_findmnt "$nested_target")"
        nested_source="$(decode_findmnt "$nested_source")"
        for i in "${!MOUNT_POINTS[@]}"; do
            parent_mount="${MOUNT_POINTS[$i]}"
            [[ "$nested_target" == "$parent_mount/"* ]] || continue
            # Child ZFS mounts are handled as part of a pool export, but a
            # single-dataset unmount can be blocked by a mounted child dataset.
            if [[ "$nested_type" != "zfs" || ( "$MODE" == "dataset" && "$nested_source" != "${MOUNT_DATASETS[$i]}" ) ]]; then
                ((nested_count+=1))
                FINDINGS=1
                printf 'Potential nested-mount issue: %s <- %s (%s, source %s)\n' \
                    "$parent_mount" "$nested_target" "$nested_type" "$nested_source"
            fi
        done
    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null)
    if ((nested_count == 0)); then
        printf 'No relevant nested non-ZFS mounts (or child mounts blocking a single-dataset unmount) detected.\n'
    fi
fi

# A whole-pool export also disconnects ZFS volumes. VMs may have a zvol open
# as a block device, which is not visible in the filesystem mountpoint scan.
if [[ "$MODE" == "pool" ]]; then
    printf '\n--- ZFS volume / block-device check ---\n'
    mapfile -t VOLUMES < <(zfs list -H -r -t volume -o name "$TARGET" 2>/dev/null || true)
    if (("${#VOLUMES[@]}" == 0)); then
        printf 'No ZFS volumes found in this pool.\n'
    else
        for volume in "${VOLUMES[@]}"; do
            device="/dev/zvol/${volume}"
            [[ -e "$device" ]] || continue
            printf 'Volume: %s\nDevice: %s\n' "$volume" "$device"

            if command -v lsof >/dev/null 2>&1; then
                volume_lsof="$(LC_ALL=C lsof -nP -- "$device" 2>/dev/null || true)"
                volume_rows="$(printf '%s\n' "$volume_lsof" | awk 'NR > 1 && NF { print }')"
                if [[ -n "$volume_rows" ]]; then
                    FINDINGS=1
                    printf 'Possible processes holding the zvol open:\n%s\n' "$volume_lsof"
                else
                    printf 'lsof: no open-device rows reported.\n'
                fi
            fi

            if command -v fuser >/dev/null 2>&1; then
                volume_fuser="$(LC_ALL=C fuser "$device" 2>&1 || true)"
                volume_pids="${volume_fuser#*:}"
                if [[ "$volume_pids" =~ [0-9]+ ]]; then
                    FINDINGS=1
                    printf 'fuser reports users of %s:\n' "$device"
                    fuser -v "$device" 2>&1 || true
                fi
            fi
        done
    fi
fi

printf '\n=== Preflight summary ===\n'
if ((FINDINGS)); then
    printf 'RESULT: Potential blockers or conditions requiring review were detected.\n'
    printf 'Do not proceed until you identify the reported processes, swap files, or nested mounts.\n'
else
    printf 'RESULT: No likely blockers were reported by the checks that ran.\n'
    printf 'This is not a guarantee that the operation will succeed.\n'
fi

printf '\nNo unmount or export command was executed.\n'
printf 'This is a point-in-time check; processes or mounts can change immediately afterward.\n'
printf 'Do not use a force option to bypass a busy filesystem without understanding the consequences.\n'

# Return 1 when review is needed, 0 when checks found no likely blockers.
if ((FINDINGS)); then
    exit 1
fi
exit 0
\t'}"
    printf '%s' "$value"
}

while (($#)); do
    case "$1" in
        --dataset|-d)
            [[ -z "$MODE" ]] || fail 'Choose either --dataset or --pool, not both.'
            (($# >= 2)) || fail "${1} requires a target."
            MODE="dataset"
            TARGET="$2"
            shift 2
            ;;
        --pool|-p)
            [[ -z "$MODE" ]] || fail 'Choose either --dataset or --pool, not both.'
            (($# >= 2)) || fail "${1} requires a target."
            MODE="pool"
            TARGET="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1 (use --help for usage)."
            ;;
    esac
done

[[ -n "$MODE" && -n "$TARGET" ]] || { usage >&2; exit 2; }

if [[ "$EUID" -ne 0 ]]; then
    fail "Run as root so process and open-file checks are meaningful: sudo ${SCRIPT_NAME} --${MODE} '${TARGET}'"
fi

for cmd in zfs zpool findmnt awk grep swapon; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
done

if ! command -v lsof >/dev/null 2>&1 && ! command -v fuser >/dev/null 2>&1; then
    fail 'Neither lsof nor fuser is installed. On Debian, install one or both with: apt install lsof psmisc'
fi

if [[ "$MODE" == "dataset" ]]; then
    if ! zfs list -H -t filesystem -o name "$TARGET" 2>/dev/null | grep -Fxq -- "$TARGET"; then
        fail "No ZFS filesystem dataset found with exact name: ${TARGET}"
    fi
    SCOPE_ROOT="$TARGET"
    printf '\n=== ZFS dataset unmount preflight ===\n'
    printf 'Target dataset: %s\n' "$TARGET"
    printf 'Planned command (not executed): zfs unmount %q\n' "$TARGET"
else
    if ! zpool list -H -o name 2>/dev/null | grep -Fxq -- "$TARGET"; then
        fail "No imported ZFS pool found with exact name: ${TARGET}"
    fi
    SCOPE_ROOT="$TARGET"
    printf '\n=== ZFS pool export preflight ===\n'
    printf 'Target pool: %s\n' "$TARGET"
    printf 'Planned command (not executed): zpool export %q\n' "$TARGET"
fi

mapfile -t DATASETS < <(zfs list -H -r -t filesystem -o name "$SCOPE_ROOT" 2>/dev/null)
(("${#DATASETS[@]}" > 0)) || fail "Could not enumerate filesystem datasets under ${SCOPE_ROOT}."

declare -a MOUNT_POINTS=()
declare -a MOUNT_DATASETS=()
declare -A SEEN_MOUNTS=()

# Match mounted ZFS sources to the target dataset and its descendants.
while IFS=$' \t' read -r source mountpoint _; do
    [[ -n "${source:-}" && -n "${mountpoint:-}" ]] || continue
    source="$(decode_findmnt "$source")"
    mountpoint="$(decode_findmnt "$mountpoint")"
    for dataset in "${DATASETS[@]}"; do
        if [[ "$source" == "$dataset" ]]; then
            key="${source}|${mountpoint}"
            if [[ -z "${SEEN_MOUNTS[$key]+x}" ]]; then
                SEEN_MOUNTS["$key"]=1
                MOUNT_DATASETS+=("$dataset")
                MOUNT_POINTS+=("$mountpoint")
            fi
            break
        fi
    done
done < <(findmnt -rn -t zfs -o SOURCE,TARGET 2>/dev/null)

printf '\n--- Dataset inventory ---\n'
printf 'Filesystem datasets in scope: %d\n' "${#DATASETS[@]}"
printf 'Currently mounted ZFS filesystems found: %d\n' "${#MOUNT_POINTS[@]}"
for i in "${!DATASETS[@]}"; do
    printf '  %s\n' "${DATASETS[$i]}"
done

if (("${#MOUNT_POINTS[@]}" == 0)); then
    printf '\nNo mounted ZFS filesystems in the selected scope were found by findmnt.\n'
fi

# Look for swap files whose paths are inside a checked ZFS mount.
mapfile -t SWAP_PATHS < <(swapon --show=NAME --noheadings --raw 2>/dev/null || true)

for i in "${!MOUNT_POINTS[@]}"; do
    dataset="${MOUNT_DATASETS[$i]}"
    mountpoint="${MOUNT_POINTS[$i]}"
    ((MOUNT_CHECKS+=1))

    printf '\n--- Mounted dataset check %d/%d ---\n' "$MOUNT_CHECKS" "${#MOUNT_POINTS[@]}"
    printf 'Dataset:    %s\n' "$dataset"
    printf 'Mountpoint: %s\n' "$mountpoint"

    # lsof reports open files on the mounted filesystem, including deleted files
    # that remain open. Ignore stderr warnings for the summary but show actual rows.
    if command -v lsof >/dev/null 2>&1; then
        lsof_output="$(LC_ALL=C lsof -nP +f -- "$mountpoint" 2>/dev/null || true)"
        lsof_rows="$(printf '%s\n' "$lsof_output" | awk 'NR > 1 && NF { print }')"
        if [[ -n "$lsof_rows" ]]; then
            FINDINGS=1
            printf 'Possible open-file/process users reported by lsof:\n%s\n' "$lsof_output"
        else
            printf 'lsof: no open-file rows reported.\n'
        fi
    fi

    # fuser provides a second view of processes using the filesystem; its
    # non-verbose output makes it possible to distinguish PIDs from mount metadata.
    if command -v fuser >/dev/null 2>&1; then
        fuser_output="$(LC_ALL=C fuser -m -- "$mountpoint" 2>&1 || true)"
        fuser_after_colon="${fuser_output#*:}"
        if [[ "$fuser_after_colon" =~ [0-9]+ ]]; then
            FINDINGS=1
            printf 'Processes reported by fuser (verbose view):\n'
            fuser -vm -- "$mountpoint" 2>&1 || true
        else
            printf 'fuser: no process IDs reported.\n'
        fi
    fi

    # Active swap files are a special case: the kernel may hold them in use
    # without showing an ordinary userspace process in lsof/fuser output.
    for swap_path in "${SWAP_PATHS[@]}"; do
        swap_path="$(decode_findmnt "$swap_path")"
        if [[ "$swap_path" == "$mountpoint" || "$swap_path" == "$mountpoint/"* ]]; then
            FINDINGS=1
            printf 'WARNING: active swap file is inside this mount: %s\n' "$swap_path"
        fi
    done

done

# Check mounts below selected ZFS mountpoints. A non-ZFS child mount is not
# automatically removed by exporting a ZFS pool and can complicate a dataset unmount.
if (("${#MOUNT_POINTS[@]}" > 0)); then
    printf '\n--- Nested mount check ---\n'
    nested_count=0
    while IFS=$' \t' read -r nested_target nested_source nested_type _; do
        [[ -n "${nested_target:-}" && -n "${nested_source:-}" && -n "${nested_type:-}" ]] || continue
        nested_target="$(decode_findmnt "$nested_target")"
        nested_source="$(decode_findmnt "$nested_source")"
        for i in "${!MOUNT_POINTS[@]}"; do
            parent_mount="${MOUNT_POINTS[$i]}"
            [[ "$nested_target" == "$parent_mount/"* ]] || continue
            # Child ZFS mounts are handled as part of a pool export, but a
            # single-dataset unmount can be blocked by a mounted child dataset.
            if [[ "$nested_type" != "zfs" || ( "$MODE" == "dataset" && "$nested_source" != "${MOUNT_DATASETS[$i]}" ) ]]; then
                ((nested_count+=1))
                FINDINGS=1
                printf 'Potential nested-mount issue: %s <- %s (%s, source %s)\n' \
                    "$parent_mount" "$nested_target" "$nested_type" "$nested_source"
            fi
        done
    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null)
    if ((nested_count == 0)); then
        printf 'No relevant nested non-ZFS mounts (or child mounts blocking a single-dataset unmount) detected.\n'
    fi
fi

# A whole-pool export also disconnects ZFS volumes. VMs may have a zvol open
# as a block device, which is not visible in the filesystem mountpoint scan.
if [[ "$MODE" == "pool" ]]; then
    printf '\n--- ZFS volume / block-device check ---\n'
    mapfile -t VOLUMES < <(zfs list -H -r -t volume -o name "$TARGET" 2>/dev/null || true)
    if (("${#VOLUMES[@]}" == 0)); then
        printf 'No ZFS volumes found in this pool.\n'
    else
        for volume in "${VOLUMES[@]}"; do
            device="/dev/zvol/${volume}"
            [[ -e "$device" ]] || continue
            printf 'Volume: %s\nDevice: %s\n' "$volume" "$device"

            if command -v lsof >/dev/null 2>&1; then
                volume_lsof="$(LC_ALL=C lsof -nP -- "$device" 2>/dev/null || true)"
                volume_rows="$(printf '%s\n' "$volume_lsof" | awk 'NR > 1 && NF { print }')"
                if [[ -n "$volume_rows" ]]; then
                    FINDINGS=1
                    printf 'Possible processes holding the zvol open:\n%s\n' "$volume_lsof"
                else
                    printf 'lsof: no open-device rows reported.\n'
                fi
            fi

            if command -v fuser >/dev/null 2>&1; then
                volume_fuser="$(LC_ALL=C fuser "$device" 2>&1 || true)"
                volume_pids="${volume_fuser#*:}"
                if [[ "$volume_pids" =~ [0-9]+ ]]; then
                    FINDINGS=1
                    printf 'fuser reports users of %s:\n' "$device"
                    fuser -v "$device" 2>&1 || true
                fi
            fi
        done
    fi
fi

printf '\n=== Preflight summary ===\n'
if ((FINDINGS)); then
    printf 'RESULT: Potential blockers or conditions requiring review were detected.\n'
    printf 'Do not proceed until you identify the reported processes, swap files, or nested mounts.\n'
else
    printf 'RESULT: No likely blockers were reported by the checks that ran.\n'
    printf 'This is not a guarantee that the operation will succeed.\n'
fi

printf '\nNo unmount or export command was executed.\n'
printf 'This is a point-in-time check; processes or mounts can change immediately afterward.\n'
printf 'Do not use a force option to bypass a busy filesystem without understanding the consequences.\n'

# Return 1 when review is needed, 0 when checks found no likely blockers.
if ((FINDINGS)); then
    exit 1
fi
exit 0
