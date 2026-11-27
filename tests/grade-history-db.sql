-- Integração transacional de notas; todo dado fictício é revertido com ROLLBACK.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES ('f0000000-0000-4000-8000-000000000001','ci-notas','Notas CI',true,30,3,'exam');
INSERT INTO public.students(id,name,class_group,active) VALUES
 ('f0000000-0000-4000-8000-000000000002','Aluno Histórico CI','TURMA NOTAS',true);
INSERT INTO public.questions(id,exam_id,position,type,stem,options,correct_answer,points,active)
VALUES ('f0000000-0000-4000-8000-000000000003',
 'f0000000-0000-4000-8000-000000000001',1,'objective','Questão CI',
 '[{"key":"A","text":"Correta"},{"key":"B","text":"Errada"},{"key":"C","text":"C"},{"key":"D","text":"D"}]'::jsonb,
 'A',2,true);
INSERT INTO public.attempts(id,exam_id,student_id,session_token,status,started_at)
VALUES ('f0000000-0000-4000-8000-000000000004',
 'f0000000-0000-4000-8000-000000000001',
 'f0000000-0000-4000-8000-000000000002',
 'f0000000-0000-4000-8000-000000000005','in_progress',now());
SET LOCAL ROLE anon;
DO $t$
DECLARE r jsonb; denied boolean:=false;
BEGIN
 PERFORM public.save_answer(
  'f0000000-0000-4000-8000-000000000005',
  'f0000000-0000-4000-8000-000000000003','{"value":"A"}');
 r:=public.submit_attempt('f0000000-0000-4000-8000-000000000005','submitted');
 IF (r->>'score')::numeric<>2 THEN RAISE EXCEPTION 'Primeira nota incorreta: %',r;END IF;
 r:=public.submit_attempt('f0000000-0000-4000-8000-000000000005','submitted');
 IF (r->>'score')::numeric<>2 THEN RAISE EXCEPTION 'Reenvio mudou a nota: %',r;END IF;
 BEGIN
  PERFORM public.save_answer(
   'f0000000-0000-4000-8000-000000000005',
   'f0000000-0000-4000-8000-000000000003','{"value":"B"}');
 EXCEPTION WHEN OTHERS THEN denied:=true;END;
 IF NOT denied THEN RAISE EXCEPTION 'Resposta alterada após finalizar';END IF;
END;$t$;
SET LOCAL ROLE postgres;
DO $t$
DECLARE qty integer;rejected boolean:=false;
BEGIN
 SELECT count(*) INTO qty FROM public.grade_history
 WHERE attempt_id='f0000000-0000-4000-8000-000000000004';
 IF qty<>1 THEN RAISE EXCEPTION 'Reenvio duplicou histórico';END IF;
 BEGIN
  PERFORM public._grade_attempt('f0000000-0000-4000-8000-000000000004');
 EXCEPTION WHEN OTHERS THEN rejected:=true;END;
 IF NOT rejected THEN RAISE EXCEPTION 'Recálculo de nota finalizada permitido';END IF;
 rejected:=false;
 BEGIN
  UPDATE public.grade_history SET score=0
  WHERE attempt_id='f0000000-0000-4000-8000-000000000004';
 EXCEPTION WHEN OTHERS THEN rejected:=true;END;
 IF NOT rejected THEN RAISE EXCEPTION 'Histórico permitiu alteração da nota';END IF;
END;$t$;
-- Simula Nova tentativa do zero: DELETE da original não apaga o histórico.
DELETE FROM public.attempts
WHERE id='f0000000-0000-4000-8000-000000000004';
DO $t$
BEGIN
 IF (SELECT count(*) FROM public.grade_history
     WHERE attempt_id='f0000000-0000-4000-8000-000000000004')<>1
 THEN RAISE EXCEPTION 'Histórico apagado pela exclusão da tentativa';END IF;
END;$t$;
INSERT INTO public.attempts(id,exam_id,student_id,session_token,status,started_at)
VALUES ('f0000000-0000-4000-8000-000000000006',
 'f0000000-0000-4000-8000-000000000001',
 'f0000000-0000-4000-8000-000000000002',
 'f0000000-0000-4000-8000-000000000007','in_progress',now());
SET LOCAL ROLE anon;
DO $t$
DECLARE r jsonb;
BEGIN
 PERFORM public.save_answer(
  'f0000000-0000-4000-8000-000000000007',
  'f0000000-0000-4000-8000-000000000003','{"value":"B"}');
 r:=public.submit_attempt('f0000000-0000-4000-8000-000000000007','submitted');
 IF (r->>'score')::numeric<>0 THEN RAISE EXCEPTION 'Segunda nota incorreta: %',r;END IF;
END;$t$;
SET LOCAL ROLE postgres;
DO $t$
BEGIN
 IF (SELECT count(*) FROM public.grade_history
     WHERE exam_id='f0000000-0000-4000-8000-000000000001')<>2
 THEN RAISE EXCEPTION 'Histórico não contém duas tentativas';END IF;
 IF (SELECT sum(score) FROM public.grade_history
     WHERE exam_id='f0000000-0000-4000-8000-000000000001')<>2
 THEN RAISE EXCEPTION 'Histórico perdeu a primeira nota';END IF;
END;$t$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $t$
DECLARE r jsonb;
BEGIN
 r:=public.teacher_dashboard('ci-notas');
 IF jsonb_array_length(r->'grade_history')<>2
 THEN RAISE EXCEPTION 'Painel não apresenta ambas as notas';END IF;
END;$t$;
SET LOCAL ROLE postgres;
ROLLBACK;
