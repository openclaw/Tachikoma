#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root_dir"
build_dir=$(swift build --show-bin-path)
profile=${1:-"$build_dir/codecov/default.profdata"}
files=(
  Models/Model
  Models/ModelParsing
  Models/OpenAIModels
  Models/AnthropicModels
  Models/HostedModels
  Models/LocalModels
  Core/Configuration
  Core/CustomProviders
  Core/Provider
  Providers/ProviderFactory
  Core/OpenAICompatibleHelper
  Utilities/UsageTracking
  Utilities/ResponseCache
  Utilities/RetryHandler
  Core/Types
)
source_paths=()
for file in "${files[@]}"; do
  source_paths+=( "$root_dir/Sources/Tachikoma/$file.swift" )
done

object_paths=()
if [[ -f "$build_dir/Tachikoma.o" ]]; then
  # Swift Build emits a module object; older SwiftPM emits per-file objects.
  object_paths+=( "$build_dir/Tachikoma.o" )
else
  for file in "${files[@]}"; do
    object="$build_dir/Tachikoma.build/${file##*/}.swift.o"
    if [[ ! -f "$object" ]]; then
      echo "error: missing $object. Run swift test --enable-code-coverage first." >&2
      exit 1
    fi
    object_paths+=( "$object" )
  done
fi

if command -v xcrun >/dev/null 2>&1; then
  coverage_tool=(xcrun llvm-cov)
else
  coverage_tool=(llvm-cov)
fi
additional_objects=()
for object in "${object_paths[@]:1}"; do
  additional_objects+=( -object "$object" )
done
"${coverage_tool[@]}" report "${object_paths[0]}" -instr-profile "$profile" \
  "${additional_objects[@]}" "${source_paths[@]}"
