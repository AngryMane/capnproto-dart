import React from 'react';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';
import Heading from '@theme/Heading';

const SECTIONS = [
  {
    title: 'Guide',
    description: 'Requirements, howto manuals, and how the 3 components relate.',
    to: '/docs/howto/getting-started',
  },
  {
    title: 'capnproto_dart',
    description: 'Serialization Runtime — external spec and internal design.',
    to: '/capnproto_dart/external-spec',
  },
  {
    title: 'capnproto_dart_rpc',
    description: 'RPC Runtime — external spec and internal design.',
    to: '/capnproto_dart_rpc/external-spec',
  },
  {
    title: 'capnpc-dart',
    description: 'Code generator CLI — external spec and internal design.',
    to: '/capnpc_dart/external-spec',
  },
];

export default function Home() {
  return (
    <Layout
      title="capnproto-dart"
      description="A pure Dart implementation of Cap'n Proto, with no FFI dependency">
      <main style={{padding: '3rem 1rem', maxWidth: 960, margin: '0 auto'}}>
        <Heading as="h1">capnproto-dart</Heading>
        <p>
          A pure Dart implementation of{' '}
          <a href="https://capnproto.org">Cap'n Proto</a> serialization and
          RPC, with no FFI dependency.
        </p>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
            gap: '1rem',
            marginTop: '2rem',
          }}>
          {SECTIONS.map((section) => (
            <Link
              key={section.to}
              to={section.to}
              style={{
                display: 'block',
                padding: '1.25rem',
                borderRadius: 8,
                border: '1px solid var(--ifm-color-emphasis-300)',
                textDecoration: 'none',
                color: 'inherit',
              }}>
              <Heading as="h3">{section.title}</Heading>
              <p style={{marginBottom: 0}}>{section.description}</p>
            </Link>
          ))}
        </div>
      </main>
    </Layout>
  );
}
