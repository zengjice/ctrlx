export const documentPrefix = '<!--orbie-document-->';

export function prepareDocument(source, isFile) {
  if (!isFile) {
    if (!/<(?:html|head|body)(?:\s|>)|<!doctype\s+html/i.test(source)) return source;
    const parsed = new DOMParser().parseFromString(source, 'text/html');
    const hasAttributes = [parsed.documentElement, parsed.head, parsed.body].some(element => element.attributes.length);
    const startsDocument = /^(?:\s|<!--[\s\S]*?-->)*<(?:html|head|body)(?:\s|>)/i.test(source);
    if (!parsed.doctype && !hasAttributes && !startsDocument) return source;
  }
  return documentPrefix + source;
}

export function measureDocument(doc) {
  const body = doc.body, win = doc.defaultView;
  const rect = body.getBoundingClientRect(), page = doc.documentElement.getBoundingClientRect();
  const margin = Math.max(0, parseFloat(win.getComputedStyle(body).marginBottom) || 0);
  const bottom = Math.max(rect.bottom, rect.top + body.clientTop + body.scrollHeight) + win.scrollY + margin;
  // The document's scrollHeight includes the current viewport and would prevent shrinking.
  return { width: Math.ceil(page.width), height: Math.ceil(Math.max(page.bottom + win.scrollY, bottom)) };
}

// Extends the pinned fragment renderer; the host remounts when replacing a document.
export function createDocumentRenderer(options, fragment, { parseMarkup, syncAttributes, runScript }) {
  const doc = options.root.ownerDocument;
  let source = '', documentMode = false, ended = false, scriptsRan = false;

  const render = async () => {
    const parsed = new DOMParser().parseFromString(source.slice(documentPrefix.length), 'text/html');
    const theme = doc.documentElement.dataset.theme, styles = doc.documentElement.style.cssText;
    for (const [live, next] of [[doc.documentElement, parsed.documentElement], [doc.head, parsed.head], [doc.body, parsed.body]]) {
      syncAttributes(live, next);
    }
    // Keep runtime theme defaults, with document-provided styles taking precedence.
    doc.documentElement.style.cssText = styles + ';' + parsed.documentElement.style.cssText;
    if (!parsed.documentElement.hasAttribute('data-theme') && theme) doc.documentElement.dataset.theme = theme;
    const head = parseMarkup(doc, parsed.head.innerHTML), body = parseMarkup(doc, parsed.body.innerHTML);
    const placeholders = [];
    for (const container of [head.fragment, body.fragment]) {
      const walker = doc.createTreeWalker(container, NodeFilter.SHOW_COMMENT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeValue === 'gf-script') placeholders.push(node);
      }
    }
    // Keep the bootstrap CSP and theme nodes; only user head content is appended.
    doc.head.append(head.fragment);
    doc.body.replaceChildren(body.fragment);
    options.onRender?.('html');
    const scripts = [...head.scripts, ...body.scripts];
    for (let index = 0; index < scripts.length; index++) await runScript(placeholders[index], scripts[index]);
    scriptsRan = true;
    doc.dispatchEvent(new Event('DOMContentLoaded', { bubbles: true }));
    doc.defaultView.dispatchEvent(new Event('load'));
  };

  return {
    get root() { return documentMode ? doc.body : fragment.root; },
    get source() { return source; },
    get kind() { return documentMode ? 'html' : fragment.kind; },
    get ended() { return documentMode ? ended : fragment.ended; },
    get scriptsRan() { return documentMode ? scriptsRan : fragment.scriptsRan; },
    write(chunk) {
      if (ended) throw new Error('Cannot write after end; use replace');
      source += chunk;
      documentMode = source.startsWith(documentPrefix);
      if (!documentMode) fragment.write(chunk);
    },
    async end() {
      if (!documentMode) return fragment.end();
      if (ended) return;
      ended = true;
      await render();
    },
    async replace(code) {
      source = code;
      documentMode = source.startsWith(documentPrefix);
      if (!documentMode) return fragment.replace(code);
      ended = true;
      await render();
    },
    flush() { if (!documentMode) fragment.flush(); }
  };
}
