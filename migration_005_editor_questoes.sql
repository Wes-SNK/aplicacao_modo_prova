-- MIGRAÇÃO 005 — EDITOR DE QUESTÕES
-- Execute uma única vez no SQL Editor do Supabase.
-- Por segurança, alterações estruturais são bloqueadas se já houver tentativas registradas.

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
  where q.exam_id=e.id;

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

  if p_type not in ('objective','open') then
    raise exception 'Tipo de questão inválido';
  end if;

  if btrim(coalesce(p_stem,'')) = '' then
    raise exception 'Enunciado obrigatório';
  end if;

  if p_type='objective' then
    if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) <> 4 then
      raise exception 'Questão objetiva deve possuir quatro alternativas';
    end if;

    if p_correct_answer not in ('A','B','C','D') then
      raise exception 'Gabarito inválido';
    end if;

    if p_points < 0 or p_points > 100 then
      raise exception 'Valor inválido';
    end if;
  else
    p_options := '[]'::jsonb;
    p_correct_answer := null;
    p_points := 0;
  end if;

  if p_question_id is null then
    select coalesce(max(position),0)+1
      into v_position
      from public.questions
     where exam_id=e.id;

    insert into public.questions(
      exam_id,position,type,stem,options,correct_answer,points,active
    )
    values(
      e.id,v_position,p_type,btrim(p_stem),p_options,p_correct_answer,p_points,p_active
    )
    returning * into q;
  else
    update public.questions
       set type=p_type,
           stem=btrim(p_stem),
           options=p_options,
           correct_answer=p_correct_answer,
           points=p_points,
           active=p_active
     where id=p_question_id
       and exam_id=e.id
     returning * into q;

    if q.id is null then raise exception 'Questão não encontrada'; end if;
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
  where id=p_question_id;

  if q.id is null then raise exception 'Questão não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=q.exam_id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  if p_direction=-1 then
    select * into other_q
    from public.questions
    where exam_id=q.exam_id
      and position < q.position
    order by position desc
    limit 1;
  else
    select * into other_q
    from public.questions
    where exam_id=q.exam_id
      and position > q.position
    order by position asc
    limit 1;
  end if;

  if other_q.id is null then
    return jsonb_build_object('ok',true);
  end if;

  temp_position := -1000000 - q.position;

  update public.questions
     set position=temp_position
   where id=q.id;

  update public.questions
     set position=q.position
   where id=other_q.id;

  update public.questions
     set position=other_q.position
   where id=q.id;

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
  where id=p_question_id;

  if q.id is null then raise exception 'Questão não encontrada'; end if;

  if exists(select 1 from public.attempts where exam_id=q.exam_id) then
    raise exception 'Estrutura bloqueada: já existem tentativas registradas';
  end if;

  delete from public.questions where id=q.id;

  with ordered as (
    select id,
           row_number() over(order by position)::integer as new_position
    from public.questions
    where exam_id=q.exam_id
  )
  update public.questions p
     set position=-(1000000 + o.new_position)
  from ordered o
  where p.id=o.id;

  update public.questions
     set position=abs(position)-1000000
   where exam_id=q.exam_id
     and position < 0;

  return jsonb_build_object('ok',true);
end;
$$;

grant execute on function public.teacher_questions(text)
to authenticated;

grant execute on function public.teacher_save_question(
  text,uuid,text,text,jsonb,text,numeric,boolean
)
to authenticated;

grant execute on function public.teacher_move_question(uuid,integer)
to authenticated;

grant execute on function public.teacher_delete_question(uuid)
to authenticated;
