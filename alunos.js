/* Cadastro simplificado de alunos e turmas. Sem remoções destrutivas. */
(() => {
  "use strict";
  const mp=window.ModeProva;
  const $=id=>document.getElementById(id);
  let students=[],editing=null,busy=false;
  async function trpc(name,args={}){
    const s=await mp.validTeacherSession();
    if(!s?.access_token)throw new Error("Faça login novamente.");
    return mp.rpc(name,args,s.access_token);
  }
  const msg=t=>$("studentManagerMessage").textContent=t;
  const make=(tag,text)=>{
    const n=document.createElement(tag);
    if(text!=null)n.textContent=String(text);
    return n;
  };
  async function refresh(){
    if(document.body.dataset.teacherPage!=="alunos" ||
       busy || $("teacherDashboard").classList.contains("hidden"))return;
    try{
      const r=await trpc("teacher_students_list");
      if(!Array.isArray(r))throw new Error("Dados inválidos.");
      students=r;render();
      msg(students.length+" estudante(s) no cadastro.");
    }catch(err){
      msg(err.status===404
        ?"Cadastro em desenvolvimento: execute as migrações de homologação antes do teste."
        :"Não foi possível carregar alunos: "+(err.message||err));
    }
  }
  function render(){
    const area=$("studentAdminRows");
    area.textContent="";
    const filter=$("studentSearch").value.trim().toLocaleLowerCase("pt-BR");
    const selected=students.filter(s=>(
      s.name+" "+(s.class_group||"")).toLocaleLowerCase("pt-BR").includes(filter));
    for(const student of selected){
      const tr=make("tr");
      for(const value of [student.name,student.class_group,
        student.active?"Ativo":"Inativo"]){
        const td=make("td",value);tr.appendChild(td);
      }
      const actions=make("td");actions.className="student-admin-actions";
      const edit=make("button","Editar");
      edit.type="button";edit.className="small secondary";edit.disabled=busy;
      edit.addEventListener("click",()=>startEdit(student));
      const toggle=make("button",student.active?"Inativar":"Reativar");
      toggle.type="button";toggle.className="small "+(student.active?"danger":"secondary");
      toggle.disabled=busy;
      toggle.addEventListener("click",()=>changeStatus(student));
      actions.append(edit,toggle);tr.appendChild(actions);area.appendChild(tr);
    }
    if(!selected.length){
      const tr=make("tr"),td=make("td","Nenhum estudante encontrado.");
      td.colSpan=4;tr.appendChild(td);area.appendChild(tr);
    }
  }
  function startEdit(student){
    editing=student;
    $("studentAdminName").value=student.name;
    $("studentAdminClass").value=student.class_group||"";
    $("studentSave").textContent="Salvar alterações";
    $("studentCancel").classList.remove("hidden");
    $("studentAdminName").focus();
  }
  function cancel(){
    editing=null;
    $("studentAdminName").value="";
    $("studentAdminClass").value="";
    $("studentSave").textContent="Cadastrar aluno";
    $("studentCancel").classList.add("hidden");
  }
  async function doTask(fn){
    if(busy)return;
    busy=true;$("studentSave").disabled=true;
    try{await fn();}
    catch(err){msg("Não foi possível concluir: "+(err.message||err));}
    finally{busy=false;$("studentSave").disabled=false;render();}
  }
  async function save(){
    const name=$("studentAdminName").value.trim();
    const group=$("studentAdminClass").value.trim();
    if(name.length<3||name.length>120||!group||group.length>80){
      msg("Informe um nome completo e uma turma válidos.");return;
    }
    await doTask(async()=>{
      const r=await trpc("teacher_student_save",{
        p_student_id:editing?.id||null,p_name:name,p_class_group:group
      });
      if(!r?.ok)throw new Error("Cadastro não confirmado.");
      cancel();
      msg("Estudante salvo.");
    });
    await refresh();
    window.dispatchEvent(new Event("modo-prova:students-updated"));
  }
  async function changeStatus(s){
    const active=!s.active;
    if(!window.confirm((active?"Reativar ":"Inativar ")+s.name+"? "+
      "As respostas e notas existentes não serão excluídas."))return;
    await doTask(async()=>{
      const r=await trpc("teacher_student_set_active",{
        p_student_id:s.id,p_active:active
      });
      if(!r?.ok)throw new Error("Alteração não confirmada.");
      msg("Situação de "+s.name+" atualizada.");
    });
    await refresh();
    window.dispatchEvent(new Event("modo-prova:students-updated"));
  }
  $("studentRefresh").addEventListener("click",refresh);
  $("studentSave").addEventListener("click",save);
  $("studentCancel").addEventListener("click",cancel);
  $("studentSearch").addEventListener("input",render);
  window.addEventListener("modo-prova:teacher-ready",refresh);
  window.addEventListener("modo-prova:students-updated",refresh);
  window.addEventListener("modo-prova:teacher-logout",()=>{
    students=[];cancel();$("studentAdminRows").textContent="";msg("");
  });
  if(!$("teacherDashboard").classList.contains("hidden"))refresh();
})();
