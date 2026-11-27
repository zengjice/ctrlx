"use strict";

window.renderPreview = async function (content, kind, dark) {
  const container = document.getElementById("content");
  container.replaceChildren();
  container.setAttribute("role", kind === "markdown" ? "article" : "img");
  container.setAttribute("aria-label", kind === "markdown" ? "Markdown preview" : "Artifact preview");
  document.body.className = kind === "markdown" ? "markdown" + (dark ? " dark" : "") : "";
  if (kind === "markdown") return window.renderMarkdown(content, dark);
  if (kind === "image") return showPreviewPNG(container, content, "Image preview");

  if (kind === "svg") {
    const image = new Image();
    const svg = sanitizeSVG(content);
    image.src = svgImageURL(svg);
    await image.decode();
    const bounds = svg.viewBox.baseVal;
    const hasFixedSize = ["width", "height"].every(name => {
      const length = svg[name].baseVal;
      return svg.hasAttribute(name) && length.valueInSpecifiedUnits > 0 && length.unitType !== SVGLength.SVG_LENGTHTYPE_PERCENTAGE;
    });
    const fitsViewBox = !hasFixedSize && bounds.width > 0 && bounds.height > 0;
    const width = fitsViewBox ? bounds.width : image.naturalWidth;
    const height = fitsViewBox ? bounds.height : image.naturalHeight;
    if (!(width > 0 && height > 0)) throw new Error("The SVG has no visible content.");
    // View-box coordinates measure drawing units. Fit them directly to the PNG pixel limit.
    const png = exportPreviewImage(image, width, height, undefined, fitsViewBox ? Infinity : 2);
    return showPreviewPNG(container, png, "SVG preview");
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
  const image = new Image();
  image.src = svgImageURL(exported);
  await image.decode();
  return exportPreviewImage(image, width, height, dark ? "#1e1e1e" : "#ffffff");
};

async function showPreviewPNG(container, png, alt) {
  const image = new Image();
  image.alt = alt;
  image.src = "data:image/png;base64," + png;
  await image.decode();
  container.appendChild(image);
  return png;
}

function exportPreviewImage(image, width, height, background, maximumScale = 2) {
  const scale = Math.min(maximumScale, 4096 / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  const context = canvas.getContext("2d");
  if (background) {
    context.fillStyle = background;
    context.fillRect(0, 0, canvas.width, canvas.height);
  }
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL("image/png").split(",")[1];
}

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
