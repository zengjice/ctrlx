#pragma once
#include <string>

// Hold the actual element and option nodes in a CDP object group, never a CSS
// selector that could silently resolve to a replacement control later.
inline std::string BrowserSelectProbe(const std::string& point) {
  return "(p=>{" + std::string(R"JS(
    const inert=e=>{for(let n=e;n;n=n.parentElement||n.getRootNode().host)if(n.inert)return true;return false};
    const visible=e=>e.getClientRects().length&&e.getBoundingClientRect().width>0&&
      e.getBoundingClientRect().height>0&&!['hidden','collapse'].includes(getComputedStyle(e).visibility);
    let hit=document.elementFromPoint(p.x,p.y);
    for(let i=0;hit?.shadowRoot&&i<32;i++){
      const next=hit.shadowRoot.elementFromPoint(p.x,p.y);if(!next||next===hit)break;hit=next;
    }
    let e=hit?.closest('select');
    if(!e){
      const label=hit?.closest('label');
      const interactive=hit?.closest('a[href],audio[controls],button,details,embed,iframe,img[usemap],input,select,summary,textarea,video[controls],[contenteditable]:not([contenteditable="false"])');
      if(label&&(!interactive||!label.contains(interactive)))e=label.control;
    }
    if(!(e instanceof HTMLSelectElement)||e.multiple||e.size>1||e.matches(':disabled')||inert(e)||!visible(e))return null;
    e.focus({preventScroll:true});
    if(!e.isConnected||e.ownerDocument!==document||e.matches(':disabled')||inert(e)||!visible(e))
      throw Error('The select changed. Click it again.');
    if(!e.options.length)return null;
    if(e.options.length>512)throw Error('Select menus support at most 512 options.');
    const options=[...e.options].map(o=>({node:o,value:o.value,text:o.label,
      selected:o.selected,disabled:o.disabled||!!o.closest('optgroup:disabled')}));
    return {element:e,document,options,selectedIndex:e.selectedIndex,
      title:(e.getAttribute('aria-label')||e.labels?.[0]?.innerText||e.title||'').slice(0,200)};
  )JS") + "})(" + point + ")";
}

inline const char* BrowserSelectDescribe() {
  return R"JS(function(){return {title:this.title,options:this.options.map((o,index)=>({
    index,text:o.text.slice(0,200),selected:o.selected,disabled:o.disabled}))};})JS";
}

inline const char* BrowserSelectChoose() {
  return R"JS(function(index){
    const inert=e=>{for(let n=e;n;n=n.parentElement||n.getRootNode().host)if(n.inert)return true;return false};
    const e=this.element,options=[...e.options];
    if(this.document!==document||!e.isConnected||e.ownerDocument!==document||e.multiple||e.size>1||
      e.matches(':disabled')||inert(e)||!e.getClientRects().length||
      e.getBoundingClientRect().width<=0||e.getBoundingClientRect().height<=0||
      ['hidden','collapse'].includes(getComputedStyle(e).visibility)||e.selectedIndex!==this.selectedIndex||
      options.length!==this.options.length||options.some((o,i)=>{
        const saved=this.options[i];return o!==saved.node||o.value!==saved.value||o.label!==saved.text||
          o.selected!==saved.selected||(o.disabled||!!o.closest('optgroup:disabled'))!==saved.disabled;
      }))throw Error('The select changed. Click it again.');
    const option=options[index];
    if(!Number.isInteger(index)||!option||this.options[index].disabled)throw Error('This option is unavailable.');
    if(e.selectedIndex===index)return {changed:false};
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'selectedIndex').set.call(e,index);
    e.dispatchEvent(new Event('input',{bubbles:true,composed:true}));
    e.dispatchEvent(new Event('change',{bubbles:true}));
    return {changed:true};
  })JS";
}
