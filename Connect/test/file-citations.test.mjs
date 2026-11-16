import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileCitations, renderFileCitations} from '../src/file-citations.mjs';
import {messages} from '../src/timeline.mjs';
import {matchesLinkedFile} from '../src/download-access.mjs';

test('Desktop file cards become mobile links in history and live messages', () => {
  const file = 'D:/报告目录/会议 [终稿] (1).pdf';
  const text = `已整理好\n\n::codex-file-citation{path="${file}" purpose="output"}`;
  const row = messages([{id:'turn',items:[{id:'answer',type:'agentMessage',text}]}])[0];
  assert.equal(row.text, `已整理好\n\n📄 [会议 \\[终稿\\] (1).pdf](<${file}>)`);
  assert.equal(row.id, 'answer');
  assert.equal(messages([{items:[{id:'user',type:'userMessage',text}]}])[0].text, text);
  assert.equal(fileCitations(':codex-file-citation{purpose="output" path="/tmp/a.pdf"}')[0].path, '/tmp/a.pdf');
});

test('citation parsing preserves Windows paths, multiple files and code examples', () => {
  const directive = '::codex-file-citation{path="C:\\temp\\a.pdf" purpose="output"}';
  assert.equal(fileCitations(directive)[0].path, 'C:\\temp\\a.pdf');
  assert.equal(fileCitations(directive.replaceAll('\\', '\\\\'))[0].path, 'C:\\temp\\a.pdf');
  for (const code of ['`'+directive+'`', '```text\n'+directive+'\n```', '~~~\n'+directive+'\n~~~', '```text\n'+directive]) {
    assert.deepEqual(fileCitations(code), []); assert.equal(renderFileCitations(code), code);
  }
  assert.equal(fileCitations(directive+'\n'+directive).length, 2);
  for (const invalid of ['https://example.com/a.pdf', 'relative.pdf', '/tmp/a\n.pdf', '/tmp/<bad>.pdf']) {
    assert.deepEqual(fileCitations(`::codex-file-citation{path="${invalid}"}`), []);
  }
});

test('only assistant file citations authorize the exact external file', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'astro-citation-'));
  try {
    const file = path.join(dir,'report.pdf'); await fs.writeFile(file,'%PDF-test');
    const text = `::codex-file-citation{path="${file.replaceAll('\\','/')}" purpose="output"}`;
    assert.equal(await matchesLinkedFile(file,[{type:'agentMessage',text}]),await fs.realpath(file));
    assert.equal(await matchesLinkedFile(path.join(dir,'other.pdf'),[{type:'agentMessage',text}]),null);
    assert.equal(await matchesLinkedFile(file,[{type:'userMessage',text}]),null);
    assert.equal(await matchesLinkedFile(file,[{type:'agentMessage',text:'```\n'+text+'\n```'}]),null);
  } finally { await fs.rm(dir,{recursive:true,force:true}); }
});
