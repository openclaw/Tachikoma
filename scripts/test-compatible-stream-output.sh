#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This fixture requires macOS URLProtocol support." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
umask 077
proof_dir="$(mktemp -d "${TMPDIR:-/tmp}/tachikoma-stream-output.XXXXXX")"
export TACHIKOMA_TEST_MODE=mock TACHIKOMA_DISABLE_API_TESTS=true
# The backticks belong to the exact Swift Testing identifier.
fixture="TachikomaTests.OpenAICompatibleHelperTests/\`Compatible streaming keeps payloads off process output\`(modelID:)"
filter="^TachikomaTests[.]OpenAICompatibleHelperTests/\`Compatible streaming keeps payloads off process output\`[(]modelID:[)](/|$)"
swift test list --only-use-versions-from-resolved-file > "$proof_dir/discovery.log" 2>&1
test "$(grep -Fxc "$fixture" "$proof_dir/discovery.log")" = 1

for mode in default legacy-debug; do
  if [[ "$mode" == default ]]; then
    command_env=(env -u DEBUG_OPENAI)
  else
    command_env=(env DEBUG_OPENAI=1)
  fi
  "${command_env[@]}" swift test --only-use-versions-from-resolved-file \
    --disable-xctest --enable-swift-testing --no-parallel --filter "$filter" \
    > "$proof_dir/$mode.stdout" 2> "$proof_dir/$mode.stderr"
  combined="$proof_dir/$mode.log"
  cat "$proof_dir/$mode.stdout" "$proof_dir/$mode.stderr" > "$combined"
  grep -Eq 'Compatible streaming keeps payloads off process output.*passed after ' "$combined"
  grep -Fq 'Suite OpenAICompatibleHelperTests passed after ' "$combined"
  grep -Eq 'Test run with 1 test( in 1 suite)? passed after ' "$combined"
  if grep -Eq 'TACHIKOMA_PRIVATE_REQUEST_FIXTURE|mock[.]compatible|quiet_tool|fixture-key|DEBUG OpenAI Request|Request JSON \(first' "$combined"; then
    echo "Unexpected streaming request output ($mode); synthetic proof retained at $proof_dir" >&2
    exit 1
  fi
done

echo "Compatible streaming payload/output contracts passed in both modes; proof: $proof_dir"
