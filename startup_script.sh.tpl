#!/bin/bash
#
# Copyright 2019 Google LLC
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e
set -x

log() { 
  echo "`date`: $1"; 
  curl -X PUT --data "$1" http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/splunk/install-status -H "Metadata-Flavor: Google"
}

export SPLUNK_USER=splunk
export SPLUNK_BIN=/opt/splunk/bin/splunk
export SPLUNK_HOME=/opt/splunk
export SPLUNK_DB_MNT_DIR=/mnt/splunk_db
export SPLUNK_ROLE="$(curl http://metadata.google.internal/computeMetadata/v1/instance/attributes/splunk-role -H "Metadata-Flavor: Google")"
export LOCAL_IP="$(curl http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip -H "Metadata-Flavor: Google")"

curl -X PUT --data "in-progress" http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/splunk/install -H "Metadata-Flavor: Google"

# Determine if this is first-time boot of a new VM as opposed to a VM restart (or a VM recreate from MIG auto-healer).
# In the latter cases, no additional configuration is needed, and just exit startup script.
# Note: the exception here is MIG-recreated VMs with local SSDs as data disks. Unlike re-attached preserved PD,
# the SSDs disks are recreated and need to be re-formatted and re-striped. TODO: add that logic below.
# More info: https://cloud.google.com/compute/docs/instance-groups/autohealing-instances-in-migs#autohealing_and_disks
if [[ -d "$SPLUNK_HOME" ]]; then
  log "Splunk installation found. Skipping node configuration."
  exit 0
fi 

log "Downloading and installing Splunk..."
# Download & install Splunk Enterprise
wget -O ${SPLUNK_PACKAGE_NAME} "${SPLUNK_PACKAGE_URL}"
tar zxf ${SPLUNK_PACKAGE_NAME}
mv splunk $SPLUNK_HOME
rm ${SPLUNK_PACKAGE_NAME}

log "Creating Splunk system user..."
# Create Splunk system user, and set directory permissions
if ! id $SPLUNK_USER >/dev/null 2>&1; then
  useradd -r -m -s /bin/bash -U $SPLUNK_USER
fi
chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME

log "Configuring data disks (if any)..."
export DATA_DISKS=`ls /dev/sd* | egrep -v '^/dev/sda[0-9]*'`
declare OVERRIDE_SPLUNK_DB_LOCATION=0

# If Data PD attached, format+mount it and override SPLUNK_DB location
if [[ -h /dev/disk/by-id/google-persistent-disk-1 ]]; then
  log "Mountaing data PD for Splunk DB"
  DATA_DISK=$(readlink /dev/disk/by-id/google-persistent-disk-1)
  DATA_DISK_ID=$(basename $DATA_DISK)
  # Confirm this is first boot based on data mount point existence
  if [[ ! -e $SPLUNK_DB_MNT_DIR ]]; then
    mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/$DATA_DISK_ID
    mkdir -p $SPLUNK_DB_MNT_DIR
    mount -o discard,defaults /dev/$DATA_DISK_ID $SPLUNK_DB_MNT_DIR
    OVERRIDE_SPLUNK_DB_LOCATION=1
  fi
# If Local SSDs attached (in SCSI mode), format+stripe+mount them and override SPLUNK_DB location
elif [[ $DATA_DISKS != "" ]]; then
  DATA_DISKS_CNT=$(echo $DATA_DISKS | tr ' ' '\n' | wc -l)
  DATA_DISK_ID='md0'
  # Confirm this is first boot based on data mount point existence
  if [[ ! -e $SPLUNK_DB_MNT_DIR ]]; then
    # Stripe local SSDs into single RAID0 array
    mdadm --create /dev/$DATA_DISK_ID --level=0 --raid-devices=$DATA_DISKS_CNT $DATA_DISKS
    # Format full array
    mkfs.ext4 -F /dev/$DATA_DISK_ID
    mkdir -p $SPLUNK_DB_MNT_DIR
    mount -o discard,defaults,nobarrier /dev/$DATA_DISK_ID $SPLUNK_DB_MNT_DIR
    OVERRIDE_SPLUNK_DB_LOCATION=1
  fi
fi

# Set Splunk DB location
if [[ $OVERRIDE_SPLUNK_DB_LOCATION -eq 1 ]]; then
  # Grant access to Splunk system user
  chown $SPLUNK_USER:$SPLUNK_USER $SPLUNK_DB_MNT_DIR
  # Persist mount in fstab for instance restarts
  echo UUID=$(blkid -s UUID -o value /dev/$DATA_DISK_ID) $SPLUNK_DB_MNT_DIR ext4 discard,defaults,nofail 0 2 | tee -a /etc/fstab

  # Point SPLUNK_DB to data disk mount directory 
  cp $SPLUNK_HOME/etc/splunk-launch.conf.default $SPLUNK_HOME/etc/splunk-launch.conf
  sed -i "/SPLUNK_DB/c\SPLUNK_DB=$SPLUNK_DB_MNT_DIR" $SPLUNK_HOME/etc/splunk-launch.conf
  chown $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/splunk-launch.conf
fi

log "Configuring Splunk installation..."
# Work around for having to pass admin pass
cd ~
mkdir .splunk
chmod 777 -R .splunk
touch .splunk/authToken_hostname_port
chmod 600 .splunk/authToken_hostname_port
cd $SPLUNK_HOME

# Set Splunk admin password and disable first-time run password prompt
cat >>$SPLUNK_HOME/etc/system/local/user-seed.conf <<end
[user_info]
USERNAME = admin
PASSWORD = ${SPLUNK_ADMIN_PASSWORD}
end
touch $SPLUNK_HOME/etc/.ui_login

# Configure systemd to start Splunk at boot
cd /opt/splunk
bin/splunk enable boot-start -user $SPLUNK_USER --accept-license -systemd-managed 0

# Configure Splunk before starting service
# Increase splunkweb connection timeout with splunkd
mkdir -p $SPLUNK_HOME/etc/apps/base-autogenerated/local
cat >>$SPLUNK_HOME/etc/apps/base-autogenerated/local/web.conf <<end
[settings]
splunkdConnectionTimeout = 300
end

chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/apps/base-autogenerated

log "Starting Splunk Service..."
# Start Splunk service
sudo /etc/init.d/splunk start

# Allow for Splunk start-up time
sleep 10

if [ $SPLUNK_ROLE = "IDX-Master" ]; then
log "Cluster Master configuration"

# Change default to HTTPS on the web interface
# cat >>$SPLUNK_HOME/etc/system/local/web.conf <<end
# [settings]
# enableSplunkWebSSL = 1
# end

# Forward to indexer cluster using indexer discovery
cat >>$SPLUNK_HOME/etc/apps/base-autogenerated/local/outputs.conf <<end
# Turn off indexing
[indexAndForward]
index = false

[tcpout]
defaultGroup = indexer_cluster_peers
forwardedindex.filter.disable = true
indexAndForward = false

[tcpout:indexer_cluster_peers]
indexerDiscovery = cluster_master

[indexer_discovery:cluster_master]
pass4SymmKey = ${SPLUNK_INDEXER_DISCOVERY_SECRET}
master_uri = https://127.0.0.1:8089
end

chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/apps/base-autogenerated

sudo -u $SPLUNK_USER $SPLUNK_BIN login -auth admin:'${SPLUNK_ADMIN_PASSWORD}'
sudo -u $SPLUNK_USER $SPLUNK_BIN edit cluster-config -mode master -replication_factor 3 -search_factor 2 -secret '${SPLUNK_CLUSTER_SECRET}' -cluster_label Splunk-IDX

# Configure indexer discovery - pass4SymmKey doesn't get hashed
cat >>$SPLUNK_HOME/etc/system/local/server.conf <<end

[indexer_discovery]
pass4SymmKey = ${SPLUNK_INDEXER_DISCOVERY_SECRET}
indexerWeightByDiskCapacity = true
end

chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/system/local/server.conf

# Add base configs for peer nodes as an app under master-apps
# Peer config 1: Enable HEC input
sudo -u $SPLUNK_USER $SPLUNK_BIN http-event-collector enable -uri https://localhost:8089 -auth admin:'${SPLUNK_ADMIN_PASSWORD}'
sudo -u $SPLUNK_USER $SPLUNK_BIN http-event-collector create default-token -uri https://localhost:8089 -auth admin:'${SPLUNK_ADMIN_PASSWORD}' > /tmp/token
TOKEN=`sed -n 's/\\ttoken=//p' /tmp/token`
rm /tmp/token
log "Setting HEC Token as guest attribute"
curl -X PUT --data "$TOKEN" http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/splunk/token -H "Metadata-Flavor: Google"

mkdir -p $SPLUNK_HOME/etc/master-apps/peer-base-autogenerated/local
mv $SPLUNK_HOME/etc/apps/splunk_httpinput/local/inputs.conf $SPLUNK_HOME/etc/master-apps/peer-base-autogenerated/local
# Peer config 2: Enable splunktcp input
cat >>$SPLUNK_HOME/etc/master-apps/peer-base-autogenerated/local/inputs.conf <<end

[splunktcp://9997]
disabled=0
end

chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/master-apps

else
# Link up with License Master
# TODO: Add following when enterprise license installed on cluster master
#sudo -u $SPLUNK_USER $SPLUNK_BIN edit licenser-localslave -master_uri https://${SPLUNK_CM_PRIVATE_IP}:8089 -auth admin:'${SPLUNK_ADMIN_PASSWORD}'
log "Skip license master link up" 
fi

if [ $SPLUNK_ROLE = "SHC-Deployer" ]; then
log "Deployer configurations"

# Change default to HTTPS on the web interface
# cat >>$SPLUNK_HOME/etc/system/local/web.conf <<end
# [settings]
# enableSplunkWebSSL = 1
# end

# Configure some SHC parameters
cat >>$SPLUNK_HOME/etc/apps/base-autogenerated/local/server.conf <<end

[shclustering]
pass4SymmKey = ${SPLUNK_CLUSTER_SECRET}
shcluster_label = SplunkSHC
end

# Forward to indexer cluster using indexer discovery
cat >>$SPLUNK_HOME/etc/apps/base-autogenerated/local/outputs.conf <<end
# Turn off indexing on the search head
[indexAndForward]
index = false

[tcpout]
defaultGroup = indexer_cluster_peers
forwardedindex.filter.disable = true
indexAndForward = false

[tcpout:indexer_cluster_peers]
indexerDiscovery = cluster_master

[indexer_discovery:cluster_master]
pass4SymmKey = ${SPLUNK_INDEXER_DISCOVERY_SECRET}
master_uri = https://${SPLUNK_CM_PRIVATE_IP}:8089
end

chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/apps/base-autogenerated

# Add base config for search head cluster members
mkdir -p $SPLUNK_HOME/etc/shcluster/apps/member-base-autogenerated/local
cat >>$SPLUNK_HOME/etc/shcluster/apps/member-base-autogenerated/local/outputs.conf <<end
# Turn off indexing on the search head
[indexAndForward]
index = false

[tcpout]
defaultGroup = indexer_cluster_peers
forwardedindex.filter.disable = true
indexAndForward = false

[tcpout:indexer_cluster_peers]
indexerDiscovery = cluster_master

[indexer_discovery:cluster_master]
pass4SymmKey = ${SPLUNK_INDEXER_DISCOVERY_SECRET}
master_uri = https://${SPLUNK_CM_PRIVATE_IP}:8089
end

chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/shcluster/apps/member-base-autogenerated

sudo -u $SPLUNK_USER $SPLUNK_BIN apply shcluster-bundle -action stage --answer-yes -auth admin:'${SPLUNK_ADMIN_PASSWORD}'
# TODO: send bundle after SHC is initialized with captain bootstrapped


elif [ $SPLUNK_ROLE = "SHC-Member" ]; then
  log "Search Head Member configurations"
  # Configure some SHC parameters
  cat >>$SPLUNK_HOME/etc/system/local/server.conf <<end
[shclustering]
register_replication_address = $LOCAL_IP
end
  chown -R $SPLUNK_USER:$SPLUNK_USER $SPLUNK_HOME/etc/system/local
  log "Setting cluster config and connecting to master"
  # Sometimes the master is restarting at the same time, retry up to 5 times
  command="sudo -u $SPLUNK_USER $SPLUNK_BIN login -auth admin:'${SPLUNK_ADMIN_PASSWORD}' && \
  sudo -u $SPLUNK_USER $SPLUNK_BIN init shcluster-config -mgmt_uri https://$LOCAL_IP:8089 -replication_port 8090 -replication_factor 2 -conf_deploy_fetch_url https://${SPLUNK_DEPLOYER_PRIVATE_IP}:8089 -shcluster_label Splunk-SHC -secret '${SPLUNK_CLUSTER_SECRET}' && \
  sudo -u $SPLUNK_USER $SPLUNK_BIN edit cluster-config -mode searchhead -master_uri https://${SPLUNK_CM_PRIVATE_IP}:8089 -secret '${SPLUNK_CLUSTER_SECRET}'"
  count=1;until eval $command || (( $count >= 5 )); do sleep 10; count=$((count + 1)); done
elif [ $SPLUNK_ROLE = "IDX-Peer" ]; then

log "Setting cluster config and connecting to master"
# Sometimes the master is restarting at the same time, retry up to 5 times
command="sudo -u $SPLUNK_USER $SPLUNK_BIN login -auth admin:'${SPLUNK_ADMIN_PASSWORD}' && \
sudo -u $SPLUNK_USER $SPLUNK_BIN edit cluster-config -mode slave -master_uri https://${SPLUNK_CM_PRIVATE_IP}:8089 -replication_port 9887 -secret '${SPLUNK_CLUSTER_SECRET}'"
count=1;until eval $command || (( $count >= 5 )); do sleep 10; count=$((count + 1)); done

# Override Splunk server name of peer node by adding a random number from 0 to 999 as suffix to hostname
SUFFIX=$(cat /dev/urandom | tr -dc '0-9' | fold -w 256 | head -n 1 | sed -e 's/^0*//' | head --bytes 3)
if [ "$SUFFIX" == "" ]; then SUFFIX=0; fi
sudo -u $SPLUNK_USER $SPLUNK_BIN set servername $(hostname)-$SUFFIX

fi

# Removing temporary permissive .splunk directory
cd ~
rm -Rf .splunk

log "Final restart of services"
# Start Splunk service - changed with 8.0.0 - sometimes it gets an error connecting to it's local web server
command="/etc/init.d/splunk restart"
count=1;until eval $command || (( $count >= 5 )); do sleep 10; count=$((count + 1)); done

# Add guest attribute indicating the install process has successfully completed
curl -X PUT --data "complete" http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/splunk/install -H "Metadata-Flavor: Google"
log "Finished setup on $HOSTNAME with role $SPLUNK_ROLE"

exit 0
