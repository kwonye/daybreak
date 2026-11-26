#include <stdbool.h>

/// Extracts an untrusted ZIP into an existing, private, empty directory.
bool evergreen_extract_zip(const char *source, const char *destination);
