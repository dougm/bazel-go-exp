"""Register the default compiler separately from Gazelle's dependency-fetch SDK."""

def _sdk_field(build_file, field):
    for line in build_file.splitlines():
        line = line.strip()
        if line.startswith(field + " = "):
            return line.split('"')[1]
    fail("Missing SDK field: " + field)

def _toolchains_repo_impl(ctx):
    sdk_root = ctx.path(ctx.attr.default_sdk).dirname
    sdk_build = ctx.read(sdk_root.get_child("BUILD.bazel"))
    if _sdk_field(sdk_build, "version") != ctx.attr.default_version:
        fail("default_version must match the downloaded default SDK")
    version = ctx.attr.default_version.split(".")
    ctx.file("versions.bzl", "FIND_GO_VERSION = {}\n".format(repr(ctx.attr.find_version)))
    ctx.file("BUILD.bazel", """
load({declarations}, "declare_bazel_toolchains")
package(default_visibility = ["//visibility:public"])
exports_files(["versions.bzl"])
declare_bazel_toolchains(
    go_toolchain_repo = {sdk_repo},
    exec_goos = {goos},
    exec_goarch = {goarch},
    major = {major},
    minor = {minor},
    patch = {patch},
    prerelease = "",
    sdk_name = {sdk_name},
    sdk_type = "remote",
)
""".format(
        declarations = repr(str(Label("@io_bazel_rules_go//go/private:go_toolchain.bzl"))),
        sdk_repo = repr("@@" + ctx.attr.default_sdk.repo_name),
        sdk_name = repr(ctx.attr.default_sdk.repo_name),
        goos = repr(_sdk_field(sdk_build, "goos")),
        goarch = repr(_sdk_field(sdk_build, "goarch")),
        major = repr(version[0]),
        minor = repr(version[1]),
        patch = repr(version[2]),
    ))

_toolchains_repo = repository_rule(
    implementation = _toolchains_repo_impl,
    attrs = {
        "default_sdk": attr.label(mandatory = True),
        "default_version": attr.string(mandatory = True),
        "find_version": attr.string(mandatory = True),
    },
)

def _plugin_toolchains_impl(ctx):
    for module in ctx.modules:
        if module.is_root:
            for config in module.tags.configure:
                _toolchains_repo(
                    name = "plugin_toolchains",
                    default_sdk = config.default_sdk,
                    default_version = config.default_version,
                    find_version = config.find_version,
                )

plugin_toolchains = module_extension(
    implementation = _plugin_toolchains_impl,
    tag_classes = {
        "configure": tag_class(attrs = {
            "default_sdk": attr.label(mandatory = True),
            "default_version": attr.string(mandatory = True),
            "find_version": attr.string(mandatory = True),
        }),
    },
)
