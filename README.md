# Velodyne VLP-16 with ROS 2 Jazzy

Guide to install ROS 2 Jazzy (Desktop), connect a Velodyne VLP-16 over Ethernet, and visualize `/velodyne_points` and `/scan` in RViz2.

**Requirements:** Ubuntu 24.04 (Noble), a VLP-16 with its power/interface box, and an Ethernet port on your computer.

---

## 1. Install ROS 2 Jazzy (Desktop)

### 1.1 Set locale

```bash
locale  # check for UTF-8

sudo apt update && sudo apt install -y locales
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8
```

### 1.2 Enable the required repositories

```bash
sudo apt install -y software-properties-common
sudo add-apt-repository universe
sudo apt update && sudo apt install -y curl

export ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F "tag_name" | awk -F\" '{print $4}')
curl -L -o /tmp/ros2-apt-source.deb "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo ${UBUNTU_CODENAME:-${VERSION_CODENAME}})_all.deb"
sudo dpkg -i /tmp/ros2-apt-source.deb
```

### 1.3 Install ROS 2 Jazzy Desktop

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y ros-jazzy-desktop ros-dev-tools
```

`ros-jazzy-desktop` includes ROS, RViz2, demos and tutorials.

### 1.4 Source the environment

```bash
source /opt/ros/jazzy/setup.bash
echo "source /opt/ros/jazzy/setup.bash" >> ~/.bashrc
```

### 1.5 Verify

```bash
printenv ROS_DISTRO        # should print: jazzy
ros2 run demo_nodes_cpp talker
```

If you see `Publishing: 'Hello World: ...'`, the install works. If the install steps change, check the official guide: https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html

### 1.6 Install the Velodyne drivers and tools

The repository includes a script that installs the Velodyne packages, RViz2, the TF tools and the network utilities. From the root of the repo:

```bash
cd scripts
chmod +x install_velodyne.sh
./install_velodyne.sh
```

Make sure ROS 2 Jazzy is installed first (steps 1.1 to 1.5), because the script detects your ROS distro and sources it.

The script asks for `sudo` when it runs `apt`, so you may be prompted for your password.

Optionally, pass the name of the network interface connected to the sensor and the script will also set the static IP described in section 2:

```bash
./install_velodyne.sh enp3s0
```

When it finishes, it prints a summary of the launch and RViz commands. You can then continue with section 2 (if you did not pass an interface) or go straight to section 3.

---

## 2. Check your network interface and set a static IP

The VLP-16 factory defaults:

| Item | Value |
|------|-------|
| Sensor IP | `192.168.1.201` |
| Data port (UDP) | `2368` |
| Host IP to use | `192.168.1.70` (any free address in `192.168.1.0/24`) |

### 2.1 Find the right interface

List interfaces:

```bash
ip -br link
ip -br addr
nmcli device status
```

Ethernet names usually start with `en` (e.g. `enp3s0`, `eno1`) or `eth`. Wi-Fi starts with `wl`. Loopback is `lo`. Ignore those two.

To identify which one is connected to the sensor, run `ip -br link` before and after plugging the cable. The interface that changes from `DOWN` to `UP` (or `NO-CARRIER` to `UP`) is the one.

Confirm the sensor is sending traffic (replace `enp3s0`):

```bash
sudo tcpdump -i enp3s0 -n udp port 2368 -c 5
```

If packets show up, you are on the right interface (even before setting the IP).

### 2.2 Set the static IP (NetworkManager, persistent)

```bash
sudo nmcli con add type ethernet ifname enp3s0 con-name velodyne \
  ipv4.method manual ipv4.addresses 192.168.1.70/24
sudo nmcli con up velodyne
```

Replace `enp3s0` with your interface. Undo it later with `sudo nmcli con delete velodyne`.

### 2.3 Alternative: temporary IP (lost on reboot)

```bash
sudo ip addr add 192.168.1.70/24 dev enp3s0
sudo ip link set enp3s0 up
```

### 2.4 Verify

```bash
ip -br addr show enp3s0     # should list 192.168.1.70/24
ping -c 3 192.168.1.201     # sensor reply
```

You can also open the sensor's web interface at http://192.168.1.201.

---

## 3. Run and visualize in RViz2

Open a terminal for each step. In every terminal, make sure ROS is sourced:

```bash
source /opt/ros/jazzy/setup.bash
```

### Step 1: Launch the full Velodyne pipeline

```bash
ros2 launch velodyne velodyne-all-nodes-VLP16-launch.py
```

This starts three nodes:

```
velodyne_driver_node -> /velodyne_packets -> velodyne_transform_node -> /velodyne_points -> velodyne_laserscan_node -> /scan
```

If you prefer launching them separately:

```bash
ros2 launch velodyne_driver velodyne_driver_node-VLP16-launch.py
ros2 launch velodyne_pointcloud velodyne_transform_node-VLP16-launch.py
ros2 launch velodyne_laserscan velodyne_laserscan_node-launch.py
```

### Step 2: Check the topics

```bash
ros2 topic list
ros2 topic hz /velodyne_packets
ros2 topic hz /velodyne_points
ros2 topic hz /scan
```

All three should report a rate (around 10 Hz by default, which matches the sensor's 600 RPM).

### Step 3: Open RViz2

```bash
rviz2
```

### Step 4: Set the Fixed Frame

In **Global Options > Fixed Frame**, **type** `velodyne` and press Enter. The dropdown will not list it because no TF publishes it, but typing it works. If your driver uses a different `frame_id`, confirm it with:

```bash
ros2 topic echo /velodyne_points --field header.frame_id --once
```

### Step 5: Add the PointCloud2 display

1. Click **Add** (bottom left) > **By topic** > `/velodyne_points` > **PointCloud2**.
2. Expand the display and open **Topic**. Set **Reliability Policy** to **Best Effort**.
3. Set **Size (m)** to about `0.03` to `0.05` and **Color Transformer** to `Intensity` or `AxisColor`.

### Step 6: Add the LaserScan display

1. Click **Add** > **By topic** > `/scan` > **LaserScan**.
2. Expand the display and open **Topic**. Set **Reliability Policy** to **Best Effort**.
3. Set **Size (m)** to about `0.05` and choose a contrasting color so it stands out from the cloud.

### Step 7: Save the RViz configuration

**File > Save Config As...** (for example `velodyne.rviz`). Next time:

```bash
rviz2 -d velodyne.rviz
```

---

## 4. Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `/velodyne_packets` has no data | Network problem: check the IP, the interface, the cable, and `tcpdump` on port 2368. |
| `/velodyne_packets` OK, `/velodyne_points` missing | The transform node is not running. Use the all-nodes launch file. |
| `/scan` silent | The laserscan node only works if something is subscribed to `/scan`. Run `ros2 topic hz /scan` or add the display in RViz. |
| RViz log: `Message Filter dropping message ... queue is full` | RViz has no transform to the Fixed Frame. Type `velodyne` as the Fixed Frame. For another frame, publish one: `ros2 run tf2_ros static_transform_publisher --frame-id base_link --child-frame-id velodyne` |
| RViz shows nothing and no errors | Set the display's Reliability Policy to **Best Effort** and increase the point size. |
| `ros2 topic echo` shows nothing | Use `--qos-reliability best_effort`. |
| Packets arrive but the cloud looks wrong | Check the model and calibration in the transform node params (`VLP16`, `VLP16db.yaml`). |