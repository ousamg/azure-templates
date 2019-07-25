#!/bin/bash -e

# This script can be found on https://github.com/ous/azure-templates/blob/master/slurm/azuredeploy.sh
# This script is part of azure deploy ARM template
# This script will install SLURM on a CentOS 7 cluster deployed on a set of Azure VMs

# Parameters
export MASTER_NAME=$1
export WORKER_NAME=$2
export TEMPLATE_BASE=$3

export DEPLOY_LOG=/tmp/azuredeploy.log.$$
export SLURM_HOSTS=/tmp/hosts.$$

# Software versions
JAVA_VERSION=1.8.0

SLURM_VERSION=18.08.5-2     # pinned to TSD
SLURM_URL=https://download.schedmd.com/slurm
SLURM_PKG=slurm-${SLURM_VERSION}.tar.bz2

SINGULARITY_VERSION=2.6.1
SINGULARITY_URL=https://github.com/singularityware/singularity/releases/download/${SINGULARITY_VERSION}
SINGULARITY_PKG=singularity-${SINGULARITY_VERSION}.tar.gz

R_VERSION=3.3.2
R_URL=https://cran.r-project.org/src/base/R-3/
R_PKG=R-${R_VERSION}.tar.gz

# install functions
is_master() {
    hostname | grep "$MASTER_NAME"
    return $?
}

install_prereqs() {
    yum install epel-release -y
    yum install -y openssl openssl-devel pam-devel numactl numactl-devel hwloc hwloc-devel lua lua-devel \
        readline-devel rrdtool-devel ncurses-devel man2html libibmad libibumad gcc gcc-c++ gcc-gfortrain \
        perl-ExtUtils-MakeMaker mariadb-server mariadb-devel nfs-utils java-${JAVA_VERSION}-openjdk \
        java-${JAVA_VERSION}-openjdk-devel libarchive-devel squashfs-tools rpm-build bzip2-devel xz-devel

    wget $SINGULARITY_URL/$SINGULARITY_PKG
    tar xvf $SINGULARITY_PKG
    pushd singularity-${SINGULARITY_VERSION}
    ./configure --prefix=/usr/local
    make && make install
    popd

    echo "Succesfully installed singularity v$(singularity --version)"

    wget $R_URL/$R_PKG
    tar xvf $R_PKG
    pushd R-${R_VERSION}
    export JAVA_HOME=/etc/alternatives/java_sdk
    ./configure --with-x=no CFLAGS="-mtune=native -g -O2"
    make
    make install
    popd

    echo "Successfully installed $(R --version | head -1)"
}

install_munge() {
    MUNGE_UID=991
    MUNGE_USER=munge
    MUNGE_GROUP=munge
    groupadd -g $MUNGE_UID $MUNGE_GROUP
    useradd -m -c "MUNGE Uid 'N' Gid Emporium" -d /var/lib/munge -u $MUNGE_UID -g $MUNGE_GROUP  -s /sbin/nologin $MUNGE_USER

    yum install -y munge-devel munge-libs munge
    systemctl enable munge
}

install_slurm() {
    SLURM_UID=992
    SLURM_USER=slurm
    SLURM_GROUP=slurm
    SLURM_RPMS=$(pwd)/slurm-rpms
    groupadd -g $SLURM_UID $SLURM_GROUP
    useradd  -m -c "SLURM workload manager" -d /var/lib/slurm -u $SLURM_UID -g $SLURM_GROUP -s /bin/bash $SLURM_USER

    SLURM_DIRS="/var/spool/slurmctld /var/spool/slurmd /var/log/slurm"
    mkdir -p $SLURM_DIRS
    chmod 755 $SLURM_DIRS
    chown -R $SLURM_USER:$SLURM_GROUP $SLURM_DIRS

    wget $SLURM_URL/$SLURM_PKG
    rpmbuild -ta $SLURM_PKG --define "_rpmdir $SLURM_RPMS"
    yum localinstall -y $SLURM_RPMS/x86_64/*.rpm


    if is_master; then
        systemctl enable slurmctld.service
    else
        systemctl enable slurmd.service
    fi
}

# Ready go!
###################################

date > $DEPLOY_LOG 2>&1
echo "$@" >> $DEPLOY_LOG 2>&1
pwd >> $DEPLOY_LOG 2>&1

# Usage
if [ "$#" -ne 9 ]; then
  echo "Usage: $0 MASTER_NAME MASTER_IP WORKER_NAME WORKER_IP_BASE WORKER_IP_START NUM_OF_VM ADMIN_USERNAME ADMIN_PASSWORD TEMPLATE_BASE" >> $DEPLOY_LOG
  exit 1
fi

install_prereqs >> $DEPLOY_LOG 2>&1

install_munge >> $DEPLOY_LOG 2>&1

install_slurm >> $DEPLOY_LOG 2>&1

echo "$(date) Completed provisioning node $(hostname)" >> $DEPLOY_LOG 2>&1
