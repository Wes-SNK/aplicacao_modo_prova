const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

const monitor = fs.readFileSync("monitoramento.js", "utf8");
const shell = fs.readFileSync("professor-shell.html", "utf8");
const style = fs.readFileSync("styles.css", "utf8");

test("alerta de ajuda aparece no painel, com acessibilidade e nomes", () => {
  assert.match(shell, /id="supervisionHelpAlert"[^>]*role="status"[^>]*aria-live="polite"/);
  assert.match(monitor, /const pendingHelp=students\.filter\(s=>s\.help_pending\)/);
  assert.match(monitor, /pendingHelp\.map\(s=>s\.name\)\.join\(", "\)/);
  assert.match(monitor, /helpAlert\.classList\.toggle\("hidden",!pendingHelp\.length\)/);
});

test("aluno com pedido pendente ganha destaque e botão Atendido", () => {
  assert.match(monitor, /if\(s\.help_pending\)tr\.classList\.add\("supervision-needs-help"\)/);
  assert.match(monitor, /help\.className="supervision-help"/);
  assert.match(monitor, /if\(s\.help_pending\)td\.appendChild\(action\("Atendido",\(\)=>resolveHelp\(s\)\)\)/);
  assert.match(style, /\.supervision-needs-help\{background:#fff5c6;\}/);
  assert.match(style, /\.supervision-help\{/);
});

test("alerta não fica preso na troca de turma e no logout", () => {
  assert.match(monitor, /function showSwitchingClass\(\)\s*\{[\s\S]*?\$\("supervisionHelpAlert"\)\.classList\.add\("hidden"\)/);
  assert.match(monitor, /modo-prova:teacher-logout[\s\S]*?\$\("supervisionHelpAlert"\)\.classList\.add\("hidden"\)/);
});

test("resolução continua autenticada no servidor e não altera autorização de prova", () => {
  assert.match(monitor, /teacher_supervision_resolve_help/);
  assert.match(monitor, /await refresh\(true\)/);
  assert.doesNotMatch(monitor.slice(monitor.indexOf("async function resolveHelp"),monitor.indexOf("function exportCsv")), /teacher_supervision_authorize/);
});
