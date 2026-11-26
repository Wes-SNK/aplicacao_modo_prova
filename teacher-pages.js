/* Navegação multipágina do professor. Nunca carrega os dados de trabalho
 * antes de validar a sessão autenticada no Supabase Auth.
 * Um único shell compartilhado conserva as integrações existentes.
 */
(async () => {
  "use strict";
  const mode=window.ModeProva;
  const page=document.body.dataset.teacherPage;
  const definitions={
    painel:{title:"Painel de controle",
      description:"Monitoramento da turma, autorizações, acompanhamento e resultados."},
    questoes:{title:"Questões",
      description:"Questões da avaliação selecionada e banco reutilizável."},
    avaliacoes:{title:"Avaliações e presets",
      description:"Presets, criação, regras, tempo e publicação das avaliações."},
    alunos:{title:"Alunos e turmas",
      description:"Cadastro, vínculos, situação de matrícula e identificação dos estudantes."}
  };
  const entry=definitions[page];
  if(!entry)return;
  const mount=document.getElementById("teacherAppMount");
  const pageURL=window.location.pathname.split("/").pop()+window.location.search;
  const loginURL="professor.html?next="+encodeURIComponent(pageURL);
  const goToLogin=()=>window.location.replace(loginURL);
  // Versionamento único impede combinar o shell atualizado com módulos antigos
  // eventualmente retidos pelo cache do navegador.
  const appRevision="20261126-panel-regression-1";
  const loadScript=src=>new Promise((resolve,reject)=>{
    const script=document.createElement("script");
    script.src=src+"?rev="+encodeURIComponent(appRevision);script.async=false;
    script.onload=resolve;script.onerror=()=>reject(new Error("Falha ao carregar "+src));
    document.body.appendChild(script);
  });

  try {
    const session=await mode.validTeacherSession();
    if(!session?.access_token){goToLogin();return;}

    const response=await fetch("professor-shell.html",{cache:"no-store"});
    if(!response.ok)throw new Error("Estrutura do painel indisponível: HTTP "+response.status);
    const fragment=await response.text();
    mount.innerHTML=fragment;
    const $=id=>document.getElementById(id);
    // A sessão já foi validada; não exibir o formulário de login ao
    // carregar as páginas internas, nem por alguns instantes.
    $("teacherLogin").classList.add("hidden");
    $("teacherMainNav").classList.remove("hidden");
    $("teacherPageHeader").classList.remove("hidden");
    $("teacherPageTitle").textContent=entry.title;
    $("teacherPageDescription").textContent=entry.description;

    document.querySelectorAll("[data-page-area]").forEach(el=>{
      el.classList.toggle("teacher-area-disabled",el.dataset.pageArea!==page);
    });
    document.querySelectorAll("[data-page-link]").forEach(a=>{
      const chosen=a.dataset.pageLink===page;
      a.setAttribute("aria-current",chosen?"page":"false");
      a.href=a.getAttribute("href").split("?")[0]+window.location.search;
    });

    const select=$("teacherAssessmentSelect");
    const presets={
      "simulado-4bim-1b-2026":"Simulado 01/12",
      "prova-4bim-1b-2026":"Prova bimestral",
      "4bim-1b-2026":"Avaliação anterior"
    };
    const slug=mode.cfg.examSlug;
    select.value=slug;
    if(!presets[slug]){
      const option=new Option("Preset personalizado selecionado",slug);
      select.add(option);
      select.value=slug;
    }
    select.addEventListener("change",()=>{
      const selected=select.value;
      const path=window.location.pathname.split("/").pop();
      const target=/^preset-[0-9a-f]{32}$/.test(selected)
        ? "?exame="+encodeURIComponent(selected)
        : selected==="simulado-4bim-1b-2026" ? "?avaliacao=simulado"
          :selected==="prova-4bim-1b-2026" ? "?avaliacao=prova" : "";
      window.location.href=path+target;
    });

    // Carrega módulos em sequência; professor.js registra login e inicia o
    // painel. Os componentes especializados verificam a sessão existente.
    for(const src of ["professor.js","presets.js","monitoramento.js","alunos.js"]){
      await loadScript(src);
    }
    // Mensagens são modulares e só devem ser inicializadas no painel de
    // monitoramento. Demais páginas não executam consultas de chat.
    if(page==="painel"){
      await loadScript("lobby-chat-utils.js");
      await loadScript("lobby-chat-teacher.js");
    }
    // Diagnóstico: falhas assíncronas devem aparecer no próprio painel.
    // Carregamento completo do shell não é garantia de RPC bem-sucedida.
    // Permite que os presets personalizados também sejam selecionados no
    // cabeçalho sem acoplar o gerenciador ao painel de login.
    try{
      const auth=await mode.validTeacherSession();
      if(auth?.access_token){
        const items=await mode.rpc("teacher_presets_list",{},auth.access_token);
        if(Array.isArray(items)){
          items.filter(x=>x.custom&&!x.archived).forEach(p=>{
            if(![...select.options].some(o=>o.value===p.slug))
              select.add(new Option(p.title,p.slug));
          });
          select.value=slug;
        }
      }
    }catch{
      // Falha apenas na lista de presets não impede o funcionamento da página.
    }
  }catch(err){
    mount.textContent="";
    const main=document.createElement("main");main.className="shell";
    const box=document.createElement("section");box.className="card";
    const heading=document.createElement("h1");heading.textContent="Não foi possível abrir o painel";
    const detail=document.createElement("p");detail.textContent=String(err?.message||err);
    const retry=document.createElement("a");retry.href=window.location.href;
    retry.textContent="Tentar novamente";retry.className="secondary teacher-retry-link";
    box.append(heading,detail,retry);main.appendChild(box);mount.appendChild(main);
  }
})();
