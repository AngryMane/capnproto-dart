# Website

This website is built using [Docusaurus](https://docusaurus.io/), a modern static website generator.

It doesn't hold any documentation content itself — `docusaurus.config.js` wires up 4
separate `@docusaurus/plugin-content-docs` instances that read markdown straight out of
`../docs/`, `../packages/capnproto_dart/doc/`, `../packages/capnproto_dart_rpc/doc/`, and
`../tools/capnpc-dart/doc/`. Add/edit docs there, not under `website/`.

## Installation

```bash
npm install
```

**Note**: feel free to use the package manager of your choice.

## Local Development

```bash
npm run start
```

This command starts a local development server and opens up a browser window. Most changes are reflected live without having to restart the server.

**Note**: `npm run start` binds to `0.0.0.0` (not just `localhost`) so the server is
reachable through VS Code's devcontainer port forwarding. If you're running outside a
container and want it restricted to `localhost` only, run `docusaurus start` directly
instead of going through the npm script.

## Build

```bash
npm run build
```

This command generates static content into the `build` directory and can be served using any static contents hosting service.

## Deployment

This repo deploys via `.github/workflows/docs.yml` (GitHub Actions builds this site and
publishes it through the GitHub Pages Actions flow on every push to `main`), not the
`npm run deploy` / `gh-pages` branch flow shown in Docusaurus's own docs. GitHub Pages
must be enabled once, with source set to "GitHub Actions", under the repo's Settings →
Pages.

## Versioning

Pushing a `vX.Y.Z` tag (e.g. `v0.2.0`) triggers `.github/workflows/docs-version.yml`,
which freezes the current content of all 4 doc sections (root `docs/` plus each
component's `doc/`) as version `X.Y.Z`, commits the snapshot to `main`, and deploys.
Past versions stay published side by side; each section's navbar link gets a version
dropdown once at least one snapshot exists. The live, unreleased source is always
available too, under `/next` for each section.

This only snapshots documentation — it does not bump `pubspec.yaml`/`CHANGELOG.md` or
publish packages, so tag docs releases independently of (or alongside) actual package
releases as needed.

To preview a snapshot locally before tagging:

```bash
ci/version-docs.sh 0.2.0   # run from the repo root
cd website && npm run start
```

Generated `*_versioned_docs/`, `*_versioned_sidebars/`, and `*_versions.json` files are
local-only until committed — discard them (`git checkout -- website` /
`git clean -fd website`) if you were just previewing.
