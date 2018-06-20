#!/bin/bash

NORMAL='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'

LOG() {
  COLOR="$1"
  TEXT="$2"
  echo -e "${COLOR}$TEXT ${NORMAL}"
}

geth_revision=60516c83b011998e20d52e2ff23b5c89527faf83
geth_url=https://github.com/iolitelabs/go-ethereum.git
geth_dir=go-ethereum

iolite_branch=iolite
iolite_patch=iolite.patch.diff

command -v go >/dev/null 2>&1 || { LOG $RED "Go is not installed. Refer to the official documentation: https://golang.org/doc/install"; exit 1; }
LOG $GREEN "Go is installed. Move on"

git clone ${geth_url} 2>&1 || { LOG $RED "Clean up your working directory"; exit 1; }
LOG $GREEN "Repository is cloned"

pushd ${geth_dir}
  git checkout -b ${iolite_branch} ${geth_revision} 2>&1 || { LOG $RED "Check the specified revision"; exit 1; }
  LOG $GREEN "iOlite branch created"
  git apply ../${iolite_patch} 2>&1 || { LOG $RED "Cannot apply patch"; exit 1; }
  LOG $GREEN "iOlite patch applied"

  make geth 2>&1 || { LOG $RED "Build failed"; exit 1; }
  LOG $GREEN "Build success"
popd
