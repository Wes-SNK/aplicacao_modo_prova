-- Migração 011 — Gerenciador de presets personalizados.
-- As três avaliações existentes permanecem intocadas.
CREATE TABLE IF NOT EXISTS public.exam_presets (
  exam_id uuid PRIMARY KEY REFERENCES public.exams(id) ON DELETE CASCADE,
  created_by uuid NOT NULL,
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exam_presets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exam_presets FROM PUBLIC,anon,authenticated;
CREATE INDEX IF NOT EXISTS idx_exam_presets_owner ON public.exam_presets(created_by,archived);

CREATE OR REPLACE FUNCTION public.teacher_presets_list()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_items jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso do professor necessário'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'slug',t.slug,'title',t.title,'assessment_mode',t.assessment_mode,
  'duration_minutes',t.duration_minutes,'max_occurrences',t.max_occurrences,
  'is_active',t.is_active,'custom',t.custom,'archived',t.archived,
  'question_count',t.question_count,'attempts_count',t.attempts_count,
  'easy_count',t.easy_count,'medium_count',t.medium_count,'hard_count',t.hard_count,
  'created_at',t.created_at
 ) ORDER BY t.custom DESC,t.archived ASC,t.created_at DESC),'[]'::jsonb)
 INTO v_items
 FROM (
 SELECT e.*,p.exam_id IS NOT NULL AS custom,coalesce(p.archived,false) AS archived,
 (SELECT count(*) FROM public.questions q WHERE q.exam_id=e.id AND q.active AND q.type='objective') AS question_count,
 (SELECT count(*) FROM public.attempts a WHERE a.exam_id=e.id) AS attempts_count,
 (SELECT count(*) FROM public.questions q WHERE q.exam_id=e.id AND q.active AND q.difficulty='facil') AS easy_count,
 (SELECT count(*) FROM public.questions q WHERE q.exam_id=e.id AND q.active AND q.difficulty='media') AS medium_count,
 (SELECT count(*) FROM public.questions q WHERE q.exam_id=e.id AND q.active AND q.difficulty='dificil') AS hard_count
 FROM public.exams e LEFT JOIN public.exam_presets p ON p.exam_id=e.id
 WHERE p.exam_id IS NULL OR p.created_by=auth.uid()
 ) t;
 RETURN v_items;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_preset_create(
 p_title text, p_assessment_mode text, p_duration_minutes integer,
 p_max_occurrences integer, p_source_slug text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_source public.exams;v_exam public.exams;v_slug text;v_n integer:=0;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso do professor necessário'; END IF;
 IF length(btrim(coalesce(p_title,''))) NOT BETWEEN 5 AND 160 THEN
  RAISE EXCEPTION 'Título deve conter entre 5 e 160 caracteres';
 END IF;
 IF p_assessment_mode NOT IN ('exam','simulation') OR p_assessment_mode IS NULL THEN
  RAISE EXCEPTION 'Modalidade deve ser prova ou simulado';
 END IF;
 IF p_duration_minutes IS NOT NULL AND p_duration_minutes NOT BETWEEN 5 AND 300 THEN
  RAISE EXCEPTION 'Duração inválida';
 END IF;
 IF p_max_occurrences IS NULL OR p_max_occurrences NOT BETWEEN 1 AND 20 THEN
  RAISE EXCEPTION 'Limite de ocorrências inválido';
 END IF;
 IF nullif(btrim(coalesce(p_source_slug,'')),'') IS NOT NULL THEN
  SELECT * INTO v_source FROM public.exams WHERE slug=p_source_slug;
  IF NOT FOUND THEN RAISE EXCEPTION 'Modelo para duplicação não encontrado'; END IF;
  IF EXISTS (SELECT 1 FROM public.exam_presets p
       WHERE p.exam_id=v_source.id AND (p.created_by<>auth.uid() OR p.archived)) THEN
   RAISE EXCEPTION 'Você não tem acesso a esse modelo';
  END IF;
 END IF;
 v_slug:='preset-'||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.exams(slug,title,assessment_mode,duration_minutes,
                          max_occurrences,is_active,opens_at,closes_at)
 VALUES(v_slug,btrim(p_title),p_assessment_mode,p_duration_minutes,
        p_max_occurrences,false,NULL,NULL)
 RETURNING * INTO v_exam;
 INSERT INTO public.exam_presets(exam_id,created_by) VALUES(v_exam.id,auth.uid());
 IF v_source.id IS NOT NULL THEN
  INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,
                               points,active,explanation,difficulty)
  SELECT v_exam.id,q.position,q.type,q.stem,q.options,q.correct_answer,
         q.points,q.active,q.explanation,q.difficulty
    FROM public.questions q WHERE q.exam_id=v_source.id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
 END IF;
 RETURN jsonb_build_object('ok',true,'slug',v_slug,'questions_copied',v_n,
  'is_active',false,'title',v_exam.title);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_preset_autofill(
 p_exam_slug text,p_plan jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_row record;v_difficulty text;v_needed integer;
 v_available integer;v_inserted integer:=0;v_total integer:=0;
 v_count_subjects integer;v_count_distinct integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso do professor necessário'; END IF;
 SELECT e.* INTO v_exam FROM public.exams e
  JOIN public.exam_presets p ON p.exam_id=e.id
  WHERE e.slug=p_exam_slug AND p.created_by=auth.uid() AND NOT p.archived FOR UPDATE OF e;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Preset próprio não encontrado ou arquivado'; END IF;
 IF v_exam.is_active THEN RAISE EXCEPTION 'Tire o preset do ar antes de montar as questões'; END IF;
 IF EXISTS(SELECT 1 FROM public.attempts a WHERE a.exam_id=v_exam.id) THEN
  RAISE EXCEPTION 'Este preset já possui tentativas: a composição está bloqueada';
 END IF;
 IF EXISTS(SELECT 1 FROM public.questions q WHERE q.exam_id=v_exam.id) THEN
  RAISE EXCEPTION 'O preenchimento automático exige um preset vazio. Para alterar a seleção, use o banco de questões ou crie um novo preset';
 END IF;
 IF p_plan IS NULL OR jsonb_typeof(p_plan)<>'array' THEN
  RAISE EXCEPTION 'Plano de distribuição inválido';
 END IF;
 SELECT count(*),count(DISTINCT subject)
  INTO v_count_subjects,v_count_distinct
  FROM jsonb_to_recordset(p_plan) AS x(subject text,facil integer,media integer,dificil integer);
 IF v_count_subjects NOT BETWEEN 1 AND 4 OR v_count_subjects<>v_count_distinct THEN
  RAISE EXCEPTION 'Informe de uma a quatro disciplinas, sem repetição';
 END IF;
 FOR v_row IN SELECT * FROM jsonb_to_recordset(p_plan)
   AS x(subject text,facil integer,media integer,dificil integer)
 LOOP
  IF v_row.subject NOT IN ('Lógica de Programação','HTML/CSS','Arquitetura e Manutenção',
                           'Planejamento de Carreira e IA') OR v_row.subject IS NULL THEN
   RAISE EXCEPTION 'Disciplina inválida no plano';
  END IF;
  IF v_row.facil IS NULL OR v_row.media IS NULL OR v_row.dificil IS NULL
     OR v_row.facil NOT BETWEEN 0 AND 50 OR v_row.media NOT BETWEEN 0 AND 50
     OR v_row.dificil NOT BETWEEN 0 AND 50 THEN
   RAISE EXCEPTION 'Quantidades por dificuldade inválidas';
  END IF;
  v_total:=v_total+v_row.facil+v_row.media+v_row.dificil;
  IF v_total>80 THEN RAISE EXCEPTION 'O limite é de 80 questões por preset'; END IF;
  FOR v_difficulty,v_needed IN
   SELECT 'facil',v_row.facil UNION ALL
   SELECT 'media',v_row.media UNION ALL
   SELECT 'dificil',v_row.dificil
  LOOP
   CONTINUE WHEN v_needed=0;
   SELECT count(*) INTO v_available FROM public.question_bank b
    WHERE b.subject=v_row.subject AND b.difficulty=v_difficulty
      AND public._valid_objective_options(b.options,b.correct_answer);
   IF v_available<v_needed THEN
    RAISE EXCEPTION 'Banco insuficiente em % / %: pediu %, disponíveis %',
     v_row.subject,v_difficulty,v_needed,v_available;
   END IF;
   INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,
             points,active,explanation,difficulty)
   SELECT v_exam.id,v_inserted+row_number() over(order by candidate.id),
          'objective',candidate.stem,candidate.options,candidate.correct_answer,
          candidate.points,true,candidate.explanation,candidate.difficulty
   FROM (
    SELECT b.* FROM public.question_bank b
    WHERE b.subject=v_row.subject AND b.difficulty=v_difficulty
      AND public._valid_objective_options(b.options,b.correct_answer)
    ORDER BY md5(v_exam.id::text||b.id::text)
    LIMIT v_needed
   ) candidate;
   v_inserted:=v_inserted+v_needed;
  END LOOP;
 END LOOP;
 IF v_inserted<>v_total OR v_total<1 THEN
  RAISE EXCEPTION 'Plano vazio ou incompleto';
 END IF;
 RETURN jsonb_build_object('ok',true,'slug',v_exam.slug,'question_count',v_inserted);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_preset_toggle(p_exam_slug text,p_online boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;v_total integer;v_invalid integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso do professor necessário'; END IF;
 IF p_online IS NULL THEN RAISE EXCEPTION 'Estado de publicação inválido'; END IF;
 SELECT e.* INTO v_exam FROM public.exams e
  JOIN public.exam_presets p ON p.exam_id=e.id
  WHERE e.slug=p_exam_slug AND p.created_by=auth.uid() AND NOT p.archived FOR UPDATE OF e;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Preset próprio não encontrado ou arquivado'; END IF;
 IF p_online THEN
  SELECT count(*),count(*) FILTER(
    WHERE NOT(active AND type='objective'
      AND public._valid_objective_options(options,correct_answer))
  ) INTO v_total,v_invalid
  FROM public.questions WHERE exam_id=v_exam.id;
  IF v_total<1 OR v_invalid<>0 THEN
   RAISE EXCEPTION 'O preset precisa de questões objetivas ativas e válidas antes da publicação';
  END IF;
  IF v_exam.duration_minutes IS NOT NULL AND v_exam.duration_minutes NOT BETWEEN 5 AND 300 THEN
   RAISE EXCEPTION 'Duração inválida'; END IF;
 END IF;
 UPDATE public.exams SET is_active=p_online WHERE id=v_exam.id
 RETURNING * INTO v_exam;
 RETURN jsonb_build_object('ok',true,'slug',v_exam.slug,'is_active',v_exam.is_active);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_preset_archive(p_exam_slug text,p_archived boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam public.exams;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso do professor necessário'; END IF;
 IF p_archived IS NULL THEN RAISE EXCEPTION 'Informe o estado do arquivo'; END IF;
 SELECT e.* INTO v_exam FROM public.exams e
  JOIN public.exam_presets p ON p.exam_id=e.id
  WHERE e.slug=p_exam_slug AND p.created_by=auth.uid() FOR UPDATE OF e;
 IF v_exam.id IS NULL THEN RAISE EXCEPTION 'Preset não encontrado'; END IF;
 IF p_archived AND v_exam.is_active THEN
  RAISE EXCEPTION 'Tire a avaliação do ar antes de arquivá-la';
 END IF;
 IF p_archived AND EXISTS(SELECT 1 FROM public.attempts
  WHERE exam_id=v_exam.id AND status IN('ready','in_progress')) THEN
  RAISE EXCEPTION 'Há tentativas pendentes: finalize-as antes de arquivar';
 END IF;
 UPDATE public.exam_presets SET archived=p_archived WHERE exam_id=v_exam.id;
 RETURN jsonb_build_object('ok',true,'slug',v_exam.slug,'archived',p_archived);
END;
$fn$;

REVOKE ALL ON FUNCTION public.teacher_presets_list() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_preset_create(text,text,integer,integer,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_preset_autofill(text,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_preset_toggle(text,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_preset_archive(text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_presets_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_preset_create(text,text,integer,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_preset_autofill(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_preset_toggle(text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_preset_archive(text,boolean) TO authenticated;
