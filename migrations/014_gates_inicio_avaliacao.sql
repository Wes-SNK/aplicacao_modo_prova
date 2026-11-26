-- MIGRAÇÃO PROPOSTA 014 — BLOQUEIOS EFETIVOS DE INÍCIO
-- Preserva o comportamento dos exames cuja supervisão está desligada.

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

  -- Não oferecer token de tentativa antes da autorização presencial.
  if exists(select 1 from public.exam_supervision
    where exam_id=e.id and enabled) then
    raise exception 'Esta avaliação exige entrada pela sala de espera';
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

  -- Bloqueia também o fluxo legado por código individual.
  if exists(select 1 from public.exam_supervision
    where exam_id=e.id and enabled) then
    raise exception 'Esta avaliação exige entrada pela sala de espera';
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

  -- Defesa no servidor: nem uma sessão adquirida por outro caminho poderá
  -- iniciar sem autorização. Tentativas já iniciadas podem continuar.
  if a.started_at is null and exists(
    select 1 from public.exam_supervision where exam_id=e.id and enabled
  ) and not exists(
    select 1 from public.exam_lobby
    where exam_id=e.id and student_id=a.student_id and authorized=true
  ) then
    raise exception 'Aguarde a autorização do professor';
  end if;

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


CREATE FUNCTION public.student_lobby_enter(p_lobby_token uuid,p_user_agent text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE l public.exam_lobby;e public.exams;s public.students;a public.attempts;
 q jsonb;ans jsonb;
BEGIN
 SELECT * INTO l FROM public.exam_lobby
 WHERE lobby_token=p_lobby_token FOR UPDATE;
 IF l.exam_id IS NULL THEN RAISE EXCEPTION 'Sala de espera inválida';END IF;
 SELECT * INTO e FROM public.exams WHERE id=l.exam_id;
 IF NOT public._exam_available(e) THEN
  RAISE EXCEPTION 'Avaliação indisponível';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.exam_supervision g
 WHERE g.exam_id=e.id AND g.enabled) THEN
  RAISE EXCEPTION 'Sala de espera não está ativa';END IF;
 IF NOT l.authorized THEN RAISE EXCEPTION 'Aguarde autorização do professor';END IF;
 SELECT * INTO s FROM public.students WHERE id=l.student_id AND active;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.exam_supervision g
 WHERE g.exam_id=e.id AND g.class_group=s.class_group) THEN
  RAISE EXCEPTION 'Estudante fora da turma autorizada';END IF;
 SELECT * INTO a FROM public.attempts WHERE exam_id=e.id AND student_id=s.id FOR UPDATE;
 IF a.id IS NULL THEN
   INSERT INTO public.attempts(exam_id,student_id,user_agent)
   VALUES(e.id,s.id,p_user_agent) RETURNING * INTO a;
 ELSIF a.status IN ('submitted','auto_submitted') THEN
   RAISE EXCEPTION 'Avaliação já finalizada';
 ELSIF a.status='in_progress' THEN
   IF NOT a.resume_allowed THEN
     RAISE EXCEPTION 'Avaliação já iniciada. Peça ao professor a liberação de retomada';
   END IF;
   UPDATE public.attempts SET session_token=gen_random_uuid(),
    resume_allowed=false,last_seen_at=now(),
    user_agent=coalesce(p_user_agent,user_agent)
   WHERE id=a.id RETURNING * INTO a;
 ELSE
   UPDATE public.attempts SET last_seen_at=now(),
    user_agent=coalesce(p_user_agent,user_agent)
   WHERE id=a.id RETURNING * INTO a;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',x.id,'type',x.type,
  'stem',x.stem,'options',x.options) ORDER BY x.sort_key),'[]'::jsonb) INTO q
 FROM (SELECT q.*,md5(a.session_token::text||q.id::text) AS sort_key
  FROM public.questions q WHERE q.exam_id=e.id AND q.active
  AND q.type='objective') x;
 SELECT coalesce(jsonb_object_agg(question_id::text,answer),'{}'::jsonb)
 INTO ans FROM public.answers WHERE attempt_id=a.id;
 RETURN jsonb_build_object(
 'attempt_id',a.id,'session_token',a.session_token,'status',a.status,
 'student_name',s.name,'exam_title',e.title,'assessment_mode',e.assessment_mode,
 'duration_minutes',e.duration_minutes,'max_occurrences',e.max_occurrences,
 'occurrences',a.occurrences,'started_at',a.started_at,
 'ends_at',CASE WHEN a.started_at IS NULL THEN NULL
   ELSE a.started_at+make_interval(mins=>e.duration_minutes) END,
 'questions',q,'answers',ans,'review_flags',coalesce(a.review_flags,'{}'::jsonb),
 'supervised',true);
END;$fn$;
REVOKE ALL ON FUNCTION public.student_lobby_enter(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.student_lobby_enter(uuid,text) TO anon,authenticated;


-- Ao retomar, preservar o indicador de supervisão para o botão de ajuda.
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
    'review_flags',coalesce(a.review_flags,'{}'::jsonb),
    'supervised',exists(select 1 from public.exam_supervision
      where exam_id=e.id and enabled)
  );
end;
$function$;
