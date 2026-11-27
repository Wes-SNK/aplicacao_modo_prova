const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const read=p=>fs.readFileSync(p,"utf8");
const shell=read("professor-shell.html");
const loader=read("teacher-pages.js");
const monitor=read("monitoramento.js");
const chat=read("chat-professor.js");
const help=read("teacher-help-summary.js");

test("sala de espera dispõe de rota autenticada e navegação própria",()=>{
  const page=read("sala-espera.html");
  assert.match(page,/data-teacher-page="sala"/);
  assert.match(page,/teacher-pages\.js\?rev=/);
  assert.match(loader,/const session=await mode\.validTeacherSession\(\)/);
  assert.match(loader,/if\(!session\?\.access_token\)\{goToLogin\(\);return;\}/);
  assert.match(shell,/href="sala-espera\.html" data-page-link="sala"/);
  assert.match(read("teacher-login.js"),/painel\|sala-espera\|questoes/);
  assert.match(loader,/sala:\{title:"Sala de espera"/);
});

test("módulos de supervisão e comunicação só executam na sala",()=>{
  assert.match(shell,/id="supervisionPanel" data-page-area="sala"/);
  assert.match(shell,/id="teacherChatSection" data-page-area="sala"/);
  assert.match(monitor,/document\.body\.dataset\.teacherPage!=="sala"/);
  assert.match(chat,/document\.body\.dataset\.teacherPage!=="sala"/);
  assert.match(loader,/if\(page==="sala"\)/);
  assert.match(loader,/await loadScript\("monitoramento\.js"\)/);
  assert.match(loader,/await loadScript\("lobby-chat-utils\.js"\)/);
  assert.match(loader,/await loadScript\("chat-professor\.js"\)/);
  assert.doesNotMatch(loader,/for\(const src of \[[^\]]*"monitoramento\.js"/);
});

test("salvamento de turma, liberações, acompanhamento e chat preservam RPCs",()=>{
 for(const fn of ["teacher_supervision_roster_by_class","teacher_supervision_configure_v3",
   "teacher_supervision_authorize","teacher_supervision_authorize_all",
   "teacher_supervision_resolve_help"])
   assert.ok(monitor.includes(fn),fn);
 for(const fn of ["teacher_lobby_chat_read","teacher_lobby_chat_send","teacher_lobby_chat_manage"])
   assert.ok(chat.includes(fn),fn);
});

test("painel mantém resultados e histórico com resumo de pedidos de ajuda",()=>{
 const professor=read("professor.js");
 assert.match(shell,/id="teacherHelpSummary" data-page-area="painel"/);
 assert.match(shell,/id="attemptsTable"/);
 assert.match(shell,/id="gradeHistoryTable"/);
 assert.match(professor,/teacher_dashboard/);
 assert.match(professor,/renderGradeHistory/);
 assert.match(loader,/if\(page==="painel"\)await loadScript\("teacher-help-summary\.js"\)/);
 assert.match(help,/teacher_supervision_roster_by_class/);
 assert.match(help,/s\.help_pending/);
 assert.match(help,/pending\.map\(s=>s\.name\)/);
 assert.match(help,/link\.href="sala-espera\.html"\+window\.location\.search/);
});

test("trocar turma e logout não deixam alertas incorretos",()=>{
 assert.match(monitor,/function showSwitchingClass\(\)/);
 assert.match(monitor,/supervisionHelpAlert/);
 assert.match(monitor,/modo-prova:teacher-logout/);
 assert.match(help,/modo-prova:teacher-logout/);
 assert.match(help,/panel\.classList\.add\("hidden"\)/);
 assert.match(help,/Não foi possível verificar os pedidos de ajuda/);
});

test("links de páginas mantêm a avaliação ao alternar entre seções",()=>{
 assert.match(loader,/a\.href=a\.getAttribute\("href"\)\.split\("\?"\)\[0\]\+window\.location\.search/);
 assert.match(loader,/window\.location\.href=path\+target/);
 for(const p of ["painel.html","sala-espera.html","questoes.html","avaliacoes.html","alunos.html"]){
   assert.match(read(p),/data-teacher-page="/);
   assert.match(read(p),/teacher-pages\.js\?rev=20261127-sala-dedicada-1/);
 }
});

test("todos os campos da sala continuam disponíveis no shell",()=>{
 for(const id of ["supervisionClass","supervisionSave","supervisionRefresh",
   "supervisionRows","supervisionAuthorizeAll","supervisionHelpAlert","supervisionFilter",
   "teacherChatEnabled","teacherChatPeers","teacherChatSend","teacherChatMessages",
   "teacherChatMuteStudent","teacherChatUnmute"]){
   assert.ok(shell.includes('id="'+id+'"'),id);
 }
 const ids=[...shell.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
 assert.equal(ids.length,new Set(ids).size,"IDs HTML duplicados");
});

test("resumo do painel mostra pedido pendente e desaparece após atendimento",async()=>{
 const vm=require("node:vm");
 const listeners={};
 const css=new Set(["hidden"]);
 const panel={classList:{
   add:x=>css.add(x),remove:x=>css.delete(x),
   toggle:(x,condition)=>condition?css.add(x):css.delete(x)
 }};
 const message={textContent:""};
 const link={href:""};
 const document={
   hidden:false,
   body:{dataset:{teacherPage:"painel"}},
   getElementById:id=>({
     teacherHelpSummary:panel,
     teacherHelpSummaryText:message,
     teacherHelpSummaryLink:link
   })[id],
   addEventListener:(event,fn)=>{listeners[event]=fn}
 };
 let current=[{name:"Aluno Teste",help_pending:true}];
 let requests=0;
 const mode={
   cfg:{examSlug:"ci-turma"},
   validTeacherSession:async()=>({access_token:"professor-autenticado"}),
   rpc:async(name,args,token)=>{
     assert.equal(name,"teacher_supervision_roster_by_class");
     assert.equal(args.p_exam_slug,"ci-turma");
     assert.equal(args.p_class_group,null);
     assert.equal(token,"professor-autenticado");
     requests++;
     return {students:current};
   }
 };
 let interval;
 vm.runInNewContext(read("teacher-help-summary.js"),{
   document,window:{ModeProva:mode,location:{search:"?avaliacao=simulado"},
      addEventListener:(event,fn)=>{listeners[event]=fn}},
   setInterval:fn=>{interval=fn}
 });
 // Drain the microtasks produced by authentication and RPC promises.
 for(let i=0;i<5;i++)await Promise.resolve();
 assert.ok(!css.has("hidden"));
 assert.match(message.textContent,/Aluno Teste/);
 assert.equal(link.href,"sala-espera.html?avaliacao=simulado");
 current=[];
 interval();
 for(let i=0;i<5;i++)await Promise.resolve();
 assert.ok(css.has("hidden"));
 assert.ok(requests>=2);
 listeners["modo-prova:teacher-logout"]();
 assert.ok(css.has("hidden"));
});
