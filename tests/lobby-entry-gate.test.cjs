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
  assert.match(login, /if \(!window\.ModeProva\.teacherPreview\)\s*\{\s*throw new Error\(/);
  assert.ok(login.indexOf('throw new Error(') < login.indexOf('rpc("start_attempt_by_name"'),
    'a chamada direta deve permanecer restrita à prévia do professor');
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
