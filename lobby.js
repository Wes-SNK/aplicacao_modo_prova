/*
 * Sala de espera supervisionada (opt-in por avaliação).
 * Todos os estados críticos são validados pelo PostgreSQL.
 * Os avatares são pseudônimos: a turma não recebe os nomes dos colegas.
 */
(() => {
  "use strict";
  const mp = window.ModeProva;
  const $ = id => document.getElementById(id);
  const cacheKey = "modoProva:lobby:" + mp.cfg.examSlug;
  let token = null, approved = false, roomTimer = null, busy = false;
  let pos = {x:12,y:65}, lastMove = 0, peers = [], helpPending = false;
  let walkingTimer = null;
  let acceptEntry = null;
  let onScreen = false;
  let hasEntered = false;
  let immersiveFallback = false;
  const curiosities=Array.isArray(window.LobbyCuriosities)
    ? window.LobbyCuriosities : [];
  let curiosityQueue=[],curiosityIndex=0,lastCuriosityAt=0;
  let releaseAnnounced=false;
  function shuffleCuriosities() {
    curiosityQueue=curiosities.map((_,i)=>i);
    for(let i=curiosityQueue.length-1;i>0;i--){
      const j=Math.floor(Math.random()*(i+1));
      [curiosityQueue[i],curiosityQueue[j]]=[curiosityQueue[j],curiosityQueue[i]];
    }
    curiosityIndex=0;
  }
  function nextCuriosity(){
    if(!curiosities.length){
      $("lobbyCuriosityText").textContent=
        "Aproveite para explorar a escola virtual enquanto aguarda o professor.";
      $("lobbyCuriosityCount").textContent="";
      $("lobbyNextCuriosity").disabled=true;
      return;
    }
    if(curiosityIndex>=curiosityQueue.length)shuffleCuriosities();
    const index=curiosityQueue[curiosityIndex++];
    $("lobbyCuriosityText").textContent=curiosities[index];
    $("lobbyCuriosityCount").textContent=curiosityIndex+" / "+curiosities.length;
    lastCuriosityAt=Date.now();
  }
  function resetCuriosities(){
    shuffleCuriosities();
    nextCuriosity();
  }
  function showReleaseNotice(){
    if(releaseAnnounced)return;
    releaseAnnounced=true;
    $("lobbyReleaseNotice").classList.remove("hidden");
  }
  const lobbyScreen = () => $("screenLobby");
  function isImmersive() {
    return immersiveFallback || document.fullscreenElement === lobbyScreen();
  }
  function syncFullscreenButton() {
    const expanded = isImmersive();
    const button = $("lobbyFullscreenButton");
    button.textContent = expanded ? "⤢ Sair da tela cheia" : "⛶ Tela cheia";
    button.setAttribute("aria-pressed",String(expanded));
    button.title = expanded ? "Voltar ao tamanho normal" : "Expandir a escola para toda a tela";
  }
  function fallbackImmersive(enable) {
    immersiveFallback=enable;
    lobbyScreen().classList.toggle("lobby-immersive",enable);
    document.body.classList.toggle("lobby-no-scroll",enable);
    syncFullscreenButton();
  }
  async function toggleFullscreen() {
    if(!onScreen)return;
    if(isImmersive()){
      if(document.fullscreenElement===lobbyScreen() && document.exitFullscreen){
        try { await document.exitFullscreen(); } catch { fallbackImmersive(false); }
      }else fallbackImmersive(false);
      syncFullscreenButton();
      return;
    }
    if(typeof lobbyScreen().requestFullscreen==="function"){
      try {
        await lobbyScreen().requestFullscreen();
        syncFullscreenButton();
        return;
      }catch { /* Alguns navegadores móveis impedem tela cheia nativa. */ }
    }
    fallbackImmersive(true);
  }
  function exitImmersive() {
    if(document.fullscreenElement===lobbyScreen()){
      document.exitFullscreen?.().catch(()=>{});
    }
    fallbackImmersive(false);
  }

  function displayMessage(message,kind="info") {
    mp.setMessage($("lobbyApprovalMessage"),message,kind);
  }
  function resetRoom() {
    clearInterval(roomTimer);
    clearInterval(walkingTimer);walkingTimer=null;
    roomTimer = null; onScreen = false; approved = false;
    releaseAnnounced=false;
    $("lobbyReleaseNotice").classList.add("hidden");
    exitImmersive();
    token = null; peers = []; busy = false;
    sessionStorage.removeItem(cacheKey);
  }
  function status(name) {
    $("lobbyConnection").textContent = name;
  }
  function showRoom(studentName) {
    onScreen = true;
    $("lobbyStudentName").textContent = studentName
      ? "Bem-vindo(a), " + studentName + "." : "Aguardando o professor…";
    $("lobbyEnterExam").disabled = true;
    $("lobbyStatusBadge").textContent = "Aguardando";
    $("lobbyStatusBadge").className = "pill";
    displayMessage("Você entrou no pátio virtual. Aguarde o professor liberar sua prova.");
    releaseAnnounced=false;
    $("lobbyReleaseNotice").classList.add("hidden");
    resetCuriosities();
    updateAccessView();
    status("Conectando à sala de espera…");
  }
  function drawAvatars() {
    const root = $("lobbyAvatars");
    root.textContent = "";
    peers.forEach((p,i) => {
      const a = document.createElement("div");
      a.className = "lobby-avatar avatar-style-" + Number(p.style||0) + (p.self ? " own-avatar":"");
      a.style.left = Math.min(96,Math.max(4,Number(p.x)||12)) + "%";
      a.style.top = Math.min(91,Math.max(8,Number(p.y)||65)) + "%";
      a.setAttribute("role","img");
      a.setAttribute("aria-label",p.self?"Seu personagem":"Outro estudante aguardando");
      const head=document.createElement("span");
      head.className="avatar-head";
      const body=document.createElement("span");
      body.className="avatar-body";
      const feet=document.createElement("span");
      feet.className="avatar-feet";
      const label=document.createElement("small");
      label.textContent = p.self ? "Você" : "Colega";
      a.append(head,body,feet,label);
      if (p.emote) {
        const emote=document.createElement("span");
        emote.className="avatar-emote";
        emote.textContent = ({wave:"Olá!",question:"?",ready:"OK"})[p.emote] || "";
        a.appendChild(emote);
      }
      if(p.self) {pos={x:Number(p.x),y:Number(p.y)};}
      root.appendChild(a);
    });
    $("lobbySimpleStatus").textContent =
      "Você está aguardando com " + Math.max(0,peers.length-1) + " colega(s). " +
      (approved ? "Prova liberada." : "Aguardando liberação da prova.");
  }
  function updateAccessView() {
    const inMap=true;
    const simple=$("lobbySimpleMode").checked;
    $("lobbyMap").classList.toggle("hidden",simple);
    $("lobbySimpleStatus").classList.toggle("hidden",!simple);
    document.querySelector(".lobby-movement").classList.toggle("hidden",simple);
    $("lobbySimpleMode").disabled=false;
    $("lobbyHelpButton").classList.remove("hidden");
    $("lobbyEnterExam").disabled=!approved || busy;
    $("lobbyStatusBadge").textContent=approved?"Prova liberada":"Aguardando prova";
    $("lobbyStatusBadge").className=approved?"pill ok":"pill";
    displayMessage(approved
      ? "O professor liberou sua prova. Clique em Entrar na avaliação."
      : "Você está na sala de espera. Aguarde a liberação da prova pelo professor.",
      approved?"ok":"info");
  }
  async function poll() {
    if (!token || !onScreen || document.hidden) return;
    try {
      const result=await mp.rpc("student_lobby_state",{p_lobby_token:token});
      peers = Array.isArray(result.peers)?result.peers:[];
      helpPending=!!result.help_pending;
      $("lobbyHelpButton").textContent = helpPending ? "Cancelar pedido de ajuda" : "Preciso de ajuda";
      status(result.is_active ? "Conectado à escola • atualização automática"
        : "Avaliação temporariamente indisponível.");
      const nowApproved=!!result.authorized && !!result.is_active;
      if(nowApproved&&!approved)showReleaseNotice();
      approved=nowApproved;
      if(!approved && Date.now()-lastCuriosityAt>=24000)
        nextCuriosity();
      updateAccessView();
      drawAvatars();
    } catch(err) {
      status("Sem conexão com a sala. Suas respostas não foram afetadas; reconectando…");
    }
  }
  function beginPoll() {
    clearInterval(roomTimer);
    poll();
    roomTimer=setInterval(poll,4000);
  }
  function setSession(value,studentName) {
    token=value;
    sessionStorage.setItem(cacheKey,JSON.stringify({token,studentName}));
    showRoom(studentName);
    updateAccessView();
    beginPoll();
  }
  async function join(name,onEntry) {
    // Na prévia, o interceptador não tem acesso a dados reais de estudante.
    if(mp.teacherPreview) return false;
    acceptEntry=onEntry;
    let response;
    try {
      response=await mp.rpc("student_lobby_join",{
        p_exam_slug:mp.cfg.examSlug,p_student_name:name
      });
    } catch(err) {
      // Compatibilidade temporária com banco sem a migração de supervisão.
      // Um erro de rede ou de autorização NUNCA ativa o fallback.
      if(err.status===404) return false;
      throw err;
    }
    if (!response?.supervised) return false;
    if (!response.lobby_token) throw new Error("Não foi possível identificar a sala de espera");
    setSession(response.lobby_token,response.student_name||name);
    return true;
  }
  async function resume(onEntry) {
    if(mp.teacherPreview) return false;
    let stored;
    try { stored=JSON.parse(sessionStorage.getItem(cacheKey)||"null"); } catch {return false;}
    if (!stored?.token) return false;
    acceptEntry=onEntry;
    token=stored.token;
    showRoom(stored.studentName);
    beginPoll();
    return true;
  }
  async function enter() {
    if (!approved || busy || !token || !acceptEntry) return;
    busy=true;
    $("lobbyEnterExam").disabled=true;
    try {
      const payload=await mp.rpc("student_lobby_enter",{
        p_lobby_token:token,p_user_agent:navigator.userAgent
      });
      hasEntered=true;
      // A prova usa sua própria política de tela cheia. Saia primeiro da
      // sala virtual para não exibir uma tela vazia durante a transição.
      if(document.fullscreenElement===lobbyScreen()){
        try { await document.exitFullscreen(); } catch {}
      }
      resetRoom();
      acceptEntry(payload);
    } catch(err) {
      displayMessage(err.message||"Não foi possível entrar. Solicite ajuda ao professor.","error");
      busy=false; $("lobbyEnterExam").disabled=!approved;
    }
  }
  async function move(dx,dy,emote=null,auto=false) {
    if(!auto){clearInterval(walkingTimer);walkingTimer=null;}
    if(!token || !onScreen || $("lobbySimpleMode").checked) return;
    if(!emote && Date.now()-lastMove<150) return;
    lastMove=Date.now();
    const next=window.SupervisionUtils.clampPosition(pos.x+dx,pos.y+dy);
    if(dx||dy)pos=next;
    const self=peers.find(p=>p.self);
    if(self){self.x=pos.x;self.y=pos.y;if(emote)self.emote=emote;drawAvatars();}
    try {
      await mp.rpc("student_lobby_move",{
        p_lobby_token:token,p_x:pos.x,p_y:pos.y,p_emote:emote
      });
    } catch{status("Reconectando movimentação…");}
  }
  function walkToPoint(event) {
    if(!onScreen || !token || $("lobbySimpleMode").checked)return;
    const map=$("lobbyMap");
    const bounds=map.getBoundingClientRect();
    if(!bounds.width||!bounds.height)return;
    const target=window.SupervisionUtils.clampPosition(
      (event.clientX-bounds.left)/bounds.width*100,
      (event.clientY-bounds.top)/bounds.height*100);
    clearInterval(walkingTimer);
    walkingTimer=setInterval(()=>{
      if(!onScreen || $("lobbySimpleMode").checked){
        clearInterval(walkingTimer);walkingTimer=null;return;
      }
      const dx=target.x-pos.x,dy=target.y-pos.y;
      if(Math.abs(dx)<2.4 && Math.abs(dy)<2.4){
        clearInterval(walkingTimer);walkingTimer=null;return;
      }
      // Um passo por atualização: evita teletransporte e preserva os
      // controles de posição já existentes no Supabase.
      move(Math.sign(dx)*Math.min(5,Math.abs(dx)),
        Math.sign(dy)*Math.min(5,Math.abs(dy)),null,true);
    },180);
  }
  async function requestHelp() {
    if(!token || !onScreen) return;
    try{
      const r=await mp.rpc("student_lobby_help",{
        p_lobby_token:token,p_request:!helpPending
      });
      helpPending=!!r.help_pending;
      $("lobbyHelpButton").textContent=helpPending?"Cancelar pedido de ajuda":"Preciso de ajuda";
      displayMessage(helpPending
        ?"Pedido de ajuda enviado ao professor.":"Pedido de ajuda cancelado.");
    }catch{displayMessage("Não foi possível enviar o pedido. Confira a conexão.","warn");}
  }
  function setup() {
    const actions=[
      ["lobbyMoveUp",0,-5],["lobbyMoveDown",0,5],
      ["lobbyMoveLeft",-5,0],["lobbyMoveRight",5,0]
    ];
    actions.forEach(([id,x,y])=>$(id).addEventListener("click",()=>move(x,y)));
    [["lobbyEmoteWave","wave"],["lobbyEmoteQuestion","question"],
      ["lobbyEmoteReady","ready"]].forEach(([id,name])=>
      $(id).addEventListener("click",()=>move(0,0,name)));
    $("lobbyHelpButton").addEventListener("click",requestHelp);
    $("lobbyNextCuriosity").addEventListener("click",nextCuriosity);
    $("lobbyDismissRelease").addEventListener("click",()=>{
      $("lobbyReleaseNotice").classList.add("hidden");
    });
    $("lobbyFullscreenButton").addEventListener("click",toggleFullscreen);
    $("lobbyMap").addEventListener("click",walkToPoint);
    document.addEventListener("fullscreenchange",syncFullscreenButton);
    $("lobbyEnterExam").addEventListener("click",enter);
    $("lobbySimpleMode").addEventListener("change",updateAccessView);
    document.addEventListener("keydown",e=>{
      if (!onScreen)return;
      if(e.key==="Escape" && immersiveFallback){
        fallbackImmersive(false);
        return;
      }
      if (["INPUT","TEXTAREA","SELECT"].includes(document.activeElement?.tagName)) return;
      if ((e.key==="f"||e.key==="F") && !$("lobbySimpleMode").checked){
        e.preventDefault();
        toggleFullscreen();
        return;
      }
      if($("lobbySimpleMode").checked)return;
      const dirs={ArrowUp:[0,-5],ArrowDown:[0,5],ArrowLeft:[-5,0],
        ArrowRight:[5,0],w:[0,-5],s:[0,5],a:[-5,0],d:[5,0]};
      const d=dirs[e.key];if(d){e.preventDefault();move(...d);}
    });
    syncFullscreenButton();
    document.addEventListener("visibilitychange",()=>{
      if(onScreen && !document.hidden)poll();
    });
  }
  setup();
  mp.lobbyBridge={join,resume,reset:resetRoom};
})();
