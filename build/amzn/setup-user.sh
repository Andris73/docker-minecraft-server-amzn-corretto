#!/usr/bin/env sh
set -e

# Remove any existing minecraft user
if id minecraft > /dev/null 2>&1; then
  userdel -r minecraft
fi

# Create group and system user with UID 1000
groupadd -g 1000 minecraft
useradd -r -u 1000 -g minecraft -d /data -s /sbin/nologin minecraft
