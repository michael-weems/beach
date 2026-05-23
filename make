#!/usr/bin/env bash

debug="$1"

source ./build_shaders
source ./build_odin

test -f ${bin} || exit 1

if [[ -z "${debug}" ]]; then
  ${bin} ./assets/audio
else
  raddbg ${bin} ./assets/audio
fi

