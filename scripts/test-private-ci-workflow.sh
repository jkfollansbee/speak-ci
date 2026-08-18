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
  ! grep -Fq 'REDROID_BROWSER_PACKAGE=$redroid_browser_package' <<< "$redroid_job_block"; then
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

if grep -Fq "TestOMNIAudioAnalysisLiveE2E$'" <<< "$omni_block"; then
  echo "OMNI audio job must not replay the combined audio scenario batch" >&2
  exit 1
fi

echo "Private CI workflow contract passed: ${#seen_jobs[@]} jobs have timeouts below 10 minutes."
