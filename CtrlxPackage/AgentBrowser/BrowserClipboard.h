#pragma once

// Fixed, page-scoped scripts. Never read or replace the Mac's global pasteboard.
static NSString* BrowserClipboardCopyScript(NSNumber* x, NSNumber* y) {
  return [NSString stringWithFormat:@R"JS((() => {
    let doc = document, point = {x:%@, y:%@};
    for (let depth = 0; depth < 12; depth++) {
      let el = doc.activeElement;
      while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
      if (el?.tagName !== 'IFRAME' && el?.tagName !== 'FRAME') break;
      if (!el.contentDocument) throw Error('Copy from this embedded page is unavailable.');
      const rect = el.getBoundingClientRect();
      point = {x:point.x - rect.left, y:point.y - rect.top};
      doc = el.contentDocument;
    }
    let el = doc.activeElement;
    while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
    if (el?.type === 'password') throw Error('Password fields cannot be copied.');
    const text = typeof el?.selectionStart === 'number'
      ? el.value.slice(el.selectionStart, el.selectionEnd)
      : (doc.getSelection()?.toString() || '');
    if (text) {
      const bytes = new TextEncoder().encode(text);
      if (bytes.length > 393216) throw Error('Copy at most 384 KiB of text.');
      let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
      return {kind:'text', data:btoa(binary)};
    }
    let image = doc.elementFromPoint(point.x, point.y);
    while (image?.shadowRoot) {
      const child = image.shadowRoot.elementFromPoint(point.x, point.y);
      if (!child || child === image) break;
      image = child;
    }
    if (image?.tagName === 'IMG') return {imageURL:image.currentSrc || image.src};
    throw Error('Select text, or click an image, before copying.');
  })())JS", x ?: @0, y ?: @0];
}

static NSString* BrowserClipboardPasteScript(NSString* kind, NSString* encoded) {
  // Both fields are JSON-encoded by the caller, never interpolated as code.
  return [NSString stringWithFormat:@R"JS((() => {
    const kind = %@, encoded = %@;
    let doc = document, el;
    for (let depth = 0; depth < 12; depth++) {
      el = doc.activeElement;
      while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
      if (el?.tagName !== 'IFRAME' && el?.tagName !== 'FRAME') break;
      if (!el.contentDocument) throw Error('Paste into this embedded page is unavailable.');
      doc = el.contentDocument;
    }
    if (!el) throw Error('Select a field before pasting.');
    const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
    const transfer = new DataTransfer();
    let text = '';
    if (kind === 'text') {
      text = new TextDecoder('utf-8', {fatal:true}).decode(bytes);
      transfer.setData('text/plain', text);
    } else {
      const mime = kind === 'png' ? 'image/png' : 'image/jpeg';
      transfer.items.add(new File([bytes], kind === 'png' ? 'Clipboard.png' : 'Clipboard.jpg', {type:mime}));
    }
    const event = new ClipboardEvent('paste', {clipboardData:transfer, bubbles:true, cancelable:true, composed:true});
    if (!el.dispatchEvent(event)) return {accepted:true};
    if (kind === 'text' && (el.isContentEditable || el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')
        && !el.disabled && !el.readOnly && doc.execCommand('insertText', false, text)) return {accepted:true};
    if (kind !== 'text' && el.isContentEditable
        && doc.execCommand('insertImage', false, 'data:' + (kind === 'png' ? 'image/png' : 'image/jpeg') + ';base64,' + encoded))
      return {accepted:true};
    throw Error(kind === 'text' ? 'The focused field did not accept text.' : 'The focused page did not accept an image.');
  })())JS", kind, encoded];
}

class BrowserClipboardImage final : public CefDownloadImageCallback {
 public:
  explicit BrowserClipboardImage(std::function<void(NSData*, NSString*)> reply) : reply_(std::move(reply)) {}
  void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
    int width = 0, height = 0;
    auto bytes = image ? image->GetAsPNG(1.0, true, width, height) : nullptr;
    NSString* kind = @"png";
    if (bytes && bytes->GetSize() > 384 * 1024) {
      bytes = image->GetAsJPEG(1.0, 75, width, height);
      kind = @"jpeg";
    }
    if (!bytes || bytes->GetSize() > 384 * 1024) { reply_(nil, kind); return; }
    NSMutableData* data = [NSMutableData dataWithLength:bytes->GetSize()];
    bytes->GetData(data.mutableBytes, data.length, 0);
    reply_(data, kind);
  }
 private:
  std::function<void(NSData*, NSString*)> reply_;
  IMPLEMENT_REFCOUNTING(BrowserClipboardImage);
};
