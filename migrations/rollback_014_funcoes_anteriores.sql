-- Cópia das funções originais antes da migração 014.
-- RESTAURAÇÃO EXIGE AVALIAÇÃO DAS TABELAS E DAS TENTATIVAS POSTERIORES.

-- begin_attempt
CREATE OR REPLACE FUNCTION public.begin_attempt(p_session_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- resume_attempt
CREATE OR REPLACE FUNCTION public.resume_attempt(p_session_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- start_attempt
CREATE OR REPLACE FUNCTION public.start_attempt(p_exam_slug text, p_access_code text, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  e public.exams;
  s public.students;
  a public.attempts;
  q jsonb;
begin
  select * into e from public.exams where slug = p_exam_slug;
  if e.id is null or not public._exam_available(e) then
    raise exception 'Avaliação indisponível';
  end if;

  select * into s
    from public.students
   where upper(access_code) = upper(trim(p_access_code))
     and active = true;

  if s.id is null then
    raise exception 'Código inválido';
  end if;

  select * into a from public.attempts
   where exam_id = e.id and student_id = s.id;

  if a.id is not null and a.status in ('submitted','auto_submitted') then
    raise exception 'Avaliação já finalizada';
  end if;

  if a.id is null then
    insert into public.attempts(exam_id, student_id, user_agent)
    values(e.id, s.id, p_user_agent)
    returning * into a;
  else
    update public.attempts set last_seen_at = now(), user_agent = coalesce(p_user_agent,user_agent)
     where id = a.id returning * into a;
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
$function$;

-- start_attempt_by_name
CREATE OR REPLACE FUNCTION public.start_attempt_by_name(p_exam_slug text, p_student_name text, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;