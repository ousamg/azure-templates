#!/bin/bash -e

# This script can be found on https://github.com/ous/azure-templates/blob/master/slurm/azuredeploy.sh
# This script is part of azure deploy ARM template
# This script will install SLURM on a CentOS 7 cluster deployed on a set of Azure VMs

# Basic info
export DEPLOY_LOG=/tmp/azuredeploy.log.$$
export SLURM_HOSTS=/tmp/hosts.$$

date > $DEPLOY_LOG 2>&1
whoami >> $DEPLOY_LOG 2>&1
echo "$@" >> $DEPLOY_LOG 2>&1
pwd >> $DEPLOY_LOG 2>&1

# Usage
if [ "$#" -ne 9 ]; then
  echo "Usage: $0 MASTER_NAME MASTER_IP WORKER_NAME WORKER_IP_BASE WORKER_IP_START NUM_OF_VM ADMIN_USERNAME ADMIN_PASSWORD TEMPLATE_BASE" >> $DEPLOY_LOG
  exit 1
fi

# Preparation steps - hosts and ssh
###################################

# Parameters
export MASTER_NAME=$1
export MASTER_IP=$2
export WORKER_NAME=$3
export WORKER_IP_BASE=$4
export WORKER_IP_START=$5
export NUM_OF_VM=$6
export ADMIN_USERNAME=$7
export ADMIN_PASSWORD=$8
export TEMPLATE_BASE=$9

# Update master node
echo $MASTER_IP $MASTER_NAME >> /etc/hosts
echo $MASTER_IP $MASTER_NAME > $SLURM_HOSTS

# Update ssh config file to ignore unknow host
# Note all settings are for azureuser, NOT root
sudo -u $ADMIN_USERNAME sh -c "mkdir /home/$ADMIN_USERNAME/.ssh/;echo Host worker\* > /home/$ADMIN_USERNAME/.ssh/config; echo StrictHostKeyChecking no >> /home/$ADMIN_USERNAME/.ssh/config; echo UserKnownHostsFile=/dev/null >> /home/$ADMIN_USERNAME/.ssh/config"

# Generate a set of sshkey under /honme/azureuser/.ssh if there is not one yet
if ! [ -f /home/$ADMIN_USERNAME/.ssh/id_rsa ]; then
    sudo -u $ADMIN_USERNAME sh -c "ssh-keygen -f /home/$ADMIN_USERNAME/.ssh/id_rsa -t rsa -N ''"
fi

# nopasswd sudo for admin user, disabled at the end
sed -i 's/ALL$/NOPASSWD:ALL/' /etc/sudoers.d/waagent

# Set filename vars
export RPM_TAR=/tmp/slurm-rpms.tar
export MUNGEKEY=/tmp/munge.key.$$
export SLURM_CONF=/tmp/slurm.conf.$$
export BOOTSTRAP_EXE=bootstrap_node.sh
cp $BOOTSTRAP_EXE /tmp/$BOOTSTRAP_EXE
chmod 755 /tmp/$BOOTSTRAP_EXE

# Install sshpass to automate ssh-copy-id action
sudo yum install sshpass -y >> $DEPLOY_LOG 2>&1

# Loop through all worker nodes, update hosts file and copy ssh public key to it
# The script make the assumption that the node is called $WORKER+<index> and have
# static IP in sequence order
LAST_VM=$(expr $NUM_OF_VM - 1)
export LAST_VM
for i in $(seq 0 $LAST_VM); do
   workerip=$(expr $i + $WORKER_IP_START)
   echo 'Updating host - '$WORKER_NAME$i >> $DEPLOY_LOG 2>&1
   echo $WORKER_IP_BASE$workerip $WORKER_NAME$i >> $SLURM_HOSTS
   echo $WORKER_IP_BASE$workerip $WORKER_NAME$i >> /etc/hosts
   sudo -u $ADMIN_USERNAME sh -c "sshpass -p '$ADMIN_PASSWORD' ssh-copy-id $WORKER_NAME$i"
   # set passwordless sudo so we can install stuff
   sudo -u $ADMIN_USERNAME ssh $WORKER_NAME$i "echo $ADMIN_PASSWORD | sudo -S sed -i 's/ALL\$/NOPASSWD:ALL/' /etc/sudoers.d/waagent"
done

# Install everything on master node
echo "Installing on master node" >> $DEPLOY_LOG 2>&1
bash $BOOTSTRAP_EXE master >> $DEPLOY_LOG 2>&1

echo "Looping over worker nodes" >> $DEPLOY_LOG 2>&1
for i in $(seq 0 $LAST_VM); do
   worker=$WORKER_NAME$i

   echo "SCP to $worker"  >> $DEPLOY_LOG 2>&1
   sudo -u $ADMIN_USERNAME scp $MUNGEKEY $SLURM_CONF $SLURM_HOSTS $RPM_TAR "/tmp/$BOOTSTRAP_EXE" $worker:/tmp/ >> $DEPLOY_LOG 2>&1

   echo "Remote execute on $worker" >> $DEPLOY_LOG 2>&1
   # update /etc/hosts with slurm nodes, install everything, then disable passwordless sudo
   # have to set MUNGEKEY and SLURM_CONF in block because it's not evaluating the globs for some reason?
sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker << ENDSSH1
    sudo bash -c 'cat $SLURM_HOSTS >> /etc/hosts'
    sudo -E bash /tmp/$BOOTSTRAP_EXE
    sudo sed -i 's/NOPASSWD://' /etc/sudoers.d/waagent
ENDSSH1
done

rm -f $MUNGEKEY
# re-enable password for sudo
sed -i 's/NOPASSWD://' /etc/sudoers.d/waagent

echo "$(date) finished bootstrapping $NUM_OF_VM nodes"
