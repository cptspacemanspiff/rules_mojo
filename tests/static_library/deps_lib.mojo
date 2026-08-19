from std.ffi import c_int, external_call


@export
def double_via_c(x: c_int) abi("C") -> c_int:
    return external_call["helper_double", c_int](x)
