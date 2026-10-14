# kubectl-plugins: Bazel / Go dependency isolation experiment

Source code cloned from:

- https://github.com/feloy/kubectl-service-tree
- https://github.com/ahmetb/kubectl-tree
- https://github.com/steveteuber/kubectl-graph

Uses Bzlmod (MODULE.bazel), Bazel 9.3.0, rules_go 0.64.2, Gazelle 0.54.0,
and a downloaded Go 1.26.0 SDK. A host Go installation is not needed to build.
The MODULE.bazel.lock files record Bazel module resolution; go.sum files
provide checksums for Go dependencies.

## Build and run

From this directory:

```sh
bazel build //:kubectl-tree
bazel build //:kubectl-graph
bazel build //:kubectl-service-tree
bazel build //:plugins                     # all three binaries
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
The top-level module uses local_path_override to include all three and aliases
their binaries. The downloaded Go SDK is shared by all three plugins.
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
from the corresponding plugin's Bazel root. Service-tree's Gazelle target
can also be run from its own root because its dependencies are isolated:

```sh
(cd kubectl-tree && bazel mod tidy)
(cd kubectl-graph && bazel mod tidy)
(cd kubectl-service-tree && bazel mod tidy && bazel run //:gazelle)
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
