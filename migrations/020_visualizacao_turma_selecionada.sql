-- 020: visualizar imediatamente os alunos da turma selecionada sem alterar a
-- vinculação persistida da avaliação ou suas autorizações.
-- A RPC só é executável pelo professor autenticado; as ações de liberação
-- continuam verificando a turma efetivamente vinculada no servidor.
CREATE OR REPLACE FUNCTION public.teacher_supervision_roster_by_class(p_exam_slug text, p_class_group text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_exam public.exams;v_super public.exam_supervision;v_students jsonb;v_groups jsonb;v_target text;v_matches_config boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO v_exam FROM public.exams WHERE slug=p_exam_slug;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 SELECT * INTO v_super FROM public.exam_supervision WHERE exam_id=v_exam.id;
 v_target:=coalesce(nullif(btrim(p_class_group),''),v_super.class_group);
 v_matches_config:=v_target IS NOT DISTINCT FROM v_super.class_group AND v_super.exam_id IS NOT NULL;
 IF v_target IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM public.students WHERE active AND class_group=v_target
 ) THEN RAISE EXCEPTION 'Turma sem estudantes ativos ou não encontrada';END IF;
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
 WHERE s.active AND v_target IS NOT NULL
  AND s.class_group=v_target;
 RETURN jsonb_build_object('enabled',coalesce(v_super.enabled,false) AND v_matches_config,
  'class_group',v_target,'configured_class_group',v_super.class_group,
  'preview_only',NOT v_matches_config,
  'configured_enabled',coalesce(v_super.enabled,false),
  'require_code',false,
  'classes',v_groups,
  'is_active',v_exam.is_active,'students',v_students,
  'server_time',now());
END;$function$;

REVOKE ALL ON FUNCTION public.teacher_supervision_roster_by_class(text,text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_supervision_roster_by_class(text,text)
TO authenticated;
