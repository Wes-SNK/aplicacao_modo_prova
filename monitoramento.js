/*
 * Monitoramento e controle de turma — atualização periódica a cada 5 segundos.
 * Sem gabaritos nem conteúdo de respostas no painel de presença.
 * Todas as autorizações e leituras são validadas pelas RPCs autenticadas.
 */
(() => {
  "use strict";
  const mp=window.ModeProva;
  const $=id=>document.getElementById(id);
  let data=null,loading=false,changing=false,dirty=false,requestVersion=0;
  const formatTime=seconds=>{
    if(seconds==null)return "—";
    const n=Math.max(0,Number(seconds));
    return Math.floor(n/60)+"m "+String(n%60).padStart(2,"0")+"s";
  };
  const escapeCsv=x=>'"'+String(x??"").replaceAll('"','""')+'"';
  const secSince=(date,now=Date.now())=>date ? Math.max(0,(now-Date.parse(date))/1000) : Infinity;
  const isRecent=(date,now)=>secSince(date,now)<=25;
  function announce(s){$("supervisionMessage").textContent=s;}
  const studentPage = () => {
    const slug=mp.cfg.examSlug;
    const qs=/^preset-[0-9a-f]{32}$/.test(slug)
      ? "?exame="+encodeURIComponent(slug)
      : slug==="simulado-4bim-1b-2026" ? "?avaliacao=simulado"
        : slug==="prova-4bim-1b-2026" ? "?avaliacao=prova" : "";
    return new URL("index.html"+qs,window.location.href).href;
  };
  function syncStudentLink(){
    $("supervisionStudentLink").href=studentPage();
    const a=document.querySelector(".supervision-guide a[href='avaliacoes.html']");
    if(a) a.href="avaliacoes.html"+window.location.search;
  }
  function renderInstructions(){
    if(!data)return;
    const msg=data.preview_only
      ? "Você está visualizando "+data.class_group+", mas a avaliação continua vinculada a "+
        (data.configured_class_group||"nenhuma turma")+
        ". Para liberar provas dessa turma, confirme a vinculação em Vincular turma à avaliação."
      : !data.enabled
      ? "Selecione a turma e clique em Vincular turma à avaliação. A entrada na sala de espera é automática, mas iniciar a prova exige sua liberação."
      : !data.is_active
        ? "Os estudantes já podem entrar no pátio virtual. Para iniciar a prova, libere os alunos e publique a avaliação em Avaliações e presets."
        : "Compartilhe o link com a turma. Cada aluno entra diretamente no pátio ao informar seu nome. Quando desejar, clique em Liberar prova. O cronômetro só começa quando o aluno confirmar as regras.";
    $("supervisionInstructions").textContent=msg;
  }
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
    $("supervisionStatusBadge").textContent=data.preview_only
      ?"Visualização — outra turma vinculada"
      : data.enabled?"Supervisão ligada":"Supervisão desativada";
    $("supervisionStatusBadge").className=data.enabled?"pill ok":"pill";
    renderInstructions();
    if(!dirty){
      const sel=$("supervisionClass");
      const old=sel.value;
      sel.textContent="";
      const none=new Option("Selecione uma turma…","");
      sel.appendChild(none);
      (data.classes||[]).forEach(name=>sel.appendChild(new Option(name,name)));
      sel.value=data.class_group||old||"";
    }
    const students=Array.isArray(data.students)?data.students:[];
    const pendingHelp=students.filter(s=>s.help_pending);
    const helpAlert=$("supervisionHelpAlert");
    helpAlert.classList.toggle("hidden",!pendingHelp.length);
    helpAlert.textContent=pendingHelp.length
      ? "Atenção: "+pendingHelp.length+" aluno(s) solicitando ajuda — "+
        pendingHelp.map(s=>s.name).join(", ")+". Localize o aluno na tabela e clique em Atendido após prestar auxílio."
      : "";
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
      if(s.help_pending)tr.classList.add("supervision-needs-help");
      const name=cell(tr,s.name,"supervision-student");
      if(s.help_pending){
        const help=document.createElement("strong");
        help.className="supervision-help";
        help.textContent="Precisa de ajuda";
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
      // Entrar no pátio é automático; somente o início da prova exige autorização.
      if(data.enabled && !data.preview_only && !hasStarted){
        td.appendChild(action(s.authorized?"Bloquear início":"Liberar prova",
          ()=>authorize(s,!s.authorized),s.authorized?"secondary":"primary"));
      }
      if(s.help_pending)td.appendChild(action("Atendido",()=>resolveHelp(s)));
      if(!td.children.length)td.textContent="—";
      body.appendChild(tr);
    }
    if(!visible.length){
      const empty=document.createElement("tr");
      const td=cell(empty,data.class_group
        ?(students.length?"Nenhum estudante corresponde ao filtro.":"Não há estudantes ativos nesta turma.")
        :"Selecione uma turma para visualizar os estudantes.");
      td.colSpan=6;body.appendChild(empty);
    }
    $("supervisionAuthorizeAll").disabled=changing ||
      !window.SupervisionUtils.canRequestExam(
        students.filter(s=>isRecent(s.last_seen,Date.now())),data.enabled && !data.preview_only);
  }
  function showSwitchingClass() {
    data=null;
    $("supervisionRows").textContent="";
    $("supervisionHelpAlert").classList.add("hidden");
    $("supervisionHelpAlert").textContent="";
    for(const id of ["supervisionTotal","supervisionWaiting",
      "supervisionInProgress","supervisionFinished"])$(id).textContent="—";
    $("supervisionAuthorizeAll").disabled=true;
    $("supervisionStatusBadge").textContent="Consultando turma…";
    announce("Carregando estudantes de "+($("supervisionClass").value||"turma selecionada")+"…");
  }
  async function withTimeout(promise,ms=12000){
    let id;
    try{
      return await Promise.race([promise,new Promise((_,reject)=>{
        id=setTimeout(()=>reject(new Error("Tempo limite de consulta excedido.")),ms);
      })]);
    }finally{clearTimeout(id);}
  }
  async function refresh(force=false){
    if(document.body.dataset.teacherPage!=="sala" ||
       changing || $("teacherDashboard").classList.contains("hidden"))return;
    if(loading && !force)return;
    const version=++requestVersion;
    const selectedGroup=$("supervisionClass").value;
    loading=true;
    $("supervisionStatusBadge").textContent="Consultando turmas…";
    announce("Consultando os alunos cadastrados…");
    try{
      const result=await withTimeout(trpc("teacher_supervision_roster_by_class",{
        p_exam_slug:mp.cfg.examSlug,
        p_class_group:selectedGroup||null
      }));
      if(version!==requestVersion)return;
      if(!result || !Array.isArray(result.students))throw new Error("Resposta inesperada");
      data=result;render();
      announce("Turma "+(result.class_group||"não selecionada")+": "+
        result.students.length+" estudante(s) ativo(s)."+
        (result.preview_only?" Visualização apenas: salve a vinculação para liberar a prova.":""));
    }catch(err){
      if(version!==requestVersion)return;
      const error=err.message||String(err);
      // Em caso de falha do módulo de monitoramento, o cadastro autenticado
      // ainda pode mostrar as turmas sem autorizar ninguém a iniciar a prova.
      try{
        const saved=await trpc("teacher_students_list");
        if(version!==requestVersion)return;
        if(!Array.isArray(saved))throw new Error("Cadastro inválido");
        const active=saved.filter(student=>student.active);
        const classes=[...new Set(active.map(student=>student.class_group)
          .filter(Boolean))].sort((a,b)=>a.localeCompare(b,"pt-BR"));
        const group=selectedGroup||"";
        data={
          enabled:false,preview_only:true,class_group:group,
          configured_class_group:null,is_active:false,
          server_time:new Date().toISOString(),
          classes,students:active.filter(student=>student.class_group===group)
            .map(student=>({...student,status:"not_started",waiting:false,
              authorized:false,answered:0,total:0,occurrences:0}))
        };
        render();
        announce("Monitoramento temporariamente indisponível ("+error+
          "). As turmas foram carregadas do cadastro; a liberação de prova permanece bloqueada.");
      }catch(fallbackErr){
        if(version!==requestVersion)return;
        $("supervisionStatusBadge").textContent="Erro ao consultar";
        announce("Não foi possível carregar as turmas: "+error+
          ". Erro no cadastro: "+(fallbackErr.message||fallbackErr)+
          ". Atualize a página ou entre novamente.");
      }
    }finally{
      if(version===requestVersion)loading=false;
    }
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
    if(!group){announce("Escolha uma turma antes de vincular.");return;}
    if(!window.confirm("Vincular a turma "+group+" a esta avaliação?"+
      "\nOs alunos entrarão diretamente na sala de espera e você liberará o início da prova."+
      "\nA alteração é exclusiva desta avaliação."))return;
    await perform(async()=>{
      const res=await trpc("teacher_supervision_configure_v3",{
        p_exam_slug:mp.cfg.examSlug,p_class_group:group,p_enabled:true
      });
      if(!res?.ok)throw new Error("Configuração não confirmada.");
      announce("Turma "+group+" vinculada à avaliação com supervisão do início.");
    });
    await refresh(true);
    dirty=false;
    if(data)render();
  }
  async function authorize(s,yes){
    if(!window.confirm((yes?"Liberar início da prova para ":"Bloquear início da prova de ")+s.name+"?"))return;
    await perform(async()=>{
      const r=await trpc("teacher_supervision_authorize",{
        p_exam_slug:mp.cfg.examSlug,p_student_id:s.id,p_authorize:yes
      });
      if(!r?.ok)throw new Error("Ação não confirmada.");
    });await refresh(true);
  }
  async function authorizeAll(){
    const candidates=(data?.students||[]).filter(s=>s.waiting&&!s.authorized&&
      isRecent(s.last_seen,Date.now()));
    if(!candidates.length)return;
    if(!window.confirm("Liberar a prova para "+candidates.length+
      " estudante(s) presentes na sala de espera? Não inclui ausentes.\nO cronômetro começará somente quando cada aluno iniciar a prova."))return;
    await perform(async()=>{
      const r=await trpc("teacher_supervision_authorize_all",{
        p_exam_slug:mp.cfg.examSlug
      });
      if(!r?.ok)throw new Error("Liberação não confirmada.");
      announce(r.authorized_count+" estudantes autorizados.");
    });await refresh(true);
  }
  async function resolveHelp(s){
    await perform(async()=>{
      const r=await trpc("teacher_supervision_resolve_help",{
        p_exam_slug:mp.cfg.examSlug,p_student_id:s.id
      });
      if(!r?.ok)throw new Error("Atendimento não confirmado.");
    });await refresh(true);
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
  $("supervisionCopyLink").addEventListener("click",async()=>{
    const url=studentPage();
    try {
      await navigator.clipboard.writeText(url);
      announce("Link da avaliação copiado. Envie aos estudantes da turma.");
    } catch {
      window.prompt("Copie o link da sala de espera:",url);
    }
  });
  syncStudentLink();
  $("supervisionRefresh").addEventListener("click",refresh);
  $("supervisionAuthorizeAll").addEventListener("click",authorizeAll);
  $("supervisionExport").addEventListener("click",exportCsv);
  $("supervisionFilter").addEventListener("input",render);
  $("supervisionClass").addEventListener("change",()=>{
    dirty=true;
    showSwitchingClass();
    refresh(true);
  });
  window.addEventListener("modo-prova:teacher-ready",refresh);
  window.addEventListener("modo-prova:teacher-logout",()=>{
    data=null;dirty=false;requestVersion++;
    $("supervisionRows").textContent="";
    $("supervisionHelpAlert").classList.add("hidden");
    $("supervisionHelpAlert").textContent="";
    announce("Entre como professor para acompanhar a turma.");
  });
  setInterval(refresh,5000);
  if(!$("teacherDashboard").classList.contains("hidden"))refresh();
})();
