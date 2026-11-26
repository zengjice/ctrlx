"use strict";

function sanitizeSVG(source) {
  const fragment = DOMPurify.sanitize(source, {
    RETURN_DOM_FRAGMENT: true,
    USE_PROFILES: { svg: true, svgFilters: true },
    ADD_TAGS: ["use"],
    FORBID_TAGS: ["script", "foreignObject", "image", "a", "animate", "set"]
  });
  const root = fragment.querySelector("svg");
  if (!root) throw new Error("Invalid SVG");
  for (const element of [root, ...root.querySelectorAll("*")]) {
    for (const attribute of Array.from(element.attributes)) {
      if (attribute.localName === "href" && !attribute.value.startsWith("#")) element.removeAttributeNode(attribute);
    }
  }
  return root;
}

function svgImageURL(root) {
  // SVG is decoded as an isolated image document, never as inline page markup.
  const xml = new XMLSerializer().serializeToString(root);
  return "data:image/svg+xml;base64," + btoa(Array.from(new TextEncoder().encode(xml), byte => String.fromCharCode(byte)).join(""));
}
