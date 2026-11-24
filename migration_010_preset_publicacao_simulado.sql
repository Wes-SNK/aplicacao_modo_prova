-- Migração 010: publicação rápida e exclusiva do simulado de 01/12/2026.
-- Não altera título, duração, ocorrências, questões nem a prova oficial.
CREATE OR REPLACE FUNCTION public.teacher_set_simulado_online(p_online boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_exam public.exams;
  v_questions integer;
  v_easy integer;
  v_medium integer;
  v_hard integer;
  v_a integer;
  v_b integer;
  v_c integer;
  v_d integer;
  v_invalid integer;
  v_total_points numeric;
  v_other_exam_active boolean;
  v_was_online boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado: entre como professor'; END IF;
  IF p_online IS NULL THEN RAISE EXCEPTION 'Informe se deseja colocar online ou tirar do ar'; END IF;

  SELECT * INTO v_exam FROM public.exams
   WHERE slug='simulado-4bim-1b-2026' FOR UPDATE;
  IF v_exam.id IS NULL OR v_exam.assessment_mode<>'simulation' THEN
    RAISE EXCEPTION 'Preset indisponível: simulado não encontrado ou modo incorreto';
  END IF;
  v_was_online:=v_exam.is_active;

  IF p_online THEN
    SELECT count(*),
       count(*) FILTER (WHERE difficulty='facil'),
       count(*) FILTER (WHERE difficulty='media'),
       count(*) FILTER (WHERE difficulty='dificil'),
       count(*) FILTER (WHERE correct_answer='A'),
       count(*) FILTER (WHERE correct_answer='B'),
       count(*) FILTER (WHERE correct_answer='C'),
       count(*) FILTER (WHERE correct_answer='D'),
       count(*) FILTER (
         WHERE NOT (
           active=true AND type='objective' AND position BETWEEN 1 AND 20
           AND public._valid_objective_options(options,correct_answer)
           AND jsonb_array_length(options)=4
           AND explanation IS NOT NULL AND btrim(explanation)<>''
           AND points=1
         )
       ),
       sum(points)
    INTO v_questions,v_easy,v_medium,v_hard,
         v_a,v_b,v_c,v_d,v_invalid,v_total_points
    FROM public.questions WHERE exam_id=v_exam.id;

    IF v_questions<>20 OR v_easy<>8 OR v_medium<>9 OR v_hard<>3
       OR v_a<>5 OR v_b<>5 OR v_c<>5 OR v_d<>5
       OR v_invalid<>0 OR v_total_points<>20
       OR (SELECT count(distinct position) FROM public.questions WHERE exam_id=v_exam.id)<>20
    THEN
      RAISE EXCEPTION 'Preset não corresponde às 20 questões validadas (8 fáceis, 9 médias, 3 difíceis). Revise antes de publicar';
    END IF;
    IF v_exam.duration_minutes IS NOT NULL
      AND (v_exam.duration_minutes<5 OR v_exam.duration_minutes>300) THEN
      RAISE EXCEPTION 'Duração inválida: revise as configurações';
    END IF;
    IF v_exam.max_occurrences IS NULL OR v_exam.max_occurrences NOT BETWEEN 1 AND 20 THEN
      RAISE EXCEPTION 'Limite de ocorrências inválido: revise as configurações';
    END IF;
  END IF;

  UPDATE public.exams SET is_active=p_online
   WHERE id=v_exam.id RETURNING * INTO v_exam;

  SELECT is_active INTO v_other_exam_active
    FROM public.exams WHERE slug='prova-4bim-1b-2026';
  RETURN jsonb_build_object(
    'ok',true,'is_active',v_exam.is_active,
    'already_in_state',v_was_online=p_online,
    'exam_slug',v_exam.slug,
    'duration_minutes',v_exam.duration_minutes,
    'max_occurrences',v_exam.max_occurrences,
    'exam_mode',v_exam.assessment_mode,
    'official_exam_is_active',v_other_exam_active
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.teacher_set_simulado_online(boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_set_simulado_online(boolean) TO authenticated;