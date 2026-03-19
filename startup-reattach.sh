#!/bin/bash
# 
# Script that will call the reattach-usb-to-domain.sh script
# for a configured list of libvirt domains.
#
# In general, this script is only for use when a host is booting up 
# and is to be called after the libvirt daemon is up and running for
# example use a systemd service that uses "After=libvirtd.service".
# During Host bootup, the main usb-libvirt-hotplug script may see
# USB devices appear before the libvirt daemon is up and running,
# but it will go ahead and create the necessary xml files for libvirt to use.
# After the libvirt daemon is ready, this script can be called.
#

#
# Configuration
# DOMAIN_LIST: it the list of libvirt domains to try and reattach USB devices to.
# FILEPATH: (Optional) - is the directory this script resides in and will
#                        use for its operations; otherwise self-determined.
#FILEPATH="/opt/udev-scripts/"
FILEPATH=$(dirname "$(realpath $0)")/

#DOMAIN_LIST=("domain1" "domain2" "domain3")
DOMAIN_LIST=("hassio")

#echo "Operating in Directory: $FILEPATH"

#The reattachment script is assumed to be the following:
REATTACH_SCRIPT="reattach-usb-to-domain.sh"
set -e

#
# Setup to send output to syslog if not called from tty
#
PROG="$(basename "$0")"
if [ ! -t 1 ]; then
  # stdout is not a tty. Send all output to syslog.
  coproc logger --tag "${PROG}"
  exec >&${COPROC[1]} 2>&1
fi


# May need to wait a second in case being called at startup by systemd
#   to let other devices get attached
#sleep 1

if [ ! -e $FILEPATH/$REATTACH_SCRIPT ]; then
  echo "Missing shell script: $FILEPATH$REATTACH_SCRIPT"
  exit 1
fi

# Iterate through the libvirt domains
for val in "${DOMAIN_LIST[@]}"; do
  echo "Attempting to run script ${FILEPATH}${REATTACH_SCRIPT} $val"
  $FILEPATH$REATTACH_SCRIPT "$val"
done
