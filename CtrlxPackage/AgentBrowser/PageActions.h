#pragma once
#include <string>

// Fixed, versioned page operations. JSON is data, never caller-provided code.
// Only the main document is supported; frames/editors remain explicit handoffs.
inline std::string PageAction(const std::string& operation, const std::string& arguments) {
  return "((op,p)=>{" + std::string(R"JS(
    const visible=e=>!!e.getClientRects().length &&
      !['hidden','collapse'].includes(getComputedStyle(e).visibility) &&
      e.getBoundingClientRect().width>0 && e.getBoundingClientRect().height>0;
    const one=s=>{const es=document.querySelectorAll(s);
      if(es.length!==1)throw Error('unique target required');return es[0]};
    const editable=e=>e.matches('textarea')||e.matches('input')&&
      ['text','search','email','url','tel'].includes(e.type);
    const interactive=e=>{if(!visible(e)||e.matches(':disabled')||e.closest('[inert]'))
      throw Error('not interactive');};
    const selector=e=>{
      if(e.id && document.querySelectorAll('#'+CSS.escape(e.id)).length===1)return '#'+CSS.escape(e.id);
      const path=[];for(let n=e;n&&n.nodeType===1;n=n.parentElement){
        const siblings=n.parentElement?[...n.parentElement.children].filter(s=>s.tagName===n.tagName):[n];
        path.unshift(n.tagName.toLowerCase()+':nth-of-type('+(siblings.indexOf(n)+1)+')');
      }return path.join(' > ');
    };
    if(op==='wait'){
      if(p.state==='ready')return {matched:document.readyState!=='loading',state:p.state};
      const es=document.querySelectorAll(p.selector);
      if(es.length>1)throw Error('unique target required');const e=es[0];
      const matched=p.state==='hidden'?!e||!visible(e):!!e&&
        (p.state==='attached'||visible(e))&&
        (p.state!=='enabled'||!e.matches(':disabled')&&!e.closest('[inert]'))&&
        (p.text===undefined||(e.innerText||e.textContent||'').includes(p.text));
      return {matched,state:p.state};
    }
    if(op==='read'){
      const root=p.selector?one(p.selector):document.body;
      const text=root?.innerText||'';
      const interactiveQuery='input,textarea,button,a,select,[role="button"],[role="checkbox"],[role="radio"],[contenteditable="true"]';
      // Keep the existing controls/pagination contract, but also expose readable
      // targets: without their selectors, agents cannot scope reads or wait for
      // result text. Named regions cover common nested scroll containers too.
      const query=interactiveQuery+',body,main,article,section,p,li,pre,h1,h2,h3,h4,h5,h6,[id],[role="status"],[role="alert"]';
      const all=root?[...(root.matches(query)?[root]:[]),...root.querySelectorAll(query)].filter(visible):[];
      const controls=all.slice(p.controlOffset,p.controlOffset+p.controlLimit).map(e=>{
        const c={selector:selector(e),kind:e.matches(interactiveQuery)?'control':'region',tag:e.tagName.toLowerCase(),type:e.type||'',
          text:(e.innerText||e.getAttribute('aria-label')||e.placeholder||'').slice(0,200),
          disabled:e.matches(':disabled')||!!e.closest('[inert]'),readOnly:!!e.readOnly,focused:document.activeElement===e};
        const style=getComputedStyle(e),page=e===document.scrollingElement;
        const sx=(page||/auto|scroll/.test(style.overflowX))&&e.scrollWidth>e.clientWidth;
        const sy=(page||/auto|scroll/.test(style.overflowY))&&e.scrollHeight>e.clientHeight;
        if(sx||sy)c.scroll={x:e.scrollLeft,y:e.scrollTop,maxX:sx?e.scrollWidth-e.clientWidth:0,maxY:sy?e.scrollHeight-e.clientHeight:0};
        // Never return password/file/hidden values, or their selected file paths.
        if(editable(e)||e.matches('select')){c.value=e.value.slice(0,2000);c.valueTruncated=e.value.length>2000;}
        if(e.matches('input[type=checkbox],input[type=radio]')){c.checked=e.checked;c.indeterminate=e.indeterminate;}
        if(e.hasAttribute('aria-checked'))c.ariaChecked=e.getAttribute('aria-checked');
        if(e.matches('select')){
          c.options=[...e.options].slice(0,100).map(o=>({value:o.value.slice(0,2000),text:o.text.slice(0,200),
            selected:o.selected,disabled:o.disabled||!!o.closest('optgroup:disabled')}));
          c.optionsTruncated=e.options.length>100;c.multiple=e.multiple;
        }return c;
      });
      const textEnd=Math.min(text.length,p.textOffset+p.textLimit);
      const controlsEnd=Math.min(all.length,p.controlOffset+p.controlLimit);
      return {title:document.title,url:location.href,text:text.slice(p.textOffset,textEnd),
        truncated:textEnd<text.length,textOffset:p.textOffset,textLength:text.length,
        nextTextOffset:textEnd<text.length?textEnd:null,controls,controlOffset:p.controlOffset,
        controlCount:all.length,nextControlOffset:controlsEnd<all.length?controlsEnd:null};
    }
    if(op==='scroll'){
      const e=p.selector?one(p.selector):document.scrollingElement;
      if(!e||!visible(e))throw Error('not scrollable');
      if(p.selector)e.scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});
      const before={x:e.scrollLeft,y:e.scrollTop};
      e.scrollBy({left:p.deltaX,top:p.deltaY,behavior:'instant'});
      return {x:e.scrollLeft,y:e.scrollTop,maxX:Math.max(0,e.scrollWidth-e.clientWidth),
        maxY:Math.max(0,e.scrollHeight-e.clientHeight),changed:before.x!==e.scrollLeft||before.y!==e.scrollTop};
    }
    if(op==='press'){
      if(p.selector){const e=one(p.selector);interactive(e);e.scrollIntoView({block:'center',behavior:'instant'});
        e.focus();if(document.activeElement!==e)throw Error('focus failed');}
      return true;
    }
    const e=one(p.selector);interactive(e);
    if(op==='type'||op==='fill'){
      if(!editable(e)||e.readOnly)throw Error('unsupported input');
      e.scrollIntoView({block:'center',inline:'center',behavior:'instant'});e.focus();
      if(document.activeElement!==e)throw Error('focus failed');
      if(op==='fill')e.select();return true;
    }
    if(op==='select'){
      if(!e.matches('select')||e.multiple)throw Error('native single-select required');
      const matches=[...e.options].filter(o=>o.value===p.value);
      if(matches.length!==1||matches[0].disabled||matches[0].closest('optgroup:disabled'))
        throw Error('unique enabled option required');
      if(e.value===p.value)return {value:e.value,changed:false};
      e.scrollIntoView({block:'center',behavior:'instant'});e.focus();
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(e,p.value);
      // Native select value semantics (like selectOption), not an OS popup click.
      e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
      if(e.value!==p.value)throw Error('selection rejected');return {value:e.value,changed:true};
    }
    if(op==='verifyCheck'){
      if(e.checked!==p.checked||e.indeterminate)throw Error('checked state rejected');
      return {checked:e.checked,changed:true};
    }
    if(op==='check'){
      if(!e.matches('input[type=checkbox],input[type=radio]'))throw Error('native checkbox/radio required');
      if(e.type==='radio'&&!p.checked)throw Error('select another radio instead');
      if(e.checked===p.checked&&!e.indeterminate)return {checked:e.checked,changed:false};
      // One click must produce the requested state; never toggle speculatively.
      if(e.indeterminate&&e.checked===p.checked)throw Error('ambiguous indeterminate state');
    }
    e.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
    const r=e.getBoundingClientRect(),x=(Math.max(0,r.left)+Math.min(innerWidth,r.right))/2,
      y=(Math.max(0,r.top)+Math.min(innerHeight,r.bottom))/2;
    if(!e.contains(document.elementFromPoint(x,y)))throw Error('target obscured');return {x,y};
  )JS") + "})(\"" + operation + "\"," + arguments + ")";
}
