-- MIGRAÇÃO PROPOSTA 015 — AJUDA DURANTE A PROVA + AUDITORIA
-- A aplicar somente em homologação, após 013 e 014.
CREATE TABLE public.exam_supervision_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 exam_id uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
 student_id uuid REFERENCES public.students(id) ON DELETE SET NULL,
 actor_id uuid,
 event text NOT NULL CHECK(event IN (
  'configure','authorize','revoke','authorize_all','help_requested',
  'help_cancelled','help_resolved')),
 created_at timestamptz NOT NULL DEFAULT now(),
 details jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX exam_supervision_audit_recent_idx
 ON public.exam_supervision_audit(exam_id,created_at DESC);
ALTER TABLE public.exam_supervision_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exam_supervision_audit FROM PUBLIC,anon,authenticated;

-- A auditoria de autorizações registra quem realizou a ação, sem senhas ou respostas.
CREATE FUNCTION public._supervision_lobby_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
BEGIN
 IF TG_OP='UPDATE' THEN
  IF OLD.authorized IS DISTINCT FROM NEW.authorized THEN
   INSERT INTO public.exam_supervision_audit(exam_id,student_id,actor_id,event)
   VALUES(NEW.exam_id,NEW.student_id,auth.uid(),
    CASE WHEN NEW.authorized THEN 'authorize' ELSE 'revoke' END);
  END IF;
  IF OLD.help_requested_at IS DISTINCT FROM NEW.help_requested_at
   AND NEW.help_requested_at IS NOT NULL THEN
   INSERT INTO public.exam_supervision_audit(exam_id,student_id,actor_id,event)
   VALUES(NEW.exam_id,NEW.student_id,auth.uid(),'help_requested');
  ELSIF OLD.help_requested_at IS DISTINCT FROM NEW.help_requested_at
   AND NEW.help_requested_at IS NULL THEN
   INSERT INTO public.exam_supervision_audit(exam_id,student_id,actor_id,event)
   VALUES(NEW.exam_id,NEW.student_id,auth.uid(),'help_cancelled');
  END IF;
  IF OLD.help_resolved_at IS DISTINCT FROM NEW.help_resolved_at
   AND NEW.help_resolved_at IS NOT NULL
   AND NEW.help_requested_at IS NOT NULL THEN
   INSERT INTO public.exam_supervision_audit(exam_id,student_id,actor_id,event)
   VALUES(NEW.exam_id,NEW.student_id,auth.uid(),'help_resolved');
  END IF;
 END IF;
 RETURN NEW;
END;$fn$;
REVOKE ALL ON FUNCTION public._supervision_lobby_audit() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_supervision_lobby_audit
AFTER UPDATE ON public.exam_lobby
FOR EACH ROW EXECUTE FUNCTION public._supervision_lobby_audit();

CREATE FUNCTION public.student_exam_help(p_session_token uuid,p_request boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE a public.attempts;v_row public.exam_lobby;
BEGIN
 SELECT * INTO a FROM public.attempts WHERE session_token=p_session_token;
 IF a.id IS NULL OR a.status<>'in_progress' THEN
  RAISE EXCEPTION 'Prova não está em andamento';END IF;
 IF p_request IS NULL THEN RAISE EXCEPTION 'Informe a ação';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.exam_supervision g
 WHERE g.exam_id=a.exam_id AND g.enabled) THEN
  RAISE EXCEPTION 'Solicitação de ajuda disponível apenas em avaliações supervisionadas';
 END IF;
 UPDATE public.exam_lobby SET
  help_requested_at=CASE WHEN p_request THEN now() ELSE NULL END,
  help_resolved_at=CASE WHEN p_request THEN NULL ELSE now() END,
  last_seen_at=now()
 WHERE exam_id=a.exam_id AND student_id=a.student_id RETURNING * INTO v_row;
 IF v_row.exam_id IS NULL THEN RAISE EXCEPTION 'Aluno não identificado na sala de espera';END IF;
 RETURN jsonb_build_object('ok',true,'help_pending',p_request);
END;$fn$;

CREATE FUNCTION public.teacher_supervision_audit(p_exam_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE v_exam_id uuid;v_events jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso negado';END IF;
 SELECT id INTO v_exam_id FROM public.exams WHERE slug=p_exam_slug;
 IF v_exam_id IS NULL THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'event',x.event,'student_name',x.student_name,
  'created_at',x.created_at,'actor_id',x.actor_id
 ) ORDER BY x.created_at DESC),'[]'::jsonb) INTO v_events
 FROM (
  SELECT a.event,s.name student_name,a.created_at,a.actor_id
  FROM public.exam_supervision_audit a
  LEFT JOIN public.students s ON s.id=a.student_id
  WHERE a.exam_id=v_exam_id ORDER BY a.created_at DESC LIMIT 200
 ) x;
 RETURN v_events;
END;$fn$;

REVOKE ALL ON FUNCTION public.teacher_supervision_audit(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.teacher_supervision_audit(text) TO authenticated;
-- Token de tentativa é necessário; não há login de estudante.
GRANT EXECUTE ON FUNCTION public.student_exam_help(uuid,boolean) TO anon,authenticated;
