# Contributing to Lyra

## Branches and pull requests

- `development` is the default integration branch. Target feature, fix, and documentation pull requests to `development`.
- Use a topic branch in your fork; do not push directly to `main` or `development`.
- `main` is the stable branch. Promote reviewed changes from `development` to `main` with a separate pull request.
- `wisphex` is the repository-wide code owner. Protected-branch pull requests require an approval from `wisphex`; approval is dismissed if new reviewable commits are pushed afterward.
- Resolve review conversations before merging.

## Review and checks

Explain the user-facing change and include the checks you ran in the pull request description. Keep changes focused and add tests when implementation exists.

The repository has no CI status checks yet, so branch protection does not require any. Required build and test checks should be added once cross-platform CI is in place.
