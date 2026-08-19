from std.ffi import c_int

from mojo_lib import double_in_c


@export
def double_via_mojo_lib(x: c_int) abi("C") -> c_int:
    return double_in_c(x)
