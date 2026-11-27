/* Resumo de solicitações de ajuda no painel geral.
 * Não altera autorizações ou dados do aluno; apenas consulta a turma vinculada.
 * Os controles operacionais permanecem na página dedicada sala-espera.html.
 */
(()=>{
  "use strict";
  if(document.body.dataset.teacherPage!=="painel")return;
  const mp=window.ModeProva;
  const panel=document.getElementById("teacherHelpSummary");
  const message=document.getElementById("teacherHelpSummaryText");
  const link=document.getElementById("teacherHelpSummaryLink");
  if(!panel||!message||!link)return;
  link.href="sala-espera.html"+window.location.search;
  let active=true,requestVersion=0,pollBusy=false;
  async function refresh(){
    if(!active||pollBusy||document.hidden)return;
    pollBusy=true;
    const version=++requestVersion;
    try{
      const session=await mp.validTeacherSession();
      if(!session?.access_token)throw Error("Sessão do professor encerrada.");
      const result=await mp.rpc("teacher_supervision_roster_by_class",{
        p_exam_slug:mp.cfg.examSlug,p_class_group:null
      },session.access_token);
      if(!active||version!==requestVersion)return;
      const students=Array.isArray(result?.students)?result.students:[];
      const pending=students.filter(s=>s.help_pending);
      panel.classList.toggle("hidden",pending.length===0);
      message.textContent=pending.length
        ? pending.length+" pedido(s) de ajuda — "+pending.map(s=>s.name).join(", ")+
          ". Acesse Sala de espera para atender."
        :"";
    }catch{
      // Um erro de conexão não deve parecer ausência de pedidos de ajuda.
      if(active&&version===requestVersion){
        panel.classList.remove("hidden");
        message.textContent="Não foi possível verificar os pedidos de ajuda. Abra Sala de espera para conferir.";
      }
    }finally{pollBusy=false;}
  }
  window.addEventListener("modo-prova:teacher-logout",()=>{
    active=false;requestVersion++;
    message.textContent="";
    panel.classList.add("hidden");
  });
  document.addEventListener("visibilitychange",()=>{if(!document.hidden)refresh();});
  refresh();
  setInterval(refresh,5000);
})();
