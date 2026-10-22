"use strict";

const markdownImages = new Map();
function escapeHTML(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
const markdownParser = new marked.Marked({
  gfm: true,
  renderer: {
    html({ text }) { return escapeHTML(text); },
    // No src is created until the Host has returned validated image bytes.
    image({ href, text }) { return '<img data-markdown-image="' + escapeHTML(href) + '" alt="' + escapeHTML(text) + '">'; }
  }
});

function headingID(text) {
  return "md-" + text.toLowerCase().replace(/[^\p{L}\p{N}_\-\s]/gu, "").replace(/\s/g, "-");
}

window.renderMarkdown = async function (source, dark) {
  markdownImages.clear();
  const container = document.getElementById("content");
  const fragment = DOMPurify.sanitize(markdownParser.parse(source), {
    RETURN_DOM_FRAGMENT: true,
    USE_PROFILES: { html: true },
    FORBID_TAGS: ["style", "iframe", "object", "embed", "form", "video", "audio", "source", "button", "textarea", "select"],
    FORBID_ATTR: ["style", "srcset", "sizes", "id", "name"]
  });
  const headings = new Map();
  for (const heading of fragment.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    const id = headingID(heading.textContent);
    const count = headings.get(id) || 0;
    headings.set(id, count + 1);
    heading.id = id + (count ? "-" + count : "");
  }
  for (const input of fragment.querySelectorAll("input")) {
    if (input.type === "checkbox") input.disabled = true;
    else input.remove();
  }
  for (const link of fragment.querySelectorAll("a[href]")) {
    const target = link.getAttribute("href");
    link.removeAttribute("target");
    if (target.startsWith("#")) {
      link.addEventListener("click", event => {
        event.preventDefault();
        let fragment;
        try { fragment = decodeURIComponent(target.slice(1)); } catch { return; }
        document.getElementById(headingID(fragment))?.scrollIntoView();
      });
    } else {
      link.href = "ctrlx-preview://link?target=" + encodeURIComponent(target);
    }
  }
  for (const image of fragment.querySelectorAll("img")) {
    const reference = image.getAttribute("data-markdown-image") || "";
    image.removeAttribute("data-markdown-image");
    image.removeAttribute("src");
    const wrapper = document.createElement("span");
    wrapper.className = "markdown-image";
    const status = document.createElement("small");
    status.className = "markdown-error";
    status.textContent = "Loading image…";
    image.replaceWith(wrapper);
    wrapper.append(image, status);
    if (!markdownImages.has(reference) && markdownImages.size >= 24) {
      status.textContent = "This preview displays at most 24 images.";
      continue;
    }
    if (!markdownImages.has(reference)) markdownImages.set(reference, []);
    markdownImages.get(reference).push({ image, status });
  }
  container.replaceChildren(fragment);
  window.configureMermaid(dark);
  let diagramIndex = 0;
  for (const code of container.querySelectorAll("pre > code.language-mermaid")) {
    const pre = code.parentElement;
    const text = code.textContent;
    const index = diagramIndex++;
    try {
      if (index >= 16) throw new Error("This preview displays at most 16 diagrams.");
      if (new TextEncoder().encode(text).length > 65536) throw new Error("This diagram exceeds 64 KiB.");
      const rendered = await mermaid.render("markdownDiagram" + index, text);
      const figure = document.createElement("div");
      figure.className = "markdown-diagram";
      figure.innerHTML = rendered.svg;
      pre.replaceWith(figure);
    } catch (error) {
      const message = document.createElement("small");
      message.className = "markdown-error";
      message.textContent = index >= 16 || new TextEncoder().encode(text).length > 65536
        ? error.message : "This diagram could not be rendered. Its source is shown below.";
      pre.before(message);
    }
  }
  return Array.from(markdownImages.keys());
};

window.setMarkdownImage = async function (reference, base64, svg, error) {
  for (const { image, status } of markdownImages.get(reference) || []) {
    if (error) {
      status.textContent = (image.alt ? image.alt + ": " : "") + error;
      continue;
    }
    try {
      if (svg) {
        const fragment = DOMPurify.sanitize(svg, {
          RETURN_DOM_FRAGMENT: true,
          USE_PROFILES: { svg: true, svgFilters: true },
          FORBID_TAGS: ["script", "foreignObject", "image", "a", "animate", "set"]
        });
        const root = fragment.querySelector("svg");
        if (!root) throw new Error("Invalid SVG");
        for (const element of root.querySelectorAll("*")) {
          for (const attribute of Array.from(element.attributes)) {
            if (attribute.localName === "href" && !attribute.value.startsWith("#")) element.removeAttributeNode(attribute);
          }
        }
        // An SVG image is an isolated image document, never inline page markup.
        const xml = new XMLSerializer().serializeToString(root);
        image.src = "data:image/svg+xml;base64," + btoa(Array.from(new TextEncoder().encode(xml), b => String.fromCharCode(b)).join(""));
      } else image.src = "data:image/png;base64," + base64;
      await image.decode();
      status.remove();
    } catch {
      image.removeAttribute("src");
      status.textContent = "This image cannot be decoded.";
    }
  }
};
