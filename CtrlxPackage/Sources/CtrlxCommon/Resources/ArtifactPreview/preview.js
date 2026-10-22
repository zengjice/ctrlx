"use strict";

window.renderPreview = async function (content, kind, dark) {
  const container = document.getElementById("content");
  container.replaceChildren();
  container.setAttribute("role", kind === "markdown" ? "article" : "img");
  container.setAttribute("aria-label", kind === "markdown" ? "Markdown preview" : "Artifact preview");
  document.body.className = kind === "markdown" ? "markdown" + (dark ? " dark" : "") : "";
  if (kind === "markdown") return window.renderMarkdown(content, dark);
  if (kind === "image") {
    const image = new Image();
    image.alt = "Image preview";
    image.src = "data:image/png;base64," + content;
    await image.decode();
    container.appendChild(image);
    return content;
  }

  window.configureMermaid(dark);
  const rendered = await mermaid.render("artifactDiagram", content);
  container.innerHTML = rendered.svg;
  const svg = container.querySelector("svg");
  const bounds = svg.viewBox.baseVal;
  const width = bounds.width || svg.getBoundingClientRect().width;
  const height = bounds.height || svg.getBoundingClientRect().height;
  if (!(width > 0 && height > 0)) throw new Error("The diagram has no visible content.");
  svg.setAttribute("width", width);
  svg.setAttribute("height", height);
  svg.style.maxWidth = "100%";

  // Export the entire diagram, independently of the current viewport/zoom.
  const exported = svg.cloneNode(true);
  exported.style.maxWidth = "none";
  const xml = new XMLSerializer().serializeToString(exported);
  const image = new Image();
  image.src = "data:image/svg+xml;base64," + btoa(Array.from(new TextEncoder().encode(xml), b => String.fromCharCode(b)).join(""));
  await image.decode();
  const scale = Math.min(2, 4096 / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.ceil(width * scale));
  canvas.height = Math.max(1, Math.ceil(height * scale));
  const context = canvas.getContext("2d");
  context.fillStyle = dark ? "#1e1e1e" : "#ffffff";
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL("image/png").split(",")[1];
};

window.configureMermaid = function (dark) {
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: dark ? "dark" : "default",
    htmlLabels: false,
    flowchart: { htmlLabels: false },
    maxTextSize: 65536,
    maxEdges: 500,
    suppressErrorRendering: true,
    secure: ["secure", "securityLevel", "startOnLoad", "maxTextSize", "maxEdges", "htmlLabels", "flowchart", "theme", "suppressErrorRendering"]
  });
};
