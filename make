#!/usr/bin/env bash

[ -f beach ] && rm beach
odin build . -debug
./beach $HOME/audio/field
