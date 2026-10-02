#!/usr/bin/env bash
# Install and set up the ROS 2 tools needed for a Velodyne VLP-16.
#
# Usage:
#   ./install_velodyne.sh                # install packages only
#   ./install_velodyne.sh enp3s0         # also set a static IP on interface enp3s0
#
# Assumes ROS 2 is already installed (e.g. Humble / Jazzy) on Ubuntu.

set -euo pipefail

IFACE="${1:-}"          # optional: network interface connected to the VLP-16
HOST_IP="192.168.1.70"  # host IP in the sensor's default subnet
SENSOR_IP="192.168.1.201"  # VLP-16 factory default

# --- 1. Detect ROS 2 distro -------------------------------------------------
if [[ -z "${ROS_DISTRO:-}" ]]; then
  # Try to find one under /opt/ros
  ROS_DISTRO="$(ls /opt/ros 2>/dev/null | head -n1 || true)"
fi
if [[ -z "${ROS_DISTRO}" ]]; then
  echo "ERROR: ROS 2 not found. Install ROS 2 first (https://docs.ros.org/)." >&2
  exit 1
fi
echo ">> Using ROS 2 distro: ${ROS_DISTRO}"
# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO}/setup.bash"

# --- 2. Install packages ----------------------------------------------------
sudo apt update
sudo apt install -y \
  "ros-${ROS_DISTRO}-velodyne" \
  "ros-${ROS_DISTRO}-velodyne-driver" \
  "ros-${ROS_DISTRO}-velodyne-pointcloud" \
  "ros-${ROS_DISTRO}-velodyne-laserscan" \
  "ros-${ROS_DISTRO}-velodyne-msgs" \
  "ros-${ROS_DISTRO}-rviz2" \
  "ros-${ROS_DISTRO}-tf2-ros" \
  "ros-${ROS_DISTRO}-tf2-tools" \
  net-tools tcpdump

# --- 3. (Optional) static IP for the sensor network ------------------------
# The VLP-16 defaults to 192.168.1.201 and sends UDP data to port 2368.
# The host must be on the same subnet.
if [[ -n "${IFACE}" ]]; then
  echo ">> Configuring ${IFACE} with static IP ${HOST_IP}/24"
  if command -v nmcli >/dev/null; then
    sudo nmcli con delete velodyne 2>/dev/null || true
    sudo nmcli con add type ethernet ifname "${IFACE}" con-name velodyne \
      ipv4.method manual ipv4.addresses "${HOST_IP}/24"
    sudo nmcli con up velodyne
  else
    sudo ip addr add "${HOST_IP}/24" dev "${IFACE}" || true
    sudo ip link set "${IFACE}" up
  fi
  ping -c 3 "${SENSOR_IP}" || echo "WARNING: sensor not reachable at ${SENSOR_IP}"
else
  echo ">> Skipping network setup (pass the interface name as first argument to enable it)."
fi

# --- 4. Summary -------------------------------------------------------------
cat <<EOF

==========================================================
 Installation done. To run the VLP-16:

   source /opt/ros/${ROS_DISTRO}/setup.bash

   # All nodes at once (driver + transform + laserscan):
   ros2 launch velodyne velodyne-all-nodes-VLP16-launch.py

   # Check the pipeline:
   ros2 topic hz /velodyne_packets
   ros2 topic hz /velodyne_points
   ros2 topic hz /scan

   # Visualize:
   rviz2
     - Fixed Frame: velodyne   (type it manually)
     - Add PointCloud2 on /velodyne_points
       (Reliability Policy: Best Effort)

 Debug raw sensor traffic:
   sudo tcpdump -i <iface> udp port 2368
 Sensor web interface:
   http://${SENSOR_IP}
==========================================================
EOF