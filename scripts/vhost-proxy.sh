#!/usr/bin/env bash
# Proxies a local unix socket to the vhost's libvirtd via virt-ssh-helper.
#
# Needed because the dmacvicar/libvirt OpenTofu provider is a statically
# linked Go binary with its own (buggy) SSH transport implementation that
# fails with "Cannot find start time for pid ..." when connecting directly
# via qemu+ssh://. Real virsh and virt-ssh-helper don't have this problem, so
# this script reproduces the same connection virsh makes, exposed as a local
# unix socket that the provider can reach with a plain qemu+unix:// URI (see
# providers.tf).
#
# Must be running before any `tofu` command that touches the vhost provider.
set -euo pipefail

SOCKET_PATH="${1:-/tmp/vhost-libvirt.sock}"
VHOST_USER="${VHOST_SSH_USER:-deploy}"
VHOST_HOST="${VHOST_HOST:-192.168.70.1}"
VHOST_KEYFILE="${VHOST_SSH_KEYFILE:-$HOME/.ssh/fedora_deploy_ed25519}"

rm -f "$SOCKET_PATH"
exec ncat -lU "$SOCKET_PATH" -k --sh-exec \
  "ssh -i ${VHOST_KEYFILE} -o BatchMode=yes ${VHOST_USER}@${VHOST_HOST} virt-ssh-helper qemu:///system"
