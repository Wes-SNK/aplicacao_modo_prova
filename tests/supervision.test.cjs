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
 assert.equal(rules.studentStatus({lobby_requested:true,lobby_allowed:false,status:"not_started"}),"Aguardando entrada no pátio");
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
  tagName:tag.toUpperCase(),className:"",classList:{
    add(){},remove(){},toggle(){}},
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
    student_name:"Estudante Teste",authorized:false};
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
 const win={ModeProva:mp,SupervisionUtils:rules};
 const doc={
  hidden:false,activeElement:node(),
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
 assert.equal(find("lobbyEnterExam").disabled,true);
 assert.equal(calls.includes("student_lobby_enter"),false);
 authorized=true;
 await intervals.at(-1)();
 await new Promise(setImmediate);
 assert.equal(find("lobbyEnterExam").disabled,false);
 await find("lobbyEnterExam").emit("click");
 assert.equal(received.session_token,"fake-attempt-token");
 assert.equal(store.size,0);
 assert.equal(calls.filter(s=>s==="student_lobby_enter").length,1);
});

test("Código individual é opcional e a ativação tardia é bloqueada",()=>{
 const frontend=read("lobby.js");
 const migration=read("migrations/016_turma_codigos.sql");
 assert.match(frontend,/p_access_code:/);
 assert.match(migration,/v_super\.require_code/);
 assert.match(migration,/códigos depois de estudantes entrarem/);
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
 assert.match(monitor,/Autorizar antecipadamente/);
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
 assert.match(read("monitoramento.js"),/teacher_supervision_lobby_access/);
 assert.match(read("lobby.js"),/lobbyAllowed/);
 assert.match(read("lobby.js"),/Aguarde a autorização do professor para ingressar na sala de espera/);
});
