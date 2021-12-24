#!/bin/bash
export OS="ULOS"
export DATE="$(date +%y.%m)"
export ULOSREL="1.7"
export ULOSVERSION="$OS $DATE-$ULOSREL"
export PREPROCESSOR="$PWD/utils/preproc.lua"
