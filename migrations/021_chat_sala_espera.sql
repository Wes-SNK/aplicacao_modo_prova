-- 021: comunicação supervisionada somente na sala de espera.
-- Não altera questões, respostas, autorização, tentativas ou cronômetro.
-- Nenhuma tabela fica diretamente acessível pelo PostgREST: todas as
-- operações passam por RPC SECURITY DEFINER com verificação de identidade.
CREATE TABLE public.lobby_chat_settings (
 exam_id uuid PRIMARY KEY REFERENCES public.exams(id) ON DELETE CASCADE,
 enabled boolean NOT NULL DEFAULT false,
 peer_messages boolean NOT NULL DEFAULT true,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.lobby_chat_mutes (
 exam_id uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
 student_id uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
 muted boolean NOT NULL DEFAULT true,
 PRIMARY KEY(exam_id,student_id)
);
CREATE TABLE public.lobby_chat_messages (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 exam_id uuid NOT NULL REFERENCES public.exams(id) ON DELETE CASCADE,
 sender_student_id uuid REFERENCES public.students(id) ON DELETE CASCADE,
 sender_teacher boolean NOT NULL DEFAULT false,
 recipient_student_id uuid REFERENCES public.students(id) ON DELETE CASCADE,
 recipient_teacher boolean NOT NULL DEFAULT false,
 body text NOT NULL CHECK(length(body) BETWEEN 1 AND 150),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((sender_teacher AND sender_student_id IS NULL) OR
        (NOT sender_teacher AND sender_student_id IS NOT NULL)),
 CHECK (NOT (recipient_teacher AND recipient_student_id IS NOT NULL))
);
CREATE INDEX lobby_chat_messages_exam_idx ON public.lobby_chat_messages(exam_id,id DESC);
CREATE INDEX lobby_chat_messages_sender_idx ON public.lobby_chat_messages(exam_id,sender_student_id,created_at DESC);

ALTER TABLE public.lobby_chat_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lobby_chat_mutes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lobby_chat_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lobby_chat_settings,public.lobby_chat_mutes,public.lobby_chat_messages FROM PUBLIC,anon,authenticated;

-- A mesma barreira é aplicada na leitura e no envio. O aluno só pode
-- conversar com um token de lobby válido, na turma vinculada, antes do
-- início de sua tentativa. O professor continua tendo acesso ao histórico.
CREATE FUNCTION public._lobby_chat_student(p_token uuid)
RETURNS public.exam_lobby LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE l public.exam_lobby; s public.students;
BEGIN
 SELECT * INTO l FROM public.exam_lobby WHERE lobby_token=p_token;
 IF NOT FOUND OR NOT l.lobby_allowed OR l.requested_at IS NULL
 THEN RAISE EXCEPTION 'Sala de espera inválida';END IF;
 SELECT * INTO s FROM public.students WHERE id=l.student_id AND active;
 IF NOT FOUND OR NOT EXISTS(
   SELECT 1 FROM public.exam_supervision g
   WHERE g.exam_id=l.exam_id AND g.enabled AND g.class_group=s.class_group)
 THEN RAISE EXCEPTION 'Turma não autorizada';END IF;
 IF EXISTS(SELECT 1 FROM public.attempts a
  WHERE a.exam_id=l.exam_id AND a.student_id=l.student_id)
 THEN RAISE EXCEPTION 'Conversa encerrada após início da prova';END IF;
 RETURN l;
END;$fn$;

CREATE FUNCTION public.student_lobby_chat_read(p_lobby_token uuid,p_after bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE l public.exam_lobby; c public.lobby_chat_settings; v_muted boolean;
 v_peers jsonb;v_messages jsonb;
BEGIN
 l:=public._lobby_chat_student(p_lobby_token);
 SELECT * INTO c FROM public.lobby_chat_settings WHERE exam_id=l.exam_id;
 IF NOT coalesce(c.enabled,false) THEN
  RETURN jsonb_build_object('enabled',false,'messages','[]'::jsonb,
   'peers','[]'::jsonb,'peer_messages',false,'muted',false);END IF;
 SELECT coalesce(muted,false) INTO v_muted
 FROM public.lobby_chat_mutes WHERE exam_id=l.exam_id AND student_id=l.student_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',substr(md5(q.student_id::text),1,10),
  'handle','Aluno-'||upper(substr(md5(q.student_id::text),1,6)),
  'self',q.student_id=l.student_id) ORDER BY q.student_id),'[]'::jsonb)
 INTO v_peers
 FROM public.exam_lobby q
 WHERE q.exam_id=l.exam_id AND q.lobby_allowed
  AND q.requested_at IS NOT NULL
  AND q.last_seen_at>now()-interval '45 seconds'
  AND NOT EXISTS(SELECT 1 FROM public.attempts a
    WHERE a.exam_id=q.exam_id AND a.student_id=q.student_id);
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',m.id,'body',m.body,
  'sender',CASE WHEN m.sender_teacher THEN 'Professor'
      WHEN m.sender_student_id=l.student_id THEN 'Você'
      ELSE 'Aluno-'||upper(substr(md5(m.sender_student_id::text),1,6)) END,
  'recipient',CASE WHEN m.recipient_teacher THEN '@Professor'
     WHEN m.recipient_student_id IS NOT NULL THEN
       '@Aluno-'||upper(substr(md5(m.recipient_student_id::text),1,6))
     ELSE 'Todos' END,
  'teacher_sender',m.sender_teacher,
  'sender_id',CASE WHEN m.sender_student_id IS NOT NULL
    THEN substr(md5(m.sender_student_id::text),1,10) ELSE NULL END,
  'public_message',m.recipient_student_id IS NULL AND NOT m.recipient_teacher,
  'self',m.sender_student_id=l.student_id)
  ORDER BY m.id),'[]'::jsonb) INTO v_messages
 FROM (SELECT * FROM public.lobby_chat_messages m
   WHERE m.exam_id=l.exam_id AND m.id>greatest(coalesce(p_after,0),0)
    AND (m.recipient_student_id IS NULL AND NOT m.recipient_teacher
       OR m.sender_student_id=l.student_id
       OR m.recipient_student_id=l.student_id)
   ORDER BY m.id DESC LIMIT 35) m;
 RETURN jsonb_build_object('enabled',true,'peer_messages',c.peer_messages,
  'muted',coalesce(v_muted,false),'peers',v_peers,'messages',v_messages);
END;$fn$;

CREATE FUNCTION public.student_lobby_chat_send(
 p_lobby_token uuid,p_body text,p_recipient text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE l public.exam_lobby;c public.lobby_chat_settings;
 v_to uuid;v_teacher boolean:=false;v_body text;v_id bigint;
BEGIN
 l:=public._lobby_chat_student(p_lobby_token);
 SELECT * INTO c FROM public.lobby_chat_settings WHERE exam_id=l.exam_id;
 IF NOT coalesce(c.enabled,false) THEN RAISE EXCEPTION 'Conversa desativada';END IF;
 IF EXISTS(SELECT 1 FROM public.lobby_chat_mutes
 WHERE exam_id=l.exam_id AND student_id=l.student_id AND muted)
 THEN RAISE EXCEPTION 'Envio suspenso pelo professor';END IF;
 v_body:=btrim(regexp_replace(coalesce(p_body,''),'[[:cntrl:]]','','g'));
 IF length(v_body) NOT BETWEEN 1 AND 150 THEN
  RAISE EXCEPTION 'Mensagem deve conter de 1 a 150 caracteres';END IF;
 IF p_recipient='teacher' THEN
   v_teacher:=true;
 ELSIF nullif(p_recipient,'') IS NOT NULL THEN
   IF NOT c.peer_messages THEN RAISE EXCEPTION 'Mensagens entre colegas desativadas';END IF;
   SELECT q.student_id INTO v_to FROM public.exam_lobby q
   WHERE q.exam_id=l.exam_id AND q.student_id<>l.student_id
    AND substr(md5(q.student_id::text),1,10)=lower(p_recipient)
    AND q.last_seen_at>now()-interval '45 seconds'
    AND NOT EXISTS(SELECT 1 FROM public.attempts a WHERE
      a.exam_id=q.exam_id AND a.student_id=q.student_id);
   IF NOT FOUND THEN RAISE EXCEPTION 'Destinatário não está na sala';END IF;
 ELSIF NOT c.peer_messages THEN
   RAISE EXCEPTION 'Somente mensagens ao professor estão habilitadas';
 END IF;
 -- Serializa envios da mesma sessão para aplicar limite antiflood
 -- mesmo quando o navegador dispara requisições concorrentes.
 PERFORM pg_advisory_xact_lock(hashtext(l.lobby_token::text));
 IF EXISTS(SELECT 1 FROM public.lobby_chat_messages m
 WHERE m.exam_id=l.exam_id AND m.sender_student_id=l.student_id
 AND m.created_at>now()-interval '3 seconds') THEN
  RAISE EXCEPTION 'Aguarde 3 segundos para enviar outra mensagem';END IF;
 INSERT INTO public.lobby_chat_messages(exam_id,sender_student_id,
  recipient_student_id,recipient_teacher,body)
 VALUES(l.exam_id,l.student_id,v_to,v_teacher,v_body) RETURNING id INTO v_id;
 RETURN jsonb_build_object('ok',true,'id',v_id);
END;$fn$;

CREATE FUNCTION public.teacher_lobby_chat_manage(
 p_exam_slug text,p_enabled boolean DEFAULT NULL,
 p_peer_messages boolean DEFAULT NULL,p_student_id uuid DEFAULT NULL,
 p_muted boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;g public.exam_supervision;c public.lobby_chat_settings;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso restrito ao professor';END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug;
 IF NOT FOUND THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 SELECT * INTO g FROM public.exam_supervision WHERE exam_id=e.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'A avaliação não tem turma vinculada';END IF;
 INSERT INTO public.lobby_chat_settings(exam_id,enabled,peer_messages)
 VALUES(e.id,false,true) ON CONFLICT DO NOTHING;
 IF p_enabled IS NOT NULL OR p_peer_messages IS NOT NULL THEN
 UPDATE public.lobby_chat_settings SET enabled=coalesce(p_enabled,enabled),
 peer_messages=coalesce(p_peer_messages,peer_messages),updated_at=now()
 WHERE exam_id=e.id;
 END IF;
 IF p_student_id IS NOT NULL THEN
   IF p_muted IS NULL THEN RAISE EXCEPTION 'Informe silenciar ou liberar';END IF;
   IF NOT EXISTS(SELECT 1 FROM public.students
     WHERE id=p_student_id AND class_group=g.class_group AND active)
   THEN RAISE EXCEPTION 'Aluno fora da turma';END IF;
   INSERT INTO public.lobby_chat_mutes(exam_id,student_id,muted)
   VALUES(e.id,p_student_id,p_muted)
   ON CONFLICT(exam_id,student_id) DO UPDATE SET muted=excluded.muted;
 END IF;
 SELECT * INTO c FROM public.lobby_chat_settings WHERE exam_id=e.id;
 RETURN jsonb_build_object('enabled',c.enabled,'peer_messages',c.peer_messages);
END;$fn$;

CREATE FUNCTION public.teacher_lobby_chat_read(p_exam_slug text,p_after bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;c public.lobby_chat_settings;v_messages jsonb;v_students jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso restrito ao professor';END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug;
 IF NOT FOUND THEN RAISE EXCEPTION 'Avaliação não encontrada';END IF;
 SELECT * INTO c FROM public.lobby_chat_settings WHERE exam_id=e.id;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',m.id,'body',m.body,'sender',coalesce(s.name,'Professor'),
   'recipient',CASE WHEN m.recipient_teacher THEN '@Professor'
    WHEN m.recipient_student_id IS NOT NULL THEN '@'||t.name
    ELSE 'Todos' END,
   'teacher_sender',m.sender_teacher) ORDER BY m.id),'[]'::jsonb)
 INTO v_messages
 FROM (SELECT * FROM public.lobby_chat_messages
 WHERE exam_id=e.id AND id>greatest(coalesce(p_after,0),0)
 ORDER BY id DESC LIMIT 50) m
 LEFT JOIN public.students s ON s.id=m.sender_student_id
 LEFT JOIN public.students t ON t.id=m.recipient_student_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,
  'muted',coalesce(z.muted,false)) ORDER BY s.name),'[]'::jsonb)
 INTO v_students FROM public.students s
 JOIN public.exam_supervision g ON g.exam_id=e.id AND s.class_group=g.class_group
 LEFT JOIN public.lobby_chat_mutes z ON z.exam_id=e.id AND z.student_id=s.id
 WHERE s.active;
 RETURN jsonb_build_object('enabled',coalesce(c.enabled,false),
 'peer_messages',coalesce(c.peer_messages,true),
 'students',v_students,'messages',v_messages);
END;$fn$;

CREATE FUNCTION public.teacher_lobby_chat_send(
 p_exam_slug text,p_body text,p_student_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='public'
AS $fn$
DECLARE e public.exams;g public.exam_supervision;v_body text;v_id bigint;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Acesso restrito ao professor';END IF;
 SELECT * INTO e FROM public.exams WHERE slug=p_exam_slug;
 SELECT * INTO g FROM public.exam_supervision WHERE exam_id=e.id;
 IF NOT coalesce(g.enabled,false) THEN RAISE EXCEPTION 'Sala desativada';END IF;
 v_body:=btrim(regexp_replace(coalesce(p_body,''),'[[:cntrl:]]','','g'));
 IF length(v_body) NOT BETWEEN 1 AND 150 THEN RAISE EXCEPTION 'Mensagem deve ter até 150 caracteres';END IF;
 IF p_student_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.students
  WHERE id=p_student_id AND class_group=g.class_group AND active)
 THEN RAISE EXCEPTION 'Destinatário fora da turma';END IF;
 INSERT INTO public.lobby_chat_messages(exam_id,sender_teacher,recipient_student_id,body)
 VALUES(e.id,true,p_student_id,v_body) RETURNING id INTO v_id;
 RETURN jsonb_build_object('ok',true,'id',v_id);
END;$fn$;

REVOKE ALL ON FUNCTION public._lobby_chat_student(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.student_lobby_chat_read(uuid,bigint),
 public.student_lobby_chat_send(uuid,text,text),
 public.teacher_lobby_chat_manage(text,boolean,boolean,uuid,boolean),
 public.teacher_lobby_chat_read(text,bigint),
 public.teacher_lobby_chat_send(text,text,uuid)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.student_lobby_chat_read(uuid,bigint),
 public.student_lobby_chat_send(uuid,text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.teacher_lobby_chat_manage(text,boolean,boolean,uuid,boolean),
 public.teacher_lobby_chat_read(text,bigint),
 public.teacher_lobby_chat_send(text,text,uuid) TO authenticated;
