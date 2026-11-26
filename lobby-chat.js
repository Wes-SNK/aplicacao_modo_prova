/* Comunicação da sala de espera.
 *  - polling a cada 13 s para não sobrecarregar Wi-Fi com 30 tablets;
 *  - mensagens somente texto, via textContent;
 *  - menciona colega conectado por identificador da sala, nunca por nome livre;
 *  - apenas no pátio: a RPC no PostgreSQL bloqueia também após saída;
 *  - nenhum listener é ligado ao modo de prova.
 */
(()=>{
 "use strict";
 const mp=window.ModeProva,u=window.LobbyChatUtils;
 const $=id=>document.getElementById(id);
 let token=null,active=false,busy=false,pollBusy=false,timer=null;
 let lastId=0,messages=[],peers=[],teacherOnly=false;
 const error=msg=>{$("lobbyChatStatus").textContent=msg;};
 function render(){
  const list=$("lobbyChatMessages");
  list.textContent="";
  messages.slice(-35).forEach(m=>{
   const row=document.createElement("div");
   row.className="lobby-chat-message"+(m.self?" mine":"")+
     (m.teacher_sender?" teacher":"");
   const caption=document.createElement("small");
   caption.textContent=(m.sender||"Colega")+" → "+(m.recipient||"Todos");
   const text=document.createElement("p");text.textContent=m.body;
   row.append(caption,text);list.appendChild(row);
  });
  if($("lobbyChatPanel").classList.contains("hidden"))return;
  list.scrollTop=list.scrollHeight;
 }
 function renderPeers(){
  const select=$("lobbyChatTarget"),selected=select.value;
  select.textContent="";
  const all=new Option("Toda a turma","");
  select.add(all);
  const teacher=new Option("@Professor","teacher");
  select.add(teacher);
  if(!teacherOnly)peers.filter(p=>!p.self).forEach(p=>{
   select.add(new Option("@"+u.handleLabel(p),p.id));
  });
  select.value=[...select.options].some(o=>o.value===selected)?selected:"";
 }
 function setEnabled(enabled,allowPeers,muted){
  const visible=!!enabled;
  $("lobbyChatToggle").classList.toggle("hidden",!visible);
  if(!visible){$("lobbyChatPanel").classList.add("hidden");}
  $("lobbyChatSend").disabled=!visible||!!muted;
  $("lobbyChatInput").disabled=!visible||!!muted;
  $("lobbyChatTarget").disabled=!visible||!!muted;
  teacherOnly=!allowPeers;
  if(muted)error("Envio temporariamente suspenso pelo professor.");
 }
 async function refresh(){
  if(!active||!token||pollBusy||document.hidden)return;
  pollBusy=true;
  try{
   const response=await mp.rpc("student_lobby_chat_read",{
    p_lobby_token:token,p_after:lastId
   });
   if(!active)return;
   setEnabled(response.enabled,response.peer_messages,response.muted);
   if(response.enabled){
    peers=Array.isArray(response.peers)?response.peers:[];
    const updates=Array.isArray(response.messages)?response.messages:[];
    messages=u.sortMessages(messages,updates);
    lastId=Math.max(lastId,...updates.map(m=>Number(m.id)||0),0);
    renderPeers();render();error("Conectado à conversa da turma.");
   }else{
    messages=[];lastId=0;render();
    error("Mensagens ainda não habilitadas pelo professor.");
   }
  }catch(e){error("Conversa indisponível. Verifique a conexão.");}
  finally{pollBusy=false;}
 }
 async function send(){
  if(!active||busy)return;
  let body;
  try{body=u.validate($("lobbyChatInput").value);}
  catch(e){error(e.message);return;}
  const selected=$("lobbyChatTarget").value;
  // Mensagem a @Professor fica reservada ao professor e ao remetente,
  // sem aparecer para os colegas nem virar uma mensagem pública.
  const teacherOnly=selected==="teacher";
  const recipient=selected&&!teacherOnly?selected:null;
  busy=true;$("lobbyChatSend").disabled=true;
  try{
   await mp.rpc("student_lobby_chat_send",{
    p_lobby_token:token,p_body:body,p_recipient:recipient,
    p_teacher_only:teacherOnly
   });
   $("lobbyChatInput").value="";
   await refresh();
  }catch(e){error(e.message||"Não foi possível enviar.");}
  finally{busy=false;$("lobbyChatSend").disabled=false;}
 }
 function open(lobbyToken){
  close();token=lobbyToken;active=true;lastId=0;messages=[];peers=[];
  $("lobbyChatPanel").classList.add("hidden");
  $("lobbyChatToggle").classList.add("hidden");
  refresh();
  timer=setInterval(refresh,13000);
 }
 function close(){
  active=false;token=null;clearInterval(timer);timer=null;
  pollBusy=false;lastId=0;messages=[];peers=[];
  $("lobbyChatPanel").classList.add("hidden");
  $("lobbyChatToggle").classList.add("hidden");
 }
 $("lobbyChatToggle").addEventListener("click",()=>{
  $("lobbyChatPanel").classList.toggle("hidden");
  if(!$("lobbyChatPanel").classList.contains("hidden"))refresh();
 });
 $("lobbyChatClose").addEventListener("click",()=>$("lobbyChatPanel").classList.add("hidden"));
 $("lobbyChatSend").addEventListener("click",send);
 $("lobbyChatInput").addEventListener("keydown",e=>{
  if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();send();}
 });
 $("lobbyChatQuick").addEventListener("click",e=>{
  const button=e.target.closest?.("[data-chat-quick]");
  if(!button)return;
  $("lobbyChatInput").value=button.dataset.chatQuick;
  $("lobbyChatInput").focus();
 });
 document.addEventListener("visibilitychange",()=>{if(!document.hidden)refresh();});
 mp.lobbyChat={open,close,refresh};
})();
