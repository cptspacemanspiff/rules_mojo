#include <cstdlib>

// The cc dep is declared on the mojo_library, not on the mojo_static_library
// this links, and not here.
extern "C" int double_via_mojo_lib(int x);

int main() { return double_via_mojo_lib(21) == 42 ? EXIT_SUCCESS : EXIT_FAILURE; }
