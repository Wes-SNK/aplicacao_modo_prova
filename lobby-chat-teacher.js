/* Moderação autenticada: este módulo usa apenas os RPCs de professor.
 * A troca de avaliação reinicializa a página, sem misturar turmas.
 * No frontend, as mensagens são sempre textContent, nunca innerHTML.
 */
(()=>{
 "use strict";
 if(document.body.dataset.teacherPage!=="painel")return;
 const mp=window.ModeProva,u=window.LobbyChatUtils;
 const $=id=>document.getElementById(id);
 let busy=false,pollBusy=false,lastId=0,active=false;
 let saved={enabled:false,peer_messages:false},messages=[];
 const notice=text=>{$("teacherChatStatus").textContent=text;};
 async function rpc(name,args={}){
  const session=await mp.validTeacherSession();
  if(!session?.access_token)throw new Error("Entre novamente como professor.");
  return mp.rpc(name,{p_exam_slug:mp.cfg.examSlug,...args},session.access_token);
 }
 function addChoices(select,rows,placeholder){
  const selected=select.value;select.textContent="";
  select.add(new Option(placeholder,""));
  rows.forEach(s=>select.add(new Option(s.name,s.id)));
  select.value=[...select.options].some(o=>o.value===selected)?selected:"";
 }
 function render(){
  const box=$("teacherChatMessages");box.textContent="";
  messages.slice(-40).forEach(m=>{
   const item=document.createElement("div");item.className="teacher-chat-item";
   const title=document.createElement("strong");
   title.textContent=m.sender+" → "+(m.teacher_only?"@Professor":m.recipient);
   const body=document.createElement("p");body.textContent=m.body;
   item.append(title,body);box.appendChild(item);
  });
  box.scrollTop=box.scrollHeight;
 }
 async function refresh(){
  if(!active||busy||pollBusy||document.hidden)return;
  pollBusy=true;
  try{
   const [setting,data,roster]=await Promise.all([
    rpc("teacher_lobby_chat_settings"),
    rpc("teacher_lobby_chat_read",{p_after:lastId}),
    rpc("teacher_supervision_roster_by_class")
   ]);
   if(!active)return;
   saved=setting;
   $("teacherChatEnabled").checked=!!saved.enabled;
   $("teacherChatPeerEnabled").checked=!!saved.peer_messages;
   const update=Array.isArray(data.messages)?data.messages:[];
   messages=u.sortMessages(messages,update,80);
   lastId=Math.max(lastId,...update.map(m=>Number(m.id)||0),0);
   render();
   const linked=roster.enabled&&!roster.preview_only;
   const students=linked?roster.students.filter(s=>s.active!==false):[];
   addChoices($("teacherChatRecipient"),students,"Toda a turma");
   addChoices($("teacherChatMuteStudent"),students,"Selecione um aluno");
   $("teacherChatSend").disabled=!saved.enabled||!linked;
   $("teacherChatMute").disabled=!linked;
   $("teacherChatUnmute").disabled=!linked;
   $("teacherChatSave").disabled=!linked;
   notice(linked?"Conversa supervisionada atualizada.":"Vincule a turma antes de ativar a comunicação.");
  }catch(e){notice("Não foi possível consultar o chat: "+(e.message||e));}
  finally{pollBusy=false;}
 }
 async function perform(callback){
  if(busy)return;
  busy=true;
  try{await callback();await refreshDirect();}
  catch(e){notice(e.message||"Falha no chat.");}
  finally{busy=false;}
 }
 async function refreshDirect(){const was=active;active=true;await refresh();active=was;}
 function save(){
  perform(async()=>{
   const result=await rpc("teacher_lobby_chat_settings",{
    p_enabled:$("teacherChatEnabled").checked,
    p_peer_messages:$("teacherChatPeerEnabled").checked
   });
   if(!result||typeof result.enabled!=="boolean")throw new Error("Configuração não confirmada.");
   saved=result;notice("Configuração de comunicação salva.");
  });
 }
 function send(){
  let body;
  try{body=u.validate($("teacherChatInput").value);}
  catch(e){notice(e.message);return;}
  perform(async()=>{
   const r=await rpc("teacher_lobby_chat_send",{
    p_body:body,p_recipient:$("teacherChatRecipient").value||null
   });
   if(!r.ok)throw new Error("Envio não confirmado.");
   $("teacherChatInput").value="";
  });
 }
 function mute(yes){
  const id=$("teacherChatMuteStudent").value;
  if(!id){notice("Selecione um estudante.");return;}
  perform(async()=>{
   const r=await rpc("teacher_lobby_chat_mute",{p_student_id:id,p_muted:yes});
   if(!r.ok)throw new Error("Moderação não confirmada.");
   notice(yes?"Aluno silenciado.":"Permissão de envio restaurada.");
  });
 }
 $("teacherChatSave").addEventListener("click",save);
 $("teacherChatSend").addEventListener("click",send);
 $("teacherChatMute").addEventListener("click",()=>mute(true));
 $("teacherChatUnmute").addEventListener("click",()=>mute(false));
 $("teacherChatInput").addEventListener("keydown",e=>{
  if(e.key==="Enter"){e.preventDefault();send();}
 });
 window.addEventListener("modo-prova:teacher-ready",()=>{active=true;refresh();});
 window.addEventListener("modo-prova:teacher-logout",()=>{
  active=false;messages=[];lastId=0;render();
 });
 if(!$("teacherDashboard").classList.contains("hidden")){active=true;refresh();}
 // Chat consulta em ritmo independente: não bloqueia nem multiplica o polling
 // do monitoramento principal e permite salas com cerca de 30 alunos.
 setInterval(refresh,12000);
})();
