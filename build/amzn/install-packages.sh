#!/bin/bash
export TARGET
set -euo pipefail

# ------------------------------------------------------------------
# 1. Update + install base packages
# ------------------------------------------------------------------
if command -v yum > /dev/null; then
    # Amazon Linux 2
    yum update -y
    yum install -y \
        ImageMagick \
        file \
        sudo \
        net-tools \
        iputils \
        curl \
        git \
        jq \
        dos2unix \
        mysql \
        tzdata \
        rsync \
        nano \
        unzip \
        zstd \
        lbzip2 \
        nfs-utils \
        libpcap \
        ${EXTRA_DNF_PACKAGES}
    yum clean all
else
    # Ubuntu / Debian
    apt-get update
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
        imagemagick \
        file \
        sudo \
        net-tools \
        iputils-ping \
        curl \
        git \
        jq \
        dos2unix \
        mysql-client \
        tzdata \
        rsync \
        nano \
        unzip \
        zstd \
        lbzip2 \
        nfs-common \
        libpcap0.8 \
        ${EXTRA_DEB_PACKAGES}
    apt-get clean
fi

# ------------------------------------------------------------------
# 2. Install Git LFS only on Debian/Ubuntu
# ------------------------------------------------------------------
if ! command -v yum > /dev/null; then
    curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | sudo bash
    apt-get update
    apt-get install -y git-lfs
fi

# ------------------------------------------------------------------
# 3. Install patched knockd (common to all OSes)
# ------------------------------------------------------------------
curl -fsSL -o /tmp/knock.tar.gz https://github.com/Metalcape/knock/releases/download/0.8.1/knock-0.8.1-${TARGET}.tar.gz
tar -xf /tmp/knock.tar.gz -C /usr/local/ && rm /tmp/knock.tar.gz
ln -s /usr/local/sbin/knockd /usr/sbin/knockd
setcap cap_net_raw=ep /usr/local/sbin/knockd
find /usr/lib -name 'libpcap.so.0.8' -exec cp '{}' libpcap.so.1 \;

# ------------------------------------------------------------------
# 4. Git global config
# ------------------------------------------------------------------
cat >> /etc/gitconfig <<EOF
[user]
    name = Minecraft Server on Docker
    email = server@example.com
EOF
