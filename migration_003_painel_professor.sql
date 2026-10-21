-- MIGRAÇÃO 003 — CONFIGURAÇÕES DO PROFESSOR E NOVA TENTATIVA
-- Execute uma única vez no SQL Editor do Supabase.

create or replace function public.teacher_update_exam_settings(
  p_exam_slug text,
  p_title text,
  p_duration_minutes integer,
  p_max_occurrences integer,
  p_is_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.exams;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;
  if btrim(coalesce(p_title,'')) = '' then raise exception 'Título obrigatório'; end if;
  if p_duration_minutes < 5 or p_duration_minutes > 300 then
    raise exception 'Duração inválida';
  end if;
  if p_max_occurrences < 1 or p_max_occurrences > 20 then
    raise exception 'Limite de ocorrências inválido';
  end if;

  update public.exams
     set title = btrim(p_title),
         duration_minutes = p_duration_minutes,
         max_occurrences = p_max_occurrences,
         is_active = p_is_active
   where slug = p_exam_slug
   returning * into e;

  if e.id is null then raise exception 'Avaliação não encontrada'; end if;

  return jsonb_build_object(
    'ok', true,
    'title', e.title,
    'duration_minutes', e.duration_minutes,
    'max_occurrences', e.max_occurrences,
    'is_active', e.is_active
  );
end;
$$;

create or replace function public.teacher_reset_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  s public.students;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into a from public.attempts where id = p_attempt_id;
  if a.id is null then raise exception 'Tentativa não encontrada'; end if;

  select * into s from public.students where id = a.student_id;

  delete from public.attempts where id = p_attempt_id;

  return jsonb_build_object(
    'ok', true,
    'student_name', s.name
  );
end;
$$;

create or replace function public.teacher_dashboard(p_exam_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.exams;
  arr jsonb;
  qcount integer;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into e from public.exams where slug=p_exam_slug;
  if e.id is null then raise exception 'Avaliação não encontrada'; end if;

  select count(*) into qcount
  from public.questions
  where exam_id=e.id and active=true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'attempt_id',a.id,
      'student_name',s.name,
      'class_group',s.class_group,
      'status',a.status,
      'created_at',a.created_at,
      'started_at',a.started_at,
      'submitted_at',a.submitted_at,
      'occurrences',a.occurrences,
      'score',a.score,
      'max_score',a.max_score,
      'submission_reason',a.submission_reason
    ) order by s.name
  ),'[]'::jsonb)
  into arr
  from public.attempts a
  join public.students s on s.id=a.student_id
  where a.exam_id=e.id;

  return jsonb_build_object(
    'exam_title',e.title,
    'duration_minutes',e.duration_minutes,
    'max_occurrences',e.max_occurrences,
    'is_active',e.is_active,
    'question_count',qcount,
    'attempts',arr
  );
end;
$$;

grant execute on function public.teacher_update_exam_settings(text,text,integer,integer,boolean) to authenticated;
grant execute on function public.teacher_reset_attempt(uuid) to authenticated;
grant execute on function public.teacher_dashboard(text) to authenticated;
