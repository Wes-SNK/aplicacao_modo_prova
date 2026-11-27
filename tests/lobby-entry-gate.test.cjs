const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

test('aluno não pode contornar a sala de espera quando não supervisionado', () => {
  const js = fs.readFileSync('student.js', 'utf8');
  const start = js.indexOf('async function enterWithName()');
  const end = js.indexOf('function humanError(', start);
  assert.ok(start !== -1 && end > start, 'fluxo de login ausente');
  const login = js.slice(start, end);
  assert.match(login, /lobby\?\.join\(studentName/);
  assert.doesNotMatch(login, /rpc\("start_attempt_by_name"/,
    'o login não pode iniciar diretamente a avaliação');
  assert.match(login, /throw new Error\("A sala de espera não está disponível/);
  assert.match(login, /showScreen\("screenLobby"\)/);
});

test('prova exige autorização no servidor, sem expor questões no pátio', () => {
  const sql = fs.readFileSync('migrations/018_duas_permissoes_sem_codigos.sql', 'utf8');
  const begin = sql.indexOf('CREATE OR REPLACE FUNCTION public.student_lobby_enter');
  const end = sql.indexOf('CREATE OR REPLACE FUNCTION public.student_lobby_move', begin);
  assert.ok(begin > -1 && end > begin);
  const entry = sql.slice(begin, end);
  assert.match(entry, /IF NOT l\.authorized THEN RAISE EXCEPTION/);
  assert.match(entry, /IF NOT public\._exam_available\(e\) THEN/);
});

test('prévia do professor deve passar pelo pátio e usar liberação simulada', () => {
  const lobby = fs.readFileSync('lobby.js', 'utf8');
  const preview = fs.readFileSync('preview-aluno.js', 'utf8');
  const html = fs.readFileSync('preview-aluno.html', 'utf8');
  assert.doesNotMatch(lobby, /if\(mp\.teacherPreview\) return false;/);
  assert.match(preview, /case "student_lobby_join"/);
  assert.match(preview, /case "student_lobby_state"/);
  assert.match(preview, /case "student_lobby_enter"/);
  assert.match(preview, /!previewLobby\.authorized/);
  assert.match(preview, /previewLobby\.authorized = true/);
  assert.match(preview, /mp\.lobbyBridge\?\.refresh\(\)/);
  assert.match(html, /id="previewReleaseExam"/);
  assert.ok(html.indexOf('preview-aluno.js') < html.indexOf('lobby.js'));
  assert.ok(html.indexOf('lobby.js') < html.indexOf('student.js'));
});
