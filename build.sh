#!/bin/bash

setup_only=0
skip_sm_init=0
is_release=0
BUILD_DIR="${PWD}/eve"

SubmoduleInit() {
    if [ ! -f .gitmodules ]; then
        return 0
    fi
    if git submodule status | grep -q '^[+-]'; then
        git submodule init
    fi
    git submodule update --remote --merge --recursive
}

# We should exit immediately as soon as any command fails
set -e

# Required arguments
if [ "$1" == "--sm-init-only" ]; then
    SubmoduleInit
    exit 0
fi
if [ "$1" == "--skip-sm-init" ]; then
    let skip_sm_init=1
    shift
fi
if [ "$1" == "--setup-only" ]; then
    let setup_only=1
    shift
fi
if [ -z "$1" ]; then
    echo "Usage: ./build.sh [--setup-only] <profile name>"
    exit 1
fi
TARGET="$1"
if [ "$2" == "1" ]; then
    let is_release=1
fi

# Check Target
if [ ! -f profiles/${TARGET}.yml ] && [ ! -f ${BUILD_DIR}/profiles/${TARGET}.yml ]; then
    echo "Error: profiles/${TARGET}.yml not found (checked repo and eve checkout)"
    exit 1
fi

# Check submodules
if [ $skip_sm_init -eq 0 ]; then
    SubmoduleInit
fi

# Setup version string
dt=`date '+%Y%m%d%H%M%S'`
id=`git log --format="%h" -n 1`
if [ $is_release -eq 0 ]; then
	export OLG_VERSION="olg-eve-dev-$dt-SHA-$id"
else
	export OLG_VERSION="olg-eve-$dt-SHA-$id"
fi
build_version=`echo $OLG_VERSION | sed 's/ /_/g'`

# Handle target-specific patches (applied directly to the eve checkout)
t_applied=""
if [ -f target-patches/applied ]; then
    t_applied="$(<target-patches/applied)"
fi
if [ "${TARGET}" != "${t_applied}" ]; then
    if [ -n "${t_applied}" ]; then
        tpatches="$(ls target-patches/${t_applied}/*.patch 2>/dev/null | sort -n)"
        if [ -n "${tpatches}" ]; then
            echo "##### Reversing target-specific patches from last target: ${t_applied} #####"
            for x in ${tpatches}; do
                (cd ${BUILD_DIR} && patch -p1 -R) < $x || exit 1
            done
        fi
    fi

    tpatches="$(ls target-patches/${TARGET}/*.patch 2>/dev/null | sort -n)"
    if [ -n "${tpatches}" ]; then
        echo "##### Applying target-specific patches for ${TARGET} #####"
        for x in ${tpatches}; do
            (cd ${BUILD_DIR} && patch -p1) < $x || exit 1
        done
    fi
    echo "${TARGET}" > target-patches/applied
fi

# Setup EVE environment
if [ ! -f ${BUILD_DIR}/Makefile ]; then
	python3 setup.py --setup
else
	python3 setup.py --rebase
fi

# Image type: qemu profile boots as a live image; other targets get installers
case "${TARGET}" in
    qemu) IMAGE_TARGET=live ;;
    *)    IMAGE_TARGET=installer ;;
esac

echo
if [ $setup_only -eq 1 ] ; then
    echo "Build environment setup: ${BUILD_DIR}"
    echo "To compile run inside ${BUILD_DIR}:"
    echo "  make pkg/pillar"
    echo "  make pkg/lps"
    echo "  make HV=kvm ROOTFS_VERSION=snapshot LPS_PROFILE=${TARGET} ${IMAGE_TARGET}"
else
    echo "#################### Building $build_version for $TARGET (${IMAGE_TARGET}) ####################"

    cd $BUILD_DIR
    make pkg/pillar
    make pkg/lps
    make HV=kvm ROOTFS_VERSION=snapshot LPS_PROFILE=${TARGET} ${IMAGE_TARGET}
    cd -
fi
