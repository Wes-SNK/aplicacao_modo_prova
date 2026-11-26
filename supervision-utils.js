/* Funções puras, compartilhadas entre aluno e professor. Executáveis em Node e navegador. */
(function (root) {
  "use strict";
  const utils = Object.freeze({
    clampPosition(x,y){
      const valid=n=>Number.isFinite(Number(n));
      if(!valid(x)||!valid(y))throw new TypeError("Coordenadas inválidas");
      return {x:Math.max(4,Math.min(96,Number(x))),
        y:Math.max(8,Math.min(91,Number(y)))};
    },
    progressPercent(answered,total){
      const a=Number(answered),t=Number(total);
      if(!Number.isFinite(a)||!Number.isFinite(t)||t<=0)return 0;
      return Math.min(100,Math.max(0,Math.round(a/t*100)));
    },
    studentStatus(s){
      if(!s)return "Desconhecido";
      if(["submitted","auto_submitted"].includes(s.status))return "Finalizado";
      if(s.status==="in_progress")return "Realizando";
      if(s.status==="ready")return "Pronto para iniciar";
      if(s.waiting && s.authorized)return "Autorizado";
      if(s.waiting)return "No pátio — aguardando liberação";
      if(s.lobby_requested)return "Na sala de espera";
      if(s.lobby_allowed)return "Na sala de espera";
      if(s.authorized)return "Prova liberada — ainda não entrou";
      return "Ainda não entrou";
    },
    connectionStatus(lastSeen,waiting,inProgress,now=Date.now()){
      if(!waiting&&!inProgress)return "—";
      const age=lastSeen ? Math.max(0,(Number(now)-Date.parse(lastSeen))/1000) : Infinity;
      if(age<=25)return "Conectado";
      if(age<=120)return "Sinal instável ("+Math.round(age)+"s)";
      return "Sem conexão recente";
    },
    canRequestExam(students,enabled){
      return !!enabled && Array.isArray(students) && students.some(s=>s.waiting && !s.authorized);
    }
  });
  root.SupervisionUtils=utils;
  if(typeof module!=="undefined"&&module.exports)module.exports=utils;
})(typeof window!=="undefined"?window:globalThis);
