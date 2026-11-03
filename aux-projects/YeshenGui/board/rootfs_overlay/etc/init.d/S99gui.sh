#!/bin/sh
# YeshenGui optional autostart (Plan Task 14).
# Only starts when the explicit flag exists; the default Phase S boot keeps
# the getty on the serial console and never spawns the GUI by itself.
if [ -f /etc/y1gui.autostart ] && [ -x /root/gui/yshell ]; then
    /root/gui/yshell --demo >/dev/null 2>&1 &
    echo "YGUI-AUTOSTART pid=$!" > /dev/kmsg 2>/dev/null
fi
