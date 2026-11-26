-- Migração 019: aluno cadastrado entra no pátio ao identificar-se;
-- somente o professor autoriza o início da avaliação.
-- A autorização continua sendo validada por student_lobby_enter.
-- O novo ingresso não cria tentativas nem entrega questões.
CREATE OR REPLACE FUNCTION public.student_lobby_join(p_exam_slug text, p_student_name text)
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
 IF EXISTS(SELECT 1 FROM public.attempts
 WHERE exam_id=v_exam.id AND student_id=v_student.id
 AND status IN ('submitted','auto_submitted')) THEN
  RAISE EXCEPTION 'Avaliação já finalizada';END IF;
 INSERT INTO public.exam_lobby(exam_id,student_id,avatar_style,access_requested_at,
    requested_at,lobby_allowed)
 VALUES(v_exam.id,v_student.id,mod(abs(hashtext(v_student.id::text)),6),
    now(),now(),true)
 ON CONFLICT(exam_id,student_id) DO UPDATE
 SET access_requested_at=now(),requested_at=now(),
     lobby_allowed=true,last_seen_at=now()
 RETURNING * INTO v_lobby;
 RETURN jsonb_build_object('supervised',true,'lobby_token',v_lobby.lobby_token,
  'student_name',v_student.name,'exam_title',v_exam.title,
  'authorized',v_lobby.authorized,'lobby_allowed',v_lobby.lobby_allowed);
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
 UPDATE public.exam_lobby SET last_seen_at=now(),lobby_allowed=true,
     requested_at=coalesce(requested_at,now())
 WHERE lobby_token=p_lobby_token;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',substr(md5(l.student_id::text),1,10),
  'x',l.avatar_x,'y',l.avatar_y,'style',l.avatar_style,
  'emote',l.emote,'self',l.student_id=v_lobby.student_id
 ) ORDER BY l.student_id),'[]'::jsonb) INTO v_peers
 FROM public.exam_lobby l WHERE l.exam_id=v_exam.id
 AND l.lobby_allowed AND l.requested_at IS NOT NULL
 AND l.last_seen_at>now()-interval '45 seconds';
 RETURN jsonb_build_object('authorized',v_lobby.authorized,
  'lobby_allowed',true,
  'is_active',public._exam_available(v_exam),
  'peers',v_peers,
  'help_pending',v_lobby.help_requested_at IS NOT NULL AND
    (v_lobby.help_resolved_at IS NULL OR v_lobby.help_resolved_at<v_lobby.help_requested_at),
  'server_time',now());
END;$function$;
-- A autorização anterior de acesso ao pátio não é mais utilizada.
REVOKE ALL ON FUNCTION public.teacher_supervision_lobby_access(text,uuid,boolean)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.student_lobby_join(text,text),
 public.student_lobby_state(uuid) TO anon,authenticated;
