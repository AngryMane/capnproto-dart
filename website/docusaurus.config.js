// @ts-check
// See: https://docusaurus.io/docs/api/docusaurus-config

import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {themes as prismThemes} from 'prism-react-renderer';

const ORG = 'AngryMane';
const REPO = 'capnproto-dart';
const EDIT_URL_BASE = `https://github.com/${ORG}/${REPO}/tree/main`;

const SITE_DIR = path.dirname(fileURLToPath(import.meta.url));

// A `docsVersionDropdown` navbar item requires the plugin to actually have at least one
// released version (i.e. `<id>_versions.json`, written by `docusaurus docs:version:<id>`
// — see ci/version-docs.sh). Before the first tagged release this file doesn't exist yet,
// so each dropdown is only added once its plugin has something to show.
const hasReleasedVersions = (pluginId) =>
  fs.existsSync(path.join(SITE_DIR, `${pluginId}_versions.json`));

/** @param {string} pluginId @returns {import('@docusaurus/types').ThemeConfigNavbarItem[]} */
const versionDropdown = (pluginId) =>
  hasReleasedVersions(pluginId)
    ? [{type: 'docsVersionDropdown', docsPluginId: pluginId, position: 'left'}]
    : [];

// This site aggregates markdown that physically lives scattered across the
// repo (root docs/, and a doc/ subdirectory inside each of the 3 components)
// into one site via multiple @docusaurus/plugin-content-docs instances,
// instead of moving/copying any of it into website/. The preset's built-in
// `docs` instance is disabled (docs: false below) so every instance is
// declared explicitly here.

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'capnproto-dart',
  tagline: "A pure Dart implementation of Cap'n Proto, with no FFI dependency",
  favicon: 'img/favicon.ico',

  future: {
    v4: true,
  },

  url: `https://${ORG.toLowerCase()}.github.io`,
  baseUrl: `/${REPO}/`,

  organizationName: ORG,
  projectName: REPO,

  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'throw',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: false,
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  plugins: [
    [
      '@docusaurus/plugin-content-docs',
      /** @type {import('@docusaurus/plugin-content-docs').Options} */
      ({
        id: 'root',
        path: '../docs',
        routeBasePath: 'docs',
        sidebarPath: './sidebars/root.js',
        editUrl: `${EDIT_URL_BASE}/docs`,
      }),
    ],
    [
      '@docusaurus/plugin-content-docs',
      /** @type {import('@docusaurus/plugin-content-docs').Options} */
      ({
        id: 'capnproto-dart',
        path: '../packages/capnproto_dart/doc',
        routeBasePath: 'capnproto_dart',
        sidebarPath: './sidebars/capnproto-dart.js',
        editUrl: `${EDIT_URL_BASE}/packages/capnproto_dart/doc`,
      }),
    ],
    [
      '@docusaurus/plugin-content-docs',
      /** @type {import('@docusaurus/plugin-content-docs').Options} */
      ({
        id: 'capnproto-dart-rpc',
        path: '../packages/capnproto_dart_rpc/doc',
        routeBasePath: 'capnproto_dart_rpc',
        sidebarPath: './sidebars/capnproto-dart-rpc.js',
        editUrl: `${EDIT_URL_BASE}/packages/capnproto_dart_rpc/doc`,
      }),
    ],
    [
      '@docusaurus/plugin-content-docs',
      /** @type {import('@docusaurus/plugin-content-docs').Options} */
      ({
        id: 'capnpc-dart',
        path: '../dev_packages/capnpc-dart/doc',
        routeBasePath: 'capnpc_dart',
        sidebarPath: './sidebars/capnpc-dart.js',
        editUrl: `${EDIT_URL_BASE}/dev_packages/capnpc-dart/doc`,
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: 'img/docusaurus-social-card.jpg',
      colorMode: {
        respectPrefersColorScheme: true,
      },
      navbar: {
        title: 'capnproto-dart',
        logo: {
          alt: 'capnproto-dart logo',
          src: 'img/logo.svg',
        },
        items: [
          {to: '/docs/howto/getting-started', label: 'Guide', position: 'left'},
          ...versionDropdown('root'),
          {
            to: '/capnproto_dart/external-spec',
            label: 'capnproto_dart',
            position: 'left',
          },
          ...versionDropdown('capnproto-dart'),
          {
            to: '/capnproto_dart_rpc/external-spec',
            label: 'capnproto_dart_rpc',
            position: 'left',
          },
          ...versionDropdown('capnproto-dart-rpc'),
          {to: '/capnpc_dart/external-spec', label: 'capnpc-dart', position: 'left'},
          ...versionDropdown('capnpc-dart'),
          {
            href: `https://github.com/${ORG}/${REPO}`,
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              {label: 'Getting Started', to: '/docs/howto/getting-started'},
              {label: 'Requirements & Scope', to: '/docs/purpose'},
            ],
          },
          {
            title: 'Components',
            items: [
              {label: 'capnproto_dart', to: '/capnproto_dart/external-spec'},
              {label: 'capnproto_dart_rpc', to: '/capnproto_dart_rpc/external-spec'},
              {label: 'capnpc-dart', to: '/capnpc_dart/external-spec'},
            ],
          },
          {
            title: 'More',
            items: [
              {
                label: 'GitHub',
                href: `https://github.com/${ORG}/${REPO}`,
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} ${REPO} contributors. Built with Docusaurus.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
      },
    }),
};

export default config;
