/* stdio.h -- minimal bare-metal stand-in. coremark.h includes <stdio.h> but with HAS_STDIO=0
 * nothing from it is used (CoreMark prints through its own ee_printf). */
#pragma once

#include <stddef.h>
