-- Banco isolado do GitHub Actions. As alterações são revertidas.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ci-supervised','Simulado CI',false,60,3,'simulation'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','ci-codes','Prova CI com código',false,90,4,'exam');
INSERT INTO public.students(id,name,class_group,active) VALUES
 ('11111111-1111-4111-8111-111111111111','Aluno Alice','TURMA A',true),
 ('22222222-2222-4222-8222-222222222222','Aluno Bruno','TURMA A',true),
 ('33333333-3333-4333-8333-333333333333','Aluno Terceiro','TURMA B',true);
INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,points,active)
VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,'objective','Questão de CI um',
  '[{"key":"A","text":"A"},{"key":"B","text":"B"},{"key":"C","text":"C"},{"key":"D","text":"D"}]'::jsonb,'A',1,true),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',2,'objective','Questão de CI dois',
  '[{"key":"A","text":"A"},{"key":"B","text":"B"},{"key":"C","text":"C"},{"key":"D","text":"D"}]'::jsonb,'B',1,true);
CREATE TABLE public.ci_state(key text PRIMARY KEY,value text NOT NULL);
GRANT SELECT,INSERT,UPDATE ON public.ci_state TO anon,authenticated;

-- Habilitar a turma usando as credenciais sintéticas do professor.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE x jsonb;
BEGIN
 x:=public.teacher_supervision_configure_v2('ci-supervised','TURMA A',true,false);
 IF x->>'enabled'<>'true' THEN RAISE EXCEPTION 'Ativação da supervisão falhou';END IF;
END;$test$;

-- Alunos podem chegar ao pátio ANTES de abrir a prova, sem receber questões.
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
INSERT INTO public.ci_state(key,value)
SELECT 'alice_token',public.student_lobby_join('ci-supervised','Aluno Alice',null)->>'lobby_token';
INSERT INTO public.ci_state(key,value)
SELECT 'bruno_token',public.student_lobby_join('ci-supervised','Aluno Bruno',null)->>'lobby_token';
DO $test$
DECLARE denied boolean:=false;
BEGIN
 BEGIN
  PERFORM public.student_lobby_enter((SELECT value::uuid FROM public.ci_state WHERE key='alice_token'),'ci-test');
 EXCEPTION WHEN OTHERS THEN
  denied:=position('Aguarde autorização' IN SQLERRM)>0;
 END;
 IF NOT denied THEN RAISE EXCEPTION 'Ingresso sem autorização foi permitido';END IF;
END;$test$;

-- Publicar no banco CI; o endpoint direto por nome continua bloqueado.
SET LOCAL ROLE postgres;
UPDATE public.exams SET is_active=true WHERE slug='ci-supervised';
SET LOCAL ROLE anon;
DO $test$
DECLARE denied boolean:=false;
BEGIN
 BEGIN PERFORM public.start_attempt_by_name('ci-supervised','Aluno Alice','ci');
 EXCEPTION WHEN OTHERS THEN denied:=position('sala de espera' IN SQLERRM)>0; END;
 IF NOT denied THEN RAISE EXCEPTION 'Atalho direto por nome permitiu iniciar';END IF;
END;$test$;

-- Testa admissão individual, liberação coletiva e ausência de nomes no mapa.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE r jsonb;batch jsonb;
BEGIN
 r:=public.teacher_supervision_authorize('ci-supervised',
   '11111111-1111-4111-8111-111111111111',true);
 IF r->>'authorized'<>'true' THEN RAISE EXCEPTION 'Liberação individual falhou';END IF;
 batch:=public.teacher_supervision_authorize_all('ci-supervised');
 IF (batch->>'authorized_count')::int<>1 THEN
  RAISE EXCEPTION 'Liberação coletiva esperava apenas Bruno: %',batch;
 END IF;
 r:=public.teacher_supervision_roster('ci-supervised');
 IF jsonb_array_length(r->'students')<>2 THEN RAISE EXCEPTION 'Turma incompleta';END IF;
END;$test$;

SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE state jsonb;
BEGIN
 state:=public.student_lobby_state((SELECT value::uuid FROM public.ci_state WHERE key='alice_token'));
 IF state->>'authorized'<>'true' THEN RAISE EXCEPTION 'Liberação não chegou ao aluno';END IF;
 IF state::text LIKE '%Aluno Alice%' OR state::text LIKE '%Aluno Bruno%' THEN
  RAISE EXCEPTION 'Dados pessoais vazaram para os avatares';END IF;
END;$test$;
INSERT INTO public.ci_state(key,value)
SELECT 'attempt_token',
 public.student_lobby_enter((SELECT value::uuid FROM public.ci_state WHERE key='alice_token'),'ci-test')->>'session_token';
DO $test$
DECLARE b jsonb;h jsonb;help jsonb;
BEGIN
 b:=public.begin_attempt((SELECT value::uuid FROM public.ci_state WHERE key='attempt_token'));
 IF b->>'status'<>'in_progress' OR b->>'started_at' IS NULL THEN
  RAISE EXCEPTION 'Tentativa autorizada não iniciou';END IF;
 h:=public.student_exam_heartbeat((SELECT value::uuid FROM public.ci_state WHERE key='attempt_token'),1);
 IF h->>'ok'<>'true' THEN RAISE EXCEPTION 'Heartbeat não registrado';END IF;
 help:=public.student_exam_help((SELECT value::uuid FROM public.ci_state WHERE key='attempt_token'),true);
 IF help->>'help_pending'<>'true' THEN RAISE EXCEPTION 'Ajuda não chegou ao professor';END IF;
END;$test$;

-- O professor resolve a solicitação, e ela permanece na auditoria.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE report jsonb;events jsonb;
BEGIN
 report:=public.teacher_supervision_roster('ci-supervised');
 IF (SELECT count(*) FROM jsonb_array_elements(report->'students') s
   WHERE s->>'name'='Aluno Alice' AND s->>'status'='in_progress'
   AND (s->>'help_pending')::boolean)=0 THEN
    RAISE EXCEPTION 'Monitor não mostra pedido de ajuda';END IF;
 PERFORM public.teacher_supervision_resolve_help('ci-supervised',
 '11111111-1111-4111-8111-111111111111');
 events:=public.teacher_supervision_audit('ci-supervised');
 IF jsonb_array_length(events)<3 THEN
  RAISE EXCEPTION 'Auditoria de intervenções não registrou eventos';END IF;
END;$test$;

-- Exigir código num segundo exame; sem código a entrada deve falhar.
INSERT INTO public.ci_state(key,value)
SELECT 'alice_code',r->>'code'
FROM (SELECT jsonb_array_elements(public.teacher_student_issue_codes('TURMA A')) r) t
WHERE r->>'name'='Aluno Alice';
DO $test$
DECLARE res jsonb;
BEGIN
 res:=public.teacher_supervision_configure_v2('ci-codes','TURMA A',true,true);
 IF res->>'require_code'<>'true' THEN RAISE EXCEPTION 'Código não foi exigido';END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE denied boolean:=false;got jsonb;
BEGIN
 BEGIN PERFORM public.student_lobby_join('ci-codes','Aluno Alice',NULL);
 EXCEPTION WHEN OTHERS THEN denied:=position('Código individual inválido' IN SQLERRM)>0;END;
 IF NOT denied THEN RAISE EXCEPTION 'Aluno entrou sem o código exigido';END IF;
 got:=public.student_lobby_join('ci-codes','Aluno Alice',
 (SELECT value FROM public.ci_state WHERE key='alice_code'));
 IF got->>'supervised'<>'true' OR got->>'lobby_token' IS NULL THEN
  RAISE EXCEPTION 'Código válido não foi aceito';END IF;
END;$test$;

-- Um usuário anônimo não pode habilitar supervisão nem ler nomes da turma.
DO $test$
DECLARE denied boolean:=false;
BEGIN
 BEGIN PERFORM public.teacher_supervision_roster('ci-supervised');
 EXCEPTION WHEN insufficient_privilege THEN denied:=true;END;
 IF NOT denied THEN RAISE EXCEPTION 'Anon conseguiu ler a turma';END IF;
END;$test$;
ROLLBACK;
