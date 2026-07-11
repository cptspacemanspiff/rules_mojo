"""Consume a pixi.lock and expose its Mojo packages as Bazel deps.

This is the pixi-flavored convenience layer over the generic `mojo_conda`
primitive -- the analog of rules_python's `pip.parse(requirements_lock=...)`.
`pixi` is the solver (it guarantees a mutually version-compatible compiler +
package set); Bazel only CONSUMES the resolved lock: no conda/pixi/mamba binary
runs during the build.

Usage (MODULE.bazel):

    mojo_pkg = use_extension("@rules_mojo//mojo:conda_lock.bzl", "mojo_pkg")
    mojo_pkg.from_lock(hub = "max_hub", lock = "//:pixi.lock", only = ["max-core"])
    use_repo(mojo_pkg, "max_hub")

    # a different component can pull a DIFFERENT set from another environment:
    mojo_pkg.from_lock(hub = "tooling_hub", lock = "//:pixi.lock",
                       environment = "tooling", only = ["some-mojo-lib"])
    use_repo(mojo_pkg, "tooling_hub")

Then `deps = ["@max//:max-core"]`. Each `from_lock` hub is an isolated repo, so
sets never collide -- one target can depend on `@max//:...` and another on
`@tools//:...` (the rules_python multi-`hub_name` model).
"""

load("//mojo:mojo_conda.bzl", "conda_stem", "fetch_conda")

# Packages that come from the wheel TOOLCHAIN (mojo.toolchain), never re-fetched
# as conda even when they appear as transitive `depends:` of a real library.
_TOOLCHAIN_PKGS = ["mojo", "mojo-compiler", "mojo-python", "mblack"]

# Default Mojo-bearing channels. conda-forge (C/Python runtime deps) is excluded
# so Python/C packages in the lock never convolve with the Mojo dep graph.
_DEFAULT_CHANNELS = ["conda.modular.com", "repo.prefix.dev"]

_PIXI_PLATFORMS = ["linux-64", "linux-aarch64", "osx-arm64"]

# ---------------------------------------------------------------------------
# pixi.lock parsing (targeted, not a general YAML parser -- pixi emits a stable,
# 2-space-indented shape).
# ---------------------------------------------------------------------------

def _pkg_name(url):
    """conda package name from its URL: strip `-<version>-<build>.conda`."""
    stem = conda_stem(url)
    out = []
    for part in stem.split("-"):
        if part and part[0] in "0123456789":  # first version-looking token
            break
        out.append(part)
    return "-".join(out)

def _parse_packages(content):
    """Top-level `packages:` -> {url: struct(sha256, depends=[names])}."""
    marker = "\npackages:\n"
    idx = content.find(marker)
    if idx == -1:
        fail("pixi.lock has no top-level 'packages:' section")
    body = content[idx + len(marker):]

    out = {}
    url = None
    sha = None
    depends = []
    in_depends = False
    for line in body.split("\n"):
        if line.startswith("- conda: "):
            if url:
                out[url] = struct(sha256 = sha, depends = depends)
            url = line[len("- conda: "):].strip()
            sha = None
            depends = []
            in_depends = False
        elif line.startswith("- pypi:") or (line and not line.startswith(" ")):
            # end of the conda packages list (pypi entries or a new section)
            if url:
                out[url] = struct(sha256 = sha, depends = depends)
                url = None
            if line and not line.startswith(" ") and not line.startswith("-"):
                break
        elif line.startswith("  sha256: "):
            sha = line[len("  sha256: "):].strip()
            in_depends = False
        elif line.startswith("  depends:"):
            in_depends = True
        elif in_depends and line.startswith("  - "):
            # "  - mojo-compiler ==1.0.0b3..." -> take the bare name
            depends.append(line[len("  - "):].strip().split(" ")[0])
        elif line.startswith("  ") and not line.startswith("  - "):
            in_depends = False
    if url:
        out[url] = struct(sha256 = sha, depends = depends)
    return out

def _parse_env_urls(content, environment):
    """`environments: <env>: packages: <platform>:` -> {platform: [urls]}."""
    lines = content.split("\n")
    n = len(lines)

    # locate the "  <environment>:" line (Starlark has no while loop, so scan
    # a bounded range and record the index).
    want = "  " + environment + ":"
    start = -1
    for k in range(n):
        if lines[k] == want:
            start = k
            break
    if start == -1:
        fail("environment '%s' not found in pixi.lock" % environment)

    # within this env, platform sub-keys and their conda members sit at 6 spaces.
    out = {}
    platform = None
    for j in range(start + 1, n):
        line = lines[j]
        if line and not line.startswith("  "):
            break  # left the environments section entirely
        if len(line) >= 3 and line[2] != " " and line.endswith(":"):
            break  # next environment
        stripped = line.strip()
        if line.startswith("      - conda: "):
            if platform != None:
                out[platform].append(line[len("      - conda: "):].strip())
        elif line.startswith("      ") and line.rstrip().endswith(":") and not stripped.startswith("- "):
            platform = stripped[:-1]
            out[platform] = []
        elif line.startswith("      - pypi:"):
            pass  # skip pypi members
    return out

# ---------------------------------------------------------------------------
# selection: named roots + transitive Mojo deps, channel-filtered
# ---------------------------------------------------------------------------

def _channel_ok(url, channels):
    for c in channels:
        if c in url:
            return True
    return False

def _select(content, tag):
    pkgs = _parse_packages(content)
    env_urls = _parse_env_urls(content, tag.environment)
    channels = tag.channels or _DEFAULT_CHANNELS
    platforms = tag.platforms or _PIXI_PLATFORMS

    # name -> {platform: (url, sha256)}  and  name -> depends, over Mojo-bearing
    # packages of this environment only. `stem_of` is the platform-INDEPENDENT
    # artifact id (the .conda filename minus suffix; the platform lives in the URL
    # path, not the name) -> used to content-address the per-artifact repo so the
    # same package shared by two hubs collapses to one fetch.
    by_name = {}
    depends_of = {}
    stem_of = {}
    for platform in platforms:
        for url in env_urls.get(platform, []):
            if not _channel_ok(url, channels):
                continue
            name = _pkg_name(url)
            if name in _TOOLCHAIN_PKGS:
                continue
            info = pkgs.get(url)
            if not info:
                continue
            by_name.setdefault(name, {})[platform] = (url, info.sha256)
            depends_of[name] = [d for d in info.depends if d not in _TOOLCHAIN_PKGS]
            stem_of[name] = conda_stem(url)

    # transitive closure from the named roots (or every Mojo package if none named)
    roots = tag.only or by_name.keys()
    wanted = {}
    stack = list(roots)
    for _ in range(1000):  # bounded; Starlark has no while
        if not stack:
            break
        name = stack.pop()
        if name in wanted or name not in by_name:
            continue
        wanted[name] = True
        for d in depends_of.get(name, []):
            if d in by_name and d not in wanted:
                stack.append(d)

    packages = []
    for name in sorted(wanted):
        plats = {}
        for platform, (url, sha) in by_name[name].items():
            plats[platform] = {"urls": [url], "sha256": sha}
        packages.append({
            "name": name,
            "stem": stem_of[name],
            "deps": [d for d in depends_of.get(name, []) if d in wanted],
            "platforms": plats,
        })
    return packages

# ---------------------------------------------------------------------------
# per-ARTIFACT repos + a thin hub of aliases (the rules_python whl_library + hub
# model): each unique .conda gets its OWN content-addressed repo, so a package
# shared by two hubs is fetched exactly once; a hub just aliases into them.
# ---------------------------------------------------------------------------

def _host_pixi_platform(rctx):
    os = rctx.os.name.lower()
    arch = rctx.os.arch.lower()
    if os.startswith("linux"):
        if arch in ["amd64", "x86_64"]:
            return "linux-64"
        if arch in ["aarch64", "arm64"]:
            return "linux-aarch64"
    if os.startswith("mac") or "os x" in os or os.startswith("darwin"):
        if arch in ["aarch64", "arm64"]:
            return "osx-arm64"
    fail("mojo_pkg: unsupported host platform %s/%s" % (os, arch))

_ALNUM = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

def _artifact_repo(stem):
    """Content-addressed repo name for a .conda stem (stable across hubs)."""
    return "mojoconda_" + "".join([c if c in _ALNUM else "_" for c in stem.elems()])

# --- per-artifact repo: fetch one .conda, expose it as `//:pkg` -------------

_ARTIFACT_BUILD = """\
load("@rules_mojo//mojo:mojo_import.bzl", "mojo_import")

mojo_import(
    name = "pkg",
    mojodeps = glob(["lib/mojo/*.mojopkg", "lib/mojo/*.mojoc"], allow_empty = True),
    deps = {deps},
    visibility = ["//visibility:public"],
)
"""

def _conda_artifact_impl(rctx):
    spec = json.decode(rctx.attr.spec)
    pl = spec["platforms"].get(_host_pixi_platform(rctx))

    # deps point at SIBLING artifact repos (same extension) -> shared, not copied.
    deps = ["@{}//:pkg".format(r) for r in spec["deps"]]
    if pl:
        fetch_conda(rctx, pl["urls"], pl["sha256"], into = "")
    else:
        # not published for this host platform: expose an empty (no-op) package.
        rctx.file("lib/mojo/.keep", "")
    rctx.file("BUILD.bazel", _ARTIFACT_BUILD.format(deps = repr(deps)))

_conda_artifact = repository_rule(
    implementation = _conda_artifact_impl,
    doc = "Fetch ONE .conda artifact; expose its lib/mojo/* as //:pkg.",
    attrs = {"spec": attr.string(
        mandatory = True,
        doc = "JSON: {platforms: {pixi_platform: {urls, sha256}}, deps: [artifact_repo_name]}.",
    )},
)

# --- hub: nothing but aliases into the per-artifact repos -------------------

def _conda_hub_impl(rctx):
    aliases = json.decode(rctx.attr.aliases)
    lines = []
    for name in sorted(aliases):
        lines.append(
            'alias(name = "{name}", actual = "@{repo}//:pkg", visibility = ["//visibility:public"])'.format(
                name = name,
                repo = aliases[name],
            ),
        )
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")

_conda_hub = repository_rule(
    implementation = _conda_hub_impl,
    doc = "A dep-set: aliases <pkg name> -> @<artifact repo>//:pkg.",
    attrs = {"aliases": attr.string(mandatory = True, doc = "JSON: {pkg_name: artifact_repo_name}.")},
)

# ---------------------------------------------------------------------------
# module extension
# ---------------------------------------------------------------------------

_from_lock = tag_class(
    doc = "Materialize one dep-set (hub) from a pixi.lock environment.",
    attrs = {
        "hub": attr.string(mandatory = True, doc = "Repo name for this dep-set (@<hub>//:<pkg>)."),
        "lock": attr.label(mandatory = True, doc = "The pixi.lock to read."),
        "environment": attr.string(default = "default", doc = "pixi environment (dep-set) to read."),
        "only": attr.string_list(
            default = [],
            doc = "Expose ONLY these package names (+ their transitive Mojo deps). Empty = every Mojo pkg in the env.",
        ),
        "channels": attr.string_list(
            default = [],
            doc = "URL substrings marking Mojo-bearing channels (default: modular channels).",
        ),
        "platforms": attr.string_list(
            default = [],
            doc = "pixi platforms to resolve (default: linux-64, linux-aarch64, osx-arm64).",
        ),
    },
)

def _mojo_pkg_impl(mctx):
    created = {}  # artifact_repo_name -> True (global dedup across all hubs)
    for mod in mctx.modules:
        for tag in mod.tags.from_lock:
            content = mctx.read(mctx.path(tag.lock))
            packages = _select(content, tag)

            # name -> artifact repo, for this dep-set (deps resolve within it).
            repo_of = {p["name"]: _artifact_repo(p["stem"]) for p in packages}

            for p in packages:
                repo = repo_of[p["name"]]
                if repo not in created:
                    created[repo] = True
                    _conda_artifact(
                        name = repo,
                        spec = json.encode({
                            "platforms": p["platforms"],
                            "deps": [repo_of[d] for d in p["deps"]],
                        }),
                    )

            _conda_hub(
                name = tag.hub,
                aliases = json.encode(repo_of),
            )
    return mctx.extension_metadata(reproducible = True)

mojo_pkg = module_extension(
    doc = "Expose pixi.lock-resolved Mojo packages as Bazel deps (no conda tooling).",
    implementation = _mojo_pkg_impl,
    tag_classes = {"from_lock": _from_lock},
)
