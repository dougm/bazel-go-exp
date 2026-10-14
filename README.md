# kubectl-plugins: Bazel / Go dependency isolation experiment

Source code cloned from:

- https://github.com/feloy/kubectl-service-tree
- https://github.com/ahmetb/kubectl-tree

Uses Bzlmod (MODULE.bazel), Bazel 9.3.0, rules_go 0.64.2, Gazelle 0.54.0,
and a downloaded Go 1.26.0 SDK. A host Go installation is not needed to build.
The MODULE.bazel.lock files record Bazel module resolution; go.sum files
provide checksums for Go dependencies.

## Build and run

From this directory:

```sh
bazel build //:kubectl-tree
bazel build //:kubectl-service-tree
bazel build //:plugins                     # both binaries
bazel run //:kubectl-tree -- --help
bazel run //:kubectl-service-tree -- --help
bazel test @kubectl_tree//cmd/kubectl-tree:kubectl-tree_test
```

Find the executable paths with:

```sh
bazel cquery //:plugins --output=files
```

## Can the two binaries use different dependency versions?

Yes, with explicit dependency isolation. By default, Gazelle's go_deps
extension selects a single version per Go module path using Minimal Version
Selection across participating Bazel modules. Simply importing go.work or
putting each plugin in a separate Bazel module does not isolate versions.
Different major versions with distinct module paths (for example /v2) can
coexist without isolation.

This experiment makes each plugin a local Bazel module and gives each its
own `use_extension(..., isolate = True)` invocation of go_deps. The top-level
module uses local_path_override to include both and aliases their binaries.
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

Inspect the resolved repositories yourself:

```sh
bazel mod show_repo --base_module=kubectl_tree @com_github_fatih_color @io_k8s_client_go
bazel mod show_repo --base_module=kubectl_service_tree @com_github_fatih_color @io_k8s_client_go
```

Bazel does not use the top-level go.work for this isolated build. Ordinary
Go commands using that workspace still select shared dependency versions.
Use GOWORK=off when maintaining either plugin's independent Go module.

## Regenerate BUILD files

Run Gazelle from each plugin's own Bazel root, where dependency repository
names resolve in that plugin's scope:

```sh
(cd kubectl-tree && bazel mod tidy && bazel run //:gazelle)
(cd kubectl-service-tree && bazel mod tidy && bazel run //:gazelle)
```

Gazelle generates BUILD files for downloaded Go dependencies automatically.
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
