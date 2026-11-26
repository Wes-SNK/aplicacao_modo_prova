-- Integração da migração 019 em PostgreSQL isolado; tudo revertido.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','ci-entrada-direta','Teste ingresso direto',true,30,3,'simulation');
INSERT INTO public.students(id,name,class_group,active)
VALUES ('bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb','ESTUDANTE CI ENTRADA DIRETA','TURMA CI DIRETA',true);
INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,points,active)
VALUES ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',1,'objective','Questão de CI',
'[{"key":"A","text":"A"},{"key":"B","text":"B"},{"key":"C","text":"C"},{"key":"D","text":"D"}]'::jsonb,'A',1,true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_supervision_configure_v3('ci-entrada-direta','TURMA CI DIRETA',true);
 IF r->>'enabled'<>'true' THEN RAISE EXCEPTION 'Supervisão não configurada'; END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE j jsonb;s jsonb;v_token uuid;denied boolean:=false;
BEGIN
 j:=public.student_lobby_join('ci-entrada-direta','ESTUDANTE CI ENTRADA DIRETA');
 IF j->>'supervised'<>'true' OR j->>'lobby_allowed'<>'true'
 OR j->>'authorized'<>'false' THEN
  RAISE EXCEPTION 'Aluno não entrou diretamente no pátio: %',j;
 END IF;
 v_token:=(j->>'lobby_token')::uuid;
 PERFORM set_config('ci.direct_lobby_token',v_token::text,true);
 s:=public.student_lobby_state(v_token);
 IF s->>'lobby_allowed'<>'true' OR s->>'authorized'<>'false'
 OR jsonb_array_length(s->'peers')<>1 THEN
  RAISE EXCEPTION 'Sala de espera não exibiu avatar: %',s;
 END IF;
 BEGIN
  PERFORM public.student_lobby_enter(v_token,'Teste CI');
 EXCEPTION WHEN OTHERS THEN
  denied:=position('Aguarde autorização de início da prova' IN SQLERRM)>0;
 END;
 IF NOT denied THEN RAISE EXCEPTION 'Prova aberta antes de autorização do professor';END IF;
END;$test$;
SET LOCAL ROLE postgres;
DO $test$
BEGIN
 IF EXISTS(SELECT 1 FROM public.attempts
   WHERE exam_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa') THEN
  RAISE EXCEPTION 'Entrada na sala criou uma tentativa prematuramente';
 END IF;
END;$test$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_supervision_authorize('ci-entrada-direta',
  'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',true);
 IF r->>'authorized'<>'true' THEN RAISE EXCEPTION 'Liberação da prova falhou';END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE s jsonb;a jsonb;v_token uuid;
BEGIN
 v_token:=current_setting('ci.direct_lobby_token',true)::uuid;
 s:=public.student_lobby_state(v_token);
 IF s->>'authorized'<>'true' THEN RAISE EXCEPTION 'Autorização não chegou ao aluno';END IF;
 a:=public.student_lobby_enter(v_token,'Teste CI');
 IF a->>'status'<>'ready' OR jsonb_array_length(a->'questions')<>1 THEN
  RAISE EXCEPTION 'Prova não disponibilizada após autorização';
 END IF;
END;$test$;
ROLLBACK;