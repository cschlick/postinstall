# Minimal Debian 13 (trixie) image with systemd as PID 1 + python3, so the role's
# `service` handler works and Ansible has an interpreter. Pre-built and used
# as-is (pre_build_image: true) to avoid molecule's own image-build task, which
# is broken against ansible-core 2.21.
#
# Build:  docker build -t molecule-trixie-systemd ansible/roles/ssh/molecule/default
FROM debian:13
ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus python3 sudo procps iproute2 ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
