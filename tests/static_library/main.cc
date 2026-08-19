#include <cstdlib>

extern "C" int times_two(int x);

int main() { return times_two(21) == 42 ? EXIT_SUCCESS : EXIT_FAILURE; }
