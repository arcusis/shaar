// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const esbuild = require('esbuild');
const svelte = require('svelte/compiler');
const root = path.resolve(__dirname, '../..');
const output = path.join(root, 'ThirdParty/InspectorFixtures');

(async () => {
  fs.mkdirSync(output, { recursive: true });
  const result = await esbuild.build({
    entryPoints: [path.join(__dirname, 'fixtures/index.js')],
    outfile: path.join(output, 'frameworks.js'), bundle: true, write: false,
    format: 'iife', target: 'chrome155', minify: true, keepNames: true,
    legalComments: 'external', define: { 'process.env.NODE_ENV': '"development"', '__VUE_OPTIONS_API__': 'true', '__VUE_PROD_DEVTOOLS__': 'false', '__VUE_PROD_HYDRATION_MISMATCH_DETAILS__': 'false' },
    plugins: [{ name: 'svelte-fixture', setup(build) {
      build.onLoad({ filter: /\.svelte$/ }, args => ({
        contents: svelte.compile(fs.readFileSync(args.path, 'utf8'), { dev: true, css: 'external', filename: path.basename(args.path) }).js.code,
        resolveDir: path.dirname(args.path), loader: 'js',
      }));
    }}],
  });
  const hashes = {};
  for (const file of result.outputFiles) {
    fs.writeFileSync(file.path, file.contents);
    hashes[path.basename(file.path)] = crypto.createHash('sha256').update(file.contents).digest('hex');
  }
  const versions = {};
  for (const name of ['react', 'react-dom', 'vue', 'svelte', 'esbuild']) {
    const packagePath = require.resolve(name + '/package.json');
    const directory = path.dirname(packagePath);
    const license = ['LICENSE', 'LICENSE.md', 'LICENSE-MIT'].find(file => fs.existsSync(path.join(directory, file)));
    if (license) fs.copyFileSync(path.join(directory, license), path.join(output, name.replaceAll('/', '-') + '-LICENSE'));
    versions[name] = JSON.parse(fs.readFileSync(packagePath, 'utf8')).version;
  }
  const sourceSHA256 = {};
  for (const name of ['build-fixtures.cjs', ...fs.readdirSync(path.join(__dirname, 'fixtures')).sort().map(file => 'fixtures/' + file)]) {
    const file = path.join(__dirname, name);
    sourceSHA256[path.relative(root, file).split(path.sep).join('/')] = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  }
  fs.writeFileSync(path.join(output, 'pin.json'), JSON.stringify({ testOnly: true, versions, sourceSHA256, sha256: hashes }, null, 2) + '\n');
  console.log('Built pinned, test-only framework fixture.');
})().catch(error => { console.error(error); process.exitCode = 1; });
