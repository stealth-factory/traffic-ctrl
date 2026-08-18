# Releasing Traffic Ctrl

Traffic Ctrl uses Semantic Versioning, Conventional Commits, Release Please,
and GitHub Actions. Maintainers do not create release tags manually during the
normal release flow.

## One-time repository setup

The current enterprise policy forces the repository `GITHUB_TOKEN` to remain
read-only by default and prevents it from creating pull requests. Release
Please therefore requires a repository Actions secret named
`RELEASE_PLEASE_TOKEN`.

Use either a fine-grained personal access token from a dedicated automation
account or a GitHub App installation token. Scope it to this repository with
read/write access to **Contents**, **Pull requests**, and **Issues**, and no
unrelated permissions. Add it under **Settings → Secrets and variables →
Actions**.

Until that secret exists, the Release workflow exits successfully with a clear
warning and does not create a release PR. Do not store a broad personal token
used for unrelated repositories in this secret.

## Commit messages

Use Conventional Commit subjects for changes that affect releases:

- `fix: correct process traffic attribution` requests a patch release;
- `feat: add per-process network blocking` requests a minor release; and
- `feat!: change the backend protocol` requests a major release.

Use `docs:`, `test:`, `build:`, `ci:`, `refactor:`, and `chore:` for changes
that should appear in history without independently requesting a release.

## Release flow

1. Merge Conventional Commits into `main`.
2. The Release workflow creates or updates a release PR containing the next
   version and generated `CHANGELOG.md` entries.
3. Review and merge the release PR when the release should ship.
4. Release Please creates the `vX.Y.Z` tag and GitHub Release.
5. The same workflow checks out that exact release commit on ARM64 and Intel
   macOS runners.
6. It verifies both command names, creates architecture-specific archives,
   generates SHA-256 checksums and provenance attestations, and uploads them to
   the GitHub Release.

The initial manifest version is `0.0.0`, so the first `feat:` commit produces
`v0.1.0`.

## Release assets

Each release currently contains:

- `traffic-ctrl-vX.Y.Z-macos-arm64.tar.gz`;
- `traffic-ctrl-vX.Y.Z-macos-x86_64.tar.gz`; and
- `SHA256SUMS`.

Each archive contains `traffic-ctrl`, `trctrl`, and the README. Linux assets,
macOS code signing, notarisation, and an installer will be added with their
respective roadmap phases.

## Recovery

If packaging fails after Release Please creates a GitHub Release, leave the tag
unchanged, fix the workflow, and rerun the failed job. Asset uploads use
`--clobber`, making a rerun safe. Do not move or recreate a published version
tag with different source.
