ARG BASE_IMAGE=debian:bookworm-slim
FROM $BASE_IMAGE

RUN echo "Installing Packages for Kubespray ..." \
  && export DEBIAN_FRONTEND=noninteractive \
  && apt-get update && apt-get install -y --no-install-recommends \
  systemd \
  dbus \
  iputils-ping conntrack iptables nftables iproute2 ethtool util-linux mount kmod \
  libseccomp2 \
  openssh-server \
  python3 \
  sudo \
  ca-certificates curl procps \
  && rm -rf /var/lib/apt/lists/* \
  && find /lib/systemd/system/sysinit.target.wants/ -name "systemd-tmpfiles-setup.service" -delete \
  && rm -f /lib/systemd/system/multi-user.target.wants/* \
  && rm -f /etc/systemd/system/*.wants/* \
  && rm -f /lib/systemd/system/local-fs.target.wants/* \
  && rm -f /lib/systemd/system/sockets.target.wants/*udev* \
  && rm -f /lib/systemd/system/sockets.target.wants/*initctl* \
  && rm -f /lib/systemd/system/basic.target.wants/* \
  && echo "ReadKMsg=no" >> /etc/systemd/journald.conf \
  && ln -s "$(which systemd)" /sbin/init

RUN echo "Configuring D-Bus and SSH ..." \
  && mkdir -p /var/run/dbus \
  && dbus-uuidgen --ensure \
  && systemctl enable dbus \
  && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
  && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
  && sed -i 's/#AuthorizedKeysFile/AuthorizedKeysFile/' /etc/ssh/sshd_config \
  && echo 'root:kubespray' | chpasswd \
  && systemctl enable ssh \
  && systemctl mask systemd-binfmt.service

RUN echo "Disabling unnecessary services ..." \
  && systemctl disable sphinxsearch.service 2>/dev/null || true \
  && systemctl mask sphinxsearch.service 2>/dev/null || true

ENV container=docker
STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/sbin/init"]

EXPOSE 6443 22
