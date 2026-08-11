# speak-ci

This repository runs GitHub Actions for the private `jkfollansbee/speak` repository while keeping the CI repository public.

## Workflow

The workflow at `.github/workflows/speak-private-ci.yml` contains the copied `jkfollansbee/speak` test, build, and publish jobs and asks them to:

- check out `jkfollansbee/speak` with `SPEAK_REPO_TOKEN`
- run the test matrix
- build the API and web images
- optionally publish the images back to `ghcr.io/jkfollansbee/speak`

Automatic behavior:

- pushes and pull requests in this repo run tests and image builds against the matching branch name in `jkfollansbee/speak`
- pushes to `main` and tags that start with `v` also publish images
- manual runs can choose any `source_ref` from `jkfollansbee/speak` and can force publishing with the `publish_image` input

## Required Setup

1. In this repository, add an Actions secret named `SPEAK_REPO_TOKEN`.
2. Use a token that can read the private `jkfollansbee/speak` repository and push packages to `ghcr.io/jkfollansbee/speak`.

Without `SPEAK_REPO_TOKEN`, the workflow can start in this public repo, but every job that checks out the private source tree will fail.
