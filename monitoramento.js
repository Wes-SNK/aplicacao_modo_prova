/*
 * Monitoramento e controle de turma — atualização periódica a cada 5 segundos.
 * Sem gabaritos nem conteúdo de respostas no painel de presença.
 * Todas as autorizações e leituras são validadas pelas RPCs autenticadas.
 */
(() => {
  "use strict";
  const mp=window.ModeProva;
  const $=id=>document.getElementById(id);
  let data=null,loading=false,changing=false,dirty=false;
  const formatTime=seconds=>{
    if(seconds==null)return "—";
    const n=Math.max(0,Number(seconds));
    return Math.floor(n/60)+"m "+String(n%60).padStart(2,"0")+"s";
  };
  const escapeCsv=x=>'"'+String(x??"").replaceAll('"','""')+'"';
  const secSince=(date,now=Date.now())=>date ? Math.max(0,(now-Date.parse(date))/1000) : Infinity;
  const isRecent=(date,now)=>secSince(date,now)<=25;
  function announce(s){$("supervisionMessage").textContent=s;}
  async function trpc(name,args={}){
    const session=await mp.validTeacherSession();
    if(!session?.access_token)throw new Error("Entre novamente como professor.");
    return mp.rpc(name,args,session.access_token);
  }
  function cell(row,text,className){
    const el=document.createElement("td");
    if(className)el.className=className;
    if(text!=null)el.textContent=String(text);
    row.appendChild(el);
    return el;
  }
  function action(label,fn,cls="secondary",disabled=false){
    const b=document.createElement("button");
    b.type="button";
    b.textContent=label;
    b.className="small "+cls;
    b.disabled=disabled || changing;
    b.addEventListener("click",fn);
    return b;
  }
  const deriveState=s=>window.SupervisionUtils.studentStatus(s);
  const connectionText=(s,now)=>window.SupervisionUtils.connectionStatus(
    s.last_seen,s.waiting,["in_progress","ready"].includes(s.status),now);
  function progressCell(row,s){
    const outer=cell(row,null,"supervision-progress-cell");
    const total=Number(s.total)||0;
    const answered=Math.min(total,Number(s.answered)||0);
    const label=document.createElement("span");
    label.textContent=answered+" / "+total+" respondidas";
    const track=document.createElement("div");
    track.className="supervision-progress-track";
    track.setAttribute("role","progressbar");
    track.setAttribute("aria-label","Respostas registradas de "+s.name);
    track.setAttribute("aria-valuemin","0");
    track.setAttribute("aria-valuemax",String(total||1));
    track.setAttribute("aria-valuenow",String(answered));
    const bar=document.createElement("div");
    bar.style.width=window.SupervisionUtils.progressPercent(answered,total)+"%";
    track.appendChild(bar);outer.append(label,track);
  }
  function render(){
    if(!data)return;
    $("supervisionStatusBadge").textContent=data.enabled?"Supervisão ligada":"Supervisão desativada";
    $("supervisionStatusBadge").className=data.enabled?"pill ok":"pill";
    if(!dirty){
      const sel=$("supervisionClass");
      const old=sel.value;
      sel.textContent="";
      const none=new Option("Selecione uma turma…","");
      sel.appendChild(none);
      (data.classes||[]).forEach(name=>sel.appendChild(new Option(name,name)));
      sel.value=data.class_group||old||"";
      $("supervisionEnabled").checked=!!data.enabled;
      $("supervisionRequireCode").checked=!!data.require_code;
    }
    const students=Array.isArray(data.students)?data.students:[];
    const now=Date.parse(data.server_time)||Date.now();
    $("supervisionTotal").textContent=students.length;
    $("supervisionWaiting").textContent=students.filter(s=>s.waiting && !s.authorized
      && !["submitted","auto_submitted","in_progress"].includes(s.status)).length;
    $("supervisionInProgress").textContent=students.filter(s=>s.status==="in_progress").length;
    $("supervisionFinished").textContent=students.filter(s=>["submitted","auto_submitted"].includes(s.status)).length;
    const filter=$("supervisionFilter").value.trim().toLocaleLowerCase("pt-BR");
    const body=$("supervisionRows");
    body.textContent="";
    const visible=students.filter(s=>s.name.toLocaleLowerCase("pt-BR").includes(filter));
    for(const s of visible){
      const tr=document.createElement("tr");
      const name=cell(tr,s.name,"supervision-student");
      if(s.help_pending){
        const help=document.createElement("strong");
        help.className="supervision-help";
        help.textContent=" Solicita ajuda";
        name.appendChild(help);
      }
      cell(tr,deriveState(s,now));
      progressCell(tr,s);
      cell(tr,s.status==="in_progress"?formatTime(s.remaining_seconds):"—");
      const connection=cell(tr,connectionText(s,now));
      if(s.waiting && !isRecent(s.last_seen,now) &&
        !["submitted","auto_submitted"].includes(s.status))
        connection.classList.add("supervision-offline");
      const td=cell(tr,null,"supervision-actions");
      const hasStarted=["in_progress","submitted","auto_submitted"].includes(s.status);
      if(data.enabled && s.waiting && !hasStarted){
        td.appendChild(action(s.authorized?"Revogar":"Autorizar",
          ()=>authorize(s,!s.authorized),s.authorized?"secondary":"primary"));
      }
      if(s.help_pending)td.appendChild(action("Atendido",()=>resolveHelp(s)));
      if(!td.children.length)td.textContent="—";
      body.appendChild(tr);
    }
    if(!visible.length){
      const empty=document.createElement("tr");
      const td=cell(empty,data.class_group
        ?"Nenhum estudante corresponde ao filtro.":"Selecione uma turma e salve as configurações.");
      td.colSpan=6;body.appendChild(empty);
    }
    $("supervisionAuthorizeAll").disabled=changing ||
      !window.SupervisionUtils.canRequestExam(
        students.filter(s=>isRecent(s.last_seen,Date.now())),data.enabled);
  }
  async function refresh(){
    if(loading || changing || $("teacherDashboard").classList.contains("hidden"))return;
    loading=true;
    try{
      const result=await trpc("teacher_supervision_roster",{
        p_exam_slug:mp.cfg.examSlug
      });
      if(!result || !Array.isArray(result.students))throw new Error("Resposta inesperada");
      data=result;render();
      announce("Atualizado em "+new Date().toLocaleTimeString("pt-BR")+
        ". A lista mostra todos os estudantes ativos da turma selecionada.");
    }catch(err){
      announce(err.status===404
        ?"Módulo ainda não ativado no banco. A migração de supervisão será aplicada após homologação."
        :"Não foi possível atualizar: "+(err.message||err));
    }finally{loading=false;}
  }
  async function perform(callback){
    if(changing)return;
    changing=true;
    $("supervisionSave").disabled=true;
    $("supervisionAuthorizeAll").disabled=true;
    try{await callback();}
    catch(err){announce("Operação não concluída: "+(err.message||err));}
    finally{changing=false;$("supervisionSave").disabled=false;render();}
  }
  async function save(){
    const group=$("supervisionClass").value;
    const enabled=$("supervisionEnabled").checked;
    const requireCode=$("supervisionRequireCode").checked;
    if(!group){announce("Escolha uma turma antes de salvar.");return;}
    if(!window.confirm((enabled
      ?"Ativar supervisão e exigir autorização individual de início?"
      :"Desativar a exigência de autorização para esta avaliação?")+
      "\nTurma: "+group+"\nEssa alteração é exclusiva desta avaliação."))return;
    await perform(async()=>{
      const res=await trpc("teacher_supervision_configure_v2",{
        p_exam_slug:mp.cfg.examSlug,p_class_group:group,p_enabled:enabled,
        p_require_code:requireCode
      });
      if(!res?.ok)throw new Error("Configuração não confirmada.");
      dirty=false;
      announce("Configuração salva para "+group+".");
    });
    await refresh();
  }
  async function issueCodes(){
    const group=$("supervisionClass").value;
    if(!group){announce("Selecione a turma antes de gerar códigos.");return;}
    if(!window.confirm("Gerar NOVOS códigos para todos os estudantes ativos de "+
      group+"? Os códigos anteriores deixarão de funcionar.\n"+
      "O CSV contém dados de acesso: guarde e distribua individualmente."))return;
    await perform(async()=>{
      const rows=await trpc("teacher_student_issue_codes",{p_class_group:group});
      if(!Array.isArray(rows)||!rows.length)throw new Error("Nenhum código retornado.");
      const csv=[["Aluno","Código"],...rows.map(r=>[r.name,r.code])];
      mp.downloadText("codigos-"+group.replace(/[^a-z0-9_-]/gi,"-")+".csv",
        "\uFEFF"+csv.map(r=>r.map(escapeCsv).join(",")).join("\r\n"),
        "text/csv;charset=utf-8");
      announce(rows.length+" códigos gerados e salvos em CSV. Não publique esse arquivo.");
      window.dispatchEvent(new Event("modo-prova:students-updated"));
    });
  }
  async function authorize(s,yes){
    if(!window.confirm((yes?"Autorizar início para ":"Revogar autorização de ")+s.name+"?"))return;
    await perform(async()=>{
      const r=await trpc("teacher_supervision_authorize",{
        p_exam_slug:mp.cfg.examSlug,p_student_id:s.id,p_authorize:yes
      });
      if(!r?.ok)throw new Error("Ação não confirmada.");
    });await refresh();
  }
  async function authorizeAll(){
    const candidates=(data?.students||[]).filter(s=>s.waiting&&!s.authorized&&
      isRecent(s.last_seen,Date.now()));
    if(!candidates.length)return;
    if(!window.confirm("Autorizar "+candidates.length+
      " estudante(s) presentes na sala de espera? Não inclui ausentes."))return;
    await perform(async()=>{
      const r=await trpc("teacher_supervision_authorize_all",{
        p_exam_slug:mp.cfg.examSlug
      });
      if(!r?.ok)throw new Error("Liberação não confirmada.");
      announce(r.authorized_count+" estudantes autorizados.");
    });await refresh();
  }
  async function resolveHelp(s){
    await perform(async()=>{
      const r=await trpc("teacher_supervision_resolve_help",{
        p_exam_slug:mp.cfg.examSlug,p_student_id:s.id
      });
      if(!r?.ok)throw new Error("Atendimento não confirmado.");
    });await refresh();
  }
  function exportCsv(){
    const students=data?.students||[];
    if(!students.length){announce("Nenhuma turma carregada para exportação.");return;}
    const rows=[["Nome","Turma","Situação","Respondidas","Questões",
      "Tempo restante (s)","Última comunicação","Pedido de ajuda","Ocorrências"]];
    const now=Date.now();
    for(const s of students)rows.push([s.name,s.class_group,deriveState(s,now),
      s.answered,s.total,s.remaining_seconds??"",s.last_seen??"",
      s.help_pending?"Sim":"Não",s.occurrences]);
    mp.downloadText("monitoramento-"+mp.cfg.examSlug+".csv","\uFEFF"+
      rows.map(row=>row.map(escapeCsv).join(",")).join("\r\n"),"text/csv;charset=utf-8");
  }
  $("supervisionSave").addEventListener("click",save);
  $("supervisionIssueCodes").addEventListener("click",issueCodes);
  $("supervisionRefresh").addEventListener("click",refresh);
  $("supervisionAuthorizeAll").addEventListener("click",authorizeAll);
  $("supervisionExport").addEventListener("click",exportCsv);
  $("supervisionFilter").addEventListener("input",render);
  $("supervisionClass").addEventListener("change",()=>{dirty=true;});
  $("supervisionEnabled").addEventListener("change",()=>{dirty=true;});
  $("supervisionRequireCode").addEventListener("change",()=>{dirty=true;});
  window.addEventListener("modo-prova:teacher-ready",refresh);
  window.addEventListener("modo-prova:teacher-logout",()=>{
    data=null;dirty=false;$("supervisionRows").textContent="";
    announce("Entre como professor para acompanhar a turma.");
  });
  setInterval(refresh,5000);
  if(!$("teacherDashboard").classList.contains("hidden"))refresh();
})();
