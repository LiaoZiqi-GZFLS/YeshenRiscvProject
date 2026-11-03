/* math.h -- minimal bare-metal stand-in. CoreMark only needs modf (used by cvt.c). */
#pragma once

double modf(double x, double *iptr);
