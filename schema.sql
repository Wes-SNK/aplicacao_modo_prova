-- MODO PROVA — ESQUEMA SUPABASE
-- Execute este arquivo no SQL Editor do seu projeto Supabase.

create extension if not exists pgcrypto;

create table if not exists public.exams (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  duration_minutes integer not null default 50 check (duration_minutes between 5 and 300),
  max_occurrences integer not null default 3 check (max_occurrences between 1 and 20),
  assessment_mode text not null default 'exam' check (assessment_mode in ('exam','simulation')),
  is_active boolean not null default false,
  opens_at timestamptz,
  closes_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  access_code text unique,
  name text not null,
  class_group text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  position integer not null,
  type text not null check (type in ('objective','open')),
  stem text not null,
  options jsonb not null default '[]'::jsonb,
  correct_answer text,
  points numeric(8,2) not null default 1,
  active boolean not null default true,
  unique(exam_id, position)
);

create table if not exists public.attempts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  session_token uuid not null unique default gen_random_uuid(),
  status text not null default 'ready'
    check (status in ('ready','in_progress','submitted','auto_submitted')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  submitted_at timestamptz,
  last_seen_at timestamptz not null default now(),
  occurrences integer not null default 0,
  score numeric(8,2),
  max_score numeric(8,2),
  user_agent text,
  submission_reason text,
  resume_allowed boolean not null default false,
  review_flags jsonb not null default '{}'::jsonb,
  unique(exam_id, student_id)
);

create table if not exists public.answers (
  attempt_id uuid not null references public.attempts(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  answer jsonb not null default '{}'::jsonb,
  saved_at timestamptz not null default now(),
  primary key (attempt_id, question_id)
);

create table if not exists public.exam_events (
  id bigint generated always as identity primary key,
  attempt_id uuid not null references public.attempts(id) on delete cascade,
  event_type text not null,
  counted boolean not null default false,
  question_id uuid references public.questions(id) on delete set null,
  occurred_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb
);

create index if not exists idx_attempts_exam on public.attempts(exam_id);
create index if not exists idx_events_attempt on public.exam_events(attempt_id, occurred_at);
create index if not exists idx_answers_attempt on public.answers(attempt_id);

-- Bloqueia acesso direto às tabelas pelo navegador.
alter table public.exams enable row level security;
alter table public.students enable row level security;
alter table public.questions enable row level security;
alter table public.attempts enable row level security;
alter table public.answers enable row level security;
alter table public.exam_events enable row level security;

revoke all on public.exams, public.students, public.questions, public.attempts, public.answers, public.exam_events
from anon, authenticated;

-- ---------------- HELPERS ----------------

create or replace function public._exam_available(e public.exams)
returns boolean
language sql stable
as $$
  select e.is_active
     and (e.opens_at is null or now() >= e.opens_at)
     and (e.closes_at is null or now() <= e.closes_at);
$$;

create or replace function public._grade_attempt(p_attempt_id uuid)
returns table(score numeric, max_score numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_score numeric := 0;
  v_max numeric := 0;
begin
  select
    coalesce(sum(
      case
        when q.type = 'objective'
         and a.answer->>'value' = q.correct_answer
        then q.points else 0
      end
    ),0),
    coalesce(sum(case when q.type = 'objective' then q.points else 0 end),0)
  into v_score, v_max
  from public.questions q
  join public.attempts atp on atp.exam_id = q.exam_id
  left join public.answers a
    on a.attempt_id = atp.id and a.question_id = q.id
  where atp.id = p_attempt_id
    and q.active = true;

  update public.attempts
     set score = v_score, max_score = v_max
   where id = p_attempt_id;

  return query select v_score, v_max;
end;
$$;

-- ---------------- ALUNO ----------------

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
    'assessment_mode', e.assessment_mode,
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

create or replace function public.begin_attempt(p_session_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
begin
  select * into a from public.attempts where session_token = p_session_token;
  if a.id is null then raise exception 'Sessão inválida'; end if;
  if a.status in ('submitted','auto_submitted') then raise exception 'Avaliação já finalizada'; end if;

  select * into e from public.exams where id = a.exam_id;
  if not public._exam_available(e) then raise exception 'Avaliação indisponível'; end if;

  if a.started_at is null then
    update public.attempts
       set started_at = now(), status = 'in_progress', last_seen_at = now()
     where id = a.id
     returning * into a;
  else
    update public.attempts set status='in_progress', last_seen_at=now()
     where id=a.id returning * into a;
  end if;

  return jsonb_build_object(
    'status', a.status,
    'started_at', a.started_at,
    'ends_at', a.started_at + make_interval(mins => e.duration_minutes),
    'occurrences', a.occurrences
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
       set status='auto_submitted', submitted_at=now(), submission_reason='time_expired'
     where id=a.id
     returning * into a;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('id',x.id,'type',x.type,'stem',x.stem,'options',x.options)
    order by x.sort_key
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
    'assessment_mode', e.assessment_mode,
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
$;

create or replace function public.save_answer(
  p_session_token uuid,
  p_question_id uuid,
  p_answer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
begin
  select * into a from public.attempts where session_token=p_session_token;
  if a.id is null or a.status <> 'in_progress' then
    raise exception 'Tentativa não está em andamento';
  end if;

  select * into e from public.exams where id=a.exam_id;
  if a.started_at + make_interval(mins => e.duration_minutes) <= now() then
    raise exception 'Tempo encerrado';
  end if;

  if not exists(
    select 1 from public.questions
     where id=p_question_id and exam_id=a.exam_id and active=true
  ) then raise exception 'Questão inválida'; end if;

  insert into public.answers(attempt_id,question_id,answer)
  values(a.id,p_question_id,p_answer)
  on conflict(attempt_id,question_id)
  do update set answer=excluded.answer, saved_at=now();

  update public.attempts set last_seen_at=now() where id=a.id;

  return jsonb_build_object('ok',true,'saved_at',now());
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
as $
declare
  a public.attempts;
begin
  select * into a from public.attempts where session_token=p_session_token;
  if a.id is null or a.status <> 'in_progress' then
    raise exception 'Tentativa não está em andamento';
  end if;

  if not exists(
    select 1 from public.questions
    where id=p_question_id and exam_id=a.exam_id and active=true
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
         last_seen_at = now()
   where id=a.id;

  return jsonb_build_object('ok',true);
end;
$;

create or replace function public.record_violation(
  p_session_token uuid,
  p_event_type text,
  p_question_id uuid default null,
  p_details jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
  v_counted boolean := true;
  v_last timestamptz;
begin
  select * into a from public.attempts where session_token=p_session_token;
  if a.id is null or a.status <> 'in_progress' then
    return jsonb_build_object('status',coalesce(a.status,'invalid'),'occurrences',coalesce(a.occurrences,0));
  end if;

  select * into e from public.exams where id=a.exam_id;

  select max(occurred_at) into v_last
    from public.exam_events
   where attempt_id=a.id and counted=true;

  if v_last is not null and now() - v_last < interval '1.5 seconds' then
    v_counted := false;
  end if;

  insert into public.exam_events(attempt_id,event_type,counted,question_id,details)
  values(a.id,p_event_type,v_counted,p_question_id,coalesce(p_details,'{}'::jsonb));

  if v_counted then
    update public.attempts
       set occurrences=occurrences+1,last_seen_at=now()
     where id=a.id
     returning * into a;
  end if;

  if a.occurrences >= e.max_occurrences then
    perform public._grade_attempt(a.id);
    update public.attempts
       set status='auto_submitted',submitted_at=now(),submission_reason='occurrence_limit'
     where id=a.id
     returning * into a;
  end if;

  return jsonb_build_object(
    'status',a.status,
    'occurrences',a.occurrences,
    'max_occurrences',e.max_occurrences,
    'counted',v_counted
  );
end;
$$;

create or replace function public.submit_attempt(
  p_session_token uuid,
  p_reason text default 'submitted'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
  g record;
begin
  select * into a from public.attempts where session_token=p_session_token;
  if a.id is null then raise exception 'Sessão inválida'; end if;
  select * into e from public.exams where id=a.exam_id;

  if a.status in ('submitted','auto_submitted') then
    return jsonb_build_object(
      'status',a.status,'score',a.score,'max_score',a.max_score,
      'assessment_mode',e.assessment_mode
    );
  end if;

  select * into g from public._grade_attempt(a.id);

  update public.attempts
     set status=case when p_reason in ('occurrence_limit','time_expired') then 'auto_submitted' else 'submitted' end,
         submitted_at=now(),
         submission_reason=p_reason,
         last_seen_at=now()
   where id=a.id
   returning * into a;

  return jsonb_build_object(
    'status',a.status,
    'submitted_at',a.submitted_at,
    'score',a.score,
    'max_score',a.max_score,
    'assessment_mode',e.assessment_mode
  );
end;
$$;

create or replace function public.simulation_result(p_session_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  e public.exams;
  arr jsonb;
  pct numeric;
begin
  select * into a from public.attempts where session_token=p_session_token;
  if a.id is null then raise exception 'Sessão inválida'; end if;
  select * into e from public.exams where id=a.exam_id;

  if e.assessment_mode <> 'simulation' then raise exception 'Resultado detalhado indisponível'; end if;
  if a.status not in ('submitted','auto_submitted') then raise exception 'Simulado ainda não finalizado'; end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'position',q.position,
      'stem',q.stem,
      'options',q.options,
      'answer',coalesce(an.answer,'{}'::jsonb),
      'correct_answer',q.correct_answer,
      'is_correct',(an.answer->>'value'=q.correct_answer),
      'points',q.points
    ) order by q.position
  ),'[]'::jsonb)
  into arr
  from public.questions q
  left join public.answers an on an.question_id=q.id and an.attempt_id=a.id
  where q.exam_id=a.exam_id and q.active=true and q.type='objective';

  pct := case when coalesce(a.max_score,0)>0 then round((a.score/a.max_score)*100,1) else 0 end;

  return jsonb_build_object(
    'score',a.score,
    'max_score',a.max_score,
    'percentage',pct,
    'questions',arr
  );
end;
$$;

-- ---------------- PROFESSOR ----------------

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

  select count(*) into qcount from public.questions where exam_id=e.id and active=true;

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
    'assessment_mode',e.assessment_mode,
    'question_count',qcount,
    'attempts',arr
  );
end;
$$;

create or replace function public.teacher_attempt_detail(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.attempts;
  s public.students;
  ans jsonb;
  ev jsonb;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into a from public.attempts where id=p_attempt_id;
  if a.id is null then raise exception 'Tentativa não encontrada'; end if;
  select * into s from public.students where id=a.student_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'question_id',q.id,
      'position',q.position,
      'type',q.type,
      'stem',q.stem,
      'answer',coalesce(an.answer,'{}'::jsonb),
      'correct_answer',q.correct_answer,
      'points',q.points
    ) order by q.position
  ),'[]'::jsonb)
  into ans
  from public.questions q
  left join public.answers an on an.question_id=q.id and an.attempt_id=a.id
  where q.exam_id=a.exam_id and q.active=true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'event_type',ee.event_type,
      'counted',ee.counted,
      'occurred_at',ee.occurred_at,
      'question_position',q.position,
      'details',ee.details
    ) order by ee.occurred_at
  ),'[]'::jsonb)
  into ev
  from public.exam_events ee
  left join public.questions q on q.id=ee.question_id
  where ee.attempt_id=a.id;

  return jsonb_build_object(
    'student_name',s.name,
    'class_group',s.class_group,
    'status',a.status,
    'occurrences',a.occurrences,
    'score',a.score,
    'max_score',a.max_score,
    'answers',ans,
    'events',ev
  );
end;
$$;

create or replace function public.teacher_questions(p_exam_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $
declare
  e public.exams;
  arr jsonb;
  v_locked boolean;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into e from public.exams where slug=p_exam_slug;
  if e.id is null then raise exception 'Avaliação não encontrada'; end if;

  select exists(
    select 1 from public.attempts where exam_id=e.id
  ) into v_locked;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',q.id,
      'position',q.position,
      'type',q.type,
      'stem',q.stem,
      'options',q.options,
      'correct_answer',q.correct_answer,
      'points',q.points,
      'active',q.active
    ) order by q.position
  ),'[]'::jsonb)
  into arr
  from public.questions q
  where q.exam_id=e.id and q.type='objective';

  return jsonb_build_object(
    'locked',v_locked,
    'questions',arr
  );
end;
$;

create or replace function public.teacher_save_question(
  p_exam_slug text,
  p_question_id uuid,
  p_type text,
  p_stem text,
  p_options jsonb,
  p_correct_answer text,
  p_points numeric,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $
declare
  e public.exams;
  q public.questions;
  v_position integer;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into e from public.exams where slug=p_exam_slug;
  if e.id is null then raise exception 'Avaliação não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=e.id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  if p_type <> 'objective' then raise exception 'Somente questões objetivas são permitidas'; end if;
  if btrim(coalesce(p_stem,'')) = '' then raise exception 'Enunciado obrigatório'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) <> 4 then
    raise exception 'Questão objetiva deve possuir quatro alternativas';
  end if;
  if p_correct_answer not in ('A','B','C','D') then raise exception 'Gabarito inválido'; end if;
  if p_points <= 0 or p_points > 100 then raise exception 'Valor inválido'; end if;

  if p_question_id is null then
    select coalesce(max(position),0)+1 into v_position
    from public.questions where exam_id=e.id;

    insert into public.questions(exam_id,position,type,stem,options,correct_answer,points,active)
    values(e.id,v_position,'objective',btrim(p_stem),p_options,p_correct_answer,p_points,p_active)
    returning * into q;
  else
    update public.questions
       set type='objective',
           stem=btrim(p_stem),
           options=p_options,
           correct_answer=p_correct_answer,
           points=p_points,
           active=p_active
     where id=p_question_id and exam_id=e.id
     returning * into q;

    if q.id is null then raise exception 'Questão não encontrada'; end if;
  end if;

  return jsonb_build_object('ok',true,'question_id',q.id);
end;
$;

create or replace function public.teacher_move_question(
  p_question_id uuid,
  p_direction integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $
declare
  q public.questions;
  other_q public.questions;
  temp_position integer;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;
  if p_direction not in (-1,1) then raise exception 'Direção inválida'; end if;

  select * into q from public.questions where id=p_question_id;
  if q.id is null then raise exception 'Questão não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=q.exam_id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  if p_direction=-1 then
    select * into other_q
    from public.questions
    where exam_id=q.exam_id and position < q.position
    order by position desc limit 1;
  else
    select * into other_q
    from public.questions
    where exam_id=q.exam_id and position > q.position
    order by position asc limit 1;
  end if;

  if other_q.id is null then return jsonb_build_object('ok',true); end if;

  temp_position := -1000000 - q.position;
  update public.questions set position=temp_position where id=q.id;
  update public.questions set position=q.position where id=other_q.id;
  update public.questions set position=other_q.position where id=q.id;

  return jsonb_build_object('ok',true);
end;
$;

create or replace function public.teacher_delete_question(p_question_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $
declare
  q public.questions;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into q from public.questions where id=p_question_id;
  if q.id is null then raise exception 'Questão não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=q.exam_id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  delete from public.questions where id=q.id;

  with ordered as (
    select id, row_number() over(order by position)::integer as new_position
    from public.questions
    where exam_id=q.exam_id
  )
  update public.questions p
     set position=-(1000000 + o.new_position)
  from ordered o
  where p.id=o.id;

  update public.questions
     set position=abs(position)-1000000
   where exam_id=q.exam_id and position < 0;

  return jsonb_build_object('ok',true);
end;
$;

create or replace function public.teacher_update_exam_settings(
  p_exam_slug text,
  p_title text,
  p_duration_minutes integer,
  p_max_occurrences integer,
  p_is_active boolean,
  p_assessment_mode text
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
  if p_duration_minutes < 5 or p_duration_minutes > 300 then raise exception 'Duração inválida'; end if;
  if p_max_occurrences < 1 or p_max_occurrences > 20 then raise exception 'Limite de ocorrências inválido'; end if;
  if p_assessment_mode not in ('exam','simulation') then raise exception 'Modo inválido'; end if;

  update public.exams
     set title=btrim(p_title),
         duration_minutes=p_duration_minutes,
         max_occurrences=p_max_occurrences,
         is_active=p_is_active,
         assessment_mode=p_assessment_mode
   where slug=p_exam_slug
   returning * into e;

  if e.id is null then raise exception 'Avaliação não encontrada'; end if;

  return jsonb_build_object(
    'ok',true,
    'title',e.title,
    'duration_minutes',e.duration_minutes,
    'max_occurrences',e.max_occurrences,
    'is_active',e.is_active,
    'assessment_mode',e.assessment_mode
  );
end;
$$;

create or replace function public.teacher_allow_resume_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $
declare
  a public.attempts;
  e public.exams;
  s public.students;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into a from public.attempts where id=p_attempt_id;
  if a.id is null then raise exception 'Tentativa não encontrada'; end if;
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
  values(a.id,'teacher_resume_authorized',false,
         jsonb_build_object('authorized_at',now()));

  return jsonb_build_object(
    'ok',true,
    'student_name',s.name,
    'resume_allowed',true
  );
end;
$;

create or replace function public.teacher_reset_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $
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
$;

-- Execução das funções públicas pelo aluno.
grant execute on function public.start_attempt_by_name(text,text,text) to anon, authenticated;
grant execute on function public.begin_attempt(uuid) to anon, authenticated;
grant execute on function public.resume_attempt(uuid) to anon, authenticated;
grant execute on function public.save_answer(uuid,uuid,jsonb) to anon, authenticated;
grant execute on function public.save_review_flag(uuid,uuid,boolean) to anon, authenticated;
grant execute on function public.record_violation(uuid,text,uuid,jsonb) to anon, authenticated;
grant execute on function public.submit_attempt(uuid,text) to anon, authenticated;
grant execute on function public.simulation_result(uuid) to anon, authenticated;

-- Painel: apenas usuário autenticado.
grant execute on function public.teacher_dashboard(text) to authenticated;
grant execute on function public.teacher_attempt_detail(uuid) to authenticated;
grant execute on function public.teacher_questions(text) to authenticated;
grant execute on function public.teacher_save_question(text,uuid,text,text,jsonb,text,numeric,boolean) to authenticated;
grant execute on function public.teacher_move_question(uuid,integer) to authenticated;
grant execute on function public.teacher_delete_question(uuid) to authenticated;
grant execute on function public.teacher_update_exam_settings(text,text,integer,integer,boolean,text) to authenticated;
grant execute on function public.teacher_reset_attempt(uuid) to authenticated;
grant execute on function public.teacher_allow_resume_attempt(uuid) to authenticated;
