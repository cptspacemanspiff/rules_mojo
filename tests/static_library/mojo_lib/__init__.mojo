from std.ffi import c_int, external_call


def double_in_c(x: c_int) -> c_int:
    return external_call["helper_double", c_int](x)
