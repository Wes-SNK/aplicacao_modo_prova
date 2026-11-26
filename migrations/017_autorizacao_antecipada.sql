-- Migração 017: autorizar alunos cadastrados antes de chegarem à sala.
-- Presença permanece distinta de autorização; nenhum token de tentativa é criado.
ALTER TABLE public.exam_lobby ALTER COLUMN requested_at DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.teacher_supervision_roster(p_exam_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  'waiting',l.requested_at IS NOT NULL,'authorized',coalesce(l.authorized,false),
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
END;$function$;

CREATE OR REPLACE FUNCTION public.teacher_supervision_authorize(p_exam_slug text, p_student_id uuid, p_authorize boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_exam public.exams;v_super public.exam_supervision;v_lobby public.exam_lobby;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 SELECT * INTO v_super FROM public.exam_supervision WHERE exam_id=v_exam.id;
 IF NOT coalesce(v_super.enabled,false) THEN RAISE EXCEPTION 'Supervisão não habilitada';END IF;
 IF p_authorize IS NULL THEN RAISE EXCEPTION 'Ação inválida';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.students WHERE id=p_student_id
    AND class_group=v_super.class_group AND active) THEN
   RAISE EXCEPTION 'Aluno não pertence à turma selecionada';
 END IF;
 SELECT * INTO v_lobby FROM public.exam_lobby
  WHERE exam_id=v_exam.id AND student_id=p_student_id FOR UPDATE;
 IF NOT FOUND THEN
   IF NOT p_authorize THEN
     RETURN jsonb_build_object('ok',true,'authorized',false);
   END IF;
   -- Pré-autorização não é presença: requested_at permanece NULL até que
   -- o aluno se identifique e entre efetivamente na sala de espera.
   INSERT INTO public.exam_lobby(
     exam_id,student_id,requested_at,authorized,authorized_at
   ) VALUES(v_exam.id,p_student_id,NULL,true,now())
   ON CONFLICT(exam_id,student_id) DO UPDATE SET
     authorized=true,authorized_at=now();
 ELSE
   IF NOT p_authorize AND EXISTS(SELECT 1 FROM public.attempts
      WHERE exam_id=v_exam.id AND student_id=p_student_id
      AND started_at IS NOT NULL) THEN
     RAISE EXCEPTION 'Não é possível revogar uma prova já iniciada';
   END IF;
   UPDATE public.exam_lobby SET authorized=p_authorize,
     authorized_at=CASE WHEN p_authorize THEN now() ELSE NULL END
   WHERE exam_id=v_exam.id AND student_id=p_student_id;
 END IF;
 RETURN jsonb_build_object('ok',true,'authorized',p_authorize);
END;$function$;

CREATE OR REPLACE FUNCTION public.student_lobby_join(p_exam_slug text, p_student_name text, p_access_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
 ON CONFLICT(exam_id,student_id) DO UPDATE
  SET last_seen_at=now(), requested_at=coalesce(public.exam_lobby.requested_at,now())
 RETURNING * INTO v_lobby;
 RETURN jsonb_build_object('supervised',true,'lobby_token',v_lobby.lobby_token,
  'student_name',v_student.name,'exam_title',v_exam.title,
  'authorized',v_lobby.authorized);
END;$function$;

CREATE OR REPLACE FUNCTION public.student_lobby_state(p_lobby_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_lobby public.exam_lobby;v_exam public.exams;v_peers jsonb;
BEGIN
 SELECT * INTO v_lobby FROM public.exam_lobby WHERE lobby_token=p_lobby_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão da sala de espera inválida';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE id=v_lobby.exam_id;
 IF NOT EXISTS(SELECT 1 FROM public.exam_supervision WHERE exam_id=v_exam.id AND enabled) THEN
  RAISE EXCEPTION 'Sala de espera desativada';END IF;
 UPDATE public.exam_lobby SET last_seen_at=now()
 WHERE lobby_token=p_lobby_token;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',substr(md5(l.student_id::text),1,10),
  'x',l.avatar_x,'y',l.avatar_y,'style',l.avatar_style,
  'emote',l.emote,'self',l.student_id=v_lobby.student_id
 ) ORDER BY l.student_id),'[]'::jsonb) INTO v_peers
 FROM public.exam_lobby l WHERE l.exam_id=v_exam.id
 AND l.requested_at IS NOT NULL
 AND l.last_seen_at>now()-interval '45 seconds';
 RETURN jsonb_build_object('authorized',v_lobby.authorized,
  'is_active',public._exam_available(v_exam),'peers',v_peers,
  'help_pending',v_lobby.help_requested_at IS NOT NULL AND
    (v_lobby.help_resolved_at IS NULL OR v_lobby.help_resolved_at<v_lobby.help_requested_at),
  'server_time',now());
END;$function$;

REVOKE ALL ON FUNCTION public.teacher_supervision_roster(text),
 public.teacher_supervision_authorize(text,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_supervision_roster(text),
 public.teacher_supervision_authorize(text,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.student_lobby_join(text,text,text),
 public.student_lobby_state(uuid) TO anon,authenticated;
