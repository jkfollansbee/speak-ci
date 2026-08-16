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

- check out `panda-lingo/speak` with `SPEAK_REPO_TOKEN`
- run the test matrix
- build the API and web images
- optionally publish the images back to `ghcr.io/panda-lingo/speak`

Automatic behavior:

- pushes and pull requests in this repo run tests and image builds against the matching branch name in `panda-lingo/speak`
- pushes to `main` and tags that start with `v` also publish images
- manual runs can choose any `source_ref` from `panda-lingo/speak` and can force publishing with the `publish_image` input

## Required Setup

1. In this repository, add an Actions secret named `SPEAK_REPO_TOKEN`.
2. Use a token that can read the private `panda-lingo/speak` repository.
3. Keep the workflow job permissions at `packages: write` so the repository `GITHUB_TOKEN` can publish `ghcr.io/panda-lingo/speak`.

Without `SPEAK_REPO_TOKEN`, the workflow can start in this public repo, but every job that checks out the private source tree will fail.
