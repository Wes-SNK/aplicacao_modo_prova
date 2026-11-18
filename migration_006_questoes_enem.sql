-- 006 - cinco alternativas e justificativa pedagógica para correção do simulado
-- Mantém RPC anterior para compatibilidade com clientes já abertos.
alter table public.questions add column if not exists explanation text;

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
      'points',q.points,
      'explanation',q.explanation
    ) order by md5(a.session_token::text || q.id::text)
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
      'explanation',q.explanation,
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

create or replace function public.teacher_save_question_v2(
  p_exam_slug text,
  p_question_id uuid,
  p_type text,
  p_stem text,
  p_options jsonb,
  p_correct_answer text,
  p_points numeric,
  p_active boolean,
  p_explanation text
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
     or jsonb_array_length(p_options)<>5 then
    raise exception 'Questão objetiva deve possuir cinco alternativas';
  end if;

  if p_correct_answer not in ('A','B','C','D','E') then
    raise exception 'Gabarito inválido';
  end if;

  if p_points<=0 or p_points>100 then
    raise exception 'Valor inválido';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_options) o
    where coalesce(btrim(o->>'text'),'')=''
       or o->>'key' not in ('A','B','C','D','E')
  ) then
    raise exception 'Alternativas inválidas';
  end if;

  if (
    select count(distinct o->>'key')
    from jsonb_array_elements(p_options) o
  ) <> 5 then
    raise exception 'As alternativas devem usar A, B, C, D e E uma única vez';
  end if;

  if p_question_id is null then
    select coalesce(max(position),0)+1 into v_position
    from public.questions
    where exam_id=e.id;

    insert into public.questions(
      exam_id,position,type,stem,options,correct_answer,points,active,explanation
    )
    values(
      e.id,v_position,'objective',btrim(p_stem),p_options,
      p_correct_answer,p_points,p_active,nullif(btrim(coalesce(p_explanation,'')),'')
    )
    returning * into q;
  else
    update public.questions
       set type='objective',
           stem=btrim(p_stem),
           options=p_options,
           correct_answer=p_correct_answer,
           points=p_points,
           explanation=nullif(btrim(coalesce(p_explanation,'')),''),
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

grant execute on function public.teacher_save_question_v2(text,uuid,text,text,jsonb,text,numeric,boolean,text) to authenticated;
