"""Fetch a single conda package and expose its Mojo payload as a mojo_import.

This is the generic, pixi-agnostic primitive: given a `.conda` artifact URL and
its sha256, it downloads the archive with Bazel's native downloader (NO conda /
pixi / mamba binary), extracts the Mojo packages it ships under `lib/mojo/`, and
emits a `mojo_import` target other Mojo rules can depend on.

A `.conda` file is a plain zip (stored) wrapping two zstd tarballs:
    <name>-<ver>-<build>.conda   (zip)
      ├─ info-<name>-<ver>-<build>.tar.zst   (metadata; ignored)
      ├─ pkg-<name>-<ver>-<build>.tar.zst     (payload: lib/mojo/*.mojoc|*.mojopkg)
      └─ metadata.json
Bazel 7+ extracts `.tar.zst` natively, so the whole thing is tool-free.

Mojo packages ship as either `.mojopkg` (portable, non-elaborated) or `.mojoc`
(precompiled, LOCKED to a specific compiler version). Version compatibility is
NOT policed here -- that is the resolver's job (pixi only locks a mutually
compatible compiler + package set). See //third_party/rules_mojo docs.
"""

load("@rules_mojo//mojo:mojo_import.bzl", "mojo_import")

def conda_stem(url):
    """Basename of a `.conda` `url` with the suffix removed (the package stem)."""
    name = url.rsplit("/", 1)[-1]
    if not name.endswith(".conda"):
        fail("expected a .conda URL, got: " + url)
    return name[:-len(".conda")]

def fetch_conda(rctx, urls, sha256, into, member = "pkg"):
    """Download a .conda and extract one of its inner tarballs under `into/`.

    A .conda is a zip wrapping zstd tarballs; extract the outer zip then the
    inner `<member>-<stem>.tar.zst`. `member="pkg"` yields `into/lib/mojo/*`
    (the payload); `member="info"` yields `into/info/recipe/recipe.yaml` etc.
    (the rattler-build metadata). Tool-free (Bazel's native zip/zstd).
    """
    stem = conda_stem(urls[0])
    archive = "{}/{}.conda".format(into, stem) if into else stem + ".conda"

    # sha256-verified download; two explicit extracts (Bazel can't reach the
    # inner tarball in one download_and_extract).
    rctx.download(url = urls, output = archive, sha256 = sha256)
    rctx.extract(archive, output = into, type = "zip")
    inner = "{}-{}.tar.zst".format(member, stem)
    rctx.extract("{}/{}".format(into, inner) if into else inner, output = into)

def _mojo_conda_repository_impl(rctx):
    fetch_conda(rctx, rctx.attr.urls, rctx.attr.sha256, into = "")

    # Emit the mojo_import over whatever Mojo packages this conda shipped.
    rctx.file("BUILD.bazel", _BUILD_TEMPLATE.format(
        name = rctx.attr.mojo_name,
        deps = repr(rctx.attr.deps),
    ))

_BUILD_TEMPLATE = """\
load("@rules_mojo//mojo:mojo_import.bzl", "mojo_import")

mojo_import(
    name = "{name}",
    # A package ships EITHER .mojopkg (portable) or .mojoc (precompiled), so
    # allow_empty -- requiring both patterns to match would reject either form.
    mojodeps = glob(["lib/mojo/*.mojopkg", "lib/mojo/*.mojoc"], allow_empty = True),
    deps = {deps},
    visibility = ["//visibility:public"],
)

# Alias so `@<repo>//:pkg` and the conda package name both resolve.
alias(name = "pkg", actual = ":{name}", visibility = ["//visibility:public"])
"""

mojo_conda_repository = repository_rule(
    implementation = _mojo_conda_repository_impl,
    doc = "Fetch one .conda artifact and expose its lib/mojo/* as a mojo_import.",
    attrs = {
        "urls": attr.string_list(
            mandatory = True,
            doc = "Mirror URLs for the .conda artifact (first is canonical).",
        ),
        "sha256": attr.string(
            mandatory = True,
            doc = "sha256 of the .conda artifact (matches conda repodata/pixi.lock).",
        ),
        "mojo_name": attr.string(
            mandatory = True,
            doc = "Target name for the mojo_import (usually the conda package name).",
        ),
        "deps": attr.string_list(
            default = [],
            doc = "Labels of other mojo_conda_repository targets this package needs.",
        ),
    },
)
