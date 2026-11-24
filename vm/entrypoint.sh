#!/bin/bash
# Host side of the VM runner. Runs as non-root with no capabilities; needs only
# /dev/kvm and a writable volume at /vm.
#
# The JIT configuration arrives once over stdin (kubectl attach, stdinOnce) and
# is handed to the guest through a FIFO-backed virtio-serial port. It never
# touches a file, argv or the environment of this container.
#
# Exit status: the guest reports through isa-debug-exit (QEMU exits with
# (value << 1) | 1). 1 = guest finished the runner cleanly. Anything else,
# including a plain poweroff/panic (QEMU exit 0), is a failure.
set -euo pipefail

IFS= read -r jit_config
[[ -n "$jit_config" ]] || { echo "vm-runner: empty registration" >&2; exit 1; }
exec </dev/null

cpus=5      # size the pod at 6 CPUs: one core for QEMU's own threads
memory=16G  # size the pod at ~20Gi
scratch=40G # sparse; /var/lib/docker and the job workspace inside the guest

cd /vm
qemu-img create -q -f qcow2 -F qcow2 -b /opt/vm/root.qcow2 root.qcow2
qemu-img create -q -f raw scratch.img "$scratch"
mkfifo -m 600 jit.in jit.out
# Blocks until QEMU opens the FIFO; the value lives only in this subshell.
( printf '%s\n' "$jit_config" >jit.in ) &
writer=$!
unset jit_config

set +e
qemu-system-x86_64 \
  -enable-kvm -cpu host -machine q35 -smp "$cpus" -m "$memory" \
  -nodefaults -display none -no-reboot -no-user-config \
  -kernel /opt/vm/vmlinuz -initrd /opt/vm/initrd.img \
  -append "console=ttyS0 root=/dev/vda rw systemd.firstboot=0 systemd.show_status=1 net.ifnames=0" \
  -drive file=root.qcow2,if=virtio,format=qcow2,discard=unmap \
  -drive file=scratch.img,if=virtio,format=raw,discard=unmap \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
  -device virtio-serial-pci \
  -chardev pipe,id=jit,path=jit -device virtserialport,chardev=jit,name=jit.config \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -serial file:/dev/stdout
status=$?
set -e
kill "$writer" 2>/dev/null || true
rm -f root.qcow2 scratch.img jit.in jit.out
echo "vm-runner: qemu exit $status"
[[ $status == 1 ]]
