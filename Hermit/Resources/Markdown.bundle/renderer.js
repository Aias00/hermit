// Per-preview caches only. Source remains local; no historical document cache.
(() => {
 'use strict';
 const target = document.getElementById('content');
 const appearance = matchMedia('(prefers-color-scheme:dark)');
 const options = {gfm:true, breaks:false};
 let generation = 0, pending = null, running = false, latestSource = null, latestMode;
 let appliedSource = null, appliedTheme = null, blocks = [], tokenCache = new Map();
 const diagrams = new Map();
 let diagramBytes = 0;
 const theme = () => (typeof latestMode === 'boolean' ? latestMode : appearance.matches) ? 'dark' : 'default';
 const counts = extra => Object.assign({
  diagrams:target.querySelectorAll('.diagram svg').length,
  headings:target.querySelectorAll('h1,h2,h3').length,
  tables:target.querySelectorAll('table').length
 }, extra);

 function rememberDiagram(key, svg) {
  const bytes = key.length + svg.length;
  if (bytes > 500000) return;
  diagrams.set(key, {svg, bytes}); diagramBytes += bytes;
  while (diagrams.size > 8 || diagramBytes > 1000000) {
   const first = diagrams.keys().next().value;
   diagramBytes -= diagrams.get(first).bytes; diagrams.delete(first);
  }
 }

 function build(source, currentTheme) {
  const nextCache = new Map();
  // Lex the complete source so reference definitions and unfinished fences
  // stay correct. Reuse HTML only for identical, fully resolved tokens.
  const html = marked.lexer(source, options).map(token => {
   const key = JSON.stringify(token);
   const value = tokenCache.has(key) ? tokenCache.get(key) : marked.parser([token], options);
   nextCache.set(key, value);
   return value;
  }).join('');
  const stage = document.createElement('main');
  stage.innerHTML = DOMPurify.sanitize(html, {
   USE_PROFILES:{html:true},
   FORBID_TAGS:['script','style','iframe','object','embed','img','video','audio','form'],
   FORBID_ATTR:['style','src','srcset','id']
  });
  stage.querySelectorAll('a').forEach(a => {
   if (!/^https?:\/\//i.test(a.getAttribute('href') || '')) a.removeAttribute('href');
  });
  stage.querySelectorAll('table').forEach(table => {
   const wrap = document.createElement('div'); wrap.className = 'table-scroll';
   table.replaceWith(wrap); wrap.append(table);
  });
  // A queue per key preserves duplicate paragraphs without aliasing nodes.
  const available = new Map();
  for (const block of blocks) {
   if (!available.has(block.key)) available.set(block.key, []);
   available.get(block.key).push(block.node);
  }
  let reused = 0;
  const next = [...stage.childNodes].map(node => {
   const hasDiagram = node.nodeType === Node.ELEMENT_NODE &&
    (node.matches('code.language-mermaid') || node.querySelector('code.language-mermaid'));
   const key = JSON.stringify([node.nodeType, node.outerHTML ?? node.textContent,
    hasDiagram ? currentTheme : null]);
   const cached = available.get(key)?.shift();
   if (cached) { reused++; return {key, node:cached}; }
   return {key, node};
  });
  return {next, nextCache, reused};
 }

 async function apply(request) {
  const {source, currentTheme, run} = request;
  document.documentElement.dataset.appearance = currentTheme;
  if (source === appliedSource && currentTheme === appliedTheme) {
   return counts({unchanged:true, reusedBlocks:blocks.length, renderedDiagrams:0});
  }
  const built = build(source, currentTheme);
  // Keep unchanged nodes in place: selection and diagram scroll offsets
  // survive updates to another paragraph.
  let cursor = target.firstChild;
  for (const {node} of built.next) {
   if (node === cursor) cursor = cursor.nextSibling;
   else target.insertBefore(node, cursor);
  }
  while (cursor) { const next = cursor.nextSibling; cursor.remove(); cursor = next; }
  blocks = built.next; tokenCache = built.nextCache;
  appliedSource = null; // Interrupted work must be completed by the next request.
  mermaid.initialize({startOnLoad:false, securityLevel:'strict', htmlLabels:false,
   theme:currentTheme, maxTextSize:20000, maxEdges:400, suppressErrorRendering:true,
   flowchart:{htmlLabels:false,useMaxWidth:false},
   secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','themeCSS','fontFamily','altFontFamily','htmlLabels']});
  let rendered = 0, reusedDiagrams = 0;
  // Count preserved diagrams too, retaining the eight-diagram work bound.
  let seen = target.querySelectorAll('.diagram').length;
  for (const code of target.querySelectorAll('code.language-mermaid')) {
   if (run !== generation) return {cancelled:true};
   if (code.parentElement?.tagName !== 'PRE') continue;
   if (seen++ >= 8 || code.textContent.length > 20000) continue;
   const pre = code.parentElement;
   const graph = code.textContent.replace(/%%\{[\s\S]*?\}%%/g,'').replace(/^---[\s\S]*?\n---\s*\n/,'');
   const key = JSON.stringify([graph,currentTheme]);
   try {
    let svg;
    if (diagrams.has(key)) {
     const cached = diagrams.get(key); diagrams.delete(key); diagrams.set(key,cached);
     svg = cached.svg; reusedDiagrams++;
    } else {
     const result = await mermaid.render('hermit-diagram-'+run+'-'+seen,graph);
     if (run !== generation) return {cancelled:true};
     svg = DOMPurify.sanitize(result.svg, {USE_PROFILES:{svg:true,svgFilters:true},
      ADD_TAGS:['style'],FORBID_TAGS:['foreignObject','script','image','a'],FORBID_ATTR:['href','xlink:href']});
     rememberDiagram(key,svg); rendered++;
    }
    const box = document.createElement('div'); box.className = 'diagram';
    // Cached SVG is sanitized above; use unique IDs for repeated diagrams.
    // Reusing nodes avoids this path for diagrams already on the page.
    box.innerHTML = svg;
    const ids = new Map([...box.querySelectorAll('[id]')].map((element,index) =>
     [element.id, 'hermit-svg-'+run+'-'+seen+'-'+index]));
    const idPattern = [...ids.keys()].sort((a,b) => b.length-a.length)
     .map(id => id.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')).join('|');
    if (idPattern) box.querySelectorAll('style').forEach(style => {
     style.textContent = style.textContent.replace(new RegExp('#('+idPattern+')(?![\\w-])','g'),
      (_,id) => '#'+ids.get(id));
    });
    box.querySelectorAll('*').forEach(element => {
     for (const attr of [...element.attributes]) {
      let value = attr.value;
      if (attr.name === 'id' && ids.has(value)) value = ids.get(value);
      else if (attr.name === 'aria-labelledby' || attr.name === 'aria-describedby') {
       value = value.split(/\s+/).map(id => ids.get(id) ?? id).join(' ');
      } else value = value.replace(/url\((['"]?)#([^)'" ]+)\1\)/g,
       (match,quote,id) => ids.has(id) ? 'url(#'+ids.get(id)+')' : match);
      if (value !== attr.value) element.setAttribute(attr.name,value);
     }
    });
    // Keep the top-level source node stable for block reuse (normally pre).
    pre.replaceChildren(box);
    pre.classList.add('mermaid-preview');
   } catch (_) {
    if (run !== generation) return {cancelled:true};
    pre.querySelectorAll(':scope > .diagram-error').forEach(note => note.remove());
    const note = document.createElement('p'); note.className = 'diagram-error';
    note.textContent = '图表内容不完整或格式不受支持，已保留源码。'; pre.prepend(note);
   }
  }
  if (run !== generation) return {cancelled:true};
  appliedSource = source; appliedTheme = currentTheme;
  return counts({reusedBlocks:built.reused, renderedDiagrams:rendered, reusedDiagrams});
 }

 async function drain() {
  running = true;
  try {
   while (pending) {
    const request = pending; pending = null;
    try { request.resolve(await apply(request)); } catch (error) { request.reject(error); }
   }
  } finally { running = false; }
 }
 window.renderMarkdown = (source,darkMode) => {
  latestSource = source;
  latestMode = darkMode;
  return new Promise((resolve,reject) => {
   if (pending) pending.resolve({cancelled:true});
   pending = {source:source.slice(0,200000),currentTheme:theme(),run:++generation,resolve,reject};
   if (!running) void drain();
  });
 };
 appearance.addEventListener('change', () => {
  if (latestSource !== null) window.renderMarkdown(latestSource,latestMode).catch(() => {});
 });
})();
