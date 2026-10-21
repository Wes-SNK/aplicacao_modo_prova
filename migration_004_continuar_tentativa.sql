-- MIGRAÇÃO 004 — CONTINUAR TENTATIVA OU RECOMEÇAR DO ZERO
-- Execute uma única vez no SQL Editor do Supabase.
-- Preserva respostas, marcações de revisão, ocorrências e tempo original ao continuar.

alter table public.attempts
  add column if not exists resume_allowed boolean not null default false;

alter table public.attempts
  add column if not exists review_flags jsonb not null default '{}'::jsonb;

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
  ans jsonb;
  v_matches integer;
begin
  select * into e from public.exams where slug = p_exam_slug;
  if e.id is null or not public._exam_available(e) then
    raise exception 'Avaliação indisponível';
  end if;

  select count(*) into v_matches
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

  select * into a
  from public.attempts
  where exam_id = e.id and student_id = s.id;

  if a.id is null then
    insert into public.attempts(exam_id, student_id, user_agent)
    values(e.id, s.id, p_user_agent)
    returning * into a;

  elsif a.status = 'in_progress' then
    if not a.resume_allowed then
      raise exception 'Avaliação já iniciada';
    end if;

    update public.attempts
       set session_token = gen_random_uuid(),
           resume_allowed = false,
           last_seen_at = now(),
           user_agent = coalesce(p_user_agent,user_agent)
     where id = a.id
     returning * into a;

  elsif a.status in ('submitted','auto_submitted') then
    raise exception 'Avaliação já finalizada';

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

  select coalesce(jsonb_object_agg(question_id::text, answer),'{}'::jsonb)
  into ans
  from public.answers
  where attempt_id = a.id;

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
    'answers', ans,
    'review_flags', coalesce(a.review_flags,'{}'::jsonb)
  );
end;
$$;

create or replace function public.resume_attempt(p_session_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
  s public.students;
  q jsonb;
  ans jsonb;
begin
  select * into a from public.attempts where session_token = p_session_token;
  if a.id is null then raise exception 'Sessão inválida'; end if;

  select * into e from public.exams where id = a.exam_id;
  select * into s from public.students where id = a.student_id;

  if a.status = 'in_progress'
     and a.started_at + make_interval(mins => e.duration_minutes) <= now() then
    perform public._grade_attempt(a.id);
    update public.attempts
       set status='auto_submitted',
           submitted_at=now(),
           submission_reason='time_expired'
     where id=a.id
     returning * into a;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',x.id,
      'type',x.type,
      'stem',x.stem,
      'options',x.options
    ) order by x.sort_key
  ),'[]'::jsonb)
  into q
  from (
    select q.*, md5(a.session_token::text || q.id::text) sort_key
    from public.questions q
    where q.exam_id=e.id and q.active=true
  ) x;

  select coalesce(jsonb_object_agg(question_id::text, answer),'{}'::jsonb)
  into ans
  from public.answers
  where attempt_id=a.id;

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
    'answers', ans,
    'review_flags', coalesce(a.review_flags,'{}'::jsonb)
  );
end;
$$;

create or replace function public.save_review_flag(
  p_session_token uuid,
  p_question_id uuid,
  p_marked boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
begin
  select * into a
  from public.attempts
  where session_token=p_session_token;

  if a.id is null or a.status <> 'in_progress' then
    raise exception 'Tentativa não está em andamento';
  end if;

  if not exists(
    select 1
    from public.questions
    where id=p_question_id
      and exam_id=a.exam_id
      and active=true
  ) then
    raise exception 'Questão inválida';
  end if;

  update public.attempts
     set review_flags = jsonb_set(
           coalesce(review_flags,'{}'::jsonb),
           array[p_question_id::text],
           to_jsonb(p_marked),
           true
         ),
         last_seen_at=now()
   where id=a.id;

  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.teacher_allow_resume_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
  s public.students;
begin
  if auth.uid() is null then
    raise exception 'Acesso negado';
  end if;

  select * into a
  from public.attempts
  where id=p_attempt_id;

  if a.id is null then
    raise exception 'Tentativa não encontrada';
  end if;

  if a.status <> 'in_progress' then
    raise exception 'Somente tentativas em andamento podem ser retomadas';
  end if;

  select * into e from public.exams where id=a.exam_id;

  if a.started_at is not null
     and a.started_at + make_interval(mins => e.duration_minutes) <= now() then
    raise exception 'Tempo encerrado';
  end if;

  select * into s from public.students where id=a.student_id;

  update public.attempts
     set resume_allowed=true,
         session_token=gen_random_uuid(),
         last_seen_at=now()
   where id=a.id
   returning * into a;

  insert into public.exam_events(attempt_id,event_type,counted,details)
  values(
    a.id,
    'teacher_resume_authorized',
    false,
    jsonb_build_object('authorized_at',now())
  );

  return jsonb_build_object(
    'ok',true,
    'student_name',s.name,
    'resume_allowed',true
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
      'submission_reason',a.submission_reason,
      'resume_allowed',a.resume_allowed
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

grant execute on function public.start_attempt_by_name(text,text,text)
to anon, authenticated;

grant execute on function public.resume_attempt(uuid)
to anon, authenticated;

grant execute on function public.save_review_flag(uuid,uuid,boolean)
to anon, authenticated;

grant execute on function public.teacher_allow_resume_attempt(uuid)
to authenticated;

grant execute on function public.teacher_dashboard(text)
to authenticated;
