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

// This site aggregates markdown that physically lives outside website/ (root
// docs/) via a single @docusaurus/plugin-content-docs instance, instead of
// moving/copying any of it into website/. The preset's built-in `docs`
// instance is disabled (docs: false below) so this instance is declared
// explicitly here.
//
// Per-component doc/ directories (packages/*/doc, dev_packages/*/doc) were
// removed pre-release; each component now documents itself via README.md
// only. Re-add plugin-content-docs instances here if those return.

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
