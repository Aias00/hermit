(() => {
 'use strict';
 const content = document.getElementById('content');
 const sources = new WeakMap(), actions = new WeakSet();
 let expansionID = 0;
 let outline = [], query = '', marks = [], selected = -1, limited = false;
 let expanded = null, restoreFocus = null, preservedIndex = null;
 const send = value => window.webkit?.messageHandlers?.hermitMarkdown?.postMessage(value);
 const state = () => ({outline, query, count:marks.length, index:selected + 1, limited});
 const report = () => send({type:'state', ...state()});
 const button = (title, action) => {
  const node = document.createElement('button'); node.type = 'button';
  node.textContent = title; node.dataset.readerAction = action; actions.add(node); return node;
 };
 function clearMarks() {
  for (const mark of marks) mark.replaceWith(document.createTextNode(mark.textContent));
  content.normalize(); marks = []; selected = -1; limited = false;
 }
 function select(index, scroll) {
  for (const mark of marks) mark.classList.remove('reader-current');
  selected = marks.length ? (index + marks.length) % marks.length : -1;
  if (selected >= 0) {
   marks[selected].classList.add('reader-current');
   if (scroll) marks[selected].scrollIntoView({block:'center', behavior:'instant'});
  }
 }
 function search(value, move = 0, scroll = true) {
  value = String(value).slice(0,256);
  if (value === query) {
   if (move && marks.length) select(selected + move, scroll);
   report(); return state();
  }
  query = value; clearMarks();
  if (query.trim()) {
   const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'), 'giu');
   const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
    acceptNode: node => node.parentElement?.closest('svg,button,.reader-tools')
     ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
   });
   const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
   outer: for (const node of nodes) {
    const text = node.textContent; pattern.lastIndex = 0;
    let match, offset = 0; const fragment = document.createDocumentFragment();
    while ((match = pattern.exec(text))) {
     if (marks.length === 1000) { limited = true; break; }
     fragment.append(document.createTextNode(text.slice(offset, match.index)));
     const mark = document.createElement('mark'); mark.className = 'reader-match';
     mark.textContent = match[0]; marks.push(mark); fragment.append(mark);
     offset = match.index + match[0].length;
    }
    if (offset) { fragment.append(document.createTextNode(text.slice(offset))); node.replaceWith(fragment); }
    if (limited) break outer;
   }
  }
  select(0, scroll); report(); return state();
 }
 function closeExpanded() {
  if (!expanded) return;
  expanded.close(); expanded.remove(); expanded = null;
  restoreFocus?.focus({preventScroll:true}); restoreFocus = null;
 }
 function expand(element, trigger) {
  closeExpanded(); restoreFocus = trigger;
  const dialog = document.createElement('dialog'); dialog.className = 'reader-dialog';
  const toolbar = document.createElement('div'); toolbar.className = 'reader-expanded-tools';
  const label = document.createElement('strong'); label.textContent = element.tagName === 'TABLE' ? '表格' : '图表';
  toolbar.append(label, button('缩小','zoom-out'), button('放大','zoom-in'), button('重置','zoom-reset'), button('关闭','close'));
  const viewport = document.createElement('div'); viewport.className = 'reader-expanded-viewport';
  const clone = element.cloneNode(true);
  const all = [clone,...clone.querySelectorAll('*')], prefix = 'hermit-expanded-' + (++expansionID) + '-';
  const ids = new Map(all.filter(n=>n.id).map((n,i)=>[n.id,prefix+i]));
  const pattern = [...ids.keys()].sort((a,b)=>b.length-a.length).map(id=>id.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')).join('|');
  if (pattern) clone.querySelectorAll('style').forEach(style => {
   style.textContent = style.textContent.replace(new RegExp('#('+pattern+')(?![\\w-])','g'),(_,id)=>'#'+ids.get(id));
  });
  all.forEach(node => { for (const attr of [...node.attributes]) {
   let value = attr.value;
   if (attr.name === 'id') value = ids.get(value) ?? value;
   else if (attr.name === 'aria-labelledby' || attr.name === 'aria-describedby') value = value.split(/\s+/).map(id=>ids.get(id)??id).join(' ');
   else value = value.replace(/url\((['"]?)#([^)\'" ]+)\1\)/g,(match,quote,id)=>ids.has(id)?'url(#'+ids.get(id)+')':match);
   if (value !== attr.value) node.setAttribute(attr.name,value);
  }});
  viewport.append(clone); dialog.append(toolbar, viewport);
  document.body.append(dialog); expanded = dialog;
  let scale = 1;
  const initialWidth = Math.max(element.getBoundingClientRect().width, element.scrollWidth, 300);
  const update = () => {
   if (clone.tagName.toLowerCase() === 'svg') {
    clone.style.width = initialWidth * scale + 'px'; clone.style.height = 'auto';
   } else { clone.style.fontSize = scale + 'em'; }
  };
  toolbar.addEventListener('click', event => {
   const action = event.target.closest('button')?.dataset.readerAction;
   if (action === 'close') { closeExpanded(); return; }
   if (action === 'zoom-in') scale = Math.min(4, scale + .25);
   if (action === 'zoom-out') scale = Math.max(.5, scale - .25);
   if (action === 'zoom-reset') scale = 1;
   update();
  });
  dialog.addEventListener('cancel', event => { event.preventDefault(); closeExpanded(); });
  dialog.showModal(); update(); toolbar.querySelector('[data-reader-action="close"]').focus();
 }
 function refresh() {
  const oldQuery = query, oldIndex = preservedIndex ?? selected; preservedIndex = null;
  clearMarks();
  outline = [...content.querySelectorAll('h1,h2,h3')].slice(0,200).map((node,index) => {
   node.id = 'hermit-heading-' + index;
   return {id:node.id, level:Number(node.tagName.slice(1)), title:node.textContent.slice(0,200)};
  });
  content.querySelectorAll('pre').forEach(pre => {
   if (pre.querySelector(':scope > .reader-tools')) return;
   const tools = document.createElement('div'); tools.className = 'reader-tools';
   if (sources.has(pre)) tools.append(button('复制代码','copy-code'));
   if (pre.querySelector('.diagram svg')) tools.append(button('放大图表','expand-diagram'));
   if (tools.childNodes.length) pre.prepend(tools);
  });
  content.querySelectorAll('.table-scroll').forEach(wrap => {
   if (wrap.querySelector(':scope > .reader-tools')) return;
   const tools = document.createElement('div'); tools.className = 'reader-tools';
   tools.append(button('全屏表格','expand-table')); wrap.prepend(tools);
  });
  query = ''; search(oldQuery, 0, false); select(oldIndex >= 0 ? oldIndex : 0, false); report();
 }
 content.addEventListener('click', event => {
  const trigger = event.target.closest('button[data-reader-action]'); if (!trigger || !actions.has(trigger)) return;
  if (trigger.dataset.readerAction === 'copy-code') {
   const text = sources.get(trigger.closest('pre')); if (typeof text === 'string') send({type:'copy',text});
  } else if (trigger.dataset.readerAction === 'expand-diagram') {
   const graph = trigger.closest('pre')?.querySelector('.diagram svg'); if (graph) expand(graph,trigger);
  } else if (trigger.dataset.readerAction === 'expand-table') {
   const table = trigger.closest('.table-scroll')?.querySelector('table'); if (table) expand(table,trigger);
  }
 });
 window.hermitMarkdownReader = {
  state, search, refresh,
  remember(root) { root.querySelectorAll('pre > code').forEach(code => sources.set(code.parentElement,code.textContent)); },
  prepare() { closeExpanded(); if (preservedIndex === null) preservedIndex = selected; clearMarks(); },
  jump(id) {
   if (!outline.some(row => row.id === id)) return false;
   document.getElementById(id)?.scrollIntoView({block:'start',behavior:'instant'}); return true;
  }
 };
 if (content.childNodes.length) refresh();
})();
