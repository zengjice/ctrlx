import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const cache = resolve('.build-local/orbie-web-assets');
const require = createRequire(`${cache}/package.json`);
const esbuild = require('esbuild');
const output = resolve('CtrlxPackage/Sources/CtrlxCommon/Resources/OrbieChat');
await mkdir(output, { recursive: true });
const entry = `${cache}/entry.js`;
await writeFile(entry, `
import { createWidget, defaultThemeTokens } from 'generative-frame';
import hljs from 'highlight.js/lib/core';
import swift from 'highlight.js/lib/languages/swift';
import javascript from 'highlight.js/lib/languages/javascript';
import typescript from 'highlight.js/lib/languages/typescript';
import python from 'highlight.js/lib/languages/python';
import json from 'highlight.js/lib/languages/json';
import bash from 'highlight.js/lib/languages/bash';
import diff from 'highlight.js/lib/languages/diff';
import xml from 'highlight.js/lib/languages/xml';
import css from 'highlight.js/lib/languages/css';
import yaml from 'highlight.js/lib/languages/yaml';
for (const [name, language] of Object.entries({swift,javascript,typescript,python,json,bash,diff,xml,css,yaml})) hljs.registerLanguage(name, language);
window.OrbieWidgets = { createWidget, defaultThemeTokens, hljs };
`);
await esbuild.build({entryPoints:[entry], bundle:true, minify:true, format:'iife', legalComments:'linked', outfile:`${output}/vendor.js`});
for (const [source, destination] of [
    ['generative-frame/LICENSE','generative-frame-LICENSE'],
    ['safe-content-frame/LICENSE','safe-content-frame-LICENSE'],
    ['github-markdown-css/github-markdown.css','markdown.css'],
    ['github-markdown-css/license','markdown-LICENSE'],
    ['highlight.js/styles/github.css','highlight.css'],
    ['highlight.js/styles/github-dark.css','highlight-dark.css'],
    ['highlight.js/LICENSE','highlight-LICENSE'],
]) {
    if (destination.endsWith('.css')) {
        const css = await readFile(`${cache}/node_modules/${source}`, 'utf8');
        await writeFile(`${output}/${destination}`, css.replace(/[ \t]+$/gm, '').trimEnd()+'\n');
    } else await copyFile(`${cache}/node_modules/${source}`, `${output}/${destination}`);
}
const lock = JSON.parse(await readFile(`${cache}/package-lock.json`, 'utf8'));
const packages = ['generative-frame','safe-content-frame','highlight.js','github-markdown-css'].map(name => {
    const record = lock.packages[`node_modules/${name}`];
    return {name, version:record.version, source:record.resolved, integrity:record.integrity, license:record.license};
});
const hash = createHash('sha256').update(await readFile(`${output}/vendor.js`)).digest('hex');
await writeFile(`${output}/upstream.json`, JSON.stringify({packages, bundle_sha256:hash, build:'bash scripts/build-orbie-chat-assets.sh'}, null, 2)+'\n');
