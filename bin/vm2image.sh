#!/bin/bash -e

function usage() {
    if [[ ! -z $1 ]]; then
        echo -e "\n\t$1"
    fi
    echo
    echo "  usage: $0 < resource_group source_vm destination_image >"
    echo
    echo "where:"
    echo "resource_group:       the resource group the VM exists in"
    echo "source_vm:            the name of the VM to be converted to an image"
    echo "destination_image:    the name for the newly created image"
    echo
    echo "e.g.,    $0 my-resource-group some-vm new-image"
    echo

    exit 1
}

function err_msg() {
    >&2 echo "ERROR: $1"
    if [[ ! -z $2 ]]; then
        exit $2
    fi
}

AZ=$(which az) || err_msg "ERROR: no azure-cli (az) found, check your PATH" 1

if [[ "$1" =~ ^-*help$ ]]; then
    usage
elif [[ $# -ne 3 ]]; then
    usage "ERROR: invalid number of arguments"
fi

RESOURCE_GROUP=$1
VM_NAME=$2
IMAGE_NAME=$3

$AZ vm deallocate \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    || err_msg "Failed to deallocate VM '$VM_NAME': exit code $?" $?

$AZ vm generalize \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    || err_msg "Failed to generalize VM '$VM_NAME': exit code $?" $?

$AZ image create \
    --resource-group $RESOURCE_GROUP \
    --name $IMAGE_NAME \
    --source $VM_NAME \
    || echo "Failed to create new image '$IMAGE_NAME' from '$VM_NAME': exit code $?" $?
