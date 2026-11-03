#!/bin/bash

FLAGS="-undef"

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
source $SCRIPTPATH/configs/$1.sh

doit() {
  cpp -E -P  $FLAGS $1 | sed -e 's/##/#/' > $2
}

doit $SCRIPTPATH/configs/naxmini_raw_defconfig   $SCRIPTPATH/configs/naxmini_defconfig
doit $SCRIPTPATH/boards/naxmini/linux/linux_raw.config  $SCRIPTPATH/boards/naxmini/linux/linux.config
doit $SCRIPTPATH/boards/naxmini/linux/linux_raw.dts   $SCRIPTPATH/boards/naxmini/linux/linux.dts
doit $SCRIPTPATH/boards/naxmini/opensbi/config_raw.mk  $SCRIPTPATH/boards/naxmini/opensbi/config.mk
