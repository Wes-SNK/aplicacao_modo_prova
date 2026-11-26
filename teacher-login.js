/* Entrada exclusiva do professor. Não consulta presets nem dados de alunos. */
(async () => {
  "use strict";
  const mp=window.ModeProva;
  const $=id=>document.getElementById(id);
  mp.setConnectionBadge($("teacherConnectionBadge"));
  const allowed=/^(?:painel|questoes|avaliacoes|alunos)\.html$/;
  const requested=new URLSearchParams(window.location.search).get("next");
  function destination(){
    if(requested){
      try{
        const url=new URL(requested,window.location.href);
        const filename=url.pathname.split("/").pop();
        if(url.origin===window.location.origin && allowed.test(filename) &&
          url.pathname.startsWith(window.location.pathname.slice(0,window.location.pathname.lastIndexOf("/")+1))){
          return filename+url.search;
        }
      }catch{}
    }
    const params=new URLSearchParams(window.location.search);
    if(params.has("exame"))return "painel.html?exame="+encodeURIComponent(params.get("exame"));
    if(["simulado","prova"].includes(params.get("avaliacao")))
      return "painel.html?avaliacao="+params.get("avaliacao");
    return "painel.html";
  }
  try{
    const previous=await mp.validTeacherSession();
    if(previous?.access_token){window.location.replace(destination());return;}
  }catch{}
  $("teacherLoginForm").addEventListener("submit",async e=>{
    e.preventDefault();
    const email=$("teacherEmail").value.trim(),password=$("teacherPassword").value;
    if(!email||!password){mp.setMessage($("teacherLoginMessage"),"Informe e-mail e senha.","warn");return;}
    const button=$("btnTeacherLogin");button.disabled=true;
    mp.setMessage($("teacherLoginMessage"),"Autenticando…","info");
    try{
      const session=await mp.signIn(email,password);
      mp.saveTeacherSession(session);
      window.location.replace(destination());
    }catch{
      mp.setMessage($("teacherLoginMessage"),"Não foi possível entrar. Verifique suas credenciais e a conexão.","error");
      button.disabled=false;
    }
  });
})();
