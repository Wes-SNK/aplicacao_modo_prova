-- Migração 012: publicar preset com apenas as questões habilitadas.
-- Questões marcadas como inativas devem permanecer preservadas e fora da aplicação.
CREATE OR REPLACE FUNCTION public.teacher_preset_toggle(p_exam_slug text,p_online boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_total integer;v_invalid integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso do professor necessário'; END IF;
 IF p_online IS NULL THEN RAISE EXCEPTION 'Estado de publicação inválido'; END IF;
 SELECT e.* INTO v_exam FROM public.exams e
  JOIN public.exam_presets p ON p.exam_id=e.id
  WHERE e.slug=p_exam_slug AND p.created_by=auth.uid() AND NOT p.archived
  FOR UPDATE OF e;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Preset próprio não encontrado ou arquivado'; END IF;
 IF p_online THEN
  SELECT count(*) FILTER(WHERE active),
   count(*) FILTER(
    WHERE active AND NOT (
      type='objective' AND public._valid_objective_options(options,correct_answer)
    )
   ) INTO v_total,v_invalid
  FROM public.questions WHERE exam_id=v_exam.id;
  IF v_total<1 OR v_invalid<>0 THEN
   RAISE EXCEPTION 'O preset precisa de questões objetivas ativas e válidas antes da publicação';
  END IF;
  IF v_exam.duration_minutes IS NOT NULL AND v_exam.duration_minutes NOT BETWEEN 5 AND 300 THEN
   RAISE EXCEPTION 'Duração inválida'; END IF;
  IF v_exam.max_occurrences NOT BETWEEN 1 AND 20 THEN
   RAISE EXCEPTION 'Limite de ocorrências inválido'; END IF;
 END IF;
 UPDATE public.exams SET is_active=p_online WHERE id=v_exam.id RETURNING * INTO v_exam;
 RETURN jsonb_build_object('ok',true,'slug',v_exam.slug,'is_active',v_exam.is_active);
END;
$fn$;
REVOKE ALL ON FUNCTION public.teacher_preset_toggle(text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_preset_toggle(text,boolean) TO authenticated;
