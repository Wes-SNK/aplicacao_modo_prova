/* Comunicação supervisionada do professor.
 * Módulo independente: nunca modifica o estado das avaliações,
 * nem autoriza tentativas. Chamadas sempre com sessão autenticada.
 */
(()=>{
 "use strict";
 if(document.body.dataset.teacherPage!=="sala")return;
 const mp=window.ModeProva,$=id=>document.getElementById(id);
 const utils=window.LobbyChatUtils;
 let last=0,items=[],students=[],busy=false,pollBusy=false,editing=false;
 const notice=s=>{$("teacherChatStatus").textContent=s;};
 async function rpc(name,args={}){
  const session=await mp.validTeacherSession();
  if(!session?.access_token)throw new Error("Entre novamente como professor.");
  return mp.rpc(name,args,session.access_token);
 }
 function updateSelect(id,rows,{emptyLabel,includeAll=false}={}){
  const select=$(id),old=select.value;
  select.textContent="";
  select.add(new Option(emptyLabel||"Selecione…",""));
  rows.forEach(s=>select.add(new Option(
    s.name+(s.muted?" (silenciado)":""),s.id)));
  select.value=[...select.options].some(o=>o.value===old)?old:"";
 }
 function render(){
  const root=$("teacherChatMessages");
  root.textContent="";
  items.slice(-50).forEach(m=>{
   const article=document.createElement("div");
   article.className="teacher-chat-message";
   const caption=document.createElement("small");
   caption.textContent=(m.sender||"Estudante")+" → "+(m.recipient||"Turma");
   const text=document.createElement("p");text.textContent=m.body;
   article.append(caption,text);root.appendChild(article);
  });
  root.scrollTop=root.scrollHeight;
 }
 async function refresh(){
  if(pollBusy||busy||document.hidden)return;
  pollBusy=true;
  try{
   const result=await rpc("teacher_lobby_chat_read",{
    p_exam_slug:mp.cfg.examSlug,p_after:last
   });
   if(!result||!Array.isArray(result.messages))throw new Error("Resposta inválida");
   items=utils.sortMessages(items,result.messages,80);
   last=Math.max(last,...result.messages.map(x=>Number(x.id)||0),0);
   students=Array.isArray(result.students)?result.students:[];
   if(!editing){
    $("teacherChatEnabled").checked=!!result.enabled;
    $("teacherChatPeers").checked=!!result.peer_messages;
   }
   $("teacherChatBadge").textContent=result.enabled?"Conversa habilitada":"Conversa desativada";
   $("teacherChatBadge").className=result.enabled?"pill ok":"pill";
   updateSelect("teacherChatRecipient",students,{emptyLabel:"Toda a turma"});
   updateSelect("teacherChatMuteStudent",students,{emptyLabel:"Selecione um estudante…"});
   render();
   notice("Histórico atualizado. Mensagens direcionadas também são visíveis ao professor.");
  }catch(e){
   notice("Comunicação ainda indisponível: "+
    (e.message||"Verifique a migração 021.")+
    " O monitoramento e a liberação de provas continuam funcionando.");
  }finally{pollBusy=false;}
 }
 async function run(fn){
  if(busy)return;
  busy=true;
  try{await fn();await refreshAfterWrite();}
  catch(e){notice(e.message||"Não foi possível concluir a ação.");}
  finally{busy=false;}
 }
 async function refreshAfterWrite(){
  // Evita que a trava de gravação bloqueie a primeira leitura pós-salvamento.
  busy=false;
  try{await refresh();}finally{busy=true;}
 }
 $("teacherChatEnabled").addEventListener("change",()=>{editing=true;});
 $("teacherChatPeers").addEventListener("change",()=>{editing=true;});
 $("teacherChatSaveSettings").addEventListener("click",()=>run(async()=>{
  await rpc("teacher_lobby_chat_manage",{
   p_exam_slug:mp.cfg.examSlug,
   p_enabled:$("teacherChatEnabled").checked,
   p_peer_messages:$("teacherChatPeers").checked
  });
  editing=false;
  notice("Configuração de conversa salva.");
 }));
 $("teacherChatSend").addEventListener("click",()=>run(async()=>{
  const body=utils.validate($("teacherChatInput").value);
  await rpc("teacher_lobby_chat_send",{
   p_exam_slug:mp.cfg.examSlug,p_body:body,
   p_student_id:$("teacherChatRecipient").value||null
  });
  $("teacherChatInput").value="";
 }));
 for(const [button,muted] of [["teacherChatMute",true],["teacherChatUnmute",false]]){
  $(button).addEventListener("click",()=>run(async()=>{
   const id=$("teacherChatMuteStudent").value;
   if(!id)throw new Error("Selecione um estudante.");
   await rpc("teacher_lobby_chat_manage",{
    p_exam_slug:mp.cfg.examSlug,p_student_id:id,p_muted:muted
   });
  }));
 }
 document.addEventListener("visibilitychange",()=>{
  if(!document.hidden)refresh();
 });
 refresh();
 // O histórico é incremental; não acompanha movimentações dos avatares.
 setInterval(refresh,12000);
})();