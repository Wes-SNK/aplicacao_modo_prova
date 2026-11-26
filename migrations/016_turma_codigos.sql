-- MIGRAÇÃO PROPOSTA 016: cadastro da turma e códigos individuais opcionais.
-- Execute depois das migrações 013, 014 e 015, somente em homologação.
ALTER TABLE public.exam_supervision
 ADD COLUMN require_code boolean NOT NULL DEFAULT false;
DROP FUNCTION IF EXISTS public.student_lobby_join(text,text);
CREATE FUNCTION public.student_lobby_join(p_exam_slug text,p_student_name text,p_access_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_super public.exam_supervision;
 v_student public.students;v_matches integer;v_lobby public.exam_lobby;
BEGIN
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Avaliação indisponível';END IF;
 SELECT * INTO v_super FROM public.exam_supervision WHERE exam_id=v_exam.id;
 IF NOT coalesce(v_super.enabled,false) THEN
  RETURN jsonb_build_object('supervised',false);END IF;
 -- A recepção pode abrir antes de a prova ser publicada; nenhum enunciado é
 -- disponibilizado até o professor ativar o exame e autorizar o aluno.
 SELECT count(*) INTO v_matches FROM public.students
 WHERE active AND class_group=v_super.class_group AND
 lower(btrim(name))=lower(btrim(p_student_name));
 IF v_matches=0 THEN RAISE EXCEPTION 'Estudante não encontrado nesta turma';END IF;
 IF v_matches>1 THEN RAISE EXCEPTION 'Nome ambíguo. Solicite identificação ao professor';END IF;
 SELECT * INTO v_student FROM public.students
 WHERE active AND class_group=v_super.class_group
 AND lower(btrim(name))=lower(btrim(p_student_name)) LIMIT 1;
 IF v_super.require_code AND (v_student.access_code IS NULL OR
  upper(btrim(coalesce(p_access_code,'')))<>upper(btrim(v_student.access_code))) THEN
  RAISE EXCEPTION 'Código individual inválido';
 END IF;
 IF EXISTS(SELECT 1 FROM public.attempts
 WHERE exam_id=v_exam.id AND student_id=v_student.id
 AND status IN ('submitted','auto_submitted')) THEN
  RAISE EXCEPTION 'Avaliação já finalizada';END IF;
 INSERT INTO public.exam_lobby(exam_id,student_id,avatar_style)
 VALUES(v_exam.id,v_student.id,mod(abs(hashtext(v_student.id::text)),6))
 ON CONFLICT(exam_id,student_id) DO UPDATE SET last_seen_at=now()
 RETURNING * INTO v_lobby;
 RETURN jsonb_build_object('supervised',true,'lobby_token',v_lobby.lobby_token,
  'student_name',v_student.name,'exam_title',v_exam.title,
  'authorized',v_lobby.authorized);
END;$fn$;
CREATE FUNCTION public.teacher_supervision_configure_v2(
 p_exam_slug text,p_class_group text,p_enabled boolean,p_require_code boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_count int;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 IF p_class_group IS NULL OR btrim(p_class_group)='' THEN
  RAISE EXCEPTION 'Selecione a turma';END IF;
 SELECT count(*) INTO v_count FROM public.students
 WHERE class_group=p_class_group AND active;
 IF v_count=0 THEN RAISE EXCEPTION 'A turma não possui estudantes ativos'; END IF;
 IF p_require_code IS NULL THEN RAISE EXCEPTION 'Informe a exigência de código';END IF;
 IF p_require_code AND EXISTS(SELECT 1 FROM public.students s WHERE s.active
  AND s.class_group=p_class_group AND nullif(btrim(coalesce(s.access_code,'')),'') IS NULL)
 THEN RAISE EXCEPTION 'Há alunos sem código: gere os códigos individuais antes de habilitar';END IF;
 IF p_enabled AND EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=v_exam.id)
 AND NOT EXISTS(SELECT 1 FROM public.exam_supervision
 WHERE exam_id=v_exam.id AND enabled AND class_group=p_class_group) THEN
   RAISE EXCEPTION 'Não é possível habilitar supervisão após o início das tentativas';
 END IF;
 INSERT INTO public.exam_supervision(exam_id,class_group,enabled,require_code,updated_by)
 VALUES(v_exam.id,p_class_group,p_enabled,p_require_code,auth.uid())
 ON CONFLICT(exam_id) DO UPDATE SET class_group=EXCLUDED.class_group,
 enabled=EXCLUDED.enabled,require_code=EXCLUDED.require_code,
 updated_by=EXCLUDED.updated_by,updated_at=now();
 RETURN jsonb_build_object('ok',true,'enabled',p_enabled,'class_group',p_class_group,
   'student_count',v_count,'require_code',p_require_code);
END;$fn$;
CREATE FUNCTION public.teacher_supervision_roster(p_exam_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_super public.exam_supervision;v_students jsonb;v_groups jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 SELECT * INTO v_super FROM public.exam_supervision WHERE exam_id=v_exam.id;
 SELECT coalesce(jsonb_agg(DISTINCT s.class_group),'[]'::jsonb) INTO v_groups
 FROM public.students s WHERE s.active AND s.class_group IS NOT NULL;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',s.id,'name',s.name,'class_group',s.class_group,
  'waiting',l.lobby_token IS NOT NULL,'authorized',coalesce(l.authorized,false),
  'last_seen',l.last_seen_at,'requested_at',l.requested_at,
  'help_pending',l.help_requested_at IS NOT NULL AND
      (l.help_resolved_at IS NULL OR l.help_resolved_at<l.help_requested_at),
  'avatar_x',l.avatar_x,'avatar_y',l.avatar_y,'avatar_style',l.avatar_style,
  'status',coalesce(a.status,'not_started'),
  'started_at',a.started_at,'occurrences',coalesce(a.occurrences,0),
  'answered',coalesce(ans.qty,0),'total',qcount.total,
  'current_position',l.current_position,
  'remaining_seconds',CASE WHEN a.started_at IS NOT NULL AND
    v_exam.duration_minutes IS NOT NULL AND a.status='in_progress' THEN
    greatest(0,extract(epoch from (a.started_at+
      make_interval(mins=>v_exam.duration_minutes)-now()))::integer)
    ELSE NULL END
 ) ORDER BY s.name),'[]'::jsonb) INTO v_students
 FROM public.students s
 LEFT JOIN public.exam_lobby l ON l.student_id=s.id AND l.exam_id=v_exam.id
 LEFT JOIN public.attempts a ON a.student_id=s.id AND a.exam_id=v_exam.id
 LEFT JOIN LATERAL (
  SELECT count(*)::int qty FROM public.answers ans
  WHERE ans.attempt_id=a.id AND ans.answer IS NOT NULL
    AND nullif(ans.answer->>'value','') IS NOT NULL
 ) ans ON true
 CROSS JOIN LATERAL (
   SELECT count(*)::int total FROM public.questions q
    WHERE q.exam_id=v_exam.id AND q.active AND q.type='objective'
 ) qcount
 WHERE s.active AND v_super.exam_id IS NOT NULL
  AND s.class_group=v_super.class_group;
 RETURN jsonb_build_object('enabled',coalesce(v_super.enabled,false),
  'class_group',v_super.class_group,'require_code',coalesce(v_super.require_code,false),
  'classes',v_groups,
  'is_active',v_exam.is_active,'students',v_students,
  'server_time',now());
END;$fn$;

CREATE FUNCTION public.teacher_students_list()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
 'id',s.id,'name',s.name,'class_group',s.class_group,
 'active',s.active,'has_code',s.access_code IS NOT NULL
 ) ORDER BY s.class_group,s.name),'[]'::jsonb)
 INTO result FROM public.students s;
 RETURN result;
END;$fn$;

CREATE FUNCTION public.teacher_student_save(
 p_student_id uuid,p_name text,p_class_group text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_student public.students;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 3 AND 120 OR
  length(btrim(coalesce(p_class_group,''))) NOT BETWEEN 1 AND 80 THEN
  RAISE EXCEPTION 'Nome ou turma inválidos';END IF;
 IF EXISTS(SELECT 1 FROM public.students s WHERE s.id IS DISTINCT FROM p_student_id
  AND s.active AND s.class_group=btrim(p_class_group)
  AND lower(btrim(s.name))=lower(btrim(p_name))) THEN
  RAISE EXCEPTION 'Estudante já cadastrado nessa turma';END IF;
 IF p_student_id IS NULL THEN
  INSERT INTO public.students(name,class_group,active) VALUES(
   btrim(p_name),btrim(p_class_group),true) RETURNING * INTO v_student;
 ELSE
  IF EXISTS(SELECT 1 FROM public.attempts a WHERE a.student_id=p_student_id
    AND a.status IN('ready','in_progress'))
  AND EXISTS(SELECT 1 FROM public.students s WHERE s.id=p_student_id
    AND s.class_group IS DISTINCT FROM btrim(p_class_group)) THEN
   RAISE EXCEPTION 'Não é possível mudar a turma de aluno com tentativa pendente';
  END IF;
  UPDATE public.students SET name=btrim(p_name),class_group=btrim(p_class_group)
   WHERE id=p_student_id RETURNING * INTO v_student;
 END IF;
 IF v_student.id IS NULL THEN RAISE EXCEPTION 'Estudante não encontrado';END IF;
 RETURN jsonb_build_object('ok',true,'id',v_student.id);
END;$fn$;

CREATE FUNCTION public.teacher_student_set_active(p_student_id uuid,p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_student public.students;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 IF p_active IS NULL THEN RAISE EXCEPTION 'Situação inválida';END IF;
 IF NOT p_active AND EXISTS(SELECT 1 FROM public.attempts
  WHERE student_id=p_student_id AND status='in_progress') THEN
  RAISE EXCEPTION 'Não é possível inativar aluno durante uma avaliação';END IF;
 UPDATE public.students SET active=p_active WHERE id=p_student_id
 RETURNING * INTO v_student;
 IF v_student.id IS NULL THEN RAISE EXCEPTION 'Estudante não encontrado';END IF;
 RETURN jsonb_build_object('ok',true,'active',v_student.active);
END;$fn$;

CREATE FUNCTION public.teacher_student_issue_codes(p_class_group text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_student public.students;v_code text;v_rows jsonb:='[]'::jsonb;v_index integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 IF nullif(btrim(coalesce(p_class_group,'')),'') IS NULL THEN
  RAISE EXCEPTION 'Informe a turma';END IF;
 FOR v_student IN SELECT * FROM public.students
  WHERE active AND class_group=p_class_group ORDER BY name FOR UPDATE
 LOOP
  FOR v_index IN 1..8 LOOP
   v_code:=upper(substr(md5(gen_random_uuid()::text),1,8));
   EXIT WHEN NOT EXISTS(SELECT 1 FROM public.students WHERE access_code=v_code);
  END LOOP;
  IF EXISTS(SELECT 1 FROM public.students WHERE access_code=v_code) THEN
    RAISE EXCEPTION 'Falha na geração do código. Tente novamente';END IF;
  UPDATE public.students SET access_code=v_code WHERE id=v_student.id;
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object('name',v_student.name,'code',v_code));
 END LOOP;
 IF jsonb_array_length(v_rows)=0 THEN RAISE EXCEPTION 'Turma sem alunos ativos';END IF;
 RETURN v_rows;
END;$fn$;

REVOKE ALL ON FUNCTION public.teacher_supervision_configure_v2(text,text,boolean,boolean),
 public.teacher_students_list(),
 public.teacher_student_save(uuid,text,text),
 public.teacher_student_set_active(uuid,boolean),
 public.teacher_student_issue_codes(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_supervision_configure_v2(text,text,boolean,boolean),
 public.teacher_students_list(),
 public.teacher_student_save(uuid,text,text),
 public.teacher_student_set_active(uuid,boolean),
 public.teacher_student_issue_codes(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.student_lobby_join(text,text,text) TO anon,authenticated;
