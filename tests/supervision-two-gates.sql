-- Testes de integração das duas permissões, em banco descartável.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES('aaaa2222-aaaa-4222-8222-aaaaaaaa2222','ci-duas-permissoes','Prova teste de controle',true,30,3,'simulation');
INSERT INTO public.students(id,name,class_group,active)
VALUES('bbbb2222-bbbb-4222-8222-bbbbbbbb2222','ALUNO CI DUAS PERMISSOES','CI DOIS CONTROLES',true);
INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,points,active)
VALUES('aaaa2222-aaaa-4222-8222-aaaaaaaa2222',1,'objective','Questão verificável',
'[{"key":"A","text":"A"},{"key":"B","text":"B"},{"key":"C","text":"C"},{"key":"D","text":"D"}]'::jsonb,'B',1,true);
CREATE TABLE ci_temporary_gate(token uuid NOT NULL);
GRANT INSERT,SELECT ON ci_temporary_gate TO anon,authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE cfg jsonb;
BEGIN
 cfg:=public.teacher_supervision_configure_v3('ci-duas-permissoes','CI DOIS CONTROLES',true);
 IF cfg->>'enabled'<>'true' OR cfg->>'require_code'<>'false' THEN
  RAISE EXCEPTION 'Configuração do professor não removeu código: %',cfg;END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE j jsonb;st jsonb;v uuid;denied boolean:=false;
BEGIN
 j:=public.student_lobby_join('ci-duas-permissoes','ALUNO CI DUAS PERMISSOES');
 v:=(j->>'lobby_token')::uuid;
 INSERT INTO ci_temporary_gate(token) VALUES(v);
 IF j->>'lobby_allowed'<>'false' THEN RAISE EXCEPTION 'Aluno entrou antes da autorização';END IF;
 st:=public.student_lobby_state(v);
 IF st->>'lobby_allowed'<>'false' OR jsonb_array_length(st->'peers')<>0 THEN
  RAISE EXCEPTION 'Pátio exposto antes da autorização: %',st;END IF;
 BEGIN
  PERFORM public.student_lobby_enter(v,'ci');
 EXCEPTION WHEN OTHERS THEN denied:=position('Aguarde autorização de entrada' IN SQLERRM)>0;END;
 IF NOT denied THEN RAISE EXCEPTION 'Sala não controlou ingresso';END IF;

END;$test$;
SET LOCAL ROLE postgres;
DO $test$
BEGIN
 IF EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=
   'aaaa2222-aaaa-4222-8222-aaaaaaaa2222') THEN
   RAISE EXCEPTION 'A espera criou tentativa antes da prova';END IF;
END;$test$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE r jsonb;
BEGIN
 -- Liberação da prova NÃO concede acesso ao pátio.
 r:=public.teacher_supervision_authorize('ci-duas-permissoes',
  'bbbb2222-bbbb-4222-8222-bbbbbbbb2222',true);
 IF r->>'authorized'<>'true' THEN RAISE EXCEPTION 'Liberação da prova falhou';END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE r jsonb;denied boolean:=false;
BEGIN
 r:=public.student_lobby_state((SELECT token FROM ci_temporary_gate));
 IF r->>'lobby_allowed'<>'false' OR r->>'authorized'<>'true' THEN
  RAISE EXCEPTION 'Acesso ao pátio confundido com início da prova';END IF;
 BEGIN
  PERFORM public.student_lobby_enter((SELECT token FROM ci_temporary_gate),'ci');
 EXCEPTION WHEN OTHERS THEN denied:=position('Aguarde autorização de entrada' IN SQLERRM)>0;END;
 IF NOT denied THEN RAISE EXCEPTION 'Prova liberada contornou controle do pátio';END IF;
END;$test$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE r jsonb;roster jsonb;
BEGIN
 r:=public.teacher_supervision_lobby_access('ci-duas-permissoes',
  'bbbb2222-bbbb-4222-8222-bbbbbbbb2222',true);
 IF r->>'lobby_allowed'<>'true' THEN RAISE EXCEPTION 'Professor não permitiu pátio';END IF;
 roster:=public.teacher_supervision_roster('ci-duas-permissoes');
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(roster->'students') s
  WHERE s->>'name'='ALUNO CI DUAS PERMISSOES' AND s->>'lobby_allowed'='true')
 THEN RAISE EXCEPTION 'Permissão não apareceu no painel';END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE state jsonb;exam jsonb;
BEGIN
 state:=public.student_lobby_state((SELECT token FROM ci_temporary_gate));
 IF state->>'lobby_allowed'<>'true' OR state->>'authorized'<>'true'
 OR jsonb_array_length(state->'peers')<>1 THEN
  RAISE EXCEPTION 'O pátio não recebeu as permissões: %',state;END IF;
 exam:=public.student_lobby_enter((SELECT token FROM ci_temporary_gate),'ci');
 IF exam->>'status'<>'ready' OR jsonb_array_length(exam->'questions')<>1 THEN
  RAISE EXCEPTION 'Prova autorizada não foi disponibilizada';END IF;
END;$test$;
ROLLBACK;
