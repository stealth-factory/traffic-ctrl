# Releasing Traffic Ctrl

Traffic Ctrl uses Semantic Versioning, Conventional Commits, Release Please,
and GitHub Actions. Maintainers do not create release tags manually during the
normal release flow.

Release Please uses its Rust strategy and `cargo-workspace` plugin so the
workspace manifest and generated lockfile stay on the same stamped version. It
also stamps the legacy Swift version and macOS project metadata.

## One-time repository setup

In **Settings → Actions → General → Workflow permissions**, keep the default
workflow permission set to **Read repository contents and packages**, and
enable **Allow GitHub Actions to create and approve pull requests**. The
Release workflow requests only the write permissions its Release Please job
needs and uses GitHub's short-lived built-in `GITHUB_TOKEN`; no personal access
token or repository secret is required.

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
   macOS runners and an x86-64 Linux runner.
6. It verifies both command names, creates architecture-specific archives,
   generates SHA-256 checksums and provenance attestations, and uploads them to
   the GitHub Release.

The first release is explicitly initialised as `v0.1.0`. After that, Release
Please calculates each version from the manifest and Conventional Commits.

## Release assets

Each release currently contains:

- `traffic-ctrl-vX.Y.Z-macos-arm64.tar.gz`;
- `traffic-ctrl-vX.Y.Z-macos-x86_64.tar.gz`;
- `traffic-ctrl-vX.Y.Z-linux-x86_64.tar.gz`; and
- `SHA256SUMS`.

Each archive contains `traffic-ctrl`, `trctrl`, and the README. macOS code
signing, notarisation, additional Linux architectures, and installers will be
added with their respective roadmap phases.

## Recovery

If packaging fails after Release Please creates a GitHub Release, leave the tag
unchanged, fix the workflow, and rerun the failed job. Asset uploads use
`--clobber`, making a rerun safe. Do not move or recreate a published version
tag with different source.
