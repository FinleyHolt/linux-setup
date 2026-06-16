#!/usr/bin/env bash
# NPS VPN MTU diagnostic + fix validation.
#
# SAFE: the only privileged action is `ip link set tun0 mtu <N>` (changes
# the tunnel interface MTU only). Everything else is non-interactive SSH
# probes. On exit, tun0 is left at the LARGEST tested MTU whose SSH key
# exchange completes -- so you finish this script still connected. If none
# work, the original MTU is restored.
#
# Run (you'll be prompted once for your sudo password):
#   bash /tmp/vpn_mtu_test.sh
# Output is mirrored to /tmp/vpn_mtu_test.log
set -u

LOG=/tmp/vpn_mtu_test.log
exec > >(tee "$LOG") 2>&1

ts() { date '+%H:%M:%S'; }

# Probe a host with a REAL ssh (BatchMode = key-only, no password hang).
# Returns the last output line: "OK <hostname>" on success, or the ssh
# error (timeout / kex stall shows as a killed/empty line).
ssh_probe() {
    timeout 16 ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none \
        -o StrictHostKeyChecking=accept-new "$1" 'echo OK $(hostname)' 2>&1 | tail -1
}

echo "================ NPS VPN MTU test @ $(ts) ================"

if ! ip link show tun0 >/dev/null 2>&1; then
    echo "tun0 is DOWN. Bring the VPN up first ('vpn'), then re-run this."
    exit 1
fi

ORIG=$(cat /sys/class/net/tun0/mtu)
echo "tun0 current MTU : $ORIG"
echo "tun0 address     : $(ip -br addr show tun0 | awk '{print $3}')"
echo "default route    : $(ip route show default | head -1)"
echo

echo "---- BASELINE ssh @ MTU $ORIG ----"
echo "  cobra   : $(ssh_probe cobra)"
echo "  hamming : $(ssh_probe hamming)"
echo
echo "---- where ssh stalls @ MTU $ORIG (verbose) ----"
timeout 12 ssh -vv -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=8 cobra true 2>&1 \
    | grep -E 'Connection established|Remote protocol|KEXINIT|KEX_ECDH_REPLY|Permission denied|timed out' \
    | tail -5
echo "  (stalling at 'expecting SSH2_MSG_KEX_ECDH_REPLY' == MTU black hole)"

WORK=""
for MTU in 1380 1280 1240 1200 1100; do
    echo
    echo "---- set tun0 MTU=$MTU @ $(ts) ----"
    if ! sudo ip link set tun0 mtu "$MTU"; then
        echo "  could not set MTU $MTU (sudo failed?) -- skipping"
        continue
    fi
    c=$(ssh_probe cobra)
    h=$(ssh_probe hamming)
    echo "  cobra   : $c"
    echo "  hamming : $h"
    if [[ "$c" == OK* ]]; then
        WORK=$MTU
        echo "  => SSH KEY EXCHANGE COMPLETES at MTU $MTU (largest working)"
        break
    fi
done

echo
echo "======================= RESULT ========================="
if [[ -n "$WORK" ]]; then
    sudo ip link set tun0 mtu "$WORK"
    echo "WORKING MTU      : $WORK"
    echo "tun0 left at     : $WORK  (you are connected)"
    # Recommend a value with a little headroom below the largest working one.
    if   (( WORK > 1280 )); then REC=1280
    else REC=$WORK; fi
    echo "RECOMMEND        : NET_TUN_MTU=$REC for the persistent fix"
else
    sudo ip link set tun0 mtu "$ORIG"
    echo "NO tested MTU fixed SSH. tun0 restored to $ORIG."
    echo "This points past MTU (dead peer / stale GP session). Try:"
    echo "    sudo gpclient disconnect && vpn   # full reconnect"
fi
echo "Log written to   : $LOG"
echo "========================================================"
