const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const vm=require("node:vm");
const root=path.resolve(__dirname,"..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const rules=require("../supervision-utils.js");

test("Movimentação dentro do mapa: limites e entrada inválida",()=>{
 assert.deepEqual(rules.clampPosition(120,-10),{x:96,y:8});
 assert.deepEqual(rules.clampPosition(12,65),{x:12,y:65});
 assert.throws(()=>rules.clampPosition("abc",20),TypeError);
});
test("Progresso: porcentagem sem valores negativos ou acima do total",()=>{
 assert.equal(rules.progressPercent(7,20),35);
 assert.equal(rules.progressPercent(100,20),100);
 assert.equal(rules.progressPercent(-1,20),0);
 assert.equal(rules.progressPercent(0,0),0);
});
test("Estados distintos: ausente, espera, autorizado, realizando e finalizado",()=>{
 assert.equal(rules.studentStatus({status:"not_started"}),"Ainda não entrou");
 assert.equal(rules.studentStatus({waiting:true,status:"not_started"}),"No pátio — aguardando liberação");
 assert.equal(rules.studentStatus({lobby_requested:true,lobby_allowed:false,status:"not_started"}),"Na sala de espera");
 assert.equal(rules.studentStatus({waiting:true,authorized:true,status:"not_started"}),"Autorizado");
 assert.equal(rules.studentStatus({waiting:false,authorized:true,status:"not_started"}),"Prova liberada — ainda não entrou");
 assert.equal(rules.studentStatus({status:"in_progress"}),"Realizando");
 assert.equal(rules.studentStatus({status:"auto_submitted"}),"Finalizado");
});
test("Indicador de conexão não confunde queda de sinal com infração",()=>{
 const now=Date.parse("2026-11-26T12:00:00Z");
 assert.equal(rules.connectionStatus(new Date(now-20000).toISOString(),true,false,now),"Conectado");
 assert.match(rules.connectionStatus(new Date(now-40000).toISOString(),true,false,now),/instável/);
 assert.equal(rules.connectionStatus(new Date(now-200000).toISOString(),true,false,now),"Sem conexão recente");
 assert.equal(rules.connectionStatus(null,false,false,now),"—");
});
test("Liberação coletiva: somente estudantes que realmente chegaram",()=>{
 assert.equal(rules.canRequestExam([{waiting:false,authorized:false}],true),false);
 assert.equal(rules.canRequestExam([{waiting:true,authorized:true}],true),false);
 assert.equal(rules.canRequestExam([{waiting:true,authorized:false}],false),false);
 assert.equal(rules.canRequestExam([{waiting:true,authorized:false}],true),true);
});
test("Todos os arquivos JavaScript passam no parser",()=>{
 for(const name of ["config.js","common.js","student.js","professor.js","presets.js",
 "preview-aluno.js","supervision-utils.js","lobby.js","monitoramento.js","alunos.js",
 "teacher-login.js","teacher-pages.js"]){
  assert.doesNotThrow(()=>new Function(read(name)),name);
 }
});
test("Todos os IDs usados pelos módulos existem nas páginas correspondentes",()=>{
 const ids=html=>new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
 const lookup=js=>[...new Set([...js.matchAll(/\$\("([^"]+)"\)/g)].map(x=>x[1]))];
 const teacher=ids(read("professor-shell.html")),student=ids(read("index.html")),
 preview=ids(read("preview-aluno.html"));
 for(const name of ["professor.js","presets.js","monitoramento.js","alunos.js"]){
  assert.deepEqual(lookup(read(name)).filter(x=>!teacher.has(x)),[],name);
 }
 for(const name of ["student.js","lobby.js"]){
  assert.deepEqual(lookup(read(name)).filter(x=>!student.has(x)),[],name+" index");
  assert.deepEqual(lookup(read(name)).filter(x=>!preview.has(x)),[],name+" preview");
 }
});
test("Módulos carregados na ordem segura; prévia sem chamadas reais",()=>{
 for(const page of ["index.html","preview-aluno.html"]){
  const scripts=[...read(page).matchAll(/<script src="([^"]+)"/g)].map(x=>x[1]);
  assert.ok(scripts.indexOf("supervision-utils.js")<scripts.indexOf("lobby.js"));
  assert.ok(scripts.indexOf("lobby.js")<scripts.indexOf("student.js"));
 }
 const preview=read("preview-aluno.js");
 assert.match(preview,/mp\.rpc = previewRpc/);
 assert.match(preview,/Ação não disponível na prévia/);
 assert.match(read("student.js"),/teacherPreview/);
});
test("O fluxo SQL exige autorização no servidor e bloqueia atalhos legados",()=>{
 const a=read("migrations/013_supervisao_sala_espera.sql");
 const b=read("migrations/014_gates_inicio_avaliacao.sql");
 const c=read("migrations/015_ajuda_auditoria.sql");
 const d=read("migrations/016_turma_codigos.sql");
 assert.match(a,/CREATE TABLE public\.exam_supervision/);
 assert.match(a,/CREATE TABLE public\.exam_lobby/);
 assert.match(a,/student_lobby_join/);
 assert.match(a,/teacher_supervision_authorize_all/);
 assert.match(b,/Esta avaliação exige entrada pela sala de espera/);
 assert.match(b,/Aguarde a autorização do professor/);
 assert.match(b,/student_lobby_enter/);
 assert.match(b,/IF NOT l\.authorized THEN/);
 assert.match(c,/CREATE TABLE public\.exam_supervision_audit/);
 assert.match(c,/student_exam_help/);
 assert.match(d,/teacher_student_save/);
 assert.match(d,/teacher_student_issue_codes/);
 assert.match(d,/Código individual inválido/);
 assert.match(d,/teacher_supervision_configure_v2/);
 assert.doesNotMatch(a+b+c+d,/service_role|sb_secret_/);
});
test("A supervisão é opt-in; uma queda de internet não deve criar ocorrência",()=>{
 const code=read("student.js")+read("lobby.js")+read("monitoramento.js");
 assert.match(code,/student_lobby_join/);
 assert.match(code,/recordViolation/);
 assert.doesNotMatch(read("lobby.js"),/record_violation/);
 assert.match(read("monitoramento.js"),/Conexão estimada|last_seen|connectionText/);
});
function node(tag="div"){
 const events={};
 return {
  tagName:tag.toUpperCase(),className:"",classList:(()=>{
    const values=new Set();
    return {add(name){values.add(name);},remove(name){values.delete(name);},
      toggle(name,force){const enabled=force===undefined?!values.has(name):force;
        if(enabled)values.add(name);else values.delete(name);return enabled;},
      contains(name){return values.has(name);}};
  })(),
  textContent:"",value:"",disabled:false,checked:false,style:{},children:[],
  addEventListener(name,fn){events[name]=fn;},
  async emit(name,evt={}){return events[name]?.(evt);},
  append(...items){this.children.push(...items);},
  appendChild(child){this.children.push(child);},
  setAttribute(){},
 };
}
test("Fluxo integrado simulado: aguardar -> autorização -> entrada, sem antecipar token",async()=>{
 const src=read("lobby.js");
 const elements={};
 const find=id=>elements[id]??=(node());
 const intervals=[];
 const calls=[];
 let authorized=false,received=null;
 const mp={
  cfg:{examSlug:"simulado-4bim-1b-2026"},teacherPreview:false,
  setMessage(el,msg,kind){el.textContent=msg;el.kind=kind;},
  rpc:async(name,args)=>{
   calls.push(name);
   if(name==="student_lobby_join")return{
    supervised:true,lobby_token:"fake-lobby-token",
    student_name:"Estudante Teste",authorized:false,lobby_allowed:false};
   if(name==="student_lobby_state")return{
    is_active:true,authorized,peers:[{id:"anon-1",x:12,y:65,style:0,self:true}],help_pending:false};
   if(name==="student_lobby_enter"){
    if(!authorized)throw Error("Unauthorized");
    return{session_token:"fake-attempt-token",questions:[]};
   }
   if(name==="student_lobby_move"||name==="student_lobby_help")return{ok:true,help_pending:true};
   throw Error("Unexpected RPC "+name);
  }
 };
 const facts=require("../lobby-curiosities.js");
 const win={ModeProva:mp,SupervisionUtils:rules,LobbyCuriosities:facts};
 const doc={
  hidden:false,activeElement:node(),body:node("body"),
  fullscreenElement:null,
  getElementById:find,createElement:node,
  querySelector(){return node();},addEventListener(){}
 };
 const store=new Map();
 const sessionStorage={
  setItem(k,v){store.set(k,v);},getItem(k){return store.get(k)||null;},
  removeItem(k){store.delete(k);}
 };
 vm.runInNewContext(src,{
  window:win,document:doc,navigator:{userAgent:"test"},sessionStorage,
  setInterval:fn=>{intervals.push(fn);return intervals.length;},
  clearInterval(){},Date,console,Promise
 });
 const present=await mp.lobbyBridge.join("Estudante Teste",payload=>received=payload);
 assert.equal(present,true);
 await new Promise(setImmediate);
 assert.ok(find("lobbyCuriosityText").textContent.length>35,
  "Uma curiosidade deve surgir ao ingressar na sala");
 const firstFact=find("lobbyCuriosityText").textContent;
 await find("lobbyNextCuriosity").emit("click");
 assert.notEqual(find("lobbyCuriosityText").textContent,firstFact,
  "O botão Outra curiosidade deve variar o conteúdo");
 assert.equal(find("lobbyReleaseNotice").classList.contains("hidden"),true,
  "Aviso de liberação não deve aparecer antes da autorização");
 // Navegadores sem requestFullscreen usam modo imersivo CSS sem
 // desativar o restante da interface da sala de espera.
 await find("lobbyFullscreenButton").emit("click");
 assert.match(find("lobbyFullscreenButton").textContent,/Sair da tela cheia/);
 await find("lobbyFullscreenButton").emit("click");
 assert.match(find("lobbyFullscreenButton").textContent,/Tela cheia/);
 // Em navegadores com API de tela cheia, o componente completo é expandido.
 find("screenLobby").requestFullscreen=async()=>{doc.fullscreenElement=find("screenLobby");};
 doc.exitFullscreen=async()=>{doc.fullscreenElement=null;};
 await find("lobbyFullscreenButton").emit("click");
 assert.equal(doc.fullscreenElement,find("screenLobby"));
 assert.match(find("lobbyFullscreenButton").textContent,/Sair da tela cheia/);
 await find("lobbyFullscreenButton").emit("click");
 assert.equal(doc.fullscreenElement,null);
 assert.equal(find("lobbyEnterExam").disabled,true);
 assert.equal(calls.includes("student_lobby_enter"),false);
 authorized=true;
 await intervals.at(-1)();
 await new Promise(setImmediate);
 assert.equal(find("lobbyReleaseNotice").classList.contains("hidden"),false,
  "O aluno deve receber aviso visual quando autorizado");
 await find("lobbyDismissRelease").emit("click");
 assert.equal(find("lobbyReleaseNotice").classList.contains("hidden"),true);
 await intervals.at(-1)();
 assert.equal(find("lobbyReleaseNotice").classList.contains("hidden"),true,
  "O aviso dispensado não deve reaparecer a cada consulta");
 assert.equal(find("lobbyEnterExam").disabled,false);
 await find("lobbyEnterExam").emit("click");
 assert.equal(received.session_token,"fake-attempt-token");
 assert.equal(store.size,0);
 assert.equal(calls.filter(s=>s==="student_lobby_enter").length,1);
});

test("Login exclusivo: nenhuma opção de presets ou turma aparece antes de autenticar",()=>{
 const login=read("professor.html");
 assert.match(login,/id="teacherLoginForm"/);
 assert.match(login,/teacher-login\.js/);
 assert.doesNotMatch(login,/id="presetManager"|id="studentManager"|id="supervisionPanel"/);
 assert.doesNotMatch(login,/id="teacherMainNav"|data-page-link/);
 assert.doesNotMatch(login,/professor\.js|presets\.js/);
});
test("Páginas distintas com layout compartilhado e controles preservados",()=>{
 const shell=read("professor-shell.html");
 const scripts=read("teacher-pages.js");
 const sections=["painel","questoes","avaliacoes","alunos"];
 for(const page of sections){
  const markup=read(page+".html");
  assert.match(markup,new RegExp('data-teacher-page="'+page+'"'));
  assert.match(markup,/teacher-pages\.js/);
  assert.match(shell,new RegExp('data-page-link="'+page+'"'));
  assert.match(shell,new RegExp('data-page-area="'+page+'"'));
 }
 assert.match(scripts,/validTeacherSession/);
 assert.match(scripts,/if\(!session\?\.access_token\)/);
 assert.match(scripts,/fetch\("professor-shell\.html"/);
 assert.match(scripts,/teacher-area-disabled/);
 assert.match(scripts,/teacher_presets_list/);
 for(const id of ["presetManager","supervisionPanel","studentManager",
  "questionBankPanel","questionList","attemptsTable","btnToggleSimuladoOnline"]){
  assert.match(shell,new RegExp('id="'+id+'"'));
 }
});
test("Rotas antigas vão à página correspondente sem abrir o login com presets",()=>{
 const preview=read("preview-aluno.js"),presets=read("presets.js");
 assert.match(preview,/painel\.html\?exame=/);
 assert.match(presets,/avaliacoes\.html\?exame=/);
 assert.match(presets,/questoes\.html/);
 assert.match(read("teacher-login.js"),/window\.location\.replace\(destination\(\)\)/);
});

test("Pré-autorização tem controle próprio e não confunde presença",()=>{
 const sql=read("migrations/017_autorizacao_antecipada.sql");
 const monitor=read("monitoramento.js");
 const shell=read("professor-shell.html");
 assert.match(sql,/requested_at DROP NOT NULL/);
 assert.match(sql,/requested_at IS NOT NULL/);
 assert.match(sql,/INSERT INTO public\.exam_lobby/);
 assert.doesNotMatch(monitor,/Permitir sala de espera/);
 assert.match(monitor,/Liberar prova/);
 assert.match(shell,/id="supervisionStudentLink"/);
 assert.match(shell,/id="supervisionCopyLink"/);
 assert.match(read(".github/workflows/supervision-tests.yml"),/supervision-preauth\.sql/);
});

test("Duas permissões independentes; códigos individuais removidos da interface",()=>{
 const sql=read("migrations/018_duas_permissoes_sem_codigos.sql");
 assert.match(sql,/teacher_supervision_lobby_access/);
 assert.match(sql,/lobby_allowed/);
 assert.match(sql,/DROP FUNCTION IF EXISTS public.student_lobby_join\(text,text,text\)/);
 assert.match(sql,/DROP FUNCTION IF EXISTS public.teacher_student_issue_codes/);
 assert.match(sql,/UPDATE public.students SET access_code=NULL/);
 for(const name of ["index.html","preview-aluno.html","professor-shell.html"]){
  assert.doesNotMatch(read(name),/studentAccessCodeInput|supervisionRequireCode|supervisionIssueCodes/);
 }
 assert.doesNotMatch(read("lobby.js"),/p_access_code|studentAccessCodeInput/);
 assert.doesNotMatch(read("monitoramento.js"),/teacher_student_issue_codes|teacher_supervision_configure_v2/);
 assert.match(read("monitoramento.js"),/teacher_supervision_configure_v3/);
 assert.doesNotMatch(read("monitoramento.js"),/teacher_supervision_lobby_access/);
 assert.doesNotMatch(read("lobby.js"),/lobbyAllowed/);
 assert.match(read("lobby.js"),/Você entrou no pátio virtual/);
});

test("Ingresso direto na sala: único bloqueio é a liberação da prova",()=>{
 const migration=read("migrations/019_entrada_direta_patio.sql");
 const lobby=read("lobby.js");
 const monitor=read("monitoramento.js");
 assert.match(migration,/requested_at=now\(\)/);
 assert.match(migration,/lobby_allowed=true/);
 assert.match(migration,/REVOKE ALL ON FUNCTION public\.teacher_supervision_lobby_access/);
 assert.match(lobby,/Aguarde o professor liberar sua prova/);
 assert.doesNotMatch(lobby,/Aguarde a autorização do professor para ingressar/);
 assert.doesNotMatch(monitor,/function allowLobby/);
 assert.match(monitor,/Liberar prova/);
});

test("Mapa de escola detalhado, responsivo e com expansão explícita",()=>{
 const svg=read("school-map.svg");
 const css=read("styles.css");
 const js=read("lobby.js");
 for(const label of ["ESCOLA VIRTUAL","LABORATÓRIO DE INFORMÁTICA","BIBLIOTECA","PÁTIO","QUADRA"]){
  assert.ok(svg.includes(label),"Mapa sem área: "+label);
 }
 assert.match(svg,/viewBox="0 0 1200 720"/);
 assert.match(css,/background:[^;]*school-map\.svg/);
 assert.match(css,/\.student-lobby:fullscreen/);
 assert.match(css,/\.student-lobby\.lobby-immersive/);
 assert.match(css,/aspect-ratio:5\/3/);
 assert.match(js,/requestFullscreen\(\)/);
 assert.match(js,/exitFullscreen/);
 assert.match(js,/fullscreenchange/);
 assert.match(js,/lobbyFullscreenButton/);
 for(const name of ["index.html","preview-aluno.html"]){
  const html=read(name);
  assert.match(html,/id="lobbyFullscreenButton"/);
  assert.match(html,/id="lobbyMap"/);
  assert.match(html,/id="lobbyAvatars"/);
 }
});

test("Curiosidades são conteúdo educativo local, sem questões ou rede",()=>{
 const facts=require("../lobby-curiosities.js");
 assert.ok(Array.isArray(facts));
 assert.ok(facts.length>=15);
 assert.ok(new Set(facts).size===facts.length);
 for(const fact of facts){
  assert.equal(typeof fact,"string");
  assert.ok(fact.length>=45 && fact.length<=180);
  assert.doesNotMatch(fact,/https?:\/\/|javascript:|<script/i);
 }
 const src=read("lobby-curiosities.js");
 assert.doesNotMatch(src,/fetch\(|XMLHttpRequest|supabase/i);
 assert.match(read("lobby.js"),/24000/);
 assert.match(read("lobby.js"),/releaseAnnounced/);
 for(const p of ["index.html","preview-aluno.html"]){
  const html=read(p);
  assert.match(html,/id="lobbyCuriosityText"/);
  assert.match(html,/id="lobbyNextCuriosity"/);
  assert.match(html,/id="lobbyReleaseNotice"/);
  assert.match(html,/id="lobbyDismissRelease"/);
  assert.match(html,/role="status" aria-live="polite"/);
  assert.ok(html.indexOf('src="lobby-curiosities.js"')<
    html.indexOf('src="lobby.js"'));
 }
});

test("Troca de turma no painel não mantém alunos de TESTE nem libera outra turma",()=>{
 const monitor=read("monitoramento.js");
 const sql=read("migrations/020_visualizacao_turma_selecionada.sql");
 assert.match(monitor,/teacher_supervision_roster_by_class/);
 assert.match(monitor,/p_class_group:selectedGroup\|\|null/);
 assert.match(monitor,/supervisionClass"\)\.addEventListener\("change"/);
 assert.match(monitor,/showSwitchingClass\(\)/);
 assert.match(monitor,/refresh\(true\)/);
 assert.match(monitor,/requestVersion/);
 assert.match(monitor,/!data\.preview_only && !hasStarted/);
 assert.match(monitor,/data\.enabled && !data\.preview_only/);
 assert.match(monitor,/Visualização apenas: salve a vinculação/);
 assert.match(sql,/configured_class_group/);
 assert.match(sql,/preview_only/);
 assert.match(sql,/s\.class_group=v_target/);
 assert.match(sql,/IF auth\.uid\(\) IS NULL/);
 assert.match(read(".github/workflows/supervision-tests.yml"),/tests\/supervision-class-switch\.sql/);
});

test("Avatares reduzidos no mapa sem alterar a lógica de movimentação",()=>{
 const css=read("styles.css");
 assert.match(css,/transform:translate\(-50%,-54%\) scale\(\.75\)/);
 assert.match(css,/\.lobby-avatar\{transform:translate\(-50%,-53%\) scale\(\.52\);\}/);
 assert.match(css,/\.lobby-avatar\.own-avatar/);
 assert.match(read("lobby.js"),/student_lobby_move/);
});
