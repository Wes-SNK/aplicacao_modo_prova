-- Integração de filtro por turma, dentro de uma transação revertida.
BEGIN;
INSERT INTO public.exams(id,slug,title,is_active,duration_minutes,max_occurrences,assessment_mode)
VALUES('12345678-1234-4123-8123-123456789a01','ci-filtro-turmas','Teste filtro',true,30,3,'simulation');
INSERT INTO public.students(id,name,class_group,active) VALUES
('12345678-1234-4123-8123-123456789a02','ALUNO DA TURMA TESTE CI','TESTE CI',true),
('12345678-1234-4123-8123-123456789a03','ALUNO TURMA REGULAR CI','1o INF B CI',true),
('12345678-1234-4123-8123-123456789a04','ALUNO INATIVO CI','1o INF B CI',false);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999999',true);
DO $test$
DECLARE c jsonb;old_group jsonb;regular jsonb;still_test jsonb;
BEGIN
 c:=public.teacher_supervision_configure_v3('ci-filtro-turmas','TESTE CI',true);
 IF c->>'enabled'<>'true' THEN RAISE EXCEPTION 'Falha ao configurar turma inicial';END IF;
 old_group:=public.teacher_supervision_roster_by_class('ci-filtro-turmas',NULL);
 IF old_group->>'class_group'<>'TESTE CI' OR old_group->>'preview_only'<>'false'
  OR jsonb_array_length(old_group->'students')<>1
 THEN RAISE EXCEPTION 'Turma vinculada não exibida: %',old_group;END IF;
 regular:=public.teacher_supervision_roster_by_class('ci-filtro-turmas','1o INF B CI');
 IF regular->>'class_group'<>'1o INF B CI' OR
 regular->>'configured_class_group'<>'TESTE CI' OR
 regular->>'preview_only'<>'true' OR regular->>'enabled'<>'false'
 THEN RAISE EXCEPTION 'A turma trocada não foi marcada como visualização: %',regular;END IF;
 IF jsonb_array_length(regular->'students')<>1 OR
  regular->'students'->0->>'name'<>'ALUNO TURMA REGULAR CI' THEN
  RAISE EXCEPTION 'Fuga de aluno da outra turma ou aluno inativo: %',regular;END IF;
 -- Consultar não persiste nenhuma mudança de vinculação.
 still_test:=public.teacher_supervision_roster_by_class('ci-filtro-turmas',NULL);
 IF still_test->>'class_group'<>'TESTE CI' OR
 jsonb_array_length(still_test->'students')<>1 THEN
  RAISE EXCEPTION 'Troca visual persistiu indevidamente: %',still_test;END IF;
END;$test$;
ROLLBACK;