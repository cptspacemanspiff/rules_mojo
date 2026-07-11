"""Fetch a hermetic pixi binary so `pixi.lock` can be (re)generated without any
host-installed pixi -- the analog of rules_uv shipping a hermetic `uv`.

Following rules_uv's logic and style, the pixi binary is pinned by a LOCKFILE
(not a version string): `pixi.lock.json` uses the rules_multitool schema -- a
per-platform list of `{url, sha256, os, cpu, file}`. The `pixi` extension reads
it, selects the entry matching the build host, and downloads that one binary.

Override the version by pointing the extension at your own lockfile -- exactly
how rules_uv's `multitool.hub(lockfile = ...)` works:

    pixi = use_extension("@rules_mojo//mojo:pixi.bzl", "pixi")
    pixi.download(lockfile = "//tools:my_pixi.lock.json")   # optional
    use_repo(pixi, "pixi")

To bump the default: edit pixi.lock.json's urls + sha256s (GitHub exposes each
release asset's sha256 as its `digest`). No .bzl change needed.
"""

_DEFAULT_LOCKFILE = Label("//mojo:pixi.lock.json")

def _host_os_cpu(rctx):
    """(os, cpu) in the lockfile's vocabulary (matches rules_multitool)."""
    name = rctx.os.name.lower()
    arch = rctx.os.arch.lower()

    if name.startswith("linux"):
        os = "linux"
    elif name.startswith("mac") or "os x" in name or name.startswith("darwin"):
        os = "macos"
    else:
        fail("pixi: unsupported host OS %s" % name)

    if arch in ["amd64", "x86_64"]:
        cpu = "x86_64"
    elif arch in ["aarch64", "arm64"]:
        cpu = "arm64"
    else:
        fail("pixi: unsupported host CPU %s" % arch)

    return os, cpu

def _pixi_repo_impl(rctx):
    lock = json.decode(rctx.read(rctx.path(rctx.attr.lockfile)))
    binaries = lock.get("pixi", {}).get("binaries")
    if not binaries:
        fail("pixi: lockfile %s has no 'pixi.binaries'" % rctx.attr.lockfile)

    os, cpu = _host_os_cpu(rctx)
    match = None
    for binary in binaries:
        if binary["os"] == os and binary["cpu"] == cpu:
            match = binary
            break
    if not match:
        fail("pixi: no binary for %s/%s in %s" % (os, cpu, rctx.attr.lockfile))

    rctx.download_and_extract(
        url = match["url"],
        sha256 = match["sha256"],
        type = "tar.gz",
    )
    rctx.file(
        "BUILD.bazel",
        'exports_files(["{}"], visibility = ["//visibility:public"])\n'.format(match["file"]),
    )

_pixi_repo = repository_rule(
    implementation = _pixi_repo_impl,
    doc = "Download the host-matching pixi binary named in a multitool-schema lockfile.",
    attrs = {"lockfile": attr.label(mandatory = True, allow_single_file = True)},
)

_download = tag_class(attrs = {
    "lockfile": attr.label(
        default = _DEFAULT_LOCKFILE,
        allow_single_file = True,
        doc = "rules_multitool-schema lockfile pinning the pixi binary. Override to change version.",
    ),
})

def _pixi_impl(mctx):
    lockfile = _DEFAULT_LOCKFILE
    for mod in mctx.modules:
        for tag in mod.tags.download:
            lockfile = tag.lockfile
    _pixi_repo(name = "pixi", lockfile = lockfile)
    return mctx.extension_metadata(reproducible = True)

pixi = module_extension(
    doc = "Downloads a hermetic pixi binary (pinned by a lockfile) as @pixi//:pixi.",
    implementation = _pixi_impl,
    tag_classes = {"download": _download},
)
