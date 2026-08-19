from std.ffi import c_int


@export
def times_two(x: c_int) abi("C") -> c_int:
    return x * 2
