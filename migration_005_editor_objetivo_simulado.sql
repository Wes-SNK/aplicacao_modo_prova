-- MIGRAÇÃO 005 — EDITOR OBJETIVO E MODO SIMULADO
-- Execute uma única vez no SQL Editor do Supabase.

alter table public.exams
  add column if not exists assessment_mode text not null default 'exam'
  check (assessment_mode in ('exam','simulation'));

-- A aplicação passa a trabalhar apenas com questões objetivas.
-- Questões abertas antigas são preservadas como histórico, mas desativadas.
update public.questions
   set active=false
 where type='open';

-- ---------- ALUNO: ENTRADA / RETOMADA COM MODO DA APLICAÇÃO ----------

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
  select * into e from public.exams where slug=p_exam_slug;
  if e.id is null or not public._exam_available(e) then
    raise exception 'Avaliação indisponível';
  end if;

  select count(*) into v_matches
  from public.students
  where lower(btrim(name))=lower(btrim(p_student_name))
    and active=true;

  if v_matches=0 then
    raise exception 'Estudante não encontrado';
  elsif v_matches>1 then
    raise exception 'Nome ambíguo';
  end if;

  select * into s
  from public.students
  where lower(btrim(name))=lower(btrim(p_student_name))
    and active=true
  limit 1;

  select * into a
  from public.attempts
  where exam_id=e.id and student_id=s.id;

  if a.id is null then
    insert into public.attempts(exam_id,student_id,user_agent)
    values(e.id,s.id,p_user_agent)
    returning * into a;

  elsif a.status='in_progress' then
    if not a.resume_allowed then
      raise exception 'Avaliação já iniciada';
    end if;

    update public.attempts
       set session_token=gen_random_uuid(),
           resume_allowed=false,
           last_seen_at=now(),
           user_agent=coalesce(p_user_agent,user_agent)
     where id=a.id
     returning * into a;

  elsif a.status in ('submitted','auto_submitted') then
    raise exception 'Avaliação já finalizada';

  else
    update public.attempts
       set last_seen_at=now(),
           user_agent=coalesce(p_user_agent,user_agent)
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
    select q.*,md5(a.session_token::text || q.id::text) as sort_key
    from public.questions q
    where q.exam_id=e.id
      and q.active=true
      and q.type='objective'
  ) x;

  select coalesce(jsonb_object_agg(question_id::text,answer),'{}'::jsonb)
  into ans
  from public.answers
  where attempt_id=a.id;

  return jsonb_build_object(
    'attempt_id',a.id,
    'session_token',a.session_token,
    'status',a.status,
    'student_name',s.name,
    'exam_title',e.title,
    'assessment_mode',e.assessment_mode,
    'duration_minutes',e.duration_minutes,
    'max_occurrences',e.max_occurrences,
    'occurrences',a.occurrences,
    'started_at',a.started_at,
    'ends_at',case when a.started_at is null then null
                   else a.started_at + make_interval(mins=>e.duration_minutes) end,
    'questions',q,
    'answers',ans,
    'review_flags',coalesce(a.review_flags,'{}'::jsonb)
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
  select * into a from public.attempts where session_token=p_session_token;
  if a.id is null then raise exception 'Sessão inválida'; end if;

  select * into e from public.exams where id=a.exam_id;
  select * into s from public.students where id=a.student_id;

  if a.status='in_progress'
     and a.started_at + make_interval(mins=>e.duration_minutes) <= now() then
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
    select q.*,md5(a.session_token::text || q.id::text) as sort_key
    from public.questions q
    where q.exam_id=e.id
      and q.active=true
      and q.type='objective'
  ) x;

  select coalesce(jsonb_object_agg(question_id::text,answer),'{}'::jsonb)
  into ans
  from public.answers
  where attempt_id=a.id;

  return jsonb_build_object(
    'attempt_id',a.id,
    'session_token',a.session_token,
    'status',a.status,
    'student_name',s.name,
    'exam_title',e.title,
    'assessment_mode',e.assessment_mode,
    'duration_minutes',e.duration_minutes,
    'max_occurrences',e.max_occurrences,
    'occurrences',a.occurrences,
    'started_at',a.started_at,
    'ends_at',case when a.started_at is null then null
                   else a.started_at + make_interval(mins=>e.duration_minutes) end,
    'questions',q,
    'answers',ans,
    'review_flags',coalesce(a.review_flags,'{}'::jsonb)
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
      'status',a.status,
      'score',a.score,
      'max_score',a.max_score,
      'assessment_mode',e.assessment_mode
    );
  end if;

  select * into g from public._grade_attempt(a.id);

  update public.attempts
     set status=case
                  when p_reason in ('occurrence_limit','time_expired')
                  then 'auto_submitted'
                  else 'submitted'
                end,
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

  if e.assessment_mode <> 'simulation' then
    raise exception 'Resultado detalhado indisponível';
  end if;

  if a.status not in ('submitted','auto_submitted') then
    raise exception 'Simulado ainda não finalizado';
  end if;

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
  left join public.answers an
    on an.question_id=q.id
   and an.attempt_id=a.id
  where q.exam_id=a.exam_id
    and q.active=true
    and q.type='objective';

  pct := case
           when coalesce(a.max_score,0)>0
           then round((a.score/a.max_score)*100,1)
           else 0
         end;

  return jsonb_build_object(
    'score',a.score,
    'max_score',a.max_score,
    'percentage',pct,
    'questions',arr
  );
end;
$$;

-- ---------- PROFESSOR: PAINEL / CONFIGURAÇÕES ----------

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
  where exam_id=e.id
    and active=true
    and type='objective';

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

drop function if exists public.teacher_update_exam_settings(
  text,text,integer,integer,boolean
);

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
  v_has_attempts boolean;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;
  if btrim(coalesce(p_title,''))='' then raise exception 'Título obrigatório'; end if;
  if p_duration_minutes<5 or p_duration_minutes>300 then
    raise exception 'Duração inválida';
  end if;
  if p_max_occurrences<1 or p_max_occurrences>20 then
    raise exception 'Limite de ocorrências inválido';
  end if;
  if p_assessment_mode not in ('exam','simulation') then
    raise exception 'Modo inválido';
  end if;

  select * into e from public.exams where slug=p_exam_slug;
  if e.id is null then raise exception 'Avaliação não encontrada'; end if;

  select exists(
    select 1 from public.attempts where exam_id=e.id
  ) into v_has_attempts;

  if v_has_attempts and (
       e.duration_minutes <> p_duration_minutes
       or e.max_occurrences <> p_max_occurrences
       or e.assessment_mode <> p_assessment_mode
     ) then
    raise exception 'Há tentativas registradas; duração, limite de ocorrências e modo de aplicação não podem ser alterados';
  end if;

  update public.exams
     set title=btrim(p_title),
         duration_minutes=p_duration_minutes,
         max_occurrences=p_max_occurrences,
         is_active=p_is_active,
         assessment_mode=p_assessment_mode
   where id=e.id
   returning * into e;

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

-- ---------- PROFESSOR: EDITOR DE QUESTÕES OBJETIVAS ----------

create or replace function public.teacher_questions(p_exam_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
      'type','objective',
      'stem',q.stem,
      'options',q.options,
      'correct_answer',q.correct_answer,
      'points',q.points,
      'active',q.active
    ) order by q.position
  ),'[]'::jsonb)
  into arr
  from public.questions q
  where q.exam_id=e.id
    and q.type='objective';

  return jsonb_build_object(
    'locked',v_locked,
    'questions',arr
  );
end;
$$;

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
as $$
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

  if p_type <> 'objective' then
    raise exception 'Somente questões objetivas são permitidas';
  end if;

  if btrim(coalesce(p_stem,''))='' then
    raise exception 'Enunciado obrigatório';
  end if;

  if jsonb_typeof(p_options)<>'array'
     or jsonb_array_length(p_options)<>4 then
    raise exception 'Questão objetiva deve possuir quatro alternativas';
  end if;

  if p_correct_answer not in ('A','B','C','D') then
    raise exception 'Gabarito inválido';
  end if;

  if p_points<=0 or p_points>100 then
    raise exception 'Valor inválido';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_options) o
    where coalesce(btrim(o->>'text'),'')=''
       or o->>'key' not in ('A','B','C','D')
  ) then
    raise exception 'Alternativas inválidas';
  end if;

  if (
    select count(distinct o->>'key')
    from jsonb_array_elements(p_options) o
  ) <> 4 then
    raise exception 'As alternativas devem usar A, B, C e D uma única vez';
  end if;

  if p_question_id is null then
    select coalesce(max(position),0)+1 into v_position
    from public.questions
    where exam_id=e.id;

    insert into public.questions(
      exam_id,position,type,stem,options,correct_answer,points,active
    )
    values(
      e.id,v_position,'objective',btrim(p_stem),p_options,
      p_correct_answer,p_points,p_active
    )
    returning * into q;
  else
    update public.questions
       set type='objective',
           stem=btrim(p_stem),
           options=p_options,
           correct_answer=p_correct_answer,
           points=p_points,
           active=p_active
     where id=p_question_id
       and exam_id=e.id
       and type='objective'
     returning * into q;

    if q.id is null then
      raise exception 'Questão não encontrada';
    end if;
  end if;

  return jsonb_build_object(
    'ok',true,
    'question_id',q.id
  );
end;
$$;

create or replace function public.teacher_move_question(
  p_question_id uuid,
  p_direction integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.questions;
  other_q public.questions;
  temp_position integer;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;
  if p_direction not in (-1,1) then raise exception 'Direção inválida'; end if;

  select * into q
  from public.questions
  where id=p_question_id
    and type='objective';

  if q.id is null then raise exception 'Questão não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=q.exam_id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  if p_direction=-1 then
    select * into other_q
    from public.questions
    where exam_id=q.exam_id
      and type='objective'
      and position<q.position
    order by position desc
    limit 1;
  else
    select * into other_q
    from public.questions
    where exam_id=q.exam_id
      and type='objective'
      and position>q.position
    order by position asc
    limit 1;
  end if;

  if other_q.id is null then
    return jsonb_build_object('ok',true);
  end if;

  temp_position := -1000000-q.position;
  update public.questions set position=temp_position where id=q.id;
  update public.questions set position=q.position where id=other_q.id;
  update public.questions set position=other_q.position where id=q.id;

  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.teacher_delete_question(p_question_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.questions;
begin
  if auth.uid() is null then raise exception 'Acesso negado'; end if;

  select * into q
  from public.questions
  where id=p_question_id
    and type='objective';

  if q.id is null then raise exception 'Questão não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=q.exam_id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  delete from public.questions where id=q.id;

  with ordered as (
    select id,row_number() over(order by position)::integer as new_position
    from public.questions
    where exam_id=q.exam_id
      and type='objective'
  )
  update public.questions p
     set position=-(1000000+o.new_position)
  from ordered o
  where p.id=o.id;

  update public.questions
     set position=abs(position)-1000000
   where exam_id=q.exam_id
     and type='objective'
     and position<0;

  return jsonb_build_object('ok',true);
end;
$$;

-- ---------- PERMISSÕES ----------

grant execute on function public.start_attempt_by_name(text,text,text)
to anon,authenticated;

grant execute on function public.resume_attempt(uuid)
to anon,authenticated;

grant execute on function public.submit_attempt(uuid,text)
to anon,authenticated;

grant execute on function public.simulation_result(uuid)
to anon,authenticated;

grant execute on function public.teacher_dashboard(text)
to authenticated;

grant execute on function public.teacher_update_exam_settings(
  text,text,integer,integer,boolean,text
) to authenticated;

grant execute on function public.teacher_questions(text)
to authenticated;

grant execute on function public.teacher_save_question(
  text,uuid,text,text,jsonb,text,numeric,boolean
) to authenticated;

grant execute on function public.teacher_move_question(uuid,integer)
to authenticated;

grant execute on function public.teacher_delete_question(uuid)
to authenticated;
