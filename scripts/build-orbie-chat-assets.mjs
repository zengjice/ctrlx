import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

const cache = resolve('.build-local/orbie-web-assets');
const require = createRequire(`${cache}/package.json`);
const esbuild = require('esbuild');
const output = resolve('CtrlxPackage/Sources/CtrlxCommon/Resources/OrbieChat');
const frameSource = resolve(cache, 'node_modules/generative-frame/src');
const documentSource = resolve(output, 'document.js');
const replaceOnce = (source, from, to) => {
    if (source.split(from).length !== 2) throw new Error(`Pinned Generative Frame source changed: ${from}`);
    return source.replace(from, to);
};
const runtime = await esbuild.build({
    stdin: {contents:`import { startRuntime } from ${JSON.stringify(`${frameSource}/runtime/index.ts`)}; startRuntime();`, resolveDir:cache, loader:'ts'},
    bundle:true, minify:true, format:'iife', write:false,
    plugins:[{name:'orbie-document-runtime', setup(build) {
        build.onLoad({filter:/generative-frame\/src\/runtime\/morph\.ts$/}, async ({path}) => {
            let source = await readFile(path, 'utf8');
            source = replaceOnce(source, 'export type StreamRenderer = {', 'export type StreamRenderer = { readonly root: Element;');
            source = replaceOnce(source, 'export function createStreamRenderer(', 'function createFragmentRenderer(');
            source = replaceOnce(source, '    get source() {', '    get root() { return root; },\n    get source() {');
            source += `\nimport { createDocumentRenderer } from ${JSON.stringify(documentSource)};
export function createStreamRenderer(options: StreamRendererOptions): StreamRenderer {
  return createDocumentRenderer(options, createFragmentRenderer(options), {parseMarkup, syncAttributes, runScript:options.runScript ?? createScriptRunner(options.onScriptError)});
}\n`;
            return {contents:source, loader:'ts'};
        });
        build.onLoad({filter:/generative-frame\/src\/runtime\/index\.ts$/}, async ({path}) => {
            let source = await readFile(path, 'utf8');
            for (const from of ['measureRoot(root)', 'reportableSize(root)', 'captureScreenshot(root,']) {
                source = replaceOnce(source, from, from.replace('root', 'renderer.root'));
            }
            source = source.replaceAll('isBlankRender(root)', 'isBlankRender(renderer.root)');
            source = replaceOnce(source, 'sizeFrame ??= win.requestAnimationFrame(reportSize);', 'sizeFrame ??= renderer.root === doc.body ? win.setTimeout(reportSize, 0) : win.requestAnimationFrame(reportSize);');
            source = replaceOnce(source, 'new win.ResizeObserver(scheduleSize).observe(root);', 'const observer = new win.ResizeObserver(scheduleSize);\n    observer.observe(doc.body);\n    observer.observe(doc.documentElement);');
            for (const from of ['await renderer.end();', 'await renderer.replace(p["code"]);']) {
                source = replaceOnce(source, from+'\n        scheduleSize();', from+'\n        reportSize();');
            }
            return {contents:source, loader:'ts'};
        });
        build.onLoad({filter:/generative-frame\/src\/runtime\/size\.ts$/}, async ({path}) => {
            let source = await readFile(path, 'utf8');
            source = replaceOnce(source, '  const rect = root.getBoundingClientRect();', '  if (root === root.ownerDocument.body) return measureDocument(root.ownerDocument);\n  const rect = root.getBoundingClientRect();');
            source = `import { measureDocument } from ${JSON.stringify(documentSource)};\n`+source;
            return {contents:source, loader:'ts'};
        });
    }}]
});
const runtimeSource = runtime.outputFiles[0].text;
await mkdir(output, { recursive: true });
const entry = `${cache}/entry.js`;
await writeFile(entry, `
import { createWidget } from ${JSON.stringify(`${frameSource}/widget.ts`)};
import { defaultThemeTokens } from ${JSON.stringify(`${frameSource}/theme.ts`)};
import { prepareDocument } from ${JSON.stringify(documentSource)};
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
window.OrbieWidgets = { createWidget, defaultThemeTokens, prepareDocument, hljs };
`);
await esbuild.build({entryPoints:[entry], bundle:true, minify:true, format:'iife', legalComments:'linked', outfile:`${output}/vendor.js`, plugins:[{
    name:'orbie-document-host', setup(build) {
        build.onLoad({filter:/generative-frame\/src\/runtime\/generated\.ts$/}, () => ({contents:`export const runtimeSource=${JSON.stringify(runtimeSource)};`, loader:'ts'}));
        build.onLoad({filter:/generative-frame\/src\/widget\.ts$/}, async ({path}) => {
            let source = await readFile(path, 'utf8');
            source = replaceOnce(source, 'pendingSession !== undefined || (ended && SCRIPT_TAG.test(code));', 'pendingSession !== undefined || code.startsWith(documentPrefix) || next.startsWith(documentPrefix) || (ended && SCRIPT_TAG.test(code));');
            return {contents:`import { documentPrefix } from ${JSON.stringify(documentSource)};\n`+source, loader:'ts'};
        });
    }
}]});
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
const documentHash = createHash('sha256').update(await readFile(documentSource)).digest('hex');
await writeFile(`${output}/upstream.json`, JSON.stringify({packages, bundle_sha256:hash, document_adapter_sha256:documentHash, build:'bash scripts/build-orbie-chat-assets.sh'}, null, 2)+'\n');
