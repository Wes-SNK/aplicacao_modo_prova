-- MIGRAÇÃO 001 — ENTRADA DO ALUNO POR NOME
-- Execute uma única vez no SQL Editor do Supabase já configurado.

alter table public.students
  alter column access_code drop not null;

create or replace function public.start_attempt_by_name(
  p_exam_slug text,
  p_student_name text,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.exams;
  s public.students;
  a public.attempts;
  q jsonb;
  v_matches integer;
begin
  select * into e from public.exams where slug = p_exam_slug;
  if e.id is null or not public._exam_available(e) then
    raise exception 'Avaliação indisponível';
  end if;

  select count(*)
    into v_matches
    from public.students
   where lower(btrim(name)) = lower(btrim(p_student_name))
     and active = true;

  if v_matches = 0 then
    raise exception 'Estudante não encontrado';
  elsif v_matches > 1 then
    raise exception 'Nome ambíguo';
  end if;

  select * into s
    from public.students
   where lower(btrim(name)) = lower(btrim(p_student_name))
     and active = true
   limit 1;

  select * into a from public.attempts
   where exam_id = e.id and student_id = s.id;

  if a.id is not null and a.status = 'in_progress' then
    raise exception 'Avaliação já iniciada';
  elsif a.id is not null and a.status in ('submitted','auto_submitted') then
    raise exception 'Avaliação já finalizada';
  end if;

  if a.id is null then
    insert into public.attempts(exam_id, student_id, user_agent)
    values(e.id, s.id, p_user_agent)
    returning * into a;
  else
    update public.attempts
       set last_seen_at = now(),
           user_agent = coalesce(p_user_agent,user_agent)
     where id = a.id
     returning * into a;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', x.id,
      'type', x.type,
      'stem', x.stem,
      'options', x.options
    ) order by x.sort_key
  ), '[]'::jsonb)
  into q
  from (
    select q.*, md5(a.session_token::text || q.id::text) as sort_key
      from public.questions q
     where q.exam_id = e.id and q.active = true
  ) x;

  return jsonb_build_object(
    'attempt_id', a.id,
    'session_token', a.session_token,
    'status', a.status,
    'student_name', s.name,
    'exam_title', e.title,
    'duration_minutes', e.duration_minutes,
    'max_occurrences', e.max_occurrences,
    'occurrences', a.occurrences,
    'started_at', a.started_at,
    'ends_at', case when a.started_at is null then null
                    else a.started_at + make_interval(mins => e.duration_minutes) end,
    'questions', q,
    'answers', '{}'::jsonb
  );
end;
$$;

grant execute on function public.start_attempt_by_name(text,text,text)
to anon, authenticated;

-- A função antiga por código deixa de estar disponível para o navegador.
revoke execute on function public.start_attempt(text,text,text)
from anon, authenticated;
