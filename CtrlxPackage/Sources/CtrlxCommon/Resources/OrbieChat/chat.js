"use strict";
(() => {
  const root = document.getElementById("messages");
  const latest = document.getElementById("latest");
  const rows = /* @__PURE__ */ new Map(), images = /* @__PURE__ */ new Map(), waitingImages = new Map();
  const htmlFiles = new Map();
  const imagePaths = new Map();
  let imageRequestsScheduled = false;
  let dark = false, follow = true, serial = 0, lastHeight = -1, lastAutoScrollY = null;
  const send = (payload) => document.dispatchEvent(new CustomEvent("orbie-native", { detail: JSON.stringify(payload) }));
  let mermaidLoading, completeMermaid;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve();
    if (!mermaidLoading) {
      mermaidLoading = new Promise((resolve, reject) => {
        completeMermaid = error => {
          completeMermaid = null;
          if (error || !window.mermaid) {
            mermaidLoading = null;
            reject(new Error(error || 'The diagram renderer is unavailable.'));
          } else resolve();
        };
      });
      send({ kind: 'mermaid' });
    }
    return mermaidLoading;
  }
  const node = (tag, cls, text) => {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text !== void 0) el.textContent = text;
    return el;
  };
  const button = (text, fn) => {
    const el = node("button", "", text);
    el.type = "button";
    el.addEventListener("click", fn);
    return el;
  };
  const nearBottom = () => window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 28;
  function toggleImage(image, row) {
    image.classList.toggle('expanded-image');
    row.element.classList.toggle('expanding', image.classList.contains('expanded-image'));
  }
  function imagePlaceholder(target, alt, reference) {
    const image = node("img", "image-placeholder");
    image.alt = alt;
    image.dataset.imageKey = String(++serial);
    image.dataset.imageReference = target;
    if (reference !== undefined) image.dataset.repoReference = String(reference);
    return image;
  }
  function resolveImagePath(row, target, key) {
    return new Promise(resolve => {
      imagePaths.set(key, resolve);
      row.cleanup.push(() => { imagePaths.delete(key); resolve(null); });
      send({ kind: 'imagePath', messageID: row.model.id, target, key });
    });
  }
  function requestImages() {
    if (imageRequestsScheduled) return;
    imageRequestsScheduled = true;
    // Finish the whole message update before admitting groups whose quota was released.
    queueMicrotask(() => {
      imageRequestsScheduled = false;
      for (const [key, group] of waitingImages) {
        if (images.size >= 24) {
          if (!group.issues.length) group.issues = group.images.map(image => {
            const issue = node("small", "issue", "This conversation displays at most 24 unique images.");
            image.replaceWith(issue);
            return issue;
          });
          continue;
        }
        waitingImages.delete(key);
        images.set(key, group);
        group.issues.forEach((issue, index) => issue.replaceWith(group.images[index]));
        group.issues = [];
        send(group.payload);
      }
    });
  }
  function layout() {
    const height = root.scrollHeight;
    if (height !== lastHeight) {
      lastHeight = height;
      send({ kind: "height", height });
    }
    if (follow) {
      window.scrollTo(0, document.documentElement.scrollHeight);
      lastAutoScrollY = window.scrollY;
    }
    latest.hidden = follow;
  }
  new ResizeObserver(layout).observe(root);
  window.addEventListener("scroll", () => {
    // A delayed event from our own scroll must not disable following after the layout grows again.
    if(lastAutoScrollY !== null && Math.abs(window.scrollY - lastAutoScrollY) < 2) return;
    lastAutoScrollY = null;
    follow = nearBottom();
    latest.hidden = follow;
  }, { passive: true });
  window.addEventListener('resize', layout);
  latest.onclick = () => {
    follow = true;
    layout();
  };
  function codeBlock(source, language, row, kind = "code") {
    const card = node("section", "card"), header = node("div", "card-header");
    const codeIndex = row.codes.push(source);
    header.append(node("span", "", language || "Text"), button("Copy", () => send({ kind: "code", messageID: row.model.id, reference: codeIndex })));
    const pre = node("pre"), code = node("code", "", source);
    pre.append(code);
    if (source.length < 32e3 && OrbieWidgets.hljs.getLanguage(language || "")) code.innerHTML = OrbieWidgets.hljs.highlight(source, { language }).value;
    card.append(header);
    if (source.split("\n").length > 14) {
      const details = node("details", "long-code");
      details.append(node("summary", "", "Show code"), pre);
      card.append(details);
    } else card.append(pre);
    return { card, header, pre };
  }
  function previewCard(source, language, row, kind, isDocument = false) {
    const diagramIndex = kind === 'mermaid' ? row.diagramCount++ : 0;
    const { card, header, pre } = codeBlock(source, language, row);
    if (pre.parentElement !== card) {
      pre.parentElement.remove();
      card.append(pre);
    }
    const preview = node("div", kind === "html" ? "widget" : "diagram");
    const status = node("div", "card-error");
    const show = button("Preview", () => {
      preview.hidden = false;
      pre.hidden = true;
      show.setAttribute("aria-pressed", "true");
      raw.setAttribute("aria-pressed", "false");
      layout();
    });
    const raw = button("Source", () => {
      preview.hidden = true;
      pre.hidden = false;
      show.setAttribute("aria-pressed", "false");
      raw.setAttribute("aria-pressed", "true");
      layout();
    });
    header.insertBefore(show, header.children[1]);
    header.insertBefore(raw, header.children[2]);
    const expand = button("Expand", () => {
      card.classList.toggle("expanded");
      row.element.classList.toggle('expanding', card.classList.contains('expanded'));
      expand.textContent = card.classList.contains("expanded") ? "Close expanded preview" : "Expand";
    });
    expand.dataset.expand = 'true';
    header.append(expand);
    card.append(preview, status);
    pre.hidden = true;
    show.setAttribute("aria-pressed", "true");
    let widget, started = false, userPaused = false, runVersion = 0;
    const stop = () => {
      ++runVersion;
      widget?.dispose();
      widget = void 0;
      started = false;
    };
    const run = () => {
      if (started || userPaused || !card.isConnected) return;
      if (kind === "html" && window.orbieChat.activeWidgets() >= 4) {
        status.textContent = "Four interactive previews are already running. Close another preview, then choose Run.";
        return;
      }
      started = true;
      const version = ++runVersion;
      status.textContent = "";
      if (kind === "html") {
        widget = OrbieWidgets.createWidget({
          container: preview,
          code: OrbieWidgets.prepareDocument(source, isDocument),
          opaqueOrigin: true,
          csp: { cdnOrigins: [] },
          animate: false,
          minHeight: 60,
          maxHeight: 480,
          tokens: OrbieWidgets.defaultThemeTokens(dark ? "dark" : "light"),
          readyTimeoutMs: 1e4,
          onOpenLink: () => {
          },
          onError: (error) => {
            if(version === runVersion) status.textContent = error.message;
          }
        });
        // WebKit throttles transparent frames before their first size report. Local frames already have their theme.
        const slot = preview.querySelector('[data-generative-frame]');
        if (slot) slot.style.opacity = '1';
        widget.on('end', ({size}) => {
          if(version === runVersion && widget?.iframe && Number.isFinite(size.height)) {
            widget.iframe.style.height = Math.min(480, Math.max(60, size.height)) + 'px';
          }
        });
        row.widgets.set(card, widget);
        widget.ready.then(() => {
          if(version === runVersion && widget?.iframe) widget.iframe.title = 'Interactive HTML preview';
        }).catch((error) => {
          if(version !== runVersion) return;
          status.textContent = String(error);
          stop();
          row.widgets.delete(card);
        });
      } else {
        if (new TextEncoder().encode(source).length > 65536 || diagramIndex >= 16) {
          status.textContent = "Diagram exceeds the preview limit. Its source is available.";
          raw.click();
          return;
        }
        loadMermaid().then(() => {
          if (!card.isConnected || version !== runVersion) return;
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark ? "dark" : "default", htmlLabels:false, flowchart:{htmlLabels:false}, maxEdges: 500, maxTextSize: 65536, suppressErrorRendering:true, secure:['secure','securityLevel','startOnLoad','htmlLabels','flowchart','theme','maxEdges','maxTextSize','suppressErrorRendering'] });
          return mermaid.render("orbieDiagram" + ++serial, source);
        }).then((result) => {
          if (result && card.isConnected && version === runVersion) {
            const image=node('img', '', '');
            image.alt='Diagram';
            image.src=svgImageURL(sanitizeSVG(result.svg));
            image.onclick=()=>toggleImage(image, row);
            preview.replaceChildren(image);
          }
        }).catch(() => {
          if (!card.isConnected || version !== runVersion) return;
          status.textContent = "This diagram could not be rendered. Its source is available.";
          raw.click();
        });
      }
    };
    if (kind === "html") header.append(button("Run again", () => {
      userPaused = false;
      stop();
      row.widgets.delete(card);
      preview.replaceChildren();
      run();
    }));
    if (kind === "html") header.append(button("Pause", () => {
      userPaused = true;
      stop();
      row.widgets.delete(card);
      preview.replaceChildren();
      status.textContent = "Preview paused. Choose Run again to restart.";
    }));
    let visible = false;
    if(kind === 'mermaid') row.redrawDiagrams.push(() => { started=false; if(visible)run(); });
    const observer = new IntersectionObserver((entries) => {
      visible = entries.some((e) => e.isIntersecting);
      if (visible) run();
      else if (kind === "html" && started) {
        stop();
        row.widgets.delete(card);
        preview.replaceChildren();
        status.textContent = "Preview paused while offscreen.";
      }
    }, { rootMargin: "300px" });
    observer.observe(card);
    row.cleanup.push(() => {
      observer.disconnect();
      stop();
    });
    return card;
  }
  function renderAnswer(row) {
    row.cleanup.forEach((fn) => fn());
    row.cleanup = [];
    row.widgets.clear();
    row.codes = [];
    row.diagramCount = 0;
    row.redrawDiagrams = [];
    const version = row.renderVersion = (row.renderVersion || 0) + 1;
    const answer = row.model.answer;
    row.renderedAnswer = answer;
    row.body.replaceChildren();
    if (answer === null || answer === void 0) return;
    if (new TextEncoder().encode(answer).length > 524288) {
      row.body.append(node("p", "", "This reply exceeds the automatic preview limit. Copy the original reply to read it in full."));
      return;
    }
    const cards = [];
    const registered = new Map(row.model.references.map((reference, index) => [reference.target, {reference, index}]));
    const referenceForMarker = (marker) => /^(<repo:[^<>\s]+>|\(repo:[^()\s]+\))$/.test(marker) ? registered.get(marker.slice(1, -1)) : undefined;
    const referenceHTML = (entry, label) => {
      const a = node('a', 'repo', label ?? entry.reference.path);
      a.href = '#';
      a.title = entry.reference.path;
      a.dataset.reference = String(entry.index);
      return a.outerHTML;
    };
    const parser = new marked.Marked({ gfm: true, breaks: true, extensions: [{
      name: 'repoReference', level: 'inline',
      start(source) { return source.match(/<repo:|\(repo:/)?.index; },
      tokenizer(source) {
        const match = /^(<repo:[^<>\s]+>|\(repo:[^()\s]+\))/.exec(source);
        if (match) return {type:'repoReference', raw:match[0]};
      },
      renderer(token) {
        const entry = referenceForMarker(token.raw);
        return entry ? referenceHTML(entry) : node('span', '', token.raw).outerHTML;
      }
    }], renderer: {
      codespan(token) {
        const entry = referenceForMarker(token.text);
        return entry ? '<code>' + referenceHTML(entry) + '</code>' : false;
      },
      link(token) {
        const entry = registered.get(token.href);
        return entry ? referenceHTML(entry, token.text) : false;
      },
      code(token) {
        const key = cards.length;
        const fence = token.raw.match(/^ {0,3}(`{3,}|~{3,})/);
        const complete = !fence || new RegExp("\\n[ \\t]*" + fence[1][0] + "{" + fence[1].length + ",}[ \\t]*\\n?$").test(token.raw);
        cards.push({ source: token.text, language: (token.lang || "").split(/\s/)[0], complete });
        return `<div data-orbie-card="${key}"></div>`;
      },
      html(token) {
        if (token.text.startsWith("<repo:")) return token.text.replace(/</g, "&lt;").replace(/>/g, "&gt;");
        if (token.block) {
          const key = cards.length;
          cards.push({ source: token.text, language: "html", complete: true });
          return `<div data-orbie-card="${key}"></div>`;
        }
        return token.text;
      },
      image(token) {
        return imagePlaceholder(token.href, token.text).outerHTML;
      }
    } });
    const fragment = DOMPurify.sanitize(parser.parse(answer), { RETURN_DOM_FRAGMENT: true, USE_PROFILES: { html: true }, FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "video", "audio", "source", "button", "textarea", "select", "base", "meta", "link"], FORBID_ATTR: ["style", "id", "name", "src", "srcset", "sizes"] });
    for (const input of fragment.querySelectorAll("input")) {
      if (input.type === "checkbox") input.disabled = true;
      else input.remove();
    }
    for (const a of fragment.querySelectorAll("a")) {
      const index = a.dataset.reference;
      if (index !== void 0) {
        a.onclick = (event) => {
          event.preventDefault();
          send({ kind: "reference", messageID: row.model.id, reference: Number(index) });
        };
        continue;
      }
      const target = a.getAttribute("href") || "";
      a.onclick = (event) => {
        event.preventDefault();
        send({ kind: "url", messageID: row.model.id, target });
      };
    }
    const shownFiles = new Set();
    const insertions = new Map(), fileRequests = [];
    let htmlCount = 0;
    for (const link of fragment.querySelectorAll('a[data-reference]')) {
      const index = Number(link.dataset.reference), reference = row.model.references[index];
      if (!reference) continue;
      const isImage = reference.previewKind === 'image', isHTML = reference.previewKind === 'html';
      if ((!isImage && !isHTML) || shownFiles.has(reference.path)) continue;
      shownFiles.add(reference.path);
      let block = link;
      while (block.parentNode !== fragment) block = block.parentNode;
      const anchor = insertions.get(block) || block;
      let preview;
      if (isImage) {
        preview = node('div', 'file-image');
        preview.append(imagePlaceholder(reference.path, reference.path.split('/').pop(), index));
      } else if (htmlCount++ >= 4) {
        preview = node('p', 'issue', 'This reply previews at most four HTML files. Open the file link for more.');
      } else {
        const key = String(++serial);
        preview = node('p', 'issue', 'Loading HTML preview…');
        htmlFiles.set(key, { row, placeholder: preview });
        row.cleanup.push(() => htmlFiles.delete(key));
        fileRequests.push({ kind: 'html', messageID: row.model.id, reference: index, key });
      }
      anchor.after(preview);
      insertions.set(block, preview);
    }
    for (const el of fragment.querySelectorAll("[data-orbie-card]")) {
      const item = cards[Number(el.dataset.orbieCard)];
      if (!item) {
        el.remove();
        continue;
      }
      const language = item.language.toLowerCase();
      el.replaceWith(item.complete && ["html", "htm", "mermaid"].includes(language) ? previewCard(item.source, language, row, language === "mermaid" ? "mermaid" : "html") : codeBlock(item.source, language, row).card);
    }
    const paths = new Map(), plans = [];
    for (const img of fragment.querySelectorAll("img")) {
      const key = img.dataset.imageKey, target = img.dataset.imageReference;
      const index = img.dataset.repoReference === undefined ? undefined : Number(img.dataset.repoReference);
      const reference = index === undefined ? undefined : row.model.references[index];
      img.removeAttribute("data-image-reference");
      img.removeAttribute("data-repo-reference");
      if (!key || !target || (index !== undefined && reference?.previewKind !== 'image')) {
        img.remove();
        continue;
      }
      const payload = { kind: "image", messageID: row.model.id, key, ...(reference ? { reference: index } : { target }) };
      const encoder = new TextEncoder();
      if (!reference && (encoder.encode(target).length > 4096 || encoder.encode(JSON.stringify({...payload, kind: 'imagePath'})).length > 16384)) {
        img.replaceWith(node('small', 'issue', 'Image address exceeds the preview limit.'));
        continue;
      }
      let path = reference ? Promise.resolve({ path: reference.path }) : paths.get(target);
      if (!path) {
        path = resolveImagePath(row, target, key);
        paths.set(target, path);
      }
      plans.push(path.then(result => result && { ...result, image: img, payload, automatic: !!reference }));
      img.onclick = () => toggleImage(img, row);
    }
    row.body.append(fragment);
    Promise.all(plans).then(entries => {
      if (row.renderVersion !== version || !row.element.isConnected) return;
      const targets = new Map();
      for (const entry of entries) {
        if (!entry || !entry.image.isConnected) continue;
        if (entry.error) {
          entry.image.replaceWith(node('small', 'issue', entry.error));
          continue;
        }
        if (!targets.has(entry.path)) targets.set(entry.path, []);
        targets.get(entry.path).push(entry);
      }
      for (const positions of targets.values()) {
        const explicit = positions.filter(entry => !entry.automatic);
        const displayed = explicit.length ? explicit : positions.slice(0, 1);
        for (const entry of positions) if (!displayed.includes(entry)) (entry.image.closest('.file-image') || entry.image).remove();
        const key = positions[0].payload.key;
        const origin = positions.find(entry => entry.automatic) || positions[0];
        const group = { images: displayed.map(entry => entry.image), issues: [], payload: { ...origin.payload, key } };
        waitingImages.set(key, group);
        row.cleanup.push(() => {
          waitingImages.delete(key);
          if (images.delete(key)) requestImages();
        });
      }
      requestImages();
    });
    fileRequests.forEach(send);
  }
  function dispose(row) {
    row.observer.disconnect();
    row.cleanup.forEach((fn) => fn());
    row.element.remove();
  }
  window.orbieChat = {
    mermaidReady: error => completeMermaid?.(error),
    activeWidgets: () => [...rows.values()].reduce((n, row) => n + row.widgets.size, 0),
    update(messages, title, isDark) {
      const oldFollow = follow;
      const themeChanged = dark !== isDark;
      dark = isDark;
      document.documentElement.classList.toggle("dark", dark);
      const ids = new Set(messages.map((message) => message.id));
      for (const [id, row] of rows) if (!ids.has(id)) {
        dispose(row);
        rows.delete(id);
      }
      for (const model of messages) {
        let row = rows.get(model.id);
        if (!row) {
          const element = node("article");
          row = { element, model: null, user: node("div", "user"), author: node("div", "author"), activity: node("div", "activity"), body: node("div", "markdown-body"), actions: node("div", "actions"), issue: node("div", "issue"), cleanup: [], widgets: /* @__PURE__ */ new Map(), codes: [], diagramCount: 0, redrawDiagrams: [] };
          row.visible = false;
          row.observer = new IntersectionObserver(entries => {
            row.visible = entries.some(entry => entry.isIntersecting);
            if(row.visible && row.renderedAnswer !== row.model?.answer) renderAnswer(row);
          }, {rootMargin:'500px'});
          element.append(row.user, row.author, row.activity, row.body, row.issue, row.actions);
          rows.set(model.id, row);
          root.append(element);
          row.observer.observe(element);
        }
        const previous = row.model;
        row.model = model;
        if(!previous || previous.text !== model.text) row.user.textContent = model.text;
        if(row.author.textContent !== "\u2726 " + title) row.author.textContent = "\u2726 " + title;
        if (!previous || previous.answer !== model.answer) {
          if(row.visible) renderAnswer(row);
          else {
            row.cleanup.forEach(fn => fn());
            row.cleanup = [];
            row.widgets.clear();
            row.renderedAnswer = undefined;
            row.body.replaceChildren(node('p', 'issue', model.answer ? 'Preparing reply…' : ''));
          }
        }
        if (!previous || JSON.stringify(previous.activity) !== JSON.stringify(model.activity) || previous.pending !== model.pending) {
          const open = previous?.pending === model.pending && row.activity.querySelector('details')?.open === true;
          const history = node('details');
          history.open = open;
          history.append(node('summary', '', model.pending ? 'Earlier activity' : 'Agent activity'));
          const earlier = model.pending ? model.activity.slice(0, -3) : model.activity;
          for (const item of earlier) history.append(node('p', '', item));
          row.activity.replaceChildren();
          if (earlier.length) row.activity.append(history);
          if (model.pending) {
            const recent = node('div', 'recent-activity');
            for (const item of model.activity.slice(-3)) recent.append(node('p', '', item));
            row.activity.append(recent);
          }
          row.activity.hidden = !model.activity.length;
        }
        row.issue.textContent = model.issue || (!model.answer ? model.pending ? "Waiting for a verified reply\u2026" : "Stopped waiting. Check the Agent tab for work still in progress." : "");
        if (!previous || JSON.stringify(previous.actions) !== JSON.stringify(model.actions)) {
          row.actions.replaceChildren();
          for (const action of model.actions) row.actions.append(button(action.title, () => send({ kind: "action", messageID: model.id, target: action.id })));
        }
        if(themeChanged) for (const widget of row.widgets.values()) widget.setTheme(OrbieWidgets.defaultThemeTokens(dark ? "dark" : "light"));
        if(themeChanged) row.redrawDiagrams.forEach(redraw => redraw());
      }
      messages.forEach((model, index) => {
        const el = rows.get(model.id).element;
        if (root.children[index] !== el) root.insertBefore(el, root.children[index] || null);
      });
      follow = oldFollow;
      layout();
    },
    code(messageID, index) {
      return rows.get(messageID)?.codes[index - 1];
    },
    html(key, source, error) {
      const entry = htmlFiles.get(key);
      if (!entry || !entry.placeholder.isConnected) return;
      htmlFiles.delete(key);
      entry.placeholder.replaceWith(error ? node('p', 'issue', error) : previewCard(source, 'html', entry.row, 'html', true));
    },
    imagePath(key, path, error) {
      const resolve = imagePaths.get(key);
      imagePaths.delete(key);
      resolve?.({ path, error });
    },
    async image(key, base64, error, svg) {
      const group = images.get(key);
      if (!group) return;
      let source;
      if (!error) {
        try { source = svg ? svgImageURL(sanitizeSVG(svg)) : "data:image/png;base64," + base64; }
        catch { error = 'This image cannot be decoded.'; }
      }
      await Promise.all(group.images.map(async image => {
        let failure = error;
        if (!failure) {
          try {
            image.src = source;
            await image.decode();
          } catch { failure = 'This image cannot be decoded.'; }
        }
        if (images.get(key) !== group || !image.isConnected) return;
        if (failure) {
          image.removeAttribute('src');
          image.replaceWith(node('small', 'issue', failure));
        } else image.classList.remove('image-placeholder');
      }));
    }
  };
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      const expanded=document.querySelectorAll('.card.expanded [data-expand], img.expanded-image');
      if(expanded.length){event.preventDefault();event.stopPropagation();expanded.forEach(element=>element.click());}
    }
  });
  send({ kind: "ready" });
})();
