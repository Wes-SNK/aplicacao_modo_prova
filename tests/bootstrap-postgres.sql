-- Schema mínimo para testes transacionais de integração em PostgreSQL isolado.
-- Nunca execute este bootstrap em produção; use apenas no contêiner CI.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $fn$
 SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$fn$;
GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated;

CREATE TABLE public.students(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 access_code text,
 name text NOT NULL,
 class_group text,
 active boolean NOT NULL DEFAULT true,
 created_at timestamptz DEFAULT now()
);
CREATE TABLE public.exams(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 slug text NOT NULL UNIQUE,title text NOT NULL,
 is_active boolean NOT NULL DEFAULT false,
 duration_minutes integer,
 max_occurrences integer NOT NULL DEFAULT 3,
 opens_at timestamptz,closes_at timestamptz,
 created_at timestamptz DEFAULT now(),
 assessment_mode text NOT NULL DEFAULT 'exam'
);
CREATE TABLE public.questions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 exam_id uuid NOT NULL REFERENCES public.exams(id),
 position integer NOT NULL,type text NOT NULL,
 stem text NOT NULL,options jsonb NOT NULL DEFAULT '[]'::jsonb,
 correct_answer text,points numeric NOT NULL DEFAULT 1,
 active boolean NOT NULL DEFAULT true,
 explanation text,difficulty text,
 UNIQUE(exam_id,position)
);
CREATE TABLE public.attempts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 exam_id uuid NOT NULL REFERENCES public.exams(id),
 student_id uuid NOT NULL REFERENCES public.students(id),
 session_token uuid NOT NULL DEFAULT gen_random_uuid(),
 status text NOT NULL DEFAULT 'ready',
 created_at timestamptz DEFAULT now(),
 started_at timestamptz,submitted_at timestamptz,
 last_seen_at timestamptz NOT NULL DEFAULT now(),
 occurrences integer NOT NULL DEFAULT 0,
 score numeric,max_score numeric,
 user_agent text,submission_reason text,
 resume_allowed boolean NOT NULL DEFAULT false,
 review_flags jsonb NOT NULL DEFAULT '{}'::jsonb,
 UNIQUE(exam_id,student_id)
);
CREATE TABLE public.answers(
 attempt_id uuid NOT NULL REFERENCES public.attempts(id),
 question_id uuid NOT NULL REFERENCES public.questions(id),
 answer jsonb NOT NULL,saved_at timestamptz DEFAULT now(),
 PRIMARY KEY(attempt_id,question_id)
);
CREATE TABLE public.exam_events(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 attempt_id uuid NOT NULL REFERENCES public.attempts(id),
 event_type text NOT NULL,
 counted boolean NOT NULL DEFAULT true,
 occurred_at timestamptz DEFAULT now(),
 question_id uuid,details jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE FUNCTION public._exam_available(e public.exams)
RETURNS boolean LANGUAGE sql STABLE
AS $fn$ SELECT e.is_active AND
 (e.opens_at IS NULL OR now()>=e.opens_at)
 AND (e.closes_at IS NULL OR now()<=e.closes_at) $fn$;
CREATE FUNCTION public._valid_objective_options(
 p_options jsonb,p_answer text
) RETURNS boolean LANGUAGE sql IMMUTABLE
AS $fn$ SELECT jsonb_typeof(p_options)='array'
 AND jsonb_array_length(p_options) IN (4,5)
 AND p_answer IN ('A','B','C','D','E') $fn$;
CREATE FUNCTION public._grade_attempt(p_attempt_id uuid)
RETURNS int LANGUAGE sql AS $fn$ SELECT 1 $fn$;
