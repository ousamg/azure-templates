#!/bin/bash -e

set +f
if [[ -z $1 ]]; then
    NODE_TYPE=worker
else
    NODE_TYPE=$1
fi

if [[ "$NODE_TYPE" != "worker" ]] && [[ "$NODE_TYPE" != "master" ]]; then
    echo "Invalid NODE_TYPE: '$NODE_TYPE'"
    exit 1
fi

# set up munge/slurm users
export MUNGEUSER=991
groupadd -g $MUNGEUSER munge
useradd  -m -c "MUNGE Uid 'N' Gid Emporium" -d /var/lib/munge -u $MUNGEUSER -g munge  -s /sbin/nologin munge
export SLURMUSER=992
groupadd -g $SLURMUSER slurm
useradd  -m -c "SLURM workload manager" -d /var/lib/slurm -u $SLURMUSER -g slurm  -s /bin/bash slurm

# install munge
yum install epel-release -y
yum install -y munge-devel munge-libs munge
if [[ "$NODE_TYPE" == "master" ]]; then
    /usr/sbin/create-munge-key -r
fi

# Install slurm deps and munge
yum install openssl openssl-devel pam-devel numactl numactl-devel hwloc hwloc-devel lua lua-devel \
    readline-devel rrdtool-devel ncurses-devel man2html libibmad libibumad rpm-build gcc perl-ExtUtils-MakeMaker \
    mariadb-server mariadb-devel -y

# use pre-set value inherited from azuredeploy.sh if running on master node
RPM_TAR=${RPM_TAR:-/tmp/slurm-rpms.tar}
if [[ "$NODE_TYPE" == "master" ]]; then
    # grab slurm, convert to rpm, and install
    SLURM_VERSION=18.08.5-2     # pinned to TSD version
    SLURM_URL=https://download.schedmd.com/slurm
    SLURM_PKG=slurm-${SLURM_VERSION}.tar.bz2
    RPM_DIR=/rpmbuild/RPMS/x86_64
    wget "$SLURM_URL/$SLURM_PKG" -O "/tmp/$SLURM_PKG"
    rpmbuild -ta "/tmp/$SLURM_PKG" >> /tmp/rpmbuild.log.$$ 2>&1
    tar -C $RPM_DIR -cvf $RPM_TAR .
else
    if [[ ! -f $RPM_TAR ]]; then
        echo "No slurm rpm tar found: '$RPM_TAR'"
        exit 1
    fi
    mkdir rpms
    tar -C rpms -xf $RPM_TAR
    RPM_DIR=$PWD/rpms
fi
yum localinstall $RPM_DIR/*.rpm -y

# Download slurm.conf and fill in the node info
if [[ "$NODE_TYPE" == "master" ]]; then
    wget $TEMPLATE_BASE/slurm.template.conf -O $SLURM_CONF
    sed -i -- 's/__MASTERNODE__/'"$MASTER_NAME"'/g' $SLURM_CONF
    sed -i -- 's/__WORKERNODES__/'"$WORKER_NAME"'[0-'"$LAST_VM"']/g' $SLURM_CONF
else
    # have to use ls because glob isn't expanding on ssh execution
    SLURM_CONF=$(ls /tmp/slurm.conf.*)
    if [[ ! -f $SLURM_CONF ]]; then
        echo "No slurm.conf found: '$SLURM_CONF'"
        exit 1
    fi
fi
cp -f $SLURM_CONF /etc/slurm/slurm.conf
chown slurm. /etc/slurm/slurm.conf

# set up log and pid dirs
SLURM_DIRS="/var/spool/slurmctld /var/spool/slurmd /var/log/slurm"
mkdir -p $SLURM_DIRS
chmod 755 $SLURM_DIRS
chown -R slurm. $SLURM_DIRS

echo "Prepare the local copy of munge key"
if [[ "$NODE_TYPE" == "master" ]]; then
    cp -f /etc/munge/munge.key $MUNGEKEY
    chown ${ADMIN_USERNAME}. $MUNGEKEY
else
    # have to use ls because glob isn't expanding on ssh execution
    MUNGEKEY=$(ls /tmp/munge.key.*)
    if [[ ! -f $MUNGEKEY ]]; then
        echo "No munge.key found: '$MUNGEKEY'"
        exit 1
    fi
    mv -f $MUNGEKEY /etc/munge/munge.key
    chown munge. /etc/munge/munge.key
fi

# start services
if [[ "$NODE_TYPE" == "master" ]]; then
    systemctl enable slurmctld.service
    systemctl start slurmctld.service
fi
systemctl enable munge
systemctl start munge
systemctl enable slurmd.service
systemctl start slurmd.service
