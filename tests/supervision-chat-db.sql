-- Teste de integração real com PostgreSQL isolado; nenhuma alteração persistida.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES('aaaa3333-aaaa-4333-8333-aaaaaaaa3333','ci-chat-021','CI Chat',true,30,3,'simulation');
INSERT INTO public.students(id,name,class_group,active) VALUES
 ('bbbb3333-bbbb-4333-8333-bbbbbbbb3331','ALUNO CHAT A','CI CHAT',true),
 ('bbbb3333-bbbb-4333-8333-bbbbbbbb3332','ALUNO CHAT B','CI CHAT',true),
 ('bbbb3333-bbbb-4333-8333-bbbbbbbb3333','ALUNO CHAT C','CI CHAT',true);
INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,points,active)
VALUES('aaaa3333-aaaa-4333-8333-aaaaaaaa3333',1,'objective','Pergunta de integração',
'[{"key":"A","text":"Sim"},{"key":"B","text":"Não"}]'::jsonb,'A',1,true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE cfg jsonb;chat jsonb;
BEGIN
 cfg:=public.teacher_supervision_configure_v3('ci-chat-021','CI CHAT',true);
 IF cfg->>'enabled'<>'true' THEN RAISE EXCEPTION 'Supervisão não configurada';END IF;
 chat:=public.teacher_lobby_chat_settings('ci-chat-021');
 IF chat->>'enabled'<>'false' THEN RAISE EXCEPTION 'Chat deve iniciar desligado';END IF;
 chat:=public.teacher_lobby_chat_settings('ci-chat-021',true,true);
 IF chat->>'enabled'<>'true' OR chat->>'peer_messages'<>'true'
 THEN RAISE EXCEPTION 'Chat não habilitado';END IF;
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE a jsonb;b jsonb;c jsonb;peers jsonb;recipient text;
 v_token uuid;denied boolean:=false;
BEGIN
 a:=public.student_lobby_join('ci-chat-021','ALUNO CHAT A');
 b:=public.student_lobby_join('ci-chat-021','ALUNO CHAT B');
 c:=public.student_lobby_join('ci-chat-021','ALUNO CHAT C');
 PERFORM set_config('ci.chat_a',a->>'lobby_token',true);
 PERFORM set_config('ci.chat_b',b->>'lobby_token',true);
 PERFORM set_config('ci.chat_c',c->>'lobby_token',true);
 v_token:=(a->>'lobby_token')::uuid;
 peers:=public.student_lobby_chat_read(v_token);
 IF peers->>'enabled'<>'true' OR jsonb_array_length(peers->'peers')<>3 THEN
  RAISE EXCEPTION 'Destinatários não retornados: %',peers;END IF;
 IF peers::text LIKE '%bbbb3333-bbbb%' THEN
  RAISE EXCEPTION 'ID privado do estudante vazou ao aluno';END IF;
 SELECT p->>'id' INTO recipient FROM jsonb_array_elements(peers->'peers') p
 WHERE p->>'handle'='Colega-'||upper(substr(md5('bbbb3333-bbbb-4333-8333-bbbbbbbb3332'),1,4));
 IF recipient IS NULL THEN RAISE EXCEPTION 'Menção de B não localizada';END IF;
 PERFORM set_config('ci.chat_b_handle',recipient,true);
 PERFORM public.student_lobby_chat_send(v_token,'Olá, pessoal!',NULL,false);
 BEGIN
  PERFORM public.student_lobby_chat_send(v_token,'Spam',NULL,false);
 EXCEPTION WHEN OTHERS THEN denied:=position('Aguarde 3 segundos' IN SQLERRM)>0;END;
 IF NOT denied THEN RAISE EXCEPTION 'Antispam falhou';END IF;
END;$test$;
SET LOCAL ROLE postgres;
UPDATE public.exam_lobby_chat_messages SET created_at=now()-interval '6 seconds'
WHERE exam_id='aaaa3333-aaaa-4333-8333-aaaaaaaa3333';
SET LOCAL ROLE anon;
DO $test$
DECLARE t uuid;r jsonb;
BEGIN
 t:=current_setting('ci.chat_a',true)::uuid;
 r:=public.student_lobby_chat_send(t,'Mensagem reservada B',
   current_setting('ci.chat_b_handle',true),false);
 IF r->>'ok'<>'true' THEN RAISE EXCEPTION 'Envio direcionado falhou';END IF;
 r:=public.student_lobby_chat_read(current_setting('ci.chat_c',true)::uuid);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(r->'messages') x
  WHERE x->>'body'='Mensagem reservada B') THEN
  RAISE EXCEPTION 'Mensagem reservada visível para C';END IF;
 r:=public.student_lobby_chat_read(current_setting('ci.chat_b',true)::uuid);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'messages') x
  WHERE x->>'body'='Mensagem reservada B') THEN
  RAISE EXCEPTION 'B não recebeu menção';END IF;
END;$test$;
SET LOCAL ROLE postgres;
UPDATE public.exam_lobby_chat_messages SET created_at=now()-interval '6 seconds'
WHERE exam_id='aaaa3333-aaaa-4333-8333-aaaaaaaa3333';
SET LOCAL ROLE anon;
DO $test$
DECLARE r jsonb;
BEGIN
 PERFORM public.student_lobby_chat_send(current_setting('ci.chat_a',true)::uuid,
   'Tenho uma dúvida',NULL,true);
 r:=public.student_lobby_chat_read(current_setting('ci.chat_b',true)::uuid);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(r->'messages') x
  WHERE x->>'body'='Tenho uma dúvida') THEN
  RAISE EXCEPTION '@Professor vazou para outro estudante';END IF;
 r:=public.student_lobby_chat_read(current_setting('ci.chat_a',true)::uuid);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'messages') x
  WHERE x->>'body'='Tenho uma dúvida' AND x->>'recipient'='@Professor') THEN
  RAISE EXCEPTION 'Remetente não vê sua mensagem ao professor';END IF;
END;$test$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_lobby_chat_read('ci-chat-021');
 IF jsonb_array_length(r->'messages')<>3 THEN
  RAISE EXCEPTION 'Professor não vê todas as mensagens';END IF;
 PERFORM public.teacher_lobby_chat_mute('ci-chat-021',
  'bbbb3333-bbbb-4333-8333-bbbbbbbb3331',true);
END;$test$;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE blocked boolean:=false;
BEGIN
 BEGIN
  PERFORM public.student_lobby_chat_send(current_setting('ci.chat_a',true)::uuid,'Teste',NULL,false);
 EXCEPTION WHEN OTHERS THEN blocked:=position('suspenso' IN SQLERRM)>0;END;
 IF NOT blocked THEN RAISE EXCEPTION 'Silenciamento não aplicado';END IF;
END;$test$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
SELECT public.teacher_lobby_chat_mute('ci-chat-021','bbbb3333-bbbb-4333-8333-bbbbbbbb3331',false);
SELECT public.teacher_supervision_authorize('ci-chat-021','bbbb3333-bbbb-4333-8333-bbbbbbbb3331',true);
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
DECLARE exam jsonb;blocked boolean:=false;
BEGIN
 exam:=public.student_lobby_enter(current_setting('ci.chat_a',true)::uuid,'CI');
 IF exam->>'status'<>'ready' THEN RAISE EXCEPTION 'Entrada na prova falhou';END IF;
 BEGIN
  PERFORM public.student_lobby_chat_send(current_setting('ci.chat_a',true)::uuid,
    'Mensagem durante prova',NULL,false);
 EXCEPTION WHEN OTHERS THEN
  blocked:=position('indisponíveis após ingresso' IN SQLERRM)>0;END;
 IF NOT blocked THEN RAISE EXCEPTION 'Aluno entrou na prova e ainda pode conversar';END IF;
END;$test$;
ROLLBACK;
