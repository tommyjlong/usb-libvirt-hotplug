#!/bin/bash
# 
# Script that will search the FILEPATH directory for a subdirectory named DOMAIN
# looking for xml files.  These XML files are assumed to contain
# XML data for attaching a USB device to a VM named DOMAIN.
# If any are found, the script makes a virsh call to attach the 
# corresponding USB device to the DOMAIN.  
# In general, this script is only for use when a host has been running
# fine but the domain has been manually restarted.  After the domain
# has restarted, call this script manually (assume it has execute permissions).
# $./reattach-usb-to-domain.sh DOMAIN
#

#
# Configuration
# FILEPATH: is the directory this script should be operating in
#
FILEPATH='/opt/udev-scripts/'

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


DOMAIN="$1"
if [ -z "${DOMAIN}" ]; then
  echo "Missing libvirt parameter DOMAIN for ${PROG}." >&2
  exit 1
fi

DOMAIN_DIR="${DOMAIN}/"

#
# Libvirtd Hook for use with qemu.
# I could not get /etc/libivird/hook/qemu script
#   to call this script, but I left stuff here anyway.
#
#HOOK_PHASE=$2  
HOOK_PHASE='started'

if [ -z "${HOOK_PHASE}" ]; then
  echo "Missing libvirt hook phase parameter for ${PROG}." >&2
  exit 1
fi

if [ "${HOOK_PHASE}" == 'prepare' ]; then
  echo "prepare hook"
  exit 0 
elif [ "${HOOK_PHASE}" == 'start' ]; then
  echo "start hook"
  exit 0 
elif [ "${HOOK_PHASE}" == 'started' ]; then
  echo "started hook"
elif [ "${HOOK_PHASE}" == 'stopped' ]; then
  echo "stopped hook"
  exit 0 
elif [ "${HOOK_PHASE}" == 'release' ]; then
  echo "release hook"
  exit 0 
else
  echo "HOOK PHASE unknown"
  exit 0 
fi

#
# For now we'll assume the VM is running
# and virsh has a socket to libvirtd
#
COMMAND='attach-device'
set +e
XML_FILE_LIST=$(ls ${FILEPATH}${DOMAIN_DIR}*.xml 2>/dev/null )
set -e
#echo $XML_FILE_LIST
if [ ! -z "${XML_FILE_LIST}" ]; then
 #echo "Attaching using Files: ${XML_FILE_LIST}" >&2
  for val in ${XML_FILE_LIST}; do
     virsh ${COMMAND} ${DOMAIN} --file $val
  done
else
  echo "No XML file list found. Nothing to attach to $DOMAIN"
fi

