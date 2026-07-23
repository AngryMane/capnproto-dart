# Contributing to capnproto-dart

This repository is a [pub workspace](https://dart.dev/tools/pub/workspaces) containing several independently-versioned packages — see the [README](README.md) for the full repository layout.

## Development environment

The easiest way to get a working toolchain is the provided devcontainer ([.devcontainer/](.devcontainer/)), which pins the exact versions CI uses.

If you'd rather set things up manually, match the versions declared in [.github/workflows/compat.yml](.github/workflows/compat.yml):

- Dart SDK (`DART_VERSION`)
- `capnp` CLI, built from source (`CAPNP_CLI_VERSION`)
- Rust stable (only needed for the cross-language interop suites under `test/interop/` and `sample/`)

## Making changes

- Branch off `main` and open a PR against `main`. There is no `develop` branch — `main` is the only long-lived branch, and it is expected to always be in a working, CI-green state.
- For the package(s) you touched, run:
  ```sh
  dart pub get
  dart analyze --fatal-infos
  dart test
  ```
- Lints come from `package:lints/recommended.yaml` with `public_member_api_docs` enabled (see each package's `analysis_options.yaml`) — public API members need a doc comment.
- Before opening a PR that touches wire format, RPC, or codegen behavior, run the full suite locally with [ci/run-tests.sh](ci/run-tests.sh). It also builds the Rust interop fixtures and runs benchmarks, so it's slower than a single package's `dart test` — CI runs this same script on every PR, so it's worth a local run first for anything beyond a single-package change.
- If you're changing user-facing behavior, update the relevant package's `CHANGELOG.md` under an `## Unreleased` heading (see [Versioning](#versioning) below for when this turns into an actual version bump).

## Documentation changes

The docs site ([website/](website/), a Docusaurus site) aggregates `docs/`, and each package's `doc/` folder. Preview locally with:

```sh
cd website && npm install && npm start
```

## Reporting issues

Use [GitHub Issues](https://github.com/AngryMane/capnproto-dart/issues). For bug reports, include the Dart SDK version, the package(s) and version(s) involved, and a minimal repro (a `.capnp` schema snippet plus the Dart code that triggers the issue is usually enough).

## Versioning

Each package (`capnproto_dart`, `capnproto_dart_rpc`, `capnpc_dart`, `capnpc_dart_builder`) is versioned and released **independently**, following [Semantic Versioning](https://semver.org/).

- Bump a package's `version:` in its `pubspec.yaml` and add a `CHANGELOG.md` entry in the same PR as the change that warrants a release. Day-to-day PRs that don't need a release (refactors, test-only changes, docs) should not touch `version:`.
- A package that hasn't changed is **not** re-released just to keep up with its siblings — package versions are expected to drift apart over time, and that's normal, not a sign of a broken process.
- Merging a version-bump PR to `main` does not, by itself, publish anything — see [Releasing](#releasing-maintainers) below. Publishing is always a separate, deliberate step, so `main` can stay a single trunk without needing a `develop` branch to buffer merge frequency.

## Releasing (maintainers)

Releasing a package is triggered by pushing a tag of the form `<package-name>-v<version>` (e.g. `capnproto_dart-v0.2.0`) against the `main` commit where that version was merged. Pushing this tag is the release action — there is no separate "cut a release" step before it and no automatic release on ordinary pushes to `main`.

That tag push:
1. Verifies the tag's version matches `version:` in that package's `pubspec.yaml` at the tagged commit.
2. Runs `dart pub publish` for that package.
3. Creates a GitHub Release on that tag, with release notes taken from the package's `CHANGELOG.md` entry.
4. Updates the versioned docs section for that package on the docs site.

Because `capnproto_dart_rpc` and `capnpc_dart` depend on `capnproto_dart`, and `capnpc_dart_builder` depends on `capnpc_dart`, tag (and therefore publish) `capnproto_dart` first when releasing multiple packages together, and confirm it's live on pub.dev before tagging its dependents.

> This flow is not yet automated end-to-end in CI — until the corresponding workflow lands, a maintainer performs these steps by hand, following the same tag convention, so release history stays consistent once the automation is in place.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE) that covers this repository.
