"""mojo_binary and mojo_test rule definitions."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain", "use_cpp_toolchain")
load("@build_bazel_rules_android//:link_hack.bzl", "link_hack")  # See link_hack.bzl for details
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_python//python:py_info.bzl", "PyInfo")
load("//mojo:providers.bzl", "MojoInfo")
load(":transitions.bzl", "python_version_transition")
load(":utils.bzl", "MOJO_EXTENSIONS", "collect_mojoinfo", "format_import", "is_exec_config")

_PYTHON_TOOLCHAIN_TYPE = "@rules_python//python:toolchain_type"
_ATTRS = {
    "srcs": attr.label_list(
        allow_files = MOJO_EXTENSIONS,
    ),
    "main": attr.label(
        allow_single_file = MOJO_EXTENSIONS,
        doc = "The main Mojo source file for the target, used to disambiguate when multiple files are passed to srcs.",
    ),
    "copts": attr.string_list(),
    "deps": attr.label_list(
        providers = [[CcInfo], [MojoInfo], [PyInfo]],
    ),
    "data": attr.label_list(allow_files = True),
    "enable_assertions": attr.bool(default = True),
    "env": attr.string_dict(),
    "linkopts": attr.string_list(
        doc = "Additional options to pass to the linker.",
    ),
    "python_version": attr.string(
        doc = "The version of Python to use for this target and all its dependencies.",
    ),
    "additional_compiler_inputs": attr.label_list(
        allow_files = True,
        doc = """\
Additional files to pass to the compiler command line. Files specified here can
then be used in copts with the $(location) function.
""",
    ),
    "_mojo_copts": attr.label(
        default = Label("//:mojo_copt"),
    ),
    "_link_extra_lib": attr.label(
        default = "@bazel_tools//tools/cpp:link_extra_lib",
        providers = [CcInfo],
        doc = """\
Pull in extra libraries passed with @bazel_tools//tools/cpp:link_extra_lib.
This is useful for shared sanitizer libraries which need to have rpaths added
by bazel.
""",
    ),
    "_export_fixits": attr.label(
        default = Label("@rules_mojo//:experimental_export_fixits"),
    ),
}

_TOOLCHAINS = use_cpp_toolchain() + [
    _PYTHON_TOOLCHAIN_TYPE,
]

_EXEC_GROUPS = {
    "mojo_compile": exec_group(toolchains = ["//:toolchain_type"]),
}

def _find_main(name, srcs, main):
    """Finds the main source file from the list of srcs and the main attribute."""
    if main:
        if main not in srcs:
            fail("Main file not found in srcs. Please add '{}' to 'srcs'.".format(main.path))
        return main

    if len(srcs) == 1:
        return srcs[0]

    files_matching_name = []
    main_files = []
    for src in srcs:
        filename_without_extension = paths.split_extension(src.basename)[0]
        if filename_without_extension == name:
            files_matching_name.append(src)
        if filename_without_extension == "main":
            main_files.append(src)
    if len(files_matching_name) == 1:
        return files_matching_name[0]
    if len(main_files) == 1:
        return main_files[0]

    fail("Multiple Mojo files provided, but no main file specified. Please set 'main = \"foo.mojo\"' to disambiguate.")

def _format_include(arg):
    return ["-I", arg.dirname]

def _mojo_binary_test_implementation(ctx, *, shared_library = False, static_library = False):
    cc_toolchain = find_cpp_toolchain(ctx)
    mojo_toolchain = ctx.exec_groups["mojo_compile"].toolchains["//:toolchain_type"].mojo_toolchain_info
    build_env = getattr(ctx.exec_groups["mojo_compile"].toolchains["//:toolchain_type"], "build_env", {})
    runtime_env_extra = getattr(ctx.exec_groups["mojo_compile"].toolchains["//:toolchain_type"], "runtime_env", {})
    extra_runfiles = getattr(ctx.exec_groups["mojo_compile"].toolchains["//:toolchain_type"], "extra_runfiles", [])
    py_toolchain = ctx.toolchains[_PYTHON_TOOLCHAIN_TYPE]

    object_file = ctx.actions.declare_file(ctx.label.name + ".lo")
    args = ctx.actions.args()
    args.add("build")
    args.add("-strip-file-prefix=.")
    args.add("--emit", "object")
    args.add("-o", object_file)
    args.add("--lld-path", mojo_toolchain.lld)

    main = _find_main(ctx.label.name, ctx.files.srcs, ctx.file.main)
    args.add(main)
    root_directory = main.dirname
    for file in ctx.files.srcs:
        if not file.dirname.startswith(root_directory):
            args.add_all([file], map_each = _format_include)

    all_deps = ctx.attr.deps + mojo_toolchain.implicit_deps + ([ctx.attr._link_extra_lib] if ctx.attr._link_extra_lib else [])
    transitive_includes, transitive_mojodeps, ccdeps = collect_mojoinfo(all_deps)
    args.add_all(transitive_includes, map_each = format_import)

    # NOTE: Argument order:
    # 1. Basic functional arguments
    # 2. Mojo toolchain arguments
    # 3. --mojocopt arguments
    # 4. copts = [] arguments
    # 5. Attribute enabled arguments
    args.add_all(mojo_toolchain.copts)

    # Ignore default mojo flags for exec built binaries
    if not is_exec_config(ctx):
        args.add_all(ctx.attr._mojo_copts[BuildSettingInfo].value)
    args.add_all([
        ctx.expand_location(copt, targets = ctx.attr.additional_compiler_inputs)
        for copt in ctx.attr.copts
    ])
    if ctx.attr.enable_assertions:
        args.add("-D", "ASSERT=all")

    output_group_kwargs = {}
    compile_outputs = [object_file]
    if ctx.attr._export_fixits[BuildSettingInfo].value:
        fixits_file = ctx.actions.declare_file(ctx.label.name + ".mojo_fixits.yaml")
        compile_outputs.append(fixits_file)
        output_group_kwargs["mojo_fixits"] = depset([fixits_file])
        args.add("--experimental-export-fixit", fixits_file)

    ctx.actions.run(
        executable = mojo_toolchain.mojo,
        tools = mojo_toolchain.all_tools,
        inputs = depset(ctx.files.srcs + ctx.files.additional_compiler_inputs, transitive = [transitive_mojodeps]),
        outputs = compile_outputs,
        arguments = [args],
        mnemonic = "MojoCompile",
        progress_message = "%{label} compiling mojo object",
        env = {
            "MODULAR_CRASH_REPORTING_ENABLED": "false",
            "MODULAR_MOJO_MAX_COMPILERRT_PATH": "/dev/null",  # Make sure this fails if accessed
            "MODULAR_MOJO_MAX_LINKER_DRIVER": "/dev/null",  # Make sure this fails if accessed
            "MODULAR_MOJO_MAX_LLD_PATH": "/dev/null",  # Make sure this fails if accessed
            "PATH": "/dev/null",  # Avoid using the host's PATH
            "TEST_TMPDIR": ".",
        } | build_env,
        use_default_shell_env = True,
        exec_group = "mojo_compile",
        toolchain = "//:toolchain_type",
        execution_requirements = {
            "supports-path-mapping": "1",
        },
    )

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    object_linking_context = cc_common.create_linking_context(
        linker_inputs = depset([cc_common.create_linker_input(
            owner = ctx.label,
            libraries = depset([
                cc_common.create_library_to_link(
                    actions = ctx.actions,
                    pic_static_library = object_file,
                    alwayslink = True,
                ),
            ]),
        )]),
    )

    # Static library: archive the compiled object into lib<name>.a with the same
    # one-call API cc_library uses.
    #
    # Unlike the binary/shared paths below, there is no link step here
    # (disallow_dynamic_library), so this rule absorbs nothing. Its deps therefore
    # have to be PROPAGATED instead: they ride along in the returned CcInfo and are
    # linked by whoever eventually links this archive. That is what cc_library does,
    # and it is what makes
    #
    #     mojo_static_library -> cc_library -> cc_shared_library
    #
    # produce the same .so -- same DT_NEEDED, same defined symbols -- as passing the
    # same srcs and deps to mojo_shared_library. Going through the static rule must
    # not change what you get.
    if static_library:
        # create_compilation_outputs validates object extensions and rejects
        # mojo's `.lo`; expose the same object under a `.o` name via a symlink.
        object_o = ctx.actions.declare_file(ctx.label.name + ".o")
        ctx.actions.symlink(output = object_o, target_file = object_file)

        # The SAME object fills both the PIC and non-PIC slot: mojo emits
        # position-independent code (the shared/binary path above hands this very
        # object to create_library_to_link as `pic_static_library`, and
        # mojo_shared_library links it into a .so), and it is equally valid in a
        # non-PIC static link. Declaring only one slot means a consumer built for
        # the other one silently sees NO objects -- e.g. under --force_pic an
        # objects-only library drops out of cc_static_library's bundle entirely,
        # yielding an archive with the kernels missing rather than an error.
        compilation_outputs = cc_common.create_compilation_outputs(
            objects = depset([object_o]),
            pic_objects = depset([object_o]),
        )

        # Every dep's linking context, so the consumer's link sees them: the
        # cc_library deps written on this target, the ones propagated through a
        # mojo_library dep, AND the toolchain's implicit_deps (the Modular runtime
        # .so's). That is exactly `ccdeps`, the merged CcInfo collect_mojoinfo
        # already built for the link below -- taking it from there rather than
        # re-walking all_deps is what keeps the static path seeing the same set the
        # shared path links. Propagating costs nothing here: it records edges for
        # the eventual linker rather than linking anything now.
        #
        # propagate_deps = False drops all of them, for an archive meant to be
        # runtime-light: one that depends on nothing but libc and defers every
        # runtime dependency to whoever links the final binary. That only works if
        # the Mojo in it avoids print, strings, raising, and owned-heap containers;
        # otherwise the object keeps its undefined KGEN_CompilerRT_* references and
        # the consumer's link fails (or, into a .so, links clean and fails at load).
        linking_contexts = []
        if ctx.attr.propagate_deps:
            linking_contexts = [ccdeps.linking_context]

        static_linking_context, static_linking_outputs = cc_common.create_linking_context_from_compilation_outputs(
            actions = ctx.actions,
            name = ctx.label.name,
            compilation_outputs = compilation_outputs,
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
            linking_contexts = linking_contexts,
            alwayslink = ctx.attr.alwayslink,
            disallow_dynamic_library = True,
        )
        library = static_linking_outputs.library_to_link
        archive = library.static_library or library.pic_static_library

        # There is no link step here to absorb anything, so runfiles are
        # forwarded rather than staged: `data` on this target, plus whatever the
        # cc deps need at runtime (a shared library a cc_import carries, say),
        # so they reach whoever ends up linking the archive.
        transitive_runfiles = [target[DefaultInfo].default_runfiles for target in ctx.attr.data]
        for target in ctx.attr.deps:
            if CcInfo in target:
                transitive_runfiles.append(target[DefaultInfo].default_runfiles)

        return [
            DefaultInfo(
                files = depset([archive]),
                runfiles = ctx.runfiles(ctx.files.data).merge_all(transitive_runfiles),
            ),
            CcInfo(linking_context = static_linking_context),
            OutputGroupInfo(mojo_object = depset([object_file]), **output_group_kwargs),
        ]

    link_kwargs = {}
    if shared_library:
        link_kwargs["output_type"] = "dynamic_library"
        if ctx.attr.shared_lib_name:
            link_kwargs["main_output"] = ctx.actions.declare_file(ctx.attr.shared_lib_name)  # Only set if name is not using the default logic

    linking_outputs = link_hack(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [object_linking_context, ccdeps.linking_context],
        name = ctx.label.name,
        user_link_flags = ctx.attr.linkopts,
        **link_kwargs
    )

    data = ctx.attr.data
    runfiles = ctx.runfiles(ctx.files.data)
    transitive_runfiles = [
        ctx.runfiles(transitive_files = py_toolchain.py3_runtime.files),
    ]
    if extra_runfiles:
        transitive_runfiles.append(ctx.runfiles(files = extra_runfiles))
    for target in data:
        transitive_runfiles.append(target[DefaultInfo].default_runfiles)

    python_imports = []
    for target in all_deps:
        transitive_runfiles.append(target[DefaultInfo].default_runfiles)

        if PyInfo in target:
            python_imports.append(target[PyInfo].imports)
            transitive_runfiles.append(
                ctx.runfiles(transitive_files = target[PyInfo].transitive_sources),
            )

    # Collect transitive shared libraries that must exist at runtime, including
    # those propagated through mojo_library deps
    transitive_libraries = []
    for linker_input in ccdeps.linking_context.linker_inputs.to_list():
        for library in linker_input.libraries:
            if library.dynamic_library and not library.pic_static_library and not library.static_library:
                transitive_libraries.append(depset([library]))
                transitive_runfiles.append(ctx.runfiles(transitive_files = depset([library.dynamic_library])))

    python_path = ""
    for path in depset(transitive = python_imports).to_list():
        python_path += "../" + path + ":"

    # https://github.com/bazelbuild/rules_python/issues/2262
    libpython = None
    for file in py_toolchain.py3_runtime.files.to_list():
        if file.basename.startswith("libpython"):
            libpython = file.short_path
            break  # if there are multiple any of them should work and they are likely symlinks to each other

    if not libpython:
        fail("failed to find libpython, please report this at https://github.com/modular/rules_mojo/issues")

    default_path = ctx.attr.env.get("PATH") or ctx.configuration.default_shell_env.get("PATH") or "/usr/bin:/bin:/usr/sbin"
    runtime_env = dict(ctx.attr.env) | {
        "MODULAR_PYTHON_EXECUTABLE": py_toolchain.py3_runtime.interpreter.short_path,
        "MOJO_PYTHON": py_toolchain.py3_runtime.interpreter.short_path,
        "MOJO_PYTHON_LIBRARY": libpython,
        "PATH": paths.dirname(py_toolchain.py3_runtime.interpreter.short_path) + ":" + default_path,  # python < 3.11 doesn't set sys.executable correctly when Py_Initialize is called unless it's in the $PATH
        "PYTHONEXECUTABLE": py_toolchain.py3_runtime.interpreter.short_path,
        "PYTHONNOUSERSITE": "affirmative",
        "PYTHONPATH": python_path,
        "PYTHONSAFEPATH": "affirmative",
    }
    runtime_env.update(runtime_env_extra)
    for key, value in runtime_env.items():
        runtime_env[key] = ctx.expand_make_variables(
            "env",
            ctx.expand_location(value, targets = data),
            {},
        )

    if shared_library:
        return [
            DefaultInfo(
                executable = linking_outputs.library_to_link.resolved_symlink_dynamic_library,
                runfiles = runfiles.merge_all(transitive_runfiles),
            ),
            PyInfo(
                imports = depset(["_main/" + paths.dirname(linking_outputs.library_to_link.dynamic_library.short_path)]),
                transitive_sources = depset([linking_outputs.library_to_link.dynamic_library]),
            ),
            CcInfo(
                linking_context = cc_common.create_linking_context(
                    linker_inputs = depset([
                        cc_common.create_linker_input(
                            owner = ctx.label,
                            libraries = depset(
                                [linking_outputs.library_to_link],
                                transitive = transitive_libraries,
                            ),
                        ),
                    ]),
                ),
            ),
            OutputGroupInfo(**output_group_kwargs),
        ]
    else:
        return [
            DefaultInfo(
                executable = linking_outputs.executable,
                runfiles = runfiles.merge_all(transitive_runfiles),
            ),
            RunEnvironmentInfo(
                environment = runtime_env,
            ),
            OutputGroupInfo(**output_group_kwargs),
        ]

mojo_binary = rule(
    implementation = lambda ctx: _mojo_binary_test_implementation(ctx),
    attrs = _ATTRS,
    exec_groups = _EXEC_GROUPS,
    toolchains = _TOOLCHAINS,
    fragments = ["cpp"],
    executable = True,
)

mojo_test = rule(
    implementation = lambda ctx: _mojo_binary_test_implementation(ctx),
    attrs = _ATTRS,
    exec_groups = _EXEC_GROUPS,
    toolchains = _TOOLCHAINS,
    fragments = ["cpp"],
    test = True,
    cfg = python_version_transition,
)

mojo_shared_library = rule(
    implementation = lambda ctx: _mojo_binary_test_implementation(ctx, shared_library = True),
    attrs = _ATTRS | {
        "shared_lib_name": attr.string(
            doc = "The name of the shared library to be created.",
        ),
    },
    exec_groups = _EXEC_GROUPS,
    toolchains = _TOOLCHAINS,
    fragments = ["cpp"],

    # Advertise CcInfo. Not cosmetic: rules_cc reaches its deps through
    # graph_structure_aspect, which is declared `required_providers = [[CcInfo],
    # [CcSharedLibraryHintInfo], [ProtoInfo]]`. An aspect with required_providers
    # is only applied to a dep whose RULE advertises them -- returning CcInfo at
    # analysis time is too late. Without this, cc_shared_library fails with
    # "doesn't contain declared provider 'GraphNodeInfo'" rather than the real
    # diagnostic.
    provides = [CcInfo],
)

mojo_static_library = rule(
    implementation = lambda ctx: _mojo_binary_test_implementation(ctx, static_library = True),
    attrs = _ATTRS | {
        "alwayslink": attr.bool(
            default = True,
            doc = """\
Whether the compiled object is linked into a consumer even when nothing references
it, i.e. -Wl,--whole-archive semantics for this archive. Mirrors cc_library's
attribute of the same name, but defaults to True rather than False.

The default is True because a Mojo library's reason to exist is its @export'd
symbols, and NOTHING INSIDE the archive references them -- the caller is across the
C ABI. The binary/shared paths already mark this same object alwayslink for that
reason. With False, packaging the archive into a .so drops the object entirely and
yields a library that links clean and exports nothing, so a consumer would have to
know to write -Wl,--whole-archive by hand.

Setting False is reasonable for an archive linked into a C/C++ binary that calls it
directly: there the caller's undefined reference pulls the object in anyway, and
False lets a consumer that uses nothing from it pay nothing.

Note this does NOT control per-kernel granularity. `mojo build` emits ONE object per
target, with a monolithic .text and no per-function sections, so referencing any one
@export pulls in every other kernel in the same target regardless of this attribute
(and --gc-sections cannot split it). Split targets, not this flag, if that matters.
""",
        ),
        "propagate_deps": attr.bool(
            default = True,
            doc = """\
Whether this archive's deps ride along in its CcInfo, to be linked by whoever
links the archive.

True (the default) makes the archive behave like any other cc_library: both the
deps written on this target and the toolchain's Mojo runtime reach the consumer's
link, so packaging this into a .so yields the same DT_NEEDED and the same symbols
as building the same sources with mojo_shared_library.

False drops them, for a runtime-light archive that depends on nothing but libc --
a shippable .a an outside build can link against without the Modular runtime .so's
in tow. This only holds if the Mojo in it avoids print, strings, raising, and
owned-heap containers; otherwise its undefined KGEN_CompilerRT_* references become
the consumer's problem, and into a .so that failure is silent until load time.
""",
        ),
    },
    exec_groups = _EXEC_GROUPS,
    toolchains = _TOOLCHAINS,
    fragments = ["cpp"],
    # Advertise CcInfo. Not cosmetic: cc_shared_library reaches its deps through
    # graph_structure_aspect, which is declared `required_providers = [[CcInfo],
    # [CcSharedLibraryHintInfo], [ProtoInfo]]`. An aspect with required_providers is
    # only applied to a dep whose RULE advertises them -- returning CcInfo at
    # analysis time is too late. Without this the aspect is skipped, no GraphNodeInfo
    # is attached, and cc_shared_library either fails outright ("doesn't contain
    # declared provider 'GraphNodeInfo'") or, with a cc_library in between, silently
    # links NOTHING and emits an empty .so.
    provides = [CcInfo],
)
