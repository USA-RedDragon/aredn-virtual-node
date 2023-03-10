#!/bin/sh

# This is Ubuntu 22.04 LTS (Jammy)
apt update
apt upgrade -y
apt install -y docker.io

systemctl enable --now docker
systemctl disable --now snapd.service
systemctl disable --now snap.amazon-ssm-agent.amazon-ssm-agent.service

echo 'wireguard' >> /etc/modules-load.d/modules.conf
modprobe wireguard

# Add the ubuntu user to the Docker group
usermod -aG docker ubuntu

# Clone this repo
docker pull ghcr.io/usa-reddragon/aredn-virtual-node:main

docker network create --subnet=10.54.25.0/24 aredn-net

LOGGING="--log-driver=awslogs --log-opt awslogs-region=${region} --log-opt awslogs-group=${awslogs-group} --log-opt awslogs-create-group=true"

mkdir -p /docker-data

# Try to mount /dev/sdf first, then if it fails, format it
if ! mount -t ext4 /dev/nvme1n1 /docker-data; then
    mkfs.ext4 /dev/nvme1n1
    mount -t ext4 /dev/nvme1n1 /docker-data
fi

mkdir -p /docker-data/netdata
chown -R root:201 /docker-data/netdata
chmod -R g+w /docker-data/netdata

# Run the Docker image
docker run \
    --cap-add=NET_ADMIN \
    --privileged \
    -e CONFIGURATION_JSON='${configuration_json}' \
    -e SERVER_NAME=${server_name} \
    -e WIREGUARD_TAP_ADDRESS=${wireguard_tap_address} \
    -e WIREGUARD_PEER_PUBLICKEY=${wireguard_peer_publickey} \
    -e WIREGUARD_SERVER_PRIVATEKEY=${wireguard_server_privatekey} \
    --device /dev/net/tun \
    --name ${server_name} \
    -p 5525:5525 \
    -p 51820:51820/udp \
    -d \
    --restart unless-stopped \
    $LOGGING \
    --net aredn-net --ip 10.54.25.2 \
    ghcr.io/usa-reddragon/aredn-virtual-node:main

docker run \
    -d \
    --name watchtower \
    $LOGGING \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --restart=unless-stopped \
    containrrr/watchtower

docker run \
    --restart=unless-stopped \
    --name openspeedtest \
    $LOGGING \
    -d \
    --network=container:${server_name} \
    openspeedtest/latest

docker run \
    --network=container:${server_name} \
    -v /etc/passwd:/host/etc/passwd:ro \
    -v /etc/group:/host/etc/group:ro \
    -v /proc:/host/proc:ro \
    -v /sys:/host/sys:ro \
    -v /etc/os-release:/host/etc/os-release:ro \
    --restart unless-stopped \
    --cap-add SYS_PTRACE \
    --security-opt apparmor=unconfined \
    -d \
    -v /docker-data/netdata/etc:/etc/netdata \
    -v /docker-data/netdata/var:/var/lib/netdata \
    -v /docker-data/netdata/cache:/var/cache/netdata \
    $LOGGING \
    --name netdata \
    netdata/netdata
