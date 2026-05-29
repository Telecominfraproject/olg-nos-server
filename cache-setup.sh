#!/bin/bash

# Get EVE revision/version
eve_ver="$1"
if [ -z "$eve_ver" ]; then
    echo "Error: EVE revision not passed in"
    exit 1
fi

# Setup download/build cache dir
if [ ! -L dist ]; then
    [ ! -d ../cache/$eve_ver/dist ] && mkdir -p ../cache/$eve_ver/dist
    ln -s ../cache/$eve_ver/dist dist
fi
