#include <cstdlib>

// Only double_via_c is called here; helper_double resolves at link time solely
// because the cc dep propagated out of the mojo_static_library.
extern "C" int double_via_c(int x);

int main() { return double_via_c(21) == 42 ? EXIT_SUCCESS : EXIT_FAILURE; }
