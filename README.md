# speak-ci

This repository is a thin GitHub Actions caller for the private `jkfollansbee/speak` repository.

## Workflow

The workflow at `.github/workflows/speak-private-ci.yml` calls the reusable workflow published by `jkfollansbee/speak` and asks it to:

- check out `jkfollansbee/speak`
- run the test matrix
- build the API and web images
- optionally publish the images back to `ghcr.io/jkfollansbee/speak`

Automatic behavior:

- pushes and pull requests in this repo run tests and image builds against the matching branch name in `jkfollansbee/speak`
- pushes to `main` and tags that start with `v` also publish images
- manual runs can choose any `source_ref` from `jkfollansbee/speak` and can force publishing with the `publish_image` input

## Required Setup

1. In `jkfollansbee/speak`, keep the Actions access policy set to `Accessible from repositories owned by the user 'jkfollansbee'`.
2. In this repository, add an Actions secret named `SPEAK_REPO_TOKEN`.
3. Use a token that can read the private `jkfollansbee/speak` repository and push packages to `ghcr.io/jkfollansbee/speak`.

Without `SPEAK_REPO_TOKEN`, the called workflow can be loaded from `jkfollansbee/speak`, but the jobs in this repo cannot check out the private source tree or publish images back to the private package namespace.
