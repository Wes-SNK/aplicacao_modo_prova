-- MIGRAÇÃO PROPOSTA 013 — APLICAR SOMENTE EM HOMOLOGAÇÃO OU APÓS APROVAÇÃO
-- Esta versão não foi aplicada ao Supabase de produção.
-- Supervisão opt-in por avaliação, sem mudança nos exames existentes.
CREATE TABLE public.exam_supervision (
  exam_id uuid PRIMARY KEY REFERENCES public.exams(id) ON DELETE CASCADE,
  class_group text NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.exam_lobby (
  exam_id uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
  student_id uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  lobby_token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  requested_at timestamptz NOT NULL DEFAULT now(),
  authorized boolean NOT NULL DEFAULT false,
  authorized_at timestamptz,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  avatar_x integer NOT NULL DEFAULT 12 CHECK (avatar_x BETWEEN 0 AND 100),
  avatar_y integer NOT NULL DEFAULT 65 CHECK (avatar_y BETWEEN 0 AND 100),
  avatar_style integer NOT NULL DEFAULT 0 CHECK (avatar_style BETWEEN 0 AND 5),
  emote text CHECK (emote IS NULL OR emote IN ('wave','question','ready')),
  help_requested_at timestamptz,
  help_resolved_at timestamptz,
  current_position integer,
  PRIMARY KEY(exam_id,student_id)
);
CREATE INDEX exam_lobby_presence_idx ON public.exam_lobby(exam_id,last_seen_at DESC);
ALTER TABLE public.exam_supervision ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exam_lobby ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exam_supervision,public.exam_lobby FROM PUBLIC,anon,authenticated;

-- Configuração restrita a usuário autenticado. Não pode habilitar controle
-- sobre uma aplicação que já teve tentativas, evitando bloquear alunos no meio.
CREATE FUNCTION public.teacher_supervision_configure(
 p_exam_slug text,p_class_group text,p_enabled boolean
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
 IF p_enabled AND EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=v_exam.id)
 AND NOT EXISTS(SELECT 1 FROM public.exam_supervision
 WHERE exam_id=v_exam.id AND enabled AND class_group=p_class_group) THEN
   RAISE EXCEPTION 'Não é possível habilitar supervisão após o início das tentativas';
 END IF;
 INSERT INTO public.exam_supervision(exam_id,class_group,enabled,updated_by)
 VALUES(v_exam.id,p_class_group,p_enabled,auth.uid())
 ON CONFLICT(exam_id) DO UPDATE SET class_group=EXCLUDED.class_group,
 enabled=EXCLUDED.enabled,updated_by=EXCLUDED.updated_by,updated_at=now();
 RETURN jsonb_build_object('ok',true,'enabled',p_enabled,'class_group',p_class_group,
   'student_count',v_count);
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
  'class_group',v_super.class_group,'classes',v_groups,
  'is_active',v_exam.is_active,'students',v_students,
  'server_time',now());
END;$fn$;

CREATE FUNCTION public.teacher_supervision_authorize(
 p_exam_slug text,p_student_id uuid,p_authorize boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
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
 IF NOT FOUND THEN RAISE EXCEPTION 'O estudante ainda não entrou na sala de espera';END IF;
 IF NOT p_authorize AND EXISTS(SELECT 1 FROM public.attempts
    WHERE exam_id=v_exam.id AND student_id=p_student_id AND started_at IS NOT NULL) THEN
   RAISE EXCEPTION 'Não é possível revogar uma prova já iniciada';END IF;
 UPDATE public.exam_lobby SET authorized=p_authorize,
  authorized_at=CASE WHEN p_authorize THEN now() ELSE NULL END
 WHERE exam_id=v_exam.id AND student_id=p_student_id;
 RETURN jsonb_build_object('ok',true,'authorized',p_authorize);
END;$fn$;

CREATE FUNCTION public.teacher_supervision_authorize_all(p_exam_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_super public.exam_supervision;v_count integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 SELECT * INTO v_super FROM public.exam_supervision WHERE exam_id=v_exam.id;
 IF NOT coalesce(v_super.enabled,false) THEN RAISE EXCEPTION 'Supervisão não habilitada';END IF;
 UPDATE public.exam_lobby l SET authorized=true,authorized_at=now()
 FROM public.students s WHERE l.exam_id=v_exam.id AND s.id=l.student_id
 AND s.active AND s.class_group=v_super.class_group AND NOT l.authorized;
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN jsonb_build_object('ok',true,'authorized_count',v_count);
END;$fn$;

CREATE FUNCTION public.teacher_supervision_resolve_help(
 p_exam_slug text,p_student_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam_id uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT id INTO v_exam_id FROM public.exams WHERE slug=p_exam_slug;
 IF NOT EXISTS(SELECT 1 FROM public.exam_supervision g
 JOIN public.students s ON s.class_group=g.class_group
 WHERE g.exam_id=v_exam_id AND g.enabled AND s.id=p_student_id AND s.active) THEN
  RAISE EXCEPTION 'Estudante fora da turma supervisionada';END IF;
 UPDATE public.exam_lobby SET help_resolved_at=now()
 WHERE exam_id=v_exam_id AND student_id=p_student_id;
 RETURN jsonb_build_object('ok',true);
END;$fn$;

-- Primeira chamada de um aluno: consulta se a prova exige autorização.
-- Quando a supervisão está desabilitada, retorna imediatamente "false",
-- preservando o fluxo existente.
CREATE FUNCTION public.student_lobby_join(p_exam_slug text,p_student_name text)
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
 IF NOT public._exam_available(v_exam) THEN RAISE EXCEPTION 'Avaliação indisponível';END IF;
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
 INSERT INTO public.exam_lobby(exam_id,student_id,avatar_style)
 VALUES(v_exam.id,v_student.id,mod(abs(hashtext(v_student.id::text)),6))
 ON CONFLICT(exam_id,student_id) DO UPDATE SET last_seen_at=now()
 RETURNING * INTO v_lobby;
 RETURN jsonb_build_object('supervised',true,'lobby_token',v_lobby.lobby_token,
  'student_name',v_student.name,'exam_title',v_exam.title,
  'authorized',v_lobby.authorized);
END;$fn$;

CREATE FUNCTION public.student_lobby_state(p_lobby_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
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
 AND l.last_seen_at>now()-interval '45 seconds';
 RETURN jsonb_build_object('authorized',v_lobby.authorized,
  'is_active',public._exam_available(v_exam),'peers',v_peers,
  'help_pending',v_lobby.help_requested_at IS NOT NULL AND
    (v_lobby.help_resolved_at IS NULL OR v_lobby.help_resolved_at<v_lobby.help_requested_at),
  'server_time',now());
END;$fn$;

CREATE FUNCTION public.student_lobby_move(
 p_lobby_token uuid,p_x integer,p_y integer,p_emote text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
BEGIN
 IF p_x NOT BETWEEN 0 AND 100 OR p_y NOT BETWEEN 0 AND 100
 OR p_emote IS NOT NULL AND p_emote NOT IN('wave','question','ready') THEN
  RAISE EXCEPTION 'Movimento inválido';END IF;
 UPDATE public.exam_lobby SET avatar_x=p_x,avatar_y=p_y,emote=p_emote,
 last_seen_at=now() WHERE lobby_token=p_lobby_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão inválida';END IF;
 RETURN jsonb_build_object('ok',true);
END;$fn$;

CREATE FUNCTION public.student_lobby_help(p_lobby_token uuid,p_request boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
BEGIN
 IF p_request IS NULL THEN RAISE EXCEPTION 'Informe a solicitação';END IF;
 UPDATE public.exam_lobby SET
  help_requested_at=CASE WHEN p_request THEN now() ELSE NULL END,
  help_resolved_at=CASE WHEN p_request THEN NULL ELSE now() END,
  last_seen_at=now()
 WHERE lobby_token=p_lobby_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão inválida';END IF;
 RETURN jsonb_build_object('ok',true,'help_pending',p_request);
END;$fn$;

CREATE FUNCTION public.student_exam_heartbeat(p_session_token uuid,p_position integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_attempt public.attempts;v_total int;
BEGIN
 SELECT * INTO v_attempt FROM public.attempts WHERE session_token=p_session_token;
 IF v_attempt.id IS NULL THEN RAISE EXCEPTION 'Sessão inválida';END IF;
 SELECT count(*) INTO v_total FROM public.questions WHERE exam_id=v_attempt.exam_id AND active;
 IF p_position IS NOT NULL AND (p_position<1 OR p_position>v_total) THEN
  RAISE EXCEPTION 'Posição inválida';END IF;
 IF v_attempt.status='in_progress' THEN
  UPDATE public.attempts SET last_seen_at=now() WHERE id=v_attempt.id;
  UPDATE public.exam_lobby SET last_seen_at=now(),current_position=p_position
   WHERE exam_id=v_attempt.exam_id AND student_id=v_attempt.student_id;
 END IF;
 RETURN jsonb_build_object('ok',true,'status',v_attempt.status);
END;$fn$;

REVOKE ALL ON FUNCTION public.teacher_supervision_configure(text,text,boolean),
 public.teacher_supervision_roster(text),
 public.teacher_supervision_authorize(text,uuid,boolean),
 public.teacher_supervision_authorize_all(text),
 public.teacher_supervision_resolve_help(text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_supervision_configure(text,text,boolean),
 public.teacher_supervision_roster(text),
 public.teacher_supervision_authorize(text,uuid,boolean),
 public.teacher_supervision_authorize_all(text),
 public.teacher_supervision_resolve_help(text,uuid) TO authenticated;
-- Os tokens imprevisíveis são o único identificador de uma sessão anônima.
GRANT EXECUTE ON FUNCTION public.student_lobby_join(text,text),
 public.student_lobby_state(uuid),public.student_lobby_move(uuid,integer,integer,text),
 public.student_lobby_help(uuid,boolean),
 public.student_exam_heartbeat(uuid,integer) TO anon,authenticated;
