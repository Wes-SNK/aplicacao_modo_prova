/* Testes executáveis de inicialização do monitoramento, com DOM e RPC simulados.
 * Capturam regressões que testes estáticos (presença de IDs) não detectam:
 * lista vazia, seletor sem opções, falha de monitoramento e configuração.
 */
const test=require("node:test");
const assert=require("node:assert/strict");
const vm=require("node:vm");
const fs=require("node:fs");
const path=require("node:path");
const script=fs.readFileSync(path.resolve(__dirname,"..","monitoramento.js"),"utf8");
const rules=require("../supervision-utils.js");

function environment({rpcFailure=false}={}){
  class FakeElement {
    constructor(tag="div"){
      this.tagName=tag.toUpperCase();
      this.children=[];
      this.events={};
      this.attributes={};
      this._text="";
      this._value="";
      this.checked=false;
      this.disabled=false;
      this.href="";
      this.style={};
      const classes=new Set();
      this.classList={
        add:s=>classes.add(s),remove:s=>classes.delete(s),
        contains:s=>classes.has(s),
        toggle:(s,v)=>{const yes=v===undefined?!classes.has(s):v;
          if(yes)classes.add(s);else classes.delete(s);return yes;}
      };
    }
    set textContent(t){this._text=String(t);this.children=[];}
    get textContent(){return this._text;}
    set value(v){this._value=String(v);}
    get value(){return this._value;}
    appendChild(el){this.children.push(el);return el;}
    append(...els){els.forEach(el=>this.appendChild(el));}
    addEventListener(name,fn){this.events[name]=fn;}
    setAttribute(name,v){this.attributes[name]=String(v);}
    async emit(event){return this.events[event]?.();}
  }
  const el=new Map();
  const find=id=>el.has(id)?el.get(id):(el.set(id,new FakeElement(
    id==="supervisionClass"?"select":id==="supervisionRows"?"tbody":"div"
  )),el.get(id));
  const document={
    body:{dataset:{teacherPage:"painel"}},
    getElementById:find,
    createElement:tag=>new FakeElement(tag),
    querySelector:()=>null
  };
  const fakeWindow={
    location:{href:"https://example.org/painel.html?exame=preset-abc",search:"?exame=preset-abc"},
    SupervisionUtils:rules,
    listeners:{},
    addEventListener(n,fn){this.listeners[n]=fn;},
    confirm:()=>true
  };
  const studentsByClass={
    TESTE:["ALUNO TESTE A","ALUNO TESTE B","ALUNO TESTE C"],
    "1º INF - B":Array.from({length:29},(_,i)=>"ALUNO REGULAR "+(i+1))
  };
  let configuredGroup="TESTE";
  const calls=[];
  const roster=group=>({
    class_group:group,
    configured_class_group:configuredGroup,
    classes:Object.keys(studentsByClass),
    preview_only:group!==configuredGroup,
    enabled:group===configuredGroup,
    is_active:true,
    server_time:new Date().toISOString(),
    students:(studentsByClass[group]||[]).map((name,i)=>({
      id:"id-"+i,name,class_group:group,active:true,waiting:false,
      authorized:false,status:"not_started",answered:0,total:5,
      last_seen:null,occurrences:0
    }))
  });
  fakeWindow.ModeProva={
    cfg:{examSlug:"preset-test"},
    validTeacherSession:async()=>({access_token:"fake-auth"}),
    rpc:async(name,args)=>{
      calls.push({name,args});
      if(name==="teacher_supervision_roster_by_class"){
        if(rpcFailure)throw new Error("Serviço de monitoramento indisponível");
        return roster(args.p_class_group||configuredGroup);
      }
      if(name==="teacher_students_list")
        return Object.entries(studentsByClass).flatMap(([group,names])=>
          names.map((name,i)=>({id:group+i,name,class_group:group,active:true})));
      if(name==="teacher_supervision_configure_v3"){
        configuredGroup=args.p_class_group;return {ok:true};
      }
      if(name==="teacher_supervision_authorize")return {ok:true};
      if(name==="teacher_supervision_authorize_all")return {ok:true,authorized_count:0};
      throw new Error("RPC inesperada: "+name);
    },
    downloadText(){}
  };
  const intervals=[];
  const context={
    window:fakeWindow,document,Date,Promise,Set,Option:(label,val)=>{
      const o=new FakeElement("option");o.textContent=label;o.value=val;return o;
    },
    setInterval:fn=>{intervals.push(fn);return intervals.length;},
    setTimeout,clearTimeout,
    console
  };
  vm.runInNewContext(script,context,{filename:"monitoramento.js"});
  const settle=async()=>{for(let i=0;i<8;i++)await new Promise(setImmediate);};
  return {find,calls,settle,intervals,studentsByClass};
}

test("Regressão: painel abre e popula seletor e os três alunos da turma vinculada",async()=>{
  const {find,settle,calls}=environment();
  await settle();
  const options=find("supervisionClass").children.map(o=>o.value);
  assert.ok(options.includes("TESTE"),"A turma TESTE não foi incluída no seletor");
  assert.ok(options.includes("1º INF - B"),"A turma regular não foi incluída");
  assert.equal(find("supervisionClass").value,"TESTE");
  assert.equal(find("supervisionTotal").textContent,"3");
  assert.equal(find("supervisionRows").children.length,3);
  assert.ok(calls.some(c=>c.name==="teacher_supervision_roster_by_class"));
  assert.notEqual(find("supervisionStatusBadge").textContent,"Consultando…");
  assert.notEqual(find("supervisionInstructions").textContent,"Carregando orientações para a avaliação selecionada…");
});

test("Regressão: mudar turma renderiza 29 alunos sem salvar configuração",async()=>{
  const {find,settle,calls}=environment();
  await settle();
  find("supervisionClass").value="1º INF - B";
  await find("supervisionClass").emit("change");
  await settle();
  assert.equal(find("supervisionTotal").textContent,"29");
  assert.equal(find("supervisionRows").children.length,29);
  assert.equal(find("supervisionClass").value,"1º INF - B");
  assert.match(find("supervisionInstructions").textContent,/continua vinculada/);
  assert.equal(calls.filter(c=>c.name==="teacher_supervision_configure_v3").length,0);
  assert.ok(!calls.some(c=>c.name==="teacher_supervision_authorize"));
  assert.equal(find("supervisionAuthorizeAll").disabled,true);
  const actions=find("supervisionRows").children[0].children.at(-1);
  assert.equal(actions.children.length,0,"Não deve autorizar aluno de turma não vinculada");
});

test("Regressão: salvamento explícito vincula turma e mantém supervisão ativa",async()=>{
  const {find,settle,calls}=environment();
  await settle();
  find("supervisionClass").value="1º INF - B";
  await find("supervisionClass").emit("change");
  await settle();
  await find("supervisionSave").emit("click");
  await settle();
  const saves=calls.filter(c=>c.name==="teacher_supervision_configure_v3");
  assert.equal(saves.length,1);
  assert.equal(saves[0].args.p_class_group,"1º INF - B");
  assert.equal(saves[0].args.p_enabled,true);
  assert.equal(find("supervisionTotal").textContent,"29");
  assert.equal(find("supervisionStatusBadge").textContent,"Supervisão ligada");
  const actions=find("supervisionRows").children[0].children.at(-1);
  assert.equal(actions.children[0].textContent,"Liberar prova");
});

test("Regressão: falha na RPC não deixa seletor vazio nem libera avaliação",async()=>{
  const {find,settle,calls}=environment({rpcFailure:true});
  await settle();
  const options=find("supervisionClass").children.map(o=>o.value);
  assert.ok(options.includes("TESTE"));
  assert.ok(options.includes("1º INF - B"));
  assert.match(find("supervisionMessage").textContent,/Monitoramento temporariamente indisponível/);
  assert.equal(find("supervisionAuthorizeAll").disabled,true);
  assert.equal(calls.some(c=>c.name==="teacher_students_list"),true);
  find("supervisionClass").value="1º INF - B";
  await find("supervisionClass").emit("change");
  await settle();
  assert.equal(find("supervisionTotal").textContent,"29");
  const actions=find("supervisionRows").children[0].children.at(-1);
  assert.equal(actions.children.length,0);
});

test("Regressão: páginas do professor versionam o carregador e seus scripts",()=>{
 const repo=path.resolve(__dirname,"..");
 const read=p=>fs.readFileSync(path.join(repo,p),"utf8");
 for(const page of ["painel","questoes","avaliacoes","alunos"]){
  const html=read(page+".html");
  assert.match(html,/teacher-pages\.js\?rev=20261126-panel-regression-1/);
 }
 const loader=read("teacher-pages.js");
 assert.match(loader,/appRevision="20261126-panel-regression-1"/);
 assert.match(loader,/script\.src=src\+"\?rev="/);
});
