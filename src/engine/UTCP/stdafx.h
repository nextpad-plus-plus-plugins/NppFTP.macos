// UTCP precompiled header — macOS port.
// The Win32/Winsock surface is provided by the compat shim.
#include "win_compat.h"

#include <algorithm>
#include <string>

// UTCP relies on char-typed isspace/isdigit so high (>127) bytes in directory
// listings don't sign-extend into undefined behaviour. Keep these overloads.
inline bool isspace(char c) {
    return (c == ' ' || c == '\n' || c == '\r' || c == '\t');
}

inline bool isdigit(char c) {
    return (c >= '0' && c <= '9');
}
