"""A rule for creating static libraries written in Mojo."""

load("//mojo/private:mojo_binary_test.bzl", _mojo_static_library = "mojo_static_library")

mojo_static_library = _mojo_static_library
