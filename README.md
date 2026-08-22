# speak-ci

This repository runs GitHub Actions for the private `panda-lingo/speak` repository while keeping the CI repository public.

## Workflow

The workflow at `.github/workflows/speak-private-ci.yml` is pinned to this organization mapping:

| Concern | Value |
| --- | --- |
| Source repository | `panda-lingo/speak` |
| CI repository | `panda-lingo/speak-ci` |
| Published API image | `ghcr.io/panda-lingo/speak` |
| Published web image | `ghcr.io/panda-lingo/speak:web-*` |
| Package publish credentials | `GITHUB_TOKEN` from `panda-lingo/speak-ci` with `packages: write` |

The workflow contains the copied `panda-lingo/speak` test, build, and publish jobs and asks them to:

- validate its own job timeout and quality-gate contract in a fast
  `test-private-ci-workflow` job
- check out `panda-lingo/speak` with `SPEAK_REPO_TOKEN`
- run the test matrix
- exercise the source repository's standalone PostgreSQL, VictoriaMetrics, and
  rclone recovery smoke before images can be built or published
- run the source repository's uncached OMNI audio-practice, pinned music-analysis,
  and voice-memo e2e contract when the mirrored `OMNI_*` settings are present
- run the source repository's real Live Talk browser journey when the mirrored
  `LIVE_TALK_*` settings are present; the journey configures the Free plan
  through the Admin Portal UI before it starts a learner conversation
- bootstrap Redroid without an APT index refresh: use the hosted runner's
  tool baseline, download the official Android Platform-Tools archive only when
  `adb` is absent, make only a bounded no-index repair attempt for a missing
  matching binder module, then validate and re-export the logged tool directory
  for the later browser step
- build the API and web images
- optionally publish the images back to `ghcr.io/panda-lingo/speak`

Automatic behavior:

- pushes and pull requests in this repo run tests and image builds against the matching branch name in `panda-lingo/speak`
- pushes to `main` and tags that start with `v` also publish images
- manual runs can choose any `source_ref` from `panda-lingo/speak` and can force publishing with the `publish_image` input

## Runtime-prefix verification contract

The fallback workflow must build the source repository's web image without
`NEXT_PUBLIC_API_URL` or `NEXT_PUBLIC_BASE_PATH` build overrides. The source
image contains validated runtime tokens; its `test-web-base-path` job runs the
source `npm run test:e2e:base-path` contract, which starts fresh containers
from one image at both `/speak` and `/academy`. This keeps fallback CI aligned
with the deploy-without-rebuild guarantee instead of testing a separately
prefix-built image.

## Job timeout contract

The workflow uses a declarative timeout budget for every job:

| Job group | `timeout-minutes` | Constraint |
| --- | ---: | --- |
| `test-*` and `build-*` jobs | 9 | Must remain strictly below 10 minutes |
| `quality-gate` | 5 | Must remain strictly below 10 minutes |

Every job must declare an integer `timeout-minutes` value from 1 through 9. The
`quality-gate` must list every `test-*` job in `needs`, including the standalone
`mm-gateway` deployment smoke and stateful recovery smoke. The contract script at
`scripts/test-private-ci-workflow.sh` checks these mappings so a newly added job
cannot silently bypass the timeout policy or required-result gate.

## Required Setup

1. In this repository, add an Actions secret named `SPEAK_REPO_TOKEN`.
2. Use a token that can read the private `panda-lingo/speak` repository.
3. Mirror `OMNI_API_FORMAT`, `OMNI_BASE_URL`, and `OMNI_MODEL` as repository
   variables and `OMNI_API_KEY` as a repository secret. Repository-level
   values take precedence over inherited organization values and keep all four
   settings bound to the same provider.
4. Mirror `LIVE_TALK_API_FORMAT`, `LIVE_TALK_BASE_URL`, and `LIVE_TALK_MODEL`
   as repository variables and `LIVE_TALK_API_KEY` as a repository secret. The
   format must be `gemini` or `openai`, and all four values must describe the
   same realtime provider endpoint. The workflow passes them only to the
   Live Talk job, whose browser setup writes them through `/admin/plans` rather
   than pre-seeding provider settings through an API shortcut.
5. Keep the workflow job permissions at `packages: write` so the repository `GITHUB_TOKEN` can publish `ghcr.io/panda-lingo/speak`.

Without `SPEAK_REPO_TOKEN`, the workflow can start in this public repo, but every job that checks out the private source tree will fail.
If the resolved `OMNI_*` configuration is incomplete, the live OMNI job is an
explicit successful no-op. Configure all four values at repository scope before
dispatching a live run; GitHub otherwise resolves any organization defaults.
The Live Talk job follows the same explicit-no-op rule only when its entire
`LIVE_TALK_*` configuration is absent or incomplete; a non-empty unsupported
format fails as a configuration error.
