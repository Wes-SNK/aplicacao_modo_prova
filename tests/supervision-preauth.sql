-- Testes transacionais de pré-autorização em Postgres isolado.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES('aaaa1111-aaaa-4111-8111-aaaaaaaa1111','ci-preauth','Pré-autorização em CI',true,30,3,'simulation');
INSERT INTO public.students(id,name,class_group,active)
VALUES('dddd1111-dddd-4111-8111-dddddddd1111','ALUNA CI PREAUTORIZADA','TURMA CI',true);
INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,points,active)
VALUES('aaaa1111-aaaa-4111-8111-aaaaaaaa1111',1,'objective','Questão CI autorizada',
'[{"key":"A","text":"A"},{"key":"B","text":"B"},{"key":"C","text":"C"},{"key":"D","text":"D"}]'::jsonb,'B',1,true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE cfg jsonb;result jsonb;roster jsonb;
BEGIN
 cfg:=public.teacher_supervision_configure_v2('ci-preauth','TURMA CI',true,false);
 IF cfg->>'enabled'<>'true' THEN RAISE EXCEPTION 'Supervisão não ativada';END IF;
 result:=public.teacher_supervision_authorize('ci-preauth',
  'dddd1111-dddd-4111-8111-dddddddd1111',true);
 IF result->>'authorized'<>'true' THEN RAISE EXCEPTION 'Pré-autorização falhou';END IF;
 roster:=public.teacher_supervision_roster('ci-preauth');
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(roster->'students') x
 WHERE x->>'name'='ALUNA CI PREAUTORIZADA' AND x->>'authorized'='true'
 AND x->>'waiting'='false') THEN
   RAISE EXCEPTION 'Pré-autorização foi confundida com presença: %',roster;
 END IF;
END;$test$;

SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE state jsonb;p jsonb;l uuid;enter jsonb;
BEGIN
 p:=public.student_lobby_join('ci-preauth','ALUNA CI PREAUTORIZADA',NULL);
 l:=(p->>'lobby_token')::uuid;
 IF l IS NULL OR p->>'authorized'<>'true' THEN
  RAISE EXCEPTION 'Pré-autorização não foi preservada: %',p;END IF;
 state:=public.student_lobby_state(l);
 IF state->>'authorized'<>'true' OR jsonb_array_length(state->'peers')<>1 THEN
  RAISE EXCEPTION 'Sala não refletiu presença: %',state;END IF;
 enter:=public.student_lobby_enter(l,'CI preauth');
 IF enter->>'status'<>'ready' OR jsonb_array_length(enter->'questions')<>1 THEN
   RAISE EXCEPTION 'Pré-autorização não liberou questões após entrada: %',enter;
 END IF;
END;$test$;
ROLLBACK;
