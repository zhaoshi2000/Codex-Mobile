// Turn native Desktop output-file directives into links older mobile clients understand.
// Code examples are kept literal and do not grant access to the referenced files.
export function fileCitations(text) {
  const found = [];
  const tokens = /(^[ \t]*(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^[ \t]*\2[^\n]*(?:\n|$)|(?![\s\S])))|(`+)[^\n]*?\3|:{1,2}codex-file-citation\{((?:"(?:\\.|[^"\\])*"|[^"}])*)\}/gm;
  for (const m of String(text).matchAll(tokens)) {
    if (m[4] === undefined) continue;
    const attrs = [...m[4].matchAll(/([\w-]+)\s*=\s*"((?:\\.|[^"\\])*)"/g)];
    const paths = attrs.filter(a => a[1] === 'path');
    if (paths.length !== 1) continue;
    const path = paths[0][2].replace(/\\([\\"])/g, '$1');
    if (!/^(?:[A-Za-z]:[\\/]|\/)/.test(path) || /[\x00-\x1f<>]/.test(path) || path.length > 4096) continue;
    found.push({start: m.index, end: m.index + m[0].length, path});
  }
  return found;
}

export function renderFileCitations(text) {
  let rendered = text;
  for (const citation of fileCitations(text).reverse()) {
    const name = citation.path.split(/[\\/]/).at(-1).replace(/[\\`*_[\]]/g, '\\$&');
    rendered = rendered.slice(0, citation.start) + `📄 [${name}](<${citation.path}>)` + rendered.slice(citation.end);
  }
  return rendered;
}
