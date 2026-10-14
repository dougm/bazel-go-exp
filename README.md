# kubectl-plugins: Bazel / Go dependency isolation experiment

Source code cloned from:

- https://github.com/feloy/kubectl-service-tree
- https://github.com/ahmetb/kubectl-tree
- https://github.com/steveteuber/kubectl-graph
- https://github.com/alikhil/kubectl-find

Uses Bzlmod (MODULE.bazel), Bazel 9.3.0, rules_go 0.64.2, Gazelle 0.54.0,
and downloaded Go 1.26.0 and Go 1.27.2 SDKs. A host Go installation is not
needed to build. Find compiles with Go 1.27.2; the other plugins use Go 1.26.0.
The MODULE.bazel.lock files record Bazel module resolution; go.sum files
provide checksums for Go dependencies.

## tl;dr

Using `go version -m` to compare versions used to build the plugin binaries:

```console
% bazel run //:version-compare
...
Module                          kubectl-find                        kubectl-graph                       kubectl-service-tree                kubectl-tree
------------------------------  ----------------------------------  ----------------------------------  ----------------------------------  ----------------------------------
Isolation                       True                                False                               True                                False
Go compiler                     go1.27.2                            go1.26.0                            go1.26.0                            go1.26.0
k8s.io/api                      v0.38.0-alpha.2                     v0.37.1                             v0.0.0-20190313235455-40a48860b5ab  v0.37.1
k8s.io/apiextensions-apiserver  v0.37.1                             —                                   —                                   —
k8s.io/apimachinery             v0.38.0-alpha.2                     v0.37.1                             v0.0.0-20190313205120-d7deff9243b1  v0.37.1
k8s.io/kube-openapi             v0.0.0-20260929181212-2cfbdf149b9a  v0.0.0-20260721132016-d427ff9ee9ad  v0.0.0-20190816220812-743ec37842bf  v0.0.0-20260721132016-d427ff9ee9ad
```

Changing `DEFAULT_GO_VERSION="1.27.2"` in MODULE.bazel and `isolate = False` kubectl-find/MODULE.bazel, puts all but kubectl-service-tree on the same versions:

```console
% bazel run //:version-compare
...
Module                          kubectl-find                        kubectl-graph                       kubectl-service-tree                kubectl-tree
------------------------------  ----------------------------------  ----------------------------------  ----------------------------------  ----------------------------------
Isolation                       False                               False                               True                                False
Go compiler                     go1.27.2                            go1.27.2                            go1.27.2                            go1.27.2
k8s.io/api                      v0.38.0-alpha.2                     v0.38.0-alpha.2                     v0.0.0-20190313235455-40a48860b5ab  v0.38.0-alpha.2
k8s.io/apiextensions-apiserver  v0.37.1                             —                                   —                                   —
k8s.io/apimachinery             v0.38.0-alpha.2                     v0.38.0-alpha.2                     v0.0.0-20190313205120-d7deff9243b1  v0.38.0-alpha.2
k8s.io/kube-openapi             v0.0.0-20260929181212-2cfbdf149b9a  v0.0.0-20260929181212-2cfbdf149b9a  v0.0.0-20190816220812-743ec37842bf  v0.0.0-20260929181212-2cfbdf149b9a
```

## Comparing Isolation

By default, tree and graph share Go module version selection; service-tree
and find each use an isolated `go_deps` extension. Find requests Kubernetes
`v0.38.0-alpha.2`, while tree and graph request `v0.37.1`.

Both configurations below were built successfully with `bazel build //:plugins`
and Go 1.27.2 on macOS arm64. Only find's `isolate = True` was toggled;
service-tree stayed isolated. Versions were read from the binaries with
`go version -m`, rather than inferred from go.mod.

| Binary: `k8s.io/apimachinery` | Find isolated | Find without isolation |
| --- | --- | --- |
| kubectl-find | v0.38.0-alpha.2 | v0.38.0-alpha.2 |
| kubectl-tree | v0.37.1 | v0.38.0-alpha.2 |
| kubectl-graph | v0.37.1 | v0.38.0-alpha.2 |
| kubectl-service-tree | v0.0.0-20190313205120-d7deff9243b1 | v0.0.0-20190313205120-d7deff9243b1 |

**Yes, the compiled module versions change.** Find's Kubernetes version stays
at the higher version it already requests. Without isolation, its requirements
join the shared selection and upgrade tree and graph too. `k8s.io/api`,
`k8s.io/cli-runtime`, and `k8s.io/client-go` follow the same v0.37.1 →
v0.38.0-alpha.2 change in tree and graph.

Find itself has exactly two changed dependency entries in `go version -m`:

| Module in kubectl-find | `isolate = True` | Without isolation |
| --- | --- | --- |
| github.com/fatih/color | v1.18.0 | v1.19.0 |
| google.golang.org/protobuf | v1.36.12-0.20260120151049-f2248ac996af | v1.36.12 |

The shared graph already requires color v1.19.0. Protobuf is a special case:
Gazelle shares its protobuf repository with its tooling even for isolated
usages. When find joins the shared graph, its protobuf requirement upgrades
that repository, including protobuf linked into isolated service-tree.
Service-tree's Kubernetes versions stay unchanged.

Full find build metadata: [isolated](docs/build-info/kubectl-find-isolated.txt)
and [shared](docs/build-info/kubectl-find-shared.txt). Compare it with:

```sh
diff -u docs/build-info/kubectl-find-isolated.txt docs/build-info/kubectl-find-shared.txt
```

Compare the current build with one command (requires Python 3.9+ on the host):

```sh
bazel run //:version-compare
```

Bazel builds all four binaries before the script runs. The script invokes the
downloaded SDK's `go version -json -m` on each binary and prints a table with
plugin names, Go compiler versions, isolation settings read from each plugin's
MODULE.bazel, and linked `k8s.io/` module paths containing `api` (including
`api`, `apimachinery`, `apiextensions-apiserver`, and `kube-openapi`). A dash
means the module is absent from that binary. No host Go installation is needed.

The historical comparison above used Go 1.27.2 for all four binaries.
To reproduce it, temporarily set `DEFAULT_GO_VERSION = "1.27.2"` in the root
MODULE.bazel and run `bazel run //:version-compare`.

**Disabling find's isolation also requires raising `DEFAULT_GO_VERSION` to
`"1.27.2"`.** Tree and graph then select find's newer Kubernetes dependencies,
including structured-merge-diff/v7, which uses Go 1.27 JSON APIs. Keeping the
default at Go 1.26 fails while compiling those shared dependencies (missing
`encoding/json/jsontext`, `encoding/json/v2`, and `MergeWithLegacySemantics`).
Running Gazelle does not resolve this compiler mismatch. To keep tree and
graph on Go 1.26, keep find isolated.

Then change only this line in `kubectl-find/MODULE.bazel`:

```starlark
# Isolated (default):
go_deps = use_extension("@gazelle//:extensions.bzl", "go_deps", isolate = True)
# Shared (replace the line above):
go_deps = use_extension("@gazelle//:extensions.bzl", "go_deps")
```

Run `bazel run //:version-compare` again. Save the first output before
rebuilding because the binary paths are reused. Restore find's
`isolate = True` and `DEFAULT_GO_VERSION = "1.26.0"` afterward, then rerun the
target. Keeping find isolated lets tree and graph retain their Go 1.26
Kubernetes dependencies. `.bazelrc` enables
`--experimental_isolated_extension_usages` for both isolated plugins.

## Build and run

From this directory:

```sh
bazel build //:kubectl-find
bazel build //:kubectl-tree
bazel build //:kubectl-graph
bazel build //:kubectl-service-tree
bazel build //:plugins                     # all four binaries
bazel run //:version-compare               # compiler + Kubernetes module comparison
bazel run //:kubectl-find -- --help
bazel run //:kubectl-tree -- --help
bazel run //:kubectl-graph -- --help
bazel run //:kubectl-service-tree -- --help
bazel test @kubectl_tree//cmd/kubectl-tree:kubectl-tree_test
```

Find the executable paths with:

```sh
bazel cquery //:plugins --output=files
```

## Shared and isolated dependency versions

Yes, with explicit dependency isolation. By default, Gazelle's go_deps
extension selects a single version per Go module path using Minimal Version
Selection across participating Bazel modules. Simply importing go.work or
putting each plugin in a separate Bazel module does not isolate versions.
Different major versions with distinct module paths (for example /v2) can
coexist without isolation.

This experiment makes each plugin a local Bazel module. kubectl-tree and
kubectl-graph use the same non-isolated go_deps extension, so their Go modules
participate in one shared version selection. kubectl-service-tree uses
`use_extension(..., isolate = True)` to keep its legacy dependencies separate.
Find also uses isolation for its prerelease Kubernetes dependencies.
The top-level module uses local_path_override to include all four and exposes
their binaries. SDK versions are configured in the root MODULE.bazel:

```starlark
DEFAULT_GO_VERSION = "1.26.0"
FIND_GO_VERSION = "1.27.2"
```

The `plugin_toolchains` extension registers the downloaded Go 1.26 SDK's
toolchains with priority, making it the default compiler. The root
`//:kubectl-find` target uses `go_cross_binary` with `FIND_GO_VERSION` exported
from the module configuration to select Go 1.27.2 for find and its entire
dependency graph. No SDK command-line flag is needed.

Gazelle's dependency fetcher uses the first downloaded SDK, Go 1.27.2, because
it cannot load find's Go 1.27 modules with Go 1.26. Compiler selection is
separate: `version-compare` reports Go 1.27.2 for find and Go 1.26.0 for the
other three plugins. The default toolchain registration uses rules_go's
internal declaration helper and the downloaded SDK's generated BUILD fields;
recheck `version-compare` when upgrading rules_go.

Find's own Bazel root already defaults to Go 1.27.2. Run its tests there:

```sh
(cd kubectl-find && bazel test //...)
```

The .bazelrc files enable --experimental_isolated_extension_usages; this is
an experimental Bazel feature. Each binary must keep its dependency graph
separate: combining conflicting versions of one Go import path in a single
binary is not supported. Gazelle also deliberately shares the golang/protobuf
and google.golang.org/protobuf repositories with its tooling, even for isolated
usages, so isolation is not a promise to preserve every go.mod version exactly.

Verified in one successful `bazel build //:plugins` on macOS arm64:

| Go module | kubectl-tree | kubectl-service-tree |
| --- | --- | --- |
| github.com/fatih/color | v1.19.0 | v1.7.0 |
| github.com/pkg/errors | v0.9.1 | v0.8.1 |
| github.com/spf13/cobra | v1.10.2 | v0.0.4 |
| k8s.io/client-go | v0.37.1 | v11.0.0+incompatible |

kubectl-graph and kubectl-tree resolve client-go to the same Bazel repository,
`gazelle++go_deps+io_k8s_client_go`, at v0.37.1. Their differing indirect
requirements for github.com/rivo/uniseg demonstrate shared selection:
tree requests v0.2.0 and graph requests v0.4.7; the shared build uses v0.4.7.

Inspect the resolved repositories yourself:

```sh
bazel mod show_repo --base_module=kubectl_tree @com_github_fatih_color @io_k8s_client_go
bazel mod show_repo --base_module=kubectl_graph @io_k8s_client_go
bazel mod show_repo --base_module=kubectl_service_tree @com_github_fatih_color @io_k8s_client_go
```

Bazel reads the individual go.mod files through go_deps; it does not use a
go.work file. When built from the top-level Bazel root, tree and graph share
resolved versions. Building either from its own Bazel root selects dependencies
from that standalone graph instead. Use GOWORK=off when maintaining a plugin's
independent Go module if a parent Go workspace is present.

## Regenerate BUILD files

From the top-level Bazel root, regenerate tree and graph with the shared
dependency configuration:

```sh
bazel run @kubectl_tree//:gazelle -- -repo_root="$PWD/kubectl-tree" "$PWD/kubectl-tree"
bazel run @kubectl_graph//:gazelle -- -repo_root="$PWD/kubectl-graph" "$PWD/kubectl-graph"
```

To refresh direct dependency imports after changing a go.mod, run mod tidy
from the corresponding plugin's Bazel root. Service-tree and find's Gazelle targets
can also be run from their own roots because their dependencies are isolated:

```sh
(cd kubectl-tree && bazel mod tidy)
(cd kubectl-graph && bazel mod tidy)
(cd kubectl-service-tree && bazel mod tidy && bazel run //:gazelle)
(cd kubectl-find && bazel mod tidy && bazel run //:gazelle)
```

Gazelle generates BUILD files for downloaded Go dependencies automatically.
The top-level MODULE.bazel disables proto generation for github.com/openshift/api,
using its checked-in generated Go sources. Gazelle requires overrides for the
non-isolated dependency graph to be declared in the root Bazel module.
The service-tree Gazelle target uses static external resolution and an explicit
mapping for k8s.io/client-go/kubernetes, avoiding Go import discovery that would
mix its legacy Kubernetes packages with newer versions.

## Compatibility changes to the old plugin

Gazelle's go_deps.from_file requires Go 1.17 or later module metadata.
kubectl-service-tree/go.mod and go.sum were tidied with GOWORK=off and
`go mod tidy -go=1.17`, retaining the used direct dependency versions and
recording indirect dependencies. Unused template dependencies were removed.
golang.org/x/sys was then updated from its 2019 revision to v0.6.0 because
the old Darwin arm64 syscall code fails to compile with Go 1.26.0.
No plugin source code changes were required.

References:

- rules_go Bzlmod / external dependencies:
  https://github.com/bazel-contrib/rules_go/blob/master/docs/go/core/bzlmod.md#external-dependencies
- Bazel isolated extension usages:
  https://bazel.build/rules/lib/globals/module#use_extension
- Gazelle shared protobuf repositories:
  https://github.com/bazel-contrib/bazel-gazelle/blob/v0.54.0/internal/bzlmod/go_deps.bzl
