-- Integração da comunicação isolada: nenhuma mensagem é mantida após o ROLLBACK.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES ('e0000000-0000-4000-8000-000000000001','ci-chat','Chat supervisionado CI',true,30,3,'simulation');
INSERT INTO public.students(id,name,class_group,active) VALUES
 ('e0000000-0000-4000-8000-000000000002','Aluna Alice CI','TURMA CHAT CI',true),
 ('e0000000-0000-4000-8000-000000000003','Aluno Bruno CI','TURMA CHAT CI',true),
 ('e0000000-0000-4000-8000-000000000004','Aluna Outra Turma CI','OUTRA CI',true);
CREATE TEMP TABLE ci_chat_tokens(student text PRIMARY KEY, token uuid);
GRANT SELECT,INSERT ON ci_chat_tokens TO anon,authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $t$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_supervision_configure_v3('ci-chat','TURMA CHAT CI',true);
 IF r->>'enabled'<>'true' THEN RAISE EXCEPTION 'Supervisão não configurada';END IF;
END;$t$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
INSERT INTO ci_chat_tokens
SELECT 'alice',(public.student_lobby_join('ci-chat','Aluna Alice CI')->>'lobby_token')::uuid;
INSERT INTO ci_chat_tokens
SELECT 'bruno',(public.student_lobby_join('ci-chat','Aluno Bruno CI')->>'lobby_token')::uuid;
DO $t$
DECLARE r jsonb;rejected boolean:=false;
BEGIN
 r:=public.student_lobby_chat_read((SELECT token FROM ci_chat_tokens WHERE student='alice'),0);
 IF r->>'enabled'<>'false' THEN RAISE EXCEPTION 'Chat não inicia desativado';END IF;
 BEGIN
  PERFORM public.student_lobby_chat_send((SELECT token FROM ci_chat_tokens WHERE student='alice'),
   'Mensagem bloqueada',null);
 EXCEPTION WHEN OTHERS THEN rejected=true;END;
 IF NOT rejected THEN RAISE EXCEPTION 'Enviou sem autorização';END IF;
END;$t$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $t$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_lobby_chat_manage('ci-chat',true,true);
 IF r->>'enabled'<>'true' THEN RAISE EXCEPTION 'Professor não ativou';END IF;
END;$t$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $t$
DECLARE a uuid;b uuid;recipient text;r jsonb;denied boolean:=false;
BEGIN
 SELECT token INTO a FROM ci_chat_tokens WHERE student='alice';
 SELECT token INTO b FROM ci_chat_tokens WHERE student='bruno';
 r:=public.student_lobby_chat_read(a,0);
 IF jsonb_array_length(r->'peers')<>2 THEN RAISE EXCEPTION 'Destinatários incorretos: %',r;END IF;
 PERFORM public.student_lobby_chat_send(a,'Olá, turma!',null);
 r:=public.student_lobby_chat_read(b,0);
 IF jsonb_array_length(r->'messages')<>1 THEN RAISE EXCEPTION 'Mensagem geral não recebida';END IF;
 -- Testa limite de frequência: o mesmo aluno não consegue spam consecutivo.
 BEGIN
  PERFORM public.student_lobby_chat_send(a,'Mensagem muito rápida',null);
 EXCEPTION WHEN OTHERS THEN denied=true;END;
 IF NOT denied THEN RAISE EXCEPTION 'Antiflood não aplicado';END IF;
 -- Outro aluno pode escrever independentemente.
 recipient:=substr(md5('e0000000-0000-4000-8000-000000000002'),1,10);
 PERFORM public.student_lobby_chat_send(b,'Mensagem para Alice',recipient);
 r:=public.student_lobby_chat_read(a,0);
 IF jsonb_array_length(r->'messages')<>2 THEN RAISE EXCEPTION 'Direta não entregue';END IF;
END;$t$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $t$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_lobby_chat_read('ci-chat',0);
 IF jsonb_array_length(r->'messages')<>2 THEN RAISE EXCEPTION 'Professor não vê diretas';END IF;
 PERFORM public.teacher_lobby_chat_send('ci-chat','A prova será liberada em breve',null);
 PERFORM public.teacher_lobby_chat_manage('ci-chat',NULL,NULL,
  'e0000000-0000-4000-8000-000000000002',true);
END;$t$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $t$
DECLARE a uuid;b uuid;r jsonb;denied boolean:=false;
BEGIN
 SELECT token INTO a FROM ci_chat_tokens WHERE student='alice';
 SELECT token INTO b FROM ci_chat_tokens WHERE student='bruno';
 r:=public.student_lobby_chat_read(b,0);
 IF jsonb_array_length(r->'messages')<>3 THEN
  RAISE EXCEPTION 'Comunicado do professor não chegou: %',r;END IF;
 BEGIN PERFORM public.student_lobby_chat_send(a,'Mensagem de aluno silenciado','teacher');
 EXCEPTION WHEN OTHERS THEN denied=true;END;
 IF NOT denied THEN RAISE EXCEPTION 'Aluno silenciado enviou';END IF;
END;$t$;
SET LOCAL ROLE postgres;
INSERT INTO public.attempts(exam_id,student_id,status,started_at)
VALUES('e0000000-0000-4000-8000-000000000001',
'e0000000-0000-4000-8000-000000000003','in_progress',now());
SET LOCAL ROLE anon;
DO $t$
DECLARE denied boolean:=false;
BEGIN
 BEGIN PERFORM public.student_lobby_chat_read(
  (SELECT token FROM ci_chat_tokens WHERE student='bruno'),0);
 EXCEPTION WHEN OTHERS THEN denied=true;END;
 IF NOT denied THEN RAISE EXCEPTION 'Chat não bloqueado durante prova';END IF;
END;$t$;
ROLLBACK;