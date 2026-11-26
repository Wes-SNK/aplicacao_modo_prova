-- 018 - Duas permissões independentes. Remove códigos individuais do fluxo.
-- Permitido: autorização de entrada no pátio e liberação do início da prova.
-- A entrada pelo nome não gera tentativa nem libera enunciado da avaliação.
ALTER TABLE public.exam_lobby ADD COLUMN lobby_allowed boolean NOT NULL DEFAULT false;
ALTER TABLE public.exam_lobby ADD COLUMN access_requested_at timestamptz;
-- Preserva presenças anteriores, caso existam.
UPDATE public.exam_lobby SET lobby_allowed=true,
 access_requested_at=requested_at WHERE requested_at IS NOT NULL;
-- Não guardar identificadores de acesso individuais, nem exigir códigos.
UPDATE public.exam_supervision SET require_code=false WHERE require_code=true;
UPDATE public.students SET access_code=NULL WHERE access_code IS NOT NULL;

-- Remover funções históricas para impedir que códigos sejam recriados/utilizados.
DROP FUNCTION IF EXISTS public.student_lobby_join(text,text,text);
DROP FUNCTION IF EXISTS public.teacher_student_issue_codes(text);
REVOKE ALL ON FUNCTION public.teacher_supervision_configure_v2(text,text,boolean,boolean)
 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.student_lobby_join(p_exam_slug text, p_student_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
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
    now(),NULL,false)
 ON CONFLICT(exam_id,student_id) DO UPDATE
 SET access_requested_at=now(),
     requested_at=CASE WHEN public.exam_lobby.lobby_allowed THEN
       coalesce(public.exam_lobby.requested_at,now()) ELSE NULL END,
     last_seen_at=CASE WHEN public.exam_lobby.lobby_allowed THEN now()
       ELSE public.exam_lobby.last_seen_at END
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
AS $function$;
DECLARE v_lobby public.exam_lobby;v_exam public.exams;v_peers jsonb;
BEGIN
 SELECT * INTO v_lobby FROM public.exam_lobby WHERE lobby_token=p_lobby_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão da sala de espera inválida';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE id=v_lobby.exam_id;
 IF NOT EXISTS(SELECT 1 FROM public.exam_supervision WHERE exam_id=v_exam.id AND enabled) THEN
  RAISE EXCEPTION 'Sala de espera desativada';END IF;
 IF v_lobby.lobby_allowed THEN
   UPDATE public.exam_lobby SET last_seen_at=now(),
       requested_at=coalesce(requested_at,now())
   WHERE lobby_token=p_lobby_token;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',substr(md5(l.student_id::text),1,10),
  'x',l.avatar_x,'y',l.avatar_y,'style',l.avatar_style,
  'emote',l.emote,'self',l.student_id=v_lobby.student_id
 ) ORDER BY l.student_id),'[]'::jsonb) INTO v_peers
 FROM public.exam_lobby l WHERE l.exam_id=v_exam.id
 AND l.lobby_allowed AND l.requested_at IS NOT NULL
 AND l.last_seen_at>now()-interval '45 seconds';
 RETURN jsonb_build_object('authorized',v_lobby.authorized,
  'lobby_allowed',v_lobby.lobby_allowed,
  'is_active',public._exam_available(v_exam),
  'peers',CASE WHEN v_lobby.lobby_allowed THEN v_peers ELSE '[]'::jsonb END,
  'help_pending',v_lobby.help_requested_at IS NOT NULL AND
    (v_lobby.help_resolved_at IS NULL OR v_lobby.help_resolved_at<v_lobby.help_requested_at),
  'server_time',now());
END;$function$;

CREATE OR REPLACE FUNCTION public.student_lobby_enter(p_lobby_token uuid, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
DECLARE l public.exam_lobby;e public.exams;s public.students;a public.attempts;
 q jsonb;ans jsonb;
BEGIN
 SELECT * INTO l FROM public.exam_lobby
 WHERE lobby_token=p_lobby_token FOR UPDATE;
 IF l.exam_id IS NULL THEN RAISE EXCEPTION 'Sala de espera inválida';END IF;
 SELECT * INTO e FROM public.exams WHERE id=l.exam_id;
 IF NOT public._exam_available(e) THEN
  RAISE EXCEPTION 'Avaliação indisponível';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.exam_supervision g
 WHERE g.exam_id=e.id AND g.enabled) THEN
  RAISE EXCEPTION 'Sala de espera não está ativa';END IF;
 IF NOT l.lobby_allowed THEN RAISE EXCEPTION 'Aguarde autorização de entrada na sala';END IF;
 IF NOT l.authorized THEN RAISE EXCEPTION 'Aguarde autorização de início da prova';END IF;
 SELECT * INTO s FROM public.students WHERE id=l.student_id AND active;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.exam_supervision g
 WHERE g.exam_id=e.id AND g.class_group=s.class_group) THEN
  RAISE EXCEPTION 'Estudante fora da turma autorizada';END IF;
 SELECT * INTO a FROM public.attempts WHERE exam_id=e.id AND student_id=s.id FOR UPDATE;
 IF a.id IS NULL THEN
   INSERT INTO public.attempts(exam_id,student_id,user_agent)
   VALUES(e.id,s.id,p_user_agent) RETURNING * INTO a;
 ELSIF a.status IN ('submitted','auto_submitted') THEN
   RAISE EXCEPTION 'Avaliação já finalizada';
 ELSIF a.status='in_progress' THEN
   IF NOT a.resume_allowed THEN
     RAISE EXCEPTION 'Avaliação já iniciada. Peça ao professor a liberação de retomada';
   END IF;
   UPDATE public.attempts SET session_token=gen_random_uuid(),
    resume_allowed=false,last_seen_at=now(),
    user_agent=coalesce(p_user_agent,user_agent)
   WHERE id=a.id RETURNING * INTO a;
 ELSE
   UPDATE public.attempts SET last_seen_at=now(),
    user_agent=coalesce(p_user_agent,user_agent)
   WHERE id=a.id RETURNING * INTO a;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'type',x.type,
  'stem',x.stem,'options',x.options) ORDER BY x.sort_key),'[]'::jsonb) INTO q
 FROM (SELECT q.*,md5(a.session_token::text||q.id::text) AS sort_key
  FROM public.questions q WHERE q.exam_id=e.id AND q.active
  AND q.type='objective') x;
 SELECT coalesce(jsonb_object_agg(question_id::text,answer),'{}'::jsonb)
 INTO ans FROM public.answers WHERE attempt_id=a.id;
 RETURN jsonb_build_object(
 'attempt_id',a.id,'session_token',a.session_token,'status',a.status,
 'student_name',s.name,'exam_title',e.title,'assessment_mode',e.assessment_mode,
 'duration_minutes',e.duration_minutes,'max_occurrences',e.max_occurrences,
 'occurrences',a.occurrences,'started_at',a.started_at,
 'ends_at',CASE WHEN a.started_at IS NULL THEN NULL
   ELSE a.started_at+make_interval(mins=>e.duration_minutes) END,
 'questions',q,'answers',ans,'review_flags',coalesce(a.review_flags,'{}'::jsonb),
 'supervised',true);
END;$function$;

CREATE OR REPLACE FUNCTION public.student_lobby_move(p_lobby_token uuid, p_x integer, p_y integer, p_emote text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
BEGIN
 IF p_x NOT BETWEEN 0 AND 100 OR p_y NOT BETWEEN 0 AND 100
 OR p_emote IS NOT NULL AND p_emote NOT IN('wave','question','ready') THEN
  RAISE EXCEPTION 'Movimento inválido';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.exam_lobby WHERE lobby_token=p_lobby_token
   AND lobby_allowed) THEN RAISE EXCEPTION 'Acesso ao pátio não autorizado';END IF;
 UPDATE public.exam_lobby SET avatar_x=p_x,avatar_y=p_y,emote=p_emote,
 last_seen_at=now() WHERE lobby_token=p_lobby_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão inválida';END IF;
 RETURN jsonb_build_object('ok',true);
END;$function$;

CREATE OR REPLACE FUNCTION public.student_lobby_help(p_lobby_token uuid, p_request boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
BEGIN
 IF p_request IS NULL THEN RAISE EXCEPTION 'Informe a solicitação';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.exam_lobby WHERE lobby_token=p_lobby_token
  AND lobby_allowed) THEN RAISE EXCEPTION 'Acesso ao pátio não autorizado';END IF;
 UPDATE public.exam_lobby SET
  help_requested_at=CASE WHEN p_request THEN now() ELSE NULL END,
  help_resolved_at=CASE WHEN p_request THEN NULL ELSE now() END,
  last_seen_at=now()
 WHERE lobby_token=p_lobby_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão inválida';END IF;
 RETURN jsonb_build_object('ok',true,'help_pending',p_request);
END;$function$;

CREATE OR REPLACE FUNCTION public.teacher_supervision_roster(p_exam_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
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
  'waiting',coalesce(l.lobby_allowed,false) AND l.requested_at IS NOT NULL,
  'lobby_allowed',coalesce(l.lobby_allowed,false),
  'lobby_requested',l.access_requested_at IS NOT NULL,'authorized',coalesce(l.authorized,false),
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

CREATE OR REPLACE FUNCTION public.teacher_supervision_authorize_all(p_exam_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
DECLARE v_exam public.exams;v_super public.exam_supervision;v_count integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 SELECT * INTO v_super FROM public.exam_supervision WHERE exam_id=v_exam.id;
 IF NOT coalesce(v_super.enabled,false) THEN RAISE EXCEPTION 'Supervisão não habilitada';END IF;
 UPDATE public.exam_lobby l SET authorized=true,authorized_at=now()
 FROM public.students s WHERE l.exam_id=v_exam.id AND s.id=l.student_id
 AND s.active AND s.class_group=v_super.class_group AND NOT l.authorized
 AND l.lobby_allowed AND l.requested_at IS NOT NULL
 AND l.last_seen_at>now()-interval '45 seconds';
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN jsonb_build_object('ok',true,'authorized_count',v_count);
END;$function$;

CREATE OR REPLACE FUNCTION public.teacher_supervision_configure_v3(p_exam_slug text, p_class_group text, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$;
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
 IF p_enabled AND EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=v_exam.id)
 AND NOT EXISTS(SELECT 1 FROM public.exam_supervision
 WHERE exam_id=v_exam.id AND enabled AND class_group=p_class_group) THEN
   RAISE EXCEPTION 'Não é possível habilitar supervisão após o início das tentativas';
 END IF;
 INSERT INTO public.exam_supervision(exam_id,class_group,enabled,require_code,updated_by)
 VALUES(v_exam.id,p_class_group,p_enabled,false,auth.uid())
 ON CONFLICT(exam_id) DO UPDATE SET class_group=EXCLUDED.class_group,
 enabled=EXCLUDED.enabled,require_code=false,
 updated_by=EXCLUDED.updated_by,updated_at=now();
 RETURN jsonb_build_object('ok',true,'enabled',p_enabled,'class_group',p_class_group,
   'student_count',v_count,'require_code',false);
END;$function$;

CREATE OR REPLACE FUNCTION public.teacher_supervision_lobby_access(
 p_exam_slug text,p_student_id uuid,p_allow boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_group public.exam_supervision;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 IF p_allow IS NULL THEN RAISE EXCEPTION 'Ação inválida'; END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
 SELECT * INTO v_group FROM public.exam_supervision
  WHERE exam_id=v_exam.id AND enabled;
 IF NOT FOUND THEN RAISE EXCEPTION 'Supervisão não habilitada'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.students s
  WHERE s.id=p_student_id AND s.active AND s.class_group=v_group.class_group)
 THEN RAISE EXCEPTION 'Estudante fora da turma'; END IF;
 IF NOT p_allow AND EXISTS(SELECT 1 FROM public.attempts a
   WHERE a.exam_id=v_exam.id AND a.student_id=p_student_id
   AND a.started_at IS NOT NULL)
 THEN RAISE EXCEPTION 'Não é possível revogar o pátio após início da prova';END IF;
 INSERT INTO public.exam_lobby(exam_id,student_id,requested_at,lobby_allowed,
  authorized,access_requested_at)
 VALUES(v_exam.id,p_student_id,NULL,p_allow,false,NULL)
 ON CONFLICT(exam_id,student_id) DO UPDATE SET
  lobby_allowed=EXCLUDED.lobby_allowed,
  last_seen_at=CASE WHEN EXCLUDED.lobby_allowed AND
     public.exam_lobby.access_requested_at IS NOT NULL THEN now()
     ELSE public.exam_lobby.last_seen_at END;
 RETURN jsonb_build_object('ok',true,'lobby_allowed',p_allow);
END;
$fn$;

REVOKE ALL ON FUNCTION public.teacher_supervision_configure_v3(text,text,boolean),
 public.teacher_supervision_lobby_access(text,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_supervision_configure_v3(text,text,boolean),
 public.teacher_supervision_lobby_access(text,uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.student_lobby_join(text,text),
 public.student_lobby_state(uuid), public.student_lobby_enter(uuid,text),
 public.student_lobby_move(uuid,integer,integer,text),
 public.student_lobby_help(uuid,boolean) TO anon,authenticated;