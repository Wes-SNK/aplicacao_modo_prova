
-- Migration 007 — reusable, append-only question bank and optional time limit.
-- IMPORTANT: No question texts or answer keys are stored in this source file.
ALTER TABLE public.exams ALTER COLUMN duration_minutes DROP NOT NULL;

CREATE TABLE IF NOT EXISTS public.question_bank (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject text NOT NULL DEFAULT 'Geral'
    CHECK (subject IN ('Lógica de Programação','HTML/CSS','Arquitetura e Manutenção',
                      'Planejamento de Carreira e IA','Geral')),
  topic text,
  stem text NOT NULL,
  options jsonb NOT NULL,
  correct_answer text NOT NULL,
  explanation text,
  points numeric NOT NULL DEFAULT 1,
  source_label text NOT NULL DEFAULT 'Criada no banco',
  source_question_id uuid,
  fingerprint text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.question_bank ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.question_bank FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._question_bank_hash(
 p_stem text,p_options jsonb,p_correct text,p_explanation text,p_points numeric
) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = 'public'
AS $fn$
 SELECT md5(jsonb_build_object(
   'stem',p_stem,'options',p_options,'answer',p_correct,
   'explanation',p_explanation,'points',p_points
 )::text);
$fn$;

CREATE OR REPLACE FUNCTION public._question_bank_capture(p_question public.questions)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE
  v_slug text;
  v_title text;
  v_subject text;
  v_hash text;
  v_id uuid;
BEGIN
  IF p_question.type <> 'objective' OR p_question.correct_answer IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT slug,title INTO v_slug,v_title FROM public.exams WHERE id=p_question.exam_id;
  v_subject := CASE
    WHEN v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 1 AND 5
      OR v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 1 AND 10
      THEN 'Lógica de Programação'
    WHEN v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 6 AND 10
      OR v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 11 AND 20
      THEN 'HTML/CSS'
    WHEN v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 11 AND 15
      OR v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 21 AND 30
      THEN 'Arquitetura e Manutenção'
    WHEN v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 16 AND 20
      OR v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 31 AND 40
      THEN 'Planejamento de Carreira e IA'
    ELSE 'Geral'
  END;
  v_hash := public._question_bank_hash(
    p_question.stem,p_question.options,p_question.correct_answer,
    p_question.explanation,p_question.points
  );
  INSERT INTO public.question_bank (
    subject,topic,stem,options,correct_answer,explanation,points,
    source_label,source_question_id,fingerprint
  )
  VALUES (
    v_subject,NULL,p_question.stem,p_question.options,p_question.correct_answer,
    p_question.explanation,p_question.points,
    coalesce(v_title,v_slug,'Avaliação anterior'),p_question.id,v_hash
  ) ON CONFLICT(fingerprint) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.question_bank WHERE fingerprint=v_hash;
  END IF;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public._question_bank_capture_trigger()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
BEGIN
  IF TG_OP='DELETE' THEN
    PERFORM public._question_bank_capture(OLD);
    RETURN OLD;
  END IF;
  IF TG_OP='UPDATE' THEN
    IF (OLD.stem,OLD.options,OLD.correct_answer,OLD.explanation,OLD.points,OLD.type)
       IS DISTINCT FROM
       (NEW.stem,NEW.options,NEW.correct_answer,NEW.explanation,NEW.points,NEW.type)
    THEN
      PERFORM public._question_bank_capture(OLD);
      PERFORM public._question_bank_capture(NEW);
    END IF;
    RETURN NEW;
  END IF;
  PERFORM public._question_bank_capture(NEW);
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_question_bank_archive ON public.questions;
CREATE TRIGGER trg_question_bank_archive
AFTER INSERT OR UPDATE OR DELETE ON public.questions
FOR EACH ROW EXECUTE FUNCTION public._question_bank_capture_trigger();

-- Backfill all existing objective questions, including deactivated legacy questions.
SELECT public._question_bank_capture(q) FROM public.questions q WHERE q.type='objective';

CREATE OR REPLACE FUNCTION public.teacher_bank_questions(
 p_subject text DEFAULT NULL, p_search text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_items jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 SELECT coalesce(jsonb_agg(
   jsonb_build_object(
     'id',x.id,'subject',x.subject,'topic',x.topic,'stem',x.stem,
     'options',x.options,'correct_answer',x.correct_answer,
     'explanation',x.explanation,'points',x.points,
     'option_count',jsonb_array_length(x.options),
     'source_label',x.source_label,'created_at',x.created_at
   ) ORDER BY x.created_at DESC,x.id
 ),'[]'::jsonb) INTO v_items
 FROM (
   SELECT *
   FROM public.question_bank
   WHERE (coalesce(p_subject,'')='' OR subject=p_subject)
     AND (coalesce(btrim(p_search),'')='' OR
          stem ILIKE '%'||btrim(p_search)||'%' OR
          coalesce(topic,'') ILIKE '%'||btrim(p_search)||'%' OR
          source_label ILIKE '%'||btrim(p_search)||'%')
   ORDER BY created_at DESC,id
   LIMIT 500
 ) x;
 RETURN jsonb_build_object(
  'questions',v_items,
  'total',(SELECT count(*) FROM public.question_bank)
 );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_bank_create(
 p_subject text,p_topic text,p_stem text,p_options jsonb,
 p_correct_answer text,p_explanation text,p_points numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_id uuid;v_hash text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 IF p_subject NOT IN ('Lógica de Programação','HTML/CSS','Arquitetura e Manutenção',
                     'Planejamento de Carreira e IA','Geral') OR p_subject IS NULL THEN
   RAISE EXCEPTION 'Disciplina inválida';
 END IF;
 IF char_length(btrim(coalesce(p_stem,'')))<10 OR char_length(p_stem)>4000 THEN
   RAISE EXCEPTION 'Enunciado inválido';
 END IF;
 IF jsonb_typeof(p_options) IS DISTINCT FROM 'array' THEN
   RAISE EXCEPTION 'Alternativas inválidas';
 END IF;
 IF jsonb_array_length(p_options)<>5
    OR (SELECT count(DISTINCT o->>'key') FROM jsonb_array_elements(p_options) o)<>5
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_options) o
               WHERE o->>'key' NOT IN ('A','B','C','D','E')
                  OR btrim(coalesce(o->>'text',''))='') THEN
   RAISE EXCEPTION 'São necessárias cinco alternativas A–E, todas preenchidas';
 END IF;
 IF p_correct_answer NOT IN ('A','B','C','D','E') OR p_correct_answer IS NULL
    OR p_points IS NULL OR p_points<=0 OR p_points>100 THEN
   RAISE EXCEPTION 'Gabarito ou pontuação inválida';
 END IF;
 v_hash:=public._question_bank_hash(
   btrim(p_stem),p_options,p_correct_answer,nullif(btrim(coalesce(p_explanation,'')),''),
   p_points
 );
 INSERT INTO public.question_bank(
   subject,topic,stem,options,correct_answer,explanation,points,
   source_label,fingerprint
 ) VALUES(
   p_subject,nullif(btrim(coalesce(p_topic,'')),''),
   btrim(p_stem),p_options,p_correct_answer,
   nullif(btrim(coalesce(p_explanation,'')),''),p_points,
   'Criada no banco',v_hash
 ) ON CONFLICT(fingerprint) DO NOTHING RETURNING id INTO v_id;
 IF v_id IS NULL THEN
   SELECT id INTO v_id FROM public.question_bank WHERE fingerprint=v_hash;
   RETURN jsonb_build_object('ok',true,'id',v_id,'existing',true);
 END IF;
 RETURN jsonb_build_object('ok',true,'id',v_id,'existing',false);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_bank_add_to_exam(
 p_exam_slug text,p_bank_question_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams; b public.question_bank;v_position integer;v_new_id uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
 IF EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=e.id) THEN
   RAISE EXCEPTION 'Questões bloqueadas: a avaliação já possui tentativas';
 END IF;
 SELECT * INTO b FROM public.question_bank WHERE id=p_bank_question_id;
 IF b.id IS NULL THEN RAISE EXCEPTION 'Questão não encontrada no banco'; END IF;
 IF jsonb_array_length(b.options)<>5 THEN
   RAISE EXCEPTION 'Questão antiga com menos de cinco alternativas: crie uma nova versão no banco antes de importar';
 END IF;
 IF EXISTS(SELECT 1 FROM public.questions
           WHERE exam_id=e.id AND type='objective' AND stem=b.stem
             AND options=b.options AND correct_answer=b.correct_answer) THEN
   RAISE EXCEPTION 'Esta questão já consta na avaliação';
 END IF;
 SELECT coalesce(max(position),0)+1 INTO v_position
 FROM public.questions WHERE exam_id=e.id;
 INSERT INTO public.questions(
   exam_id,position,type,stem,options,correct_answer,points,active,explanation
 ) VALUES(
   e.id,v_position,'objective',b.stem,b.options,b.correct_answer,
   b.points,true,b.explanation
 ) RETURNING id INTO v_new_id;
 RETURN jsonb_build_object('ok',true,'question_id',v_new_id,'position',v_position);
END;
$fn$;

-- Existing RPC accepts NULL as "no time limit". Recorded attempts lock this setting.
CREATE OR REPLACE FUNCTION public.teacher_update_exam_settings(
 p_exam_slug text,p_title text,p_duration_minutes integer,p_max_occurrences integer,
 p_is_active boolean,p_assessment_mode text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;v_has_attempts boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 IF btrim(coalesce(p_title,''))='' THEN RAISE EXCEPTION 'Título obrigatório'; END IF;
 IF p_duration_minutes IS NOT NULL AND
    (p_duration_minutes<5 OR p_duration_minutes>300) THEN
   RAISE EXCEPTION 'Duração inválida';
 END IF;
 IF p_max_occurrences IS NULL OR p_max_occurrences<1 OR p_max_occurrences>20 THEN
   RAISE EXCEPTION 'Limite de ocorrências inválido';
 END IF;
 IF p_assessment_mode IS NULL OR p_assessment_mode NOT IN ('exam','simulation') THEN
   RAISE EXCEPTION 'Modo inválido';
 END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
 SELECT EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=e.id)
 INTO v_has_attempts;
 IF v_has_attempts AND (
      e.duration_minutes IS DISTINCT FROM p_duration_minutes
      OR e.max_occurrences IS DISTINCT FROM p_max_occurrences
      OR e.assessment_mode IS DISTINCT FROM p_assessment_mode
    ) THEN
   RAISE EXCEPTION 'Há tentativas registradas; duração, limite de ocorrências e modo de aplicação não podem ser alterados';
 END IF;
 UPDATE public.exams SET
   title=btrim(p_title),
   duration_minutes=p_duration_minutes,
   max_occurrences=p_max_occurrences,
   is_active=p_is_active,
   assessment_mode=p_assessment_mode
 WHERE id=e.id RETURNING * INTO e;
 RETURN jsonb_build_object(
   'ok',true,'title',e.title,'duration_minutes',e.duration_minutes,
   'max_occurrences',e.max_occurrences,
   'is_active',e.is_active,'assessment_mode',e.assessment_mode
 );
END;
$fn$;

-- Only authenticated professor sessions can use bank RPCs.
REVOKE ALL ON FUNCTION public._question_bank_hash(text,jsonb,text,text,numeric) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._question_bank_capture(public.questions) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._question_bank_capture_trigger() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.teacher_bank_questions(text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_bank_create(text,text,text,jsonb,text,text,numeric) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_bank_add_to_exam(text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_bank_questions(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_bank_create(text,text,text,jsonb,text,text,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_bank_add_to_exam(text,uuid) TO authenticated;
