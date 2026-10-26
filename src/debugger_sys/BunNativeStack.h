#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Returns an owned string, or null on allocation failure. */
char* dumpBtjsTrace(void);
void freeBtjsTrace(char* trace);

#ifdef __cplusplus
}
#endif
