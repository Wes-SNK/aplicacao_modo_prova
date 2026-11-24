
-- Migration 008: questões contextualizadas com quatro ou cinco alternativas;
-- classificação de dificuldade, sem modificar questões já aplicadas.
ALTER TABLE public.question_bank ADD COLUMN IF NOT EXISTS difficulty text
  CHECK (difficulty IS NULL OR difficulty IN ('facil','media','dificil'));
ALTER TABLE public.questions ADD COLUMN IF NOT EXISTS difficulty text
  CHECK (difficulty IS NULL OR difficulty IN ('facil','media','dificil'));

CREATE OR REPLACE FUNCTION public._valid_objective_options(p_options jsonb,p_correct_answer text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='public'
AS $fn$
 SELECT CASE WHEN jsonb_typeof(p_options)<>'array' THEN false
 ELSE
  jsonb_array_length(p_options) BETWEEN 4 AND 5
  AND (SELECT count(*) FROM jsonb_array_elements(p_options) AS x(opt)
        WHERE btrim(coalesce(x.opt->>'text',''))='' OR x.opt->>'key' NOT IN ('A','B','C','D','E'))=0
  AND (SELECT count(distinct x.opt->>'key')
       FROM jsonb_array_elements(p_options) AS x(opt))=jsonb_array_length(p_options)
  AND (SELECT string_agg(x.opt->>'key',',' ORDER BY x.i)
       FROM jsonb_array_elements(p_options) WITH ORDINALITY AS x(opt,i))
     =CASE WHEN jsonb_array_length(p_options)=4 THEN 'A,B,C,D' ELSE 'A,B,C,D,E' END
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_options) AS x(opt)
              WHERE x.opt->>'key'=p_correct_answer)
 END;
$fn$;

CREATE OR REPLACE FUNCTION public._question_bank_capture(p_question public.questions)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_slug text;v_title text;v_subject text;v_hash text;v_id uuid;
BEGIN
 IF p_question.type <> 'objective' OR p_question.correct_answer IS NULL THEN RETURN NULL; END IF;
 SELECT slug,title INTO v_slug,v_title FROM public.exams WHERE id=p_question.exam_id;
 v_subject:=CASE
   WHEN (v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 1 AND 5)
     OR (v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 1 AND 10)
    THEN 'Lógica de Programação'
   WHEN (v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 6 AND 10)
     OR (v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 11 AND 20)
    THEN 'HTML/CSS'
   WHEN (v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 11 AND 15)
     OR (v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 21 AND 30)
    THEN 'Arquitetura e Manutenção'
   WHEN (v_slug='simulado-4bim-1b-2026' AND p_question.position BETWEEN 16 AND 20)
     OR (v_slug='prova-4bim-1b-2026' AND p_question.position BETWEEN 31 AND 40)
    THEN 'Planejamento de Carreira e IA'
   ELSE 'Geral'
 END;
 v_hash:=public._question_bank_hash(p_question.stem,p_question.options,
                p_question.correct_answer,p_question.explanation,p_question.points);
 INSERT INTO public.question_bank(subject,topic,stem,options,correct_answer,
      explanation,points,source_label,source_question_id,fingerprint,difficulty)
 VALUES(v_subject,NULL,p_question.stem,p_question.options,p_question.correct_answer,
     p_question.explanation,p_question.points,coalesce(v_title,v_slug,'Avaliação anterior'),
     p_question.id,v_hash,p_question.difficulty)
 ON CONFLICT(fingerprint) DO UPDATE
   SET difficulty=coalesce(public.question_bank.difficulty,EXCLUDED.difficulty)
 RETURNING id INTO v_id;
 RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public._question_bank_capture_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
BEGIN
 IF TG_OP='DELETE' THEN
   PERFORM public._question_bank_capture(OLD);
   RETURN OLD;
 END IF;
 IF TG_OP='UPDATE' THEN
   IF (OLD.stem,OLD.options,OLD.correct_answer,OLD.explanation,OLD.points,OLD.type,OLD.difficulty)
      IS DISTINCT FROM
      (NEW.stem,NEW.options,NEW.correct_answer,NEW.explanation,NEW.points,NEW.type,NEW.difficulty)
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

CREATE OR REPLACE FUNCTION public.teacher_bank_questions_v2(
  p_subject text DEFAULT NULL,p_search text DEFAULT NULL,p_difficulty text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_items jsonb;v_total int;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 IF p_difficulty IS NOT NULL AND p_difficulty NOT IN ('facil','media','dificil','sem_classificacao') THEN
   RAISE EXCEPTION 'Filtro de dificuldade inválido';
 END IF;
 SELECT count(*) INTO v_total FROM public.question_bank;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',x.id,'subject',x.subject,'topic',x.topic,'stem',x.stem,
   'options',x.options,'correct_answer',x.correct_answer,
   'explanation',x.explanation,'points',x.points,'difficulty',x.difficulty,
   'option_count',jsonb_array_length(x.options),'source_label',x.source_label,
   'created_at',x.created_at
 ) ORDER BY x.created_at DESC,x.id),'[]'::jsonb)
 INTO v_items
 FROM (
   SELECT * FROM public.question_bank
   WHERE (coalesce(p_subject,'')='' OR subject=p_subject)
   AND (coalesce(btrim(p_search),'')='' OR
        stem ILIKE '%'||btrim(p_search)||'%' OR
        coalesce(topic,'') ILIKE '%'||btrim(p_search)||'%' OR
        source_label ILIKE '%'||btrim(p_search)||'%')
   AND (p_difficulty IS NULL OR
       (p_difficulty='sem_classificacao' AND difficulty IS NULL) OR
       difficulty=p_difficulty)
   ORDER BY created_at DESC,id LIMIT 500
 ) x;
 RETURN jsonb_build_object('questions',v_items,'total',v_total);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_bank_create_v2(
 p_subject text,p_topic text,p_stem text,p_options jsonb,p_correct_answer text,
 p_explanation text,p_points numeric,p_difficulty text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_id uuid;v_hash text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 IF p_subject IS NULL OR p_subject NOT IN
   ('Lógica de Programação','HTML/CSS','Arquitetura e Manutenção','Planejamento de Carreira e IA','Geral')
 THEN RAISE EXCEPTION 'Disciplina inválida'; END IF;
 IF char_length(btrim(coalesce(p_stem,'')))<10 OR char_length(p_stem)>4000
 THEN RAISE EXCEPTION 'Enunciado inválido'; END IF;
 IF NOT public._valid_objective_options(p_options,p_correct_answer)
 THEN RAISE EXCEPTION 'A questão exige quatro alternativas A–D ou cinco A–E e gabarito correspondente'; END IF;
 IF p_points IS NULL OR p_points<=0 OR p_points>100
 THEN RAISE EXCEPTION 'Pontuação inválida'; END IF;
 IF p_difficulty IS NOT NULL AND p_difficulty NOT IN ('facil','media','dificil')
 THEN RAISE EXCEPTION 'Dificuldade inválida'; END IF;
 v_hash:=public._question_bank_hash(btrim(p_stem),p_options,p_correct_answer,
          nullif(btrim(coalesce(p_explanation,'')),''),p_points);
 INSERT INTO public.question_bank(subject,topic,stem,options,correct_answer,
     explanation,points,source_label,fingerprint,difficulty)
 VALUES(p_subject,nullif(btrim(coalesce(p_topic,'')),''),
     btrim(p_stem),p_options,p_correct_answer,
     nullif(btrim(coalesce(p_explanation,'')),''),p_points,
     'Criada no banco',v_hash,p_difficulty)
 ON CONFLICT(fingerprint) DO UPDATE SET
     difficulty=coalesce(public.question_bank.difficulty,EXCLUDED.difficulty)
 RETURNING id INTO v_id;
 RETURN jsonb_build_object('ok',true,'id',v_id);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_save_question_v3(
 p_exam_slug text,p_question_id uuid,p_type text,p_stem text,p_options jsonb,
 p_correct_answer text,p_points numeric,p_active boolean,p_explanation text,p_difficulty text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;q public.questions;v_position integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
 IF EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=e.id) THEN
   RAISE EXCEPTION 'Estrutura bloqueada: já existem tentativas registradas';
 END IF;
 IF p_type IS DISTINCT FROM 'objective' THEN RAISE EXCEPTION 'Apenas questões objetivas'; END IF;
 IF char_length(btrim(coalesce(p_stem,'')))<10 THEN RAISE EXCEPTION 'Enunciado obrigatório'; END IF;
 IF NOT public._valid_objective_options(p_options,p_correct_answer) THEN
   RAISE EXCEPTION 'Alternativas inválidas: use A–D ou A–E com gabarito correspondente'; END IF;
 IF p_points IS NULL OR p_points<=0 OR p_points>100 THEN RAISE EXCEPTION 'Pontuação inválida'; END IF;
 IF p_difficulty IS NOT NULL AND p_difficulty NOT IN ('facil','media','dificil')
 THEN RAISE EXCEPTION 'Dificuldade inválida'; END IF;
 IF p_question_id IS NULL THEN
   SELECT coalesce(max(position),0)+1 INTO v_position FROM public.questions WHERE exam_id=e.id;
   INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,
                                points,active,explanation,difficulty)
   VALUES(e.id,v_position,'objective',btrim(p_stem),p_options,p_correct_answer,
           p_points,coalesce(p_active,true),
           nullif(btrim(coalesce(p_explanation,'')),''),p_difficulty)
   RETURNING * INTO q;
 ELSE
   UPDATE public.questions SET stem=btrim(p_stem),options=p_options,
      correct_answer=p_correct_answer,points=p_points,active=coalesce(p_active,true),
      explanation=nullif(btrim(coalesce(p_explanation,'')),''),difficulty=p_difficulty
   WHERE id=p_question_id AND exam_id=e.id AND type='objective'
   RETURNING * INTO q;
   IF q.id IS NULL THEN RAISE EXCEPTION 'Questão não encontrada'; END IF;
 END IF;
 RETURN jsonb_build_object('ok',true,'question_id',q.id);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_bank_add_to_exam(
 p_exam_slug text,p_bank_question_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;b public.question_bank;v_position integer;v_id uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug FOR UPDATE;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
 IF EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=e.id) THEN
   RAISE EXCEPTION 'Avaliação bloqueada por tentativas já registradas';
 END IF;
 SELECT * INTO b FROM public.question_bank WHERE id=p_bank_question_id;
 IF b.id IS NULL THEN RAISE EXCEPTION 'Questão não encontrada no banco'; END IF;
 IF NOT public._valid_objective_options(b.options,b.correct_answer)
 THEN RAISE EXCEPTION 'Formato de alternativas inválido'; END IF;
 IF EXISTS(SELECT 1 FROM public.questions WHERE exam_id=e.id AND type='objective'
   AND stem=b.stem AND options=b.options AND correct_answer=b.correct_answer)
 THEN RAISE EXCEPTION 'Esta questão já consta na avaliação'; END IF;
 SELECT coalesce(max(position),0)+1 INTO v_position FROM public.questions WHERE exam_id=e.id;
 INSERT INTO public.questions(exam_id,position,type,stem,options,correct_answer,
                              points,active,explanation,difficulty)
 VALUES(e.id,v_position,'objective',b.stem,b.options,b.correct_answer,b.points,true,
        b.explanation,b.difficulty) RETURNING id INTO v_id;
 RETURN jsonb_build_object('ok',true,'question_id',v_id,'position',v_position);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.teacher_questions(p_exam_slug text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;v_locked boolean;v_questions jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug;
 IF e.id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada'; END IF;
 SELECT EXISTS(SELECT 1 FROM public.attempts WHERE exam_id=e.id) INTO v_locked;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
 'id',q.id,'position',q.position,'type',q.type,'stem',q.stem,'explanation',q.explanation,
 'options',q.options,'correct_answer',q.correct_answer,'points',q.points,
 'active',q.active,'difficulty',q.difficulty
 ) ORDER BY q.position),'[]'::jsonb) INTO v_questions
 FROM public.questions q WHERE q.exam_id=e.id AND q.type='objective';
 RETURN jsonb_build_object('locked',v_locked,'questions',v_questions);
END;
$fn$;

REVOKE ALL ON FUNCTION public._valid_objective_options(jsonb,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.teacher_bank_questions_v2(text,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_bank_create_v2(text,text,text,jsonb,text,text,numeric,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.teacher_save_question_v3(text,uuid,text,text,jsonb,text,numeric,boolean,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_bank_questions_v2(text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_bank_create_v2(text,text,text,jsonb,text,text,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_save_question_v3(text,uuid,text,text,jsonb,text,numeric,boolean,text,text) TO authenticated;
