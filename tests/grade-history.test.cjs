const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const read=path=>fs.readFileSync(path,"utf8");
const sql=read("migrations/022_historico_notas_imutavel.sql");
const student=read("student.js");
const teacher=read("professor.js");
const panel=read("professor-shell.html");

test("histórico é permanente e sobrevive à exclusão da tentativa original",()=>{
 assert.match(sql,/CREATE TABLE public\.grade_history/);
 assert.match(sql,/attempt_id uuid NOT NULL UNIQUE/);
 assert.match(sql,/CREATE TRIGGER grade_history_protect_attempt/);
 assert.match(sql,/TG_OP='DELETE'/);
 assert.match(sql,/PERFORM public\._archive_final_grade\(OLD\.id\)/);
 assert.match(sql,/SELECT public\._archive_final_grade\(id\) FROM public\.attempts/);
 assert.doesNotMatch(sql,/DELETE FROM public\.grade_history/);
});
test("finalizações repetidas usam um único histórico por tentativa",()=>{
 assert.match(sql,/ON CONFLICT \(attempt_id\) DO NOTHING/);
 assert.match(sql,/CREATE TRIGGER grade_history_after_finalize/);
 assert.match(sql,/WHERE session_token=p_session_token FOR UPDATE/);
 assert.match(sql,/IF a\.status IN \('submitted','auto_submitted'\) THEN/);
 assert.match(sql,/RETURN jsonb_build_object\('status',a\.status,'submitted_at',a\.submitted_at/);
});
test("nota final não pode ser recalculada e histórico é protegido",()=>{
 assert.match(sql,/Nota finalizada não pode ser recalculada/);
 assert.match(sql,/REVOKE ALL ON FUNCTION public\._grade_attempt\(uuid\)/);
 assert.match(sql,/CREATE TRIGGER grade_history_immutable/);
 assert.match(sql,/ENABLE ROW LEVEL SECURITY/);
 assert.match(sql,/REVOKE ALL ON public\.grade_history FROM PUBLIC,anon,authenticated/);
});
test("respostas são serializadas com envio e sincronizadas pelo navegador",()=>{
 assert.match(sql,/CREATE OR REPLACE FUNCTION public\.save_answer/);
 assert.match(sql,/WHERE session_token=p_session_token FOR UPDATE/);
 assert.match(student,/inFlightAnswerSaves/);
 assert.match(student,/await Promise\.allSettled\(\[\.\.\.inFlightAnswerSaves\.values\(\)\]\)/);
 assert.match(student,/if\(!await flushPendingAnswers\(\)\)/);
 assert.match(student,/Não finalize agora/);
 assert.match(student,/cachePending\(q\.id\)/);
});
test("painel mostra e exporta todas as notas, não apenas a tentativa atual",()=>{
 assert.match(sql,/'grade_history',hist/);
 assert.match(panel,/id="gradeHistoryTable"/);
 assert.match(panel,/id="btnExportGradeHistory"/);
 assert.match(teacher,/function renderGradeHistory\(history\)/);
 assert.match(teacher,/function exportGradeHistoryCsv\(\)/);
 assert.match(teacher,/dashboardData\.grade_history/);
});
