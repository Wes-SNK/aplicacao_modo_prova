-- 022: histórico imutável de notas, proteção de finalizações e novas tentativas.
-- O histórico não possui FK ON DELETE CASCADE: deve sobreviver a reset de tentativa.
CREATE TABLE public.grade_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  attempt_id uuid NOT NULL UNIQUE,
  exam_id uuid NOT NULL,
  student_id uuid NOT NULL,
  exam_slug text NOT NULL,
  exam_title text NOT NULL,
  student_name text NOT NULL,
  class_group text,
  status text NOT NULL CHECK (status IN ('submitted','auto_submitted')),
  score numeric NOT NULL,
  max_score numeric NOT NULL,
  started_at timestamptz,
  submitted_at timestamptz NOT NULL,
  submission_reason text,
  responses jsonb NOT NULL DEFAULT '[]'::jsonb,
  archived_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX grade_history_exam_idx ON public.grade_history(exam_id,submitted_at DESC);
CREATE INDEX grade_history_student_idx ON public.grade_history(exam_id,student_id,submitted_at DESC);
ALTER TABLE public.grade_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.grade_history FROM PUBLIC,anon,authenticated;

-- Uma única rotina registra a primeira finalização de cada attempt_id.
-- A operação é idempotente para reenvios de finalização.
CREATE FUNCTION public._archive_final_grade(p_attempt_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
BEGIN
 INSERT INTO public.grade_history (
   attempt_id,exam_id,student_id,exam_slug,exam_title,student_name,class_group,
   status,score,max_score,started_at,submitted_at,submission_reason,responses
 )
 SELECT a.id,a.exam_id,a.student_id,e.slug,e.title,s.name,s.class_group,
   a.status,a.score,a.max_score,a.started_at,a.submitted_at,a.submission_reason,
   coalesce((SELECT jsonb_agg(jsonb_build_object(
     'question_id',q.id,'position',q.position,'correct_answer',q.correct_answer,
     'points',q.points,'active',q.active,'answer',an.answer,'saved_at',an.saved_at
   ) ORDER BY q.position) FROM public.questions q
   LEFT JOIN public.answers an ON an.question_id=q.id AND an.attempt_id=a.id
   WHERE q.exam_id=a.exam_id),'[]'::jsonb)
 FROM public.attempts a
 JOIN public.exams e ON e.id=a.exam_id
 JOIN public.students s ON s.id=a.student_id
 WHERE a.id=p_attempt_id AND a.status IN ('submitted','auto_submitted')
 AND a.score IS NOT NULL AND a.max_score IS NOT NULL AND a.submitted_at IS NOT NULL
 ON CONFLICT (attempt_id) DO NOTHING;
END;$fn$;

CREATE FUNCTION public._grade_history_attempt_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
BEGIN
 IF TG_OP='UPDATE' THEN
   IF OLD.status IN ('submitted','auto_submitted') AND
     (NEW.status IS DISTINCT FROM OLD.status OR NEW.score IS DISTINCT FROM OLD.score
      OR NEW.max_score IS DISTINCT FROM OLD.max_score
      OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
      OR NEW.student_id IS DISTINCT FROM OLD.student_id
      OR NEW.exam_id IS DISTINCT FROM OLD.exam_id) THEN
     RAISE EXCEPTION 'Nota finalizada é imutável; utilize o histórico para nova tentativa';
   END IF;
   RETURN NEW;
 ELSIF TG_OP='DELETE' THEN
   IF OLD.status IN ('submitted','auto_submitted') THEN
     PERFORM public._archive_final_grade(OLD.id);
     IF NOT EXISTS(SELECT 1 FROM public.grade_history WHERE attempt_id=OLD.id)
     THEN RAISE EXCEPTION 'Não é possível excluir resultado sem preservar histórico';END IF;
   END IF;
   RETURN OLD;
 END IF;
 RETURN NULL;
END;$fn$;

CREATE TRIGGER grade_history_protect_attempt
BEFORE UPDATE OR DELETE ON public.attempts
FOR EACH ROW EXECUTE FUNCTION public._grade_history_attempt_trigger();

CREATE FUNCTION public._grade_history_on_finalize()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
BEGIN
 IF NEW.status IN ('submitted','auto_submitted') AND
    OLD.status NOT IN ('submitted','auto_submitted') THEN
   PERFORM public._archive_final_grade(NEW.id);
   IF NOT EXISTS(SELECT 1 FROM public.grade_history WHERE attempt_id=NEW.id)
   THEN RAISE EXCEPTION 'Finalização não persistiu no histórico de notas';END IF;
 END IF;
 RETURN NEW;
END;$fn$;
CREATE TRIGGER grade_history_after_finalize
AFTER UPDATE OF status ON public.attempts
FOR EACH ROW EXECUTE FUNCTION public._grade_history_on_finalize();

CREATE FUNCTION public._grade_history_immutable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
BEGIN
 RAISE EXCEPTION 'Histórico de notas é imutável';
END;$fn$;
CREATE TRIGGER grade_history_immutable
BEFORE UPDATE OR DELETE ON public.grade_history
FOR EACH ROW EXECUTE FUNCTION public._grade_history_immutable();

-- Restaurar o passado ANTES de expor novas funcionalidades.
SELECT public._archive_final_grade(id) FROM public.attempts
WHERE status IN ('submitted','auto_submitted');

-- Não permitir recalcular uma nota encerrada, inclusive via RPC direta.
CREATE OR REPLACE FUNCTION public._grade_attempt(p_attempt_id uuid)
RETURNS TABLE(score numeric,max_score numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
DECLARE a public.attempts; v_score numeric; v_max numeric;
BEGIN
 SELECT * INTO a FROM public.attempts WHERE id=p_attempt_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tentativa não encontrada';END IF;
 IF a.status IN ('submitted','auto_submitted') THEN
   RAISE EXCEPTION 'Nota finalizada não pode ser recalculada';
 END IF;
 SELECT coalesce(sum(CASE WHEN q.type='objective' AND ans.answer->>'value'=q.correct_answer
    THEN q.points ELSE 0 END),0),
   coalesce(sum(CASE WHEN q.type='objective' THEN q.points ELSE 0 END),0)
 INTO v_score,v_max FROM public.questions q
 LEFT JOIN public.answers ans ON ans.question_id=q.id AND ans.attempt_id=a.id
 WHERE q.exam_id=a.exam_id AND q.active;
 UPDATE public.attempts SET score=v_score,max_score=v_max WHERE id=a.id;
 RETURN QUERY SELECT v_score,v_max;
END;$fn$;
REVOKE ALL ON FUNCTION public._grade_attempt(uuid) FROM PUBLIC,anon,authenticated;

-- Finalização serializada por tentativa; reenvio retorna exatamente a mesma nota.
CREATE OR REPLACE FUNCTION public.submit_attempt(
 p_session_token uuid,p_reason text DEFAULT 'submitted')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
DECLARE a public.attempts;e public.exams;
BEGIN
 SELECT * INTO a FROM public.attempts WHERE session_token=p_session_token FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sessão inválida';END IF;
 SELECT * INTO e FROM public.exams WHERE id=a.exam_id;
 IF a.status IN ('submitted','auto_submitted') THEN
   RETURN jsonb_build_object('status',a.status,'submitted_at',a.submitted_at,
     'score',a.score,'max_score',a.max_score,'assessment_mode',e.assessment_mode);
 END IF;
 IF a.status<>'in_progress' THEN RAISE EXCEPTION 'Tentativa ainda não iniciada';END IF;
 PERFORM public._grade_attempt(a.id);
 UPDATE public.attempts SET
   status=CASE WHEN p_reason IN ('occurrence_limit','time_expired')
      THEN 'auto_submitted' ELSE 'submitted' END,
   submitted_at=now(),submission_reason=p_reason,last_seen_at=now()
 WHERE id=a.id RETURNING * INTO a;
 RETURN jsonb_build_object('status',a.status,'submitted_at',a.submitted_at,
   'score',a.score,'max_score',a.max_score,'assessment_mode',e.assessment_mode);
END;$fn$;

-- Manter leitura autenticada no painel, incluindo todas as tentativas históricas.
CREATE OR REPLACE FUNCTION public.teacher_dashboard(p_exam_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public' AS $fn$
DECLARE e public.exams; arr jsonb; hist jsonb; qcount integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug;
 IF NOT FOUND THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 SELECT count(*) INTO qcount FROM public.questions
 WHERE exam_id=e.id AND active=true AND type='objective';
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'attempt_id',a.id,'student_name',s.name,'class_group',s.class_group,
   'status',a.status,'created_at',a.created_at,'started_at',a.started_at,
   'submitted_at',a.submitted_at,'occurrences',a.occurrences,
   'score',a.score,'max_score',a.max_score,
   'submission_reason',a.submission_reason,'resume_allowed',a.resume_allowed
 ) ORDER BY s.name),'[]'::jsonb) INTO arr
 FROM public.attempts a JOIN public.students s ON s.id=a.student_id
 WHERE a.exam_id=e.id;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'attempt_id',h.attempt_id,'student_name',h.student_name,
   'class_group',h.class_group,'status',h.status,'score',h.score,
   'max_score',h.max_score,'submitted_at',h.submitted_at,
   'submission_reason',h.submission_reason,'archived_at',h.archived_at
 ) ORDER BY h.submitted_at DESC,h.id DESC),'[]'::jsonb) INTO hist
 FROM public.grade_history h WHERE h.exam_id=e.id;
 RETURN jsonb_build_object(
   'exam_title',e.title,'duration_minutes',e.duration_minutes,
   'max_occurrences',e.max_occurrences,'is_active',e.is_active,
   'assessment_mode',e.assessment_mode,'question_count',qcount,
   'attempts',arr,'grade_history',hist);
END;$fn$;

REVOKE ALL ON FUNCTION public._archive_final_grade(uuid),
 public._grade_history_attempt_trigger(),public._grade_history_on_finalize(),
 public._grade_history_immutable() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_attempt(uuid,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_dashboard(text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.teacher_dashboard(text) FROM PUBLIC,anon;
