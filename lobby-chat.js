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
 let lastId=0,messages=[],peers=[],teacherOnly=false,canSend=false;
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
  canSend=visible&&!muted;
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
    const hadHistory=lastId>0;
    lastId=Math.max(lastId,...updates.map(m=>Number(m.id)||0),0);
    renderPeers();render();
    if(hadHistory)updates.filter(m=>m.public_message&&!m.self&&m.sender_id)
      .slice(-2).forEach(m=>mp.lobbyBridge?.showBubble?.(m.sender_id,m.body));
    if(!response.muted)error("Conectado à conversa da turma.");
   }else{
    messages=[];lastId=0;render();
    error("Mensagens ainda não habilitadas pelo professor.");
   }
  }catch(e){error("Conversa indisponível. Verifique a conexão.");}
  finally{pollBusy=false;}
 }
 function renderMentions(){
  const box=$("lobbyChatMentions");
  box.textContent="";
  const input=$("lobbyChatInput").value;
  const match=input.match(/(?:^|\s)@([\wÀ-ÿ-]*)$/);
  if(!match){box.classList.add("hidden");return;}
  const fragment=match[1].toLocaleLowerCase("pt-BR");
  const candidates=[{id:"teacher",handle:"Professor"},
    ...(!teacherOnly?peers.filter(p=>!p.self).map(p=>({
      id:p.id,handle:u.handleLabel(p)})):[])];
  const filtered=candidates.filter(p=>
    p.handle.toLocaleLowerCase("pt-BR").includes(fragment)).slice(0,8);
  box.classList.toggle("hidden",!filtered.length);
  for(const target of filtered){
    const button=document.createElement("button");
    button.type="button";button.className="secondary small";
    button.textContent="@"+target.handle;
    button.setAttribute("role","option");
    button.addEventListener("click",()=>{
      $("lobbyChatTarget").value=target.id;
      $("lobbyChatInput").value=input.replace(/@([\wÀ-ÿ-]*)$/,
        "@"+target.handle+" ");
      box.classList.add("hidden");
      $("lobbyChatInput").focus();
    });
    box.appendChild(button);
  }
 }
 async function send(){
  if(!active||busy||!canSend)return;
  let body;
  try{body=u.validate($("lobbyChatInput").value);}
  catch(e){error(e.message);return;}
  let selected=$("lobbyChatTarget").value;
  // Menções textuais são resolvidas para IDs que o servidor retornou.
  // Nunca considerar nomes digitados como identificadores confiáveis.
  const mention=body.match(/^@([\wÀ-ÿ-]+)\s*(.*)$/s);
  if(mention){
    const handle=mention[1].toLocaleLowerCase("pt-BR");
    if(handle==="professor")selected="teacher";
    else{
      const target=peers.find(p=>!p.self &&
        u.handleLabel(p).toLocaleLowerCase("pt-BR")===handle);
      if(!target){error("Escolha um destinatário válido na lista de @.");return;}
      selected=target.id;
    }
    try{body=u.validate(mention[2]);}catch(e){error(e.message);return;}
  }
  // O backend mapeia o identificador reservado "teacher" à caixa do professor.
  const recipient=selected||null;
  busy=true;$("lobbyChatSend").disabled=true;
  try{
   await mp.rpc("student_lobby_chat_send",{
    p_lobby_token:token,p_body:body,p_recipient:recipient
   });
   $("lobbyChatInput").value="";
   await refresh();
  }catch(e){error(e.message||"Não foi possível enviar.");}
  finally{busy=false;$("lobbyChatSend").disabled=!canSend;}
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
  $("lobbyChatMentions").classList.add("hidden");
 }
 $("lobbyChatToggle").addEventListener("click",()=>{
  $("lobbyChatPanel").classList.toggle("hidden");
  if(!$("lobbyChatPanel").classList.contains("hidden"))refresh();
 });
 $("lobbyChatClose").addEventListener("click",()=>$("lobbyChatPanel").classList.add("hidden"));
 $("lobbyChatSend").addEventListener("click",send);
 $("lobbyChatInput").addEventListener("input",renderMentions);
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
