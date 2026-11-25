# One-job GitHub Actions runner inside a QEMU/KVM VM.
#
# Stage `guest` is the VM's root filesystem: Ubuntu, Docker, the Actions runner
# and a systemd unit that runs exactly one JIT job, then powers off.
# Stage `disk` turns it into a compressed qcow2 plus kernel/initrd without root
# or loop devices (mke2fs -d). The final image only holds QEMU, the disk and the
# wrapper; it runs as a non-root user with no capabilities and needs only
# /dev/kvm (e.g. from a device plugin) and a writable volume at /vm.
#
# VARIANT=base (default) or macos-sdk: the latter adds Apple's macOS SDK from
# the newest Command Line Tools in Apple's public software update catalog
# (macos-sdk/fetch.py) at /opt/macos-sdk, with SDKROOT set for jobs. Target
# `macos-sdk-version` outputs only its VERSION file (publish.yml tags with it).

ARG UBUNTU=ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254
ARG VARIANT=base

FROM ${UBUNTU} AS guest-base
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      linux-image-virtual initramfs-tools systemd systemd-sysv udev dbus \
      iproute2 e2fsprogs util-linux kmod \
      ca-certificates curl docker.io docker-buildx git iptables jq sudo tar unzip xz-utils \
      build-essential \
      libicu74 \
    && useradd --create-home --shell /bin/bash runner \
    && usermod -aG docker runner \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner \
    && mkdir -p /opt/runner/_work /opt/hostedtoolcache /mnt/scratch \
    && curl --fail --location --retry 3 \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
      -o /tmp/runner.tar.gz \
    && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum --check \
    && tar xzf /tmp/runner.tar.gz -C /opt/runner \
    && rm /tmp/runner.tar.gz \
    && /opt/runner/bin/installdependencies.sh \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R runner:runner /opt/runner /opt/hostedtoolcache
COPY guest/jit-run /usr/local/sbin/jit-run
COPY guest/jit-runner.service /etc/systemd/system/jit-runner.service
COPY guest/10-eth.network /etc/systemd/network/10-eth.network
RUN chmod 755 /usr/local/sbin/jit-run \
    && systemctl enable systemd-networkd.service jit-runner.service \
    && systemctl disable docker.service docker.socket \
    && systemctl mask serial-getty@ttyS0.service getty@tty1.service \
         systemd-firstboot.service apt-daily.timer apt-daily-upgrade.timer \
    && ls /boot/vmlinuz-* /boot/initrd.img-*

FROM ${UBUNTU} AS macos-sdk
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 libarchive-tools ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY macos-sdk/fetch.py /usr/local/bin/macos-sdk-fetch
# NMOS: the SDK of the macOS the tools were released with (27.2 for CLT 27.2).
ARG MACOS_SDK_PACKAGE=CLTools_macOSNMOS_SDK.pkg
RUN python3 -I /usr/local/bin/macos-sdk-fetch /out/macos-sdk "$MACOS_SDK_PACKAGE"

FROM scratch AS macos-sdk-version
COPY --from=macos-sdk /out/macos-sdk/VERSION /VERSION

FROM guest-base AS guest-macos-sdk
COPY --from=macos-sdk /out/macos-sdk/ /opt/macos-sdk/
RUN echo SDKROOT=/opt/macos-sdk/MacOSX.sdk >/etc/jit-runner.env \
    && test -f /opt/macos-sdk/MacOSX.sdk/SDKSettings.plist

FROM guest-${VARIANT} AS guest

FROM ${UBUNTU} AS disk
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs qemu-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=guest / /rootfs/
# 16G virtual root: room for apt installs by jobs. Zeros compress away.
# resolv.conf/hostname are bind-mounted during a build: set them on the copy.
RUN rm -f /rootfs/etc/resolv.conf && echo 'nameserver 10.0.2.3' >/rootfs/etc/resolv.conf \
    && echo jit-runner >/rootfs/etc/hostname \
    && : >/rootfs/etc/machine-id \
    && mkdir /out \
    && cp /rootfs/boot/vmlinuz-* /out/vmlinuz \
    && cp /rootfs/boot/initrd.img-* /out/initrd.img \
    && mke2fs -q -t ext4 -L root -d /rootfs /tmp/root.img 16G \
    && qemu-img convert -c -O qcow2 /tmp/root.img /out/root.qcow2 \
    && rm /tmp/root.img \
    && chmod 0444 /out/*

FROM ${UBUNTU}
LABEL org.opencontainers.image.source=https://github.com/shinsenkyo-net/github-jit-runner
LABEL org.opencontainers.image.description="One-job GitHub Actions runner in a QEMU/KVM VM"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin vm
COPY --from=disk /out/ /opt/vm/
COPY entrypoint.sh /usr/local/bin/vm-runner
RUN chmod 755 /usr/local/bin/vm-runner
USER 10001
WORKDIR /vm
ENTRYPOINT ["/usr/local/bin/vm-runner"]
