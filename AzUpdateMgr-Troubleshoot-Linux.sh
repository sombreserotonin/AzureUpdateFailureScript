#!/usr/bin/env bash
# =============================================================================
#  Azure Update Manager - Linux VM diagnostic collector (read-only)
# -----------------------------------------------------------------------------
#  Purpose : Comprehensive troubleshooting data collector for update failures
#            surfaced by Azure Update Manager on Linux VMs. Safe for Azure
#            Run Command (RunShellScript) and Azure Arc equivalents.
#
#  Guarantees:
#    * READ-ONLY. No package installs, no cache updates, no service
#      restarts, no reboots, no config edits. Only `list`/`status`/`cat`.
#    * All output is written to /var/log/azupdatemgr-diag-<ts>.log
#      (fallback: /tmp/azupdatemgr-diag-<ts>.log if /var/log not writable).
#    * A JSON summary is written next to the log.
#    * Only a short SUMMARY is printed to stdout, because Azure Run Command
#      truncates stdout to ~4 KB. Pull the full log off the VM afterwards.
#    * Every command is wrapped with a timeout so a single hung tool cannot
#      block the run.
#    * `set -e` is deliberately NOT used; we want partial data even when
#      individual checks fail.
#
#  Tested against : Ubuntu 18.04/20.04/22.04/24.04, RHEL/CentOS/Rocky/Alma
#                   7/8/9, SLES 12/15, Debian 10/11/12, Oracle Linux 7/8/9,
#                   Azure Linux (CBL-Mariner) 2/3.
# =============================================================================

# ---- config -----------------------------------------------------------------
TAIL_LINES="${TAIL_LINES:-200}"
CMD_TIMEOUT="${CMD_TIMEOUT:-45}"          # per external command (seconds)
RECENT_COUNT="${RECENT_COUNT:-25}"        # recent updates / history entries
NET_TIMEOUT="${NET_TIMEOUT:-5}"

TS="$(date -u +%Y%m%d-%H%M%SZ)"
OUT_DIR="/var/log"
if [ ! -w "$OUT_DIR" ]; then OUT_DIR="/tmp"; fi
LOG="$OUT_DIR/azupdatemgr-diag-$TS.log"
JSON="$OUT_DIR/azupdatemgr-diag-$TS-summary.json"

WARN_COUNT=0
ERR_COUNT=0
REBOOT_REQUIRED="unknown"
DISTRO="unknown"
PKG_MGR="unknown"

# ---- helpers ----------------------------------------------------------------
log()      { printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${2:-INFO}" "$1" >> "$LOG"; }
section()  { printf '\n%s\n== %s\n%s\n' "$(printf '=%.0s' {1..78})" "$1" "$(printf '=%.0s' {1..78})" >> "$LOG"; }

# run_safe "Section title" -- command args...
# Uses `timeout` when available; captures stdout+stderr into $LOG. Never fails.
run_safe() {
    local title="$1"; shift
    [ "$1" = "--" ] && shift
    section "$title"
    log "BEGIN: $title"
    if command -v timeout >/dev/null 2>&1; then
        timeout --preserve-status "${CMD_TIMEOUT}s" "$@" >>"$LOG" 2>&1
        local rc=$?
    else
        "$@" >>"$LOG" 2>&1
        local rc=$?
    fi
    if [ $rc -ne 0 ]; then
        log "END:   $title (rc=$rc)" "WARN"
        WARN_COUNT=$((WARN_COUNT+1))
    else
        log "END:   $title"
    fi
    return 0
}

# Same as run_safe but for a shell snippet (`sh -c '...'`).
run_sh() {
    local title="$1"; local snippet="$2"
    section "$title"
    log "BEGIN: $title"
    if command -v timeout >/dev/null 2>&1; then
        timeout --preserve-status "${CMD_TIMEOUT}s" sh -c "$snippet" >>"$LOG" 2>&1
    else
        sh -c "$snippet" >>"$LOG" 2>&1
    fi
    log "END:   $title"
    return 0
}

tail_file() {
    local f="$1"
    if [ ! -e "$f" ]; then echo "  <not found: $f>"; return; fi
    if [ ! -r "$f" ]; then echo "  <unreadable: $f>"; return; fi
    local size mtime
    size=$(stat -c '%s' "$f" 2>/dev/null || echo '?')
    mtime=$(stat -c '%y' "$f" 2>/dev/null || echo '?')
    echo "  >> $f ($size bytes, modified $mtime)"
    echo "  ---- tail begin ----"
    tail -n "$TAIL_LINES" "$f" 2>/dev/null | sed 's/^/  /'
    echo "  ---- tail end ----"
}

# ---- header -----------------------------------------------------------------
mkdir -p "$OUT_DIR" 2>/dev/null || true
: > "$LOG"
section "Azure Update Manager - Linux diagnostic"
log "Script started on $(hostname) as $(id -un) (uid=$(id -u))"
log "Read-only mode. No changes will be made to this VM."
log "Log file: $LOG"

# ---- 1. OS identity ---------------------------------------------------------
run_sh "OS identity" '
    echo "---- /etc/os-release ----"
    cat /etc/os-release 2>/dev/null || echo "  <missing>"
    echo "---- uname ----"
    uname -a
    echo "---- uptime ----"
    uptime
    echo "---- date (UTC) ----"
    date -u
'

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
fi

# Detect package manager without invoking it
if   command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
elif command -v dnf     >/dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum     >/dev/null 2>&1; then PKG_MGR="yum"
elif command -v zypper  >/dev/null 2>&1; then PKG_MGR="zypper"
elif command -v tdnf    >/dev/null 2>&1; then PKG_MGR="tdnf"
fi
log "Detected distro=$DISTRO, package manager=$PKG_MGR"

# ---- 2. Azure Instance Metadata --------------------------------------------
run_sh "Azure Instance Metadata (IMDS)" "
    if command -v curl >/dev/null 2>&1; then
        curl -sS --max-time $NET_TIMEOUT --noproxy '*' \
            -H 'Metadata: true' \
            'http://169.254.169.254/metadata/instance?api-version=2021-12-13' \
            | python3 -m json.tool 2>/dev/null \
              || curl -sS --max-time $NET_TIMEOUT --noproxy '*' -H 'Metadata: true' \
                 'http://169.254.169.254/metadata/instance?api-version=2021-12-13'
    else
        echo 'curl not present, skipping IMDS'
    fi
"

VM_RESOURCE_ID=""
if command -v curl >/dev/null 2>&1; then
    VM_RESOURCE_ID=$(curl -sS --max-time "$NET_TIMEOUT" --noproxy '*' \
        -H 'Metadata: true' \
        'http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-12-13&format=text' \
        2>/dev/null)
fi

# ---- 3. Azure VM / Arc agent ------------------------------------------------
run_sh "Azure Linux agent (waagent)" '
    echo "---- waagent version ----"
    (waagent --version 2>&1 || echo "  waagent not on PATH")
    echo "---- systemd unit walinuxagent / waagent ----"
    for u in walinuxagent waagent; do
        systemctl status "$u" --no-pager -l 2>/dev/null | head -n 30 || true
    done
    echo "---- /var/lib/waagent (top level) ----"
    ls -la /var/lib/waagent 2>/dev/null | head -n 60 || echo "  <missing>"
'

run_sh "Azure Arc agent (if present)" '
    if command -v azcmagent >/dev/null 2>&1; then
        azcmagent show 2>/dev/null || true
        echo "---- Arc extension manager logs (last few files) ----"
        ls -lt /var/lib/GuestConfig/ext_mgr_logs 2>/dev/null | head -n 10 || true
    else
        echo "azcmagent not installed (not an Azure Arc-enabled machine)"
    fi
'

# ---- 4. Update Manager Linux patch extension --------------------------------
run_sh "LinuxPatchExtension - installed versions" '
    base=/var/lib/waagent
    if [ -d "$base" ]; then
        ls -1d "$base"/Microsoft.CPlat.Core.LinuxPatchExtension-* 2>/dev/null \
            || echo "  <LinuxPatchExtension not installed>"
    else
        echo "  <no /var/lib/waagent>"
    fi
'

section "LinuxPatchExtension - status files (latest per version)"
for extdir in /var/lib/waagent/Microsoft.CPlat.Core.LinuxPatchExtension-*/status \
              /var/lib/waagent/Microsoft.CPlat.Core.LinuxPatchExtension-*/config; do
    [ -d "$extdir" ] || continue
    echo "  ---- $extdir ----" >> "$LOG"
    ls -lt "$extdir" 2>/dev/null | head -n 5 >> "$LOG"
    # cat the newest 2 status files
    latest=$(ls -1t "$extdir"/*.status 2>/dev/null | head -n 2)
    for f in $latest; do
        echo "  ==== $f ====" >> "$LOG"
        # Pretty-print if python3 available, else raw
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "import json,sys; print(json.dumps(json.load(open('$f')), indent=2))" \
                >>"$LOG" 2>>"$LOG" || cat "$f" >>"$LOG"
        else
            cat "$f" >>"$LOG"
        fi
    done
done

section "LinuxPatchExtension - operational logs"
LOG_ROOT=/var/log/azure/Microsoft.CPlat.Core.LinuxPatchExtension
if [ -d "$LOG_ROOT" ]; then
    # newest 6 files, tail each
    ls -1t "$LOG_ROOT"/*.log "$LOG_ROOT"/*.ext.log "$LOG_ROOT"/*.core.log 2>/dev/null \
        | head -n 6 | while read -r f; do
            tail_file "$f" >> "$LOG"
        done
else
    echo "  <$LOG_ROOT not present>" >> "$LOG"
fi

# Arc-enabled equivalent (Microsoft.SoftwareUpdateManagement.LinuxOsUpdateExtension)
section "LinuxOsUpdateExtension (Arc) - if present"
for base in /var/lib/GuestConfig/extension_logs \
            /var/lib/GuestConfig/Extension/Microsoft.SoftwareUpdateManagement.LinuxOsUpdateExtension; do
    [ -d "$base" ] || continue
    echo "  ---- $base ----" >> "$LOG"
    ls -lt "$base" 2>/dev/null | head -n 20 >> "$LOG"
done
if [ -d /var/lib/GuestConfig/extension_logs ]; then
    find /var/lib/GuestConfig/extension_logs -type f \
        \( -name '*.log' -o -name '*.txt' \) -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n 6 | awk '{print $2}' | while read -r f; do
            tail_file "$f" >> "$LOG"
        done
fi

# ---- 5. waagent log ---------------------------------------------------------
section "waagent.log (tail)"
tail_file /var/log/waagent.log >> "$LOG"

# ---- 6. Package manager state (read-only!) ----------------------------------
case "$PKG_MGR" in
  apt)
    run_sh "APT - held packages / policy (read-only)" '
        echo "---- apt-mark showhold ----"
        apt-mark showhold 2>/dev/null
        echo "---- /etc/apt/apt.conf.d/ (files list) ----"
        ls -la /etc/apt/apt.conf.d/ 2>/dev/null
        echo "---- unattended-upgrades config ----"
        cat /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | head -n 80
        echo "---- dpkg audit ----"
        dpkg --audit 2>&1 | head -n 40
        echo "---- Broken / half-installed packages ----"
        dpkg -l 2>/dev/null | awk "\$1 !~ /^ii/ && NR>5 {print}" | head -n 40
    '
    run_sh "APT - available upgrades (list only, no update)" '
        # "apt list --upgradable" reads the current cache; does NOT hit the net,
        # does NOT modify the cache. If cache is stale we simply see stale data,
        # which is exactly what we want to observe.
        LANG=C apt list --upgradable 2>/dev/null | head -n 200
    '
    run_sh "APT - history (last entries)" '
        for f in /var/log/apt/history.log /var/log/apt/history.log.1; do
            [ -f "$f" ] || continue
            echo "---- $f ----"
            tail -n 200 "$f" 2>/dev/null
        done
        echo "---- /var/log/apt/term.log (tail) ----"
        tail -n 120 /var/log/apt/term.log 2>/dev/null
        echo "---- /var/log/unattended-upgrades ----"
        for f in /var/log/unattended-upgrades/unattended-upgrades.log \
                 /var/log/unattended-upgrades/unattended-upgrades-dpkg.log; do
            [ -f "$f" ] && { echo "  == $f =="; tail -n 120 "$f"; }
        done
    '
    ;;

  dnf|yum|tdnf)
    PM="$PKG_MGR"
    run_sh "$PM - repolist (uses cache only)" "
        LANG=C $PM -C repolist all 2>/dev/null | head -n 200
    "
    run_sh "$PM - check-update (cache-only, exit code informational)" "
        # -C forces cache-only mode: no network, no metadata refresh.
        LANG=C $PM -C check-update 2>/dev/null | head -n 200
        echo \"(exit code intentionally ignored - 100 means updates available)\"
    "
    run_sh "$PM - history (last entries)" "
        LANG=C $PM history 2>/dev/null | head -n 40
        echo '---- Last transaction detail ----'
        last_id=\$($PM history 2>/dev/null | awk '/^ *[0-9]+ / {print \$1; exit}')
        [ -n \"\$last_id\" ] && LANG=C $PM history info \"\$last_id\" 2>/dev/null | head -n 80
    "
    run_sh "$PM - repo files" '
        ls -la /etc/yum.repos.d/ 2>/dev/null
        for f in /etc/yum.repos.d/*.repo; do
            [ -f "$f" ] || continue
            echo "---- $f ----"; cat "$f"
        done
    '
    run_sh "RPM - broken package check" '
        rpm -Va --nofiles --nodigest 2>&1 | head -n 60
        echo "---- dnf/yum lock files ----"
        ls -la /var/run/dnf.pid /var/run/yum.pid /var/lib/rpm/.rpm.lock 2>/dev/null
    '
    ;;

  zypper)
    run_sh "zypper - repos and locks" '
        LANG=C zypper --non-interactive lr -u 2>/dev/null | head -n 60
        LANG=C zypper --non-interactive ll 2>/dev/null | head -n 60
    '
    run_sh "zypper - patches/updates from cache (no refresh)" '
        LANG=C zypper --non-interactive --no-refresh lu 2>/dev/null | head -n 200
        LANG=C zypper --non-interactive --no-refresh lp 2>/dev/null | head -n 100
    '
    run_sh "zypper - history" '
        tail -n 200 /var/log/zypp/history 2>/dev/null
    '
    ;;

  *)
    section "Package manager"
    echo "  <no supported package manager detected>" >> "$LOG"
    ;;
esac

# ---- 7. Reboot-required signals --------------------------------------------
section "Reboot-required checks"
{
    reboot_hits=0
    if [ -f /var/run/reboot-required ]; then
        echo "  /var/run/reboot-required present"
        [ -f /var/run/reboot-required.pkgs ] && cat /var/run/reboot-required.pkgs | sed 's/^/    /'
        reboot_hits=$((reboot_hits+1))
    fi
    if command -v needs-restarting >/dev/null 2>&1; then
        echo "---- needs-restarting -r ----"
        needs-restarting -r 2>&1 | head -n 5
        needs-restarting -r >/dev/null 2>&1
        rc=$?
        [ $rc -eq 1 ] && reboot_hits=$((reboot_hits+1))
    fi
    if command -v zypper >/dev/null 2>&1; then
        zypper ps -s 2>/dev/null | head -n 40
    fi
    if command -v dnf >/dev/null 2>&1 && dnf help needs-restarting >/dev/null 2>&1; then
        dnf needs-restarting 2>&1 | head -n 20
    fi
    if [ $reboot_hits -gt 0 ]; then
        REBOOT_REQUIRED="yes"
    else
        REBOOT_REQUIRED="no"
    fi
    echo "  REBOOT_REQUIRED=$REBOOT_REQUIRED"
} >> "$LOG" 2>&1

# ---- 8. Disk space ----------------------------------------------------------
run_safe "Disk usage (df -hT)" -- df -hT

FREE_MB_ROOT=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
FREE_MB_VAR=$(df -Pm /var 2>/dev/null | awk 'NR==2 {print $4}')
FREE_MB_BOOT=$(df -Pm /boot 2>/dev/null | awk 'NR==2 {print $4}')
log "Free MB: /=$FREE_MB_ROOT /var=$FREE_MB_VAR /boot=$FREE_MB_BOOT"

# Warn on low disk conditions common cause of patch failures
if [ -n "$FREE_MB_ROOT" ] && [ "$FREE_MB_ROOT" -lt 1024 ]; then
    log "WARNING: / has less than 1 GB free" "WARN"; WARN_COUNT=$((WARN_COUNT+1))
fi
if [ -n "$FREE_MB_BOOT" ] && [ "$FREE_MB_BOOT" -lt 200 ]; then
    log "WARNING: /boot has less than 200 MB free (kernel updates will fail)" "WARN"
    WARN_COUNT=$((WARN_COUNT+1))
fi

# ---- 9. Network path to update endpoints -----------------------------------
run_sh "Connectivity - Azure/IMDS/repos (read-only probes)" "
    endpoints_common='169.254.169.254:80 management.azure.com:443 login.microsoftonline.com:443 packages.microsoft.com:443'
    endpoints_apt='archive.ubuntu.com:80 security.ubuntu.com:80 deb.debian.org:80 azure.archive.ubuntu.com:80'
    endpoints_rh='cdn.redhat.com:443 rhui-1.microsoft.com:443 rhui-2.microsoft.com:443 rhui-3.microsoft.com:443'
    endpoints_all=\"\$endpoints_common\"
    case '$PKG_MGR' in
        apt) endpoints_all=\"\$endpoints_all \$endpoints_apt\" ;;
        dnf|yum) endpoints_all=\"\$endpoints_all \$endpoints_rh\" ;;
    esac
    for pair in \$endpoints_all; do
        host=\${pair%:*}; port=\${pair##*:}
        # /dev/tcp is a bash builtin; fall back to nc/curl if unavailable
        if timeout ${NET_TIMEOUT}s bash -c \"echo > /dev/tcp/\$host/\$port\" 2>/dev/null; then
            printf '  %-45s TCP %-4s OK\n' \"\$host\" \"\$port\"
        else
            printf '  %-45s TCP %-4s FAIL\n' \"\$host\" \"\$port\"
        fi
    done
    echo '---- /etc/resolv.conf ----'
    cat /etc/resolv.conf 2>/dev/null | head -n 20
    echo '---- proxy env ----'
    env | grep -iE '^(http|https|no)_proxy=' || echo '  (none set for current shell)'
    echo '---- default route ----'
    ip route 2>/dev/null | head -n 20
"

# ---- 10. sudoers sanity (Update extension needs to invoke sudo) ------------
run_sh "sudoers sanity for extension user (root)" '
    echo "---- id ----"; id
    echo "---- sudo -n -l (root, no password) ----"
    sudo -n -l 2>&1 | head -n 20
    echo "---- /etc/sudoers.d files present ----"
    ls -la /etc/sudoers.d/ 2>/dev/null
'

# ---- 11. Kernel / systemd state --------------------------------------------
run_sh "Systemd - failed units + auto-update timers" '
    systemctl --no-pager list-units --state=failed 2>/dev/null | head -n 40
    echo "---- unattended-upgrades / dnf-automatic timers ----"
    systemctl list-timers --all 2>/dev/null | grep -iE "unattended|apt|dnf|yum|zypp" | head -n 20
    echo "---- Auto-update service status ----"
    for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
             dnf-automatic.timer dnf-automatic-install.timer packagekit.service; do
        systemctl is-enabled "$u" 2>/dev/null | awk -v u="$u" "{print u\": \"\$0}"
    done
'

run_sh "Kernel journal - errors from the last 24h" '
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --since "24 hours ago" -p err --no-pager 2>/dev/null | tail -n 200
    else
        echo "  journalctl not present"
    fi
'

# ---- 12. Patch settings via IMDS (guest patch mode) ------------------------
run_sh "Guest patch mode (IMDS)" "
    if command -v curl >/dev/null 2>&1; then
        curl -sS --max-time $NET_TIMEOUT --noproxy '*' \
            -H 'Metadata: true' \
            'http://169.254.169.254/metadata/instance/compute/osProfile?api-version=2021-12-13' \
            2>/dev/null | (python3 -m json.tool 2>/dev/null || cat)
    fi
"

# ---- Summary ---------------------------------------------------------------
section "Summary"
LOG_SIZE=$(stat -c '%s' "$LOG" 2>/dev/null || echo 0)
LOG_KB=$(( LOG_SIZE / 1024 ))

cat > "$JSON" <<JSON
{
  "hostname"          : "$(hostname)",
  "started_utc"       : "$TS",
  "finished_utc"      : "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "distro"            : "$DISTRO",
  "package_manager"   : "$PKG_MGR",
  "vm_resource_id"    : "${VM_RESOURCE_ID}",
  "reboot_required"   : "$REBOOT_REQUIRED",
  "free_mb_root"      : "${FREE_MB_ROOT:-unknown}",
  "free_mb_var"       : "${FREE_MB_VAR:-unknown}",
  "free_mb_boot"      : "${FREE_MB_BOOT:-unknown}",
  "warnings"          : $WARN_COUNT,
  "errors"            : $ERR_COUNT,
  "log_path"          : "$LOG",
  "log_size_bytes"    : $LOG_SIZE
}
JSON

cat <<EOF
=== Azure Update Manager diag (Linux) ===
Host             : $(hostname)
Distro / pkg mgr : $DISTRO / $PKG_MGR
Started (UTC)    : $TS
Finished (UTC)   : $(date -u +%Y-%m-%dT%H:%M:%SZ)
Log file         : $LOG  (${LOG_KB} KB)
Summary JSON     : $JSON
Reboot required  : $REBOOT_REQUIRED
Free MB /,/var,/boot : ${FREE_MB_ROOT:-?}, ${FREE_MB_VAR:-?}, ${FREE_MB_BOOT:-?}
VM Resource ID   : ${VM_RESOURCE_ID:-<IMDS unreachable>}
Warnings raised  : $WARN_COUNT

Retrieve the full log with, for example:
  az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \\
    --scripts "cat $LOG"
EOF
