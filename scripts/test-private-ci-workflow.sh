#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root_dir/.github/workflows/speak-private-ci.yml"

if [[ ! -f "$workflow" ]]; then
  echo "Private CI workflow not found: $workflow" >&2
  exit 1
fi

test_jobs=(
  test-private-ci-workflow
  test-api
  test-api-ai-text-live
  test-api-omni-audio-e2e
  test-proxy
  test-standalone-mm-gateway
  test-standalone-operations
  test-web
  test-web-sites
  test-web-base-path
  test-web-ai-text-live
  test-web-live-talk-live
  test-web-e2e
  test-web-e2e-redroid-mobile
)

expected_jobs=(
  "${test_jobs[@]}"
  quality-gate
  build-api
  build-web
)

job_timeouts="$(awk '
  /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
  in_jobs && /^[^[:space:]]/ { in_jobs = 0 }
  in_jobs && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ {
    if (job != "") {
      print job "\t" timeout
    }
    job = $0
    sub(/^  /, "", job)
    sub(/:.*/, "", job)
    timeout = ""
    next
  }
  in_jobs && job != "" && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
    timeout = $0
    sub(/^    timeout-minutes:[[:space:]]*/, "", timeout)
    sub(/[[:space:]]*$/, "", timeout)
  }
  END {
    if (job != "") {
      print job "\t" timeout
    }
  }
' "$workflow")"

declare -A seen_jobs=()
while IFS=$'\t' read -r job timeout; do
  [[ -n "$job" ]] || continue
  seen_jobs["$job"]=1
  if [[ ! "$timeout" =~ ^[0-9]+$ ]] || (( timeout < 1 || timeout >= 10 )); then
    echo "Job $job must declare timeout-minutes from 1 through 9; found '${timeout:-missing}'" >&2
    exit 1
  fi
done <<< "$job_timeouts"

for job in "${expected_jobs[@]}"; do
  if [[ -z "${seen_jobs[$job]+present}" ]]; then
    echo "Expected private CI job is missing: $job" >&2
    exit 1
  fi
done

quality_gate_needs="$(awk '
  /^  quality-gate:[[:space:]]*$/ { in_quality_gate = 1; next }
  in_quality_gate && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ { exit }
  in_quality_gate && /^      - [a-z0-9][a-z0-9-]*[[:space:]]*$/ {
    job = $0
    sub(/^      - /, "", job)
    sub(/[[:space:]]*$/, "", job)
    print job
  }
' "$workflow")"

expected_quality_gate_needs="$(printf '%s\n' "${test_jobs[@]}" | sort)"
actual_quality_gate_needs="$(printf '%s\n' "$quality_gate_needs" | sed '/^$/d' | sort)"
if [[ "$actual_quality_gate_needs" != "$expected_quality_gate_needs" ]]; then
  echo "quality-gate needs must exactly match the required test jobs" >&2
  diff -u <(printf '%s\n' "$expected_quality_gate_needs") <(printf '%s\n' "$actual_quality_gate_needs") >&2 || true
  exit 1
fi

workflow_job() {
  local target="$1"
  awk -v target="$target" '
    $0 == "  " target ":" { in_job = 1; print; next }
    in_job && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ { exit }
    in_job { print }
  ' "$workflow"
}

for job in "${test_jobs[@]}"; do
  job_block="$(workflow_job "$job")"
  if [[ "$job" == "test-web-ai-text-live" ]]; then
    if ! grep -Fxq '    needs: test-api-ai-text-live' <<< "$job_block"; then
      echo "Live AI browser job must depend on the direct API live job" >&2
      exit 1
    fi
  elif grep -Eq '^    needs:' <<< "$job_block"; then
    echo "Required test job $job must start without a needs dependency" >&2
    exit 1
  fi
done

live_ai_job_block="$(workflow_job test-api-ai-text-live)"
if ! grep -Fxq '          AI_HTTP_TRACE: "1"' <<< "$live_ai_job_block"; then
  echo "test-api-ai-text-live must enable redacted AI HTTP tracing" >&2
  exit 1
fi

redroid_job_block="$(workflow_job test-web-e2e-redroid-mobile)"
if ! grep -Fq 'nohup bash -c' <<< "$redroid_job_block" ||
  ! grep -Fq '      - name: Wait for redroid Android' <<< "$redroid_job_block" ||
  ! grep -Fq 'redroid-start.status' <<< "$redroid_job_block" ||
  ! grep -Fq 'Using Android browser package:' <<< "$redroid_job_block" ||
  ! grep -Fq 'REDROID_BROWSER_PACKAGE=$redroid_browser_package' <<< "$redroid_job_block" ||
  ! grep -Fq 'Using Android Platform-Tools directory:' <<< "$redroid_job_block" ||
  ! grep -Fq 'redroid_platform_tools_dir' <<< "$redroid_job_block" ||
  ! grep -Fq 'GITHUB_PATH' <<< "$redroid_job_block"; then
  echo "Redroid mobile jobs must overlap startup with web install and wait on its status log" >&2
  exit 1
fi

quality_gate_block="$(workflow_job quality-gate)"
if ! grep -Fxq '    if: always()' <<< "$quality_gate_block" ||
  ! grep -Fq 'all(.[]; .result == "success")' <<< "$quality_gate_block"; then
  echo "quality-gate must always run and require every result to be success" >&2
  exit 1
fi

for job in build-api build-web; do
  if ! grep -Fxq '    needs: quality-gate' <<< "$(workflow_job "$job")"; then
    echo "$job must depend only on quality-gate" >&2
    exit 1
  fi
done

gateway_block="$(workflow_job test-standalone-mm-gateway)"
for mapping in \
  'repository: ${{ env.CHECKOUT_REPOSITORY }}' \
  'ref: ${{ env.CHECKOUT_REF }}' \
  'token: ${{ secrets.SPEAK_REPO_TOKEN }}'; do
  if ! grep -Fq "$mapping" <<< "$gateway_block"; then
    echo "Standalone mm-gateway smoke must preserve private source checkout mapping: $mapping" >&2
    exit 1
  fi
done

if ! awk '
  /^  test-standalone-mm-gateway:[[:space:]]*$/ { in_gateway = 1 }
  in_gateway && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ && $0 !~ /^  test-standalone-mm-gateway:/ { exit }
  in_gateway && $0 == "        run: ./scripts/test-standalone-mm-gateway.sh" { found = 1 }
  END { exit !found }
' "$workflow"; then
  echo "Standalone mm-gateway smoke job must run its source-repository smoke script" >&2
  exit 1
fi

operations_block="$(workflow_job test-standalone-operations)"
for mapping in \
  'repository: ${{ env.CHECKOUT_REPOSITORY }}' \
  'ref: ${{ env.CHECKOUT_REF }}' \
  'token: ${{ secrets.SPEAK_REPO_TOKEN }}'; do
  if ! grep -Fq "$mapping" <<< "$operations_block"; then
    echo "Standalone operations smoke must preserve private source checkout mapping: $mapping" >&2
    exit 1
  fi
done

if ! awk '
  /^  test-standalone-operations:[[:space:]]*$/ { in_operations = 1 }
  in_operations && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ && $0 !~ /^  test-standalone-operations:/ { exit }
  in_operations && $0 == "        run: ./scripts/test-standalone-operations.sh" { found = 1 }
  END { exit !found }
' "$workflow"; then
  echo "Standalone operations smoke job must run its source-repository recovery script" >&2
  exit 1
fi

live_browser_block="$(workflow_job test-web-ai-text-live)"
if ! grep -Fxq '      max-parallel: 1' <<< "$live_browser_block"; then
  echo "Live AI browser matrix must cap provider concurrency at one job" >&2
  exit 1
fi
if ! grep -Fq '../scripts/validate-live-ai-text-config.sh' <<< "$live_browser_block"; then
  echo "Live AI browser job must run the provider configuration preflight" >&2
  exit 1
fi

live_talk_browser_block="$(workflow_job test-web-live-talk-live)"
for mapping in \
  'LIVE_TALK_API_KEY: ${{ secrets.LIVE_TALK_API_KEY }}' \
  'LIVE_TALK_BASE_URL: ${{ vars.LIVE_TALK_BASE_URL }}' \
  'LIVE_TALK_MODEL: ${{ vars.LIVE_TALK_MODEL }}' \
  'LIVE_TALK_API_FORMAT: ${{ vars.LIVE_TALK_API_FORMAT }}'; do
  if ! grep -Fq "$mapping" <<< "$live_talk_browser_block"; then
    echo "Live Talk browser job must preserve the declared configuration mapping: $mapping" >&2
    exit 1
  fi
done
if ! grep -Fq '../scripts/validate-live-talk-config.sh' <<< "$live_talk_browser_block"; then
  echo "Live Talk browser job must run the provider configuration preflight" >&2
  exit 1
fi
if ! grep -Fq 'npm run test:e2e:ci:live-talk-live' <<< "$live_talk_browser_block"; then
  echo "Live Talk browser job must run the dedicated real-provider e2e command" >&2
  exit 1
fi
if grep -Fq 'LIVE_TALK_API_KEY=$LIVE_TALK_API_KEY' <<< "$live_talk_browser_block"; then
  echo "Live Talk browser job must not print its API key" >&2
  exit 1
fi

for browser_job in test-web-sites test-web-base-path test-web-ai-text-live test-web-live-talk-live test-web-e2e; do
  browser_job_block="$(workflow_job "$browser_job")"
  if ! grep -Fq 'install-dependencies: false' <<< "$browser_job_block"; then
    echo "$browser_job must avoid an unbounded APT dependency refresh" >&2
    exit 1
  fi
  if ! grep -Fq 'Verify Chrome browser' <<< "$browser_job_block"; then
    echo "$browser_job must verify the action-provided Chrome executable" >&2
    exit 1
  fi
done

base_path_block="$(workflow_job test-web-base-path)"
if ! grep -Fq 'npm run test:e2e:base-path' <<< "$base_path_block"; then
  echo "Runtime-prefix browser job must run the source one-image prefix e2e contract" >&2
  exit 1
fi
if grep -Eq 'NEXT_PUBLIC_(API_URL|BASE_PATH)=' <<< "$base_path_block" ||
  grep -Eq 'NEXT_PUBLIC_(API_URL|BASE_PATH)=' "$workflow"; then
  echo "Private CI must not override tokenized web runtime configuration at build time" >&2
  exit 1
fi

postflight_artifact_contracts=(
  'test-proxy|e2e-observability-proxy-attempt-${{ github.run_attempt }}|.tmp/e2e/observability/proxy-*'
  'test-standalone-mm-gateway|e2e-observability-standalone-mm-gateway-attempt-${{ github.run_attempt }}|.tmp/e2e/observability/standalone-mm-gateway'
  'test-standalone-operations|e2e-observability-standalone-operations-attempt-${{ github.run_attempt }}|.tmp/e2e/observability/standalone-operations'
  'test-web-base-path|e2e-observability-base-path-attempt-${{ github.run_attempt }}|.tmp/e2e/observability/runtime-prefix'
  'test-web-ai-text-live|e2e-observability-ai-text-${{ matrix.scenario }}-attempt-${{ github.run_attempt }}|.tmp/e2e/observability'
  'test-web-live-talk-live|e2e-observability-live-talk-attempt-${{ github.run_attempt }}|.tmp/e2e/observability'
  'test-web-e2e|e2e-observability-desktop-${{ matrix.database }}-attempt-${{ github.run_attempt }}|.tmp/e2e/observability'
  'test-web-e2e-redroid-mobile|e2e-observability-redroid-${{ matrix.database }}-attempt-${{ github.run_attempt }}|.tmp/e2e/observability'
)
for contract in "${postflight_artifact_contracts[@]}"; do
  IFS='|' read -r job artifact_name artifact_path <<< "$contract"
  job_block="$(workflow_job "$job")"
  if ! grep -Fq "name: $artifact_name" <<< "$job_block" ||
    ! grep -Fq 'if: always()' <<< "$job_block" ||
    ! grep -Fq 'uses: actions/upload-artifact@v7' <<< "$job_block" ||
    ! grep -Fq "path: $artifact_path" <<< "$job_block"; then
    echo "$job must upload non-secret e2e postflight evidence on every result" >&2
    exit 1
  fi
done

live_api_block="$(workflow_job test-api-ai-text-live)"
if ! grep -Fq './scripts/validate-live-ai-text-config.sh' <<< "$live_api_block"; then
  echo "Live AI API job must run the provider configuration preflight" >&2
  exit 1
fi
if ! grep -Fq './scripts/run-live-ai-text-tests.sh' <<< "$live_api_block"; then
  echo "Live AI API job must use the data-driven live text scenario runner" >&2
  exit 1
fi

omni_block="$(workflow_job test-api-omni-audio-e2e)"
if ! grep -Fq './scripts/run-live-omni-audio-tests.sh' <<< "$omni_block"; then
  echo "OMNI audio job must use the data-driven audio scenario runner" >&2
  exit 1
fi
if grep -Fq 'apt-get' <<< "$omni_block"; then
  echo "OMNI audio job must not use an APT mirror before provider verification" >&2
  exit 1
fi
if ! grep -Fq 'if command -v ffmpeg >/dev/null; then' <<< "$omni_block"; then
  echo "OMNI audio job must use the hosted runner FFmpeg binary when available" >&2
  exit 1
fi
if ! grep -Fq 'timeout 240s curl --fail --location --retry 2 --retry-all-errors' <<< "$omni_block"; then
  echo "OMNI audio job must bound its missing-FFmpeg archive download" >&2
  exit 1
fi
if ! grep -Fq 'autobuild-2026-08-18-15-03/ffmpeg-N-126207-g21bbd98e7b-linux64-gpl.tar.xz' <<< "$omni_block"; then
  echo "OMNI audio job must use the declared static FFmpeg release" >&2
  exit 1
fi
if ! grep -Fq 'ae86e7d2924f46a4658c2a83a74096c8bf5dc7e78bd94e869ff35b45ddf762a0' <<< "$omni_block"; then
  echo "OMNI audio job must pin the FFmpeg archive checksum" >&2
  exit 1
fi
if ! grep -Fq 'sha256sum --check --status' <<< "$omni_block"; then
  echo "OMNI audio job must verify the FFmpeg archive checksum" >&2
  exit 1
fi
if ! grep -Fq 'GITHUB_PATH' <<< "$omni_block"; then
  echo "OMNI audio job must expose the verified FFmpeg binary to later steps" >&2
  exit 1
fi
if ! grep -Fq 'ffmpeg -version' <<< "$omni_block"; then
  echo "OMNI audio job must verify FFmpeg before provider scenarios" >&2
  exit 1
fi

if grep -Fq "TestOMNIAudioAnalysisLiveE2E$'" <<< "$omni_block"; then
  echo "OMNI audio job must not replay the combined audio scenario batch" >&2
  exit 1
fi

echo "Private CI workflow contract passed: ${#seen_jobs[@]} jobs have timeouts below 10 minutes."
