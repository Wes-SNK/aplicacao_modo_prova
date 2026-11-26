/* Utilitários de desempenho do cliente, sem dependências e sem dados de aluno.
 *
 * LatestSender: combina movimentações frequentes em uma atualização recente,
 * limita a taxa de envios e impede duas gravações simultâneas. Apenas o
 * estado visual (posição/avatar) usa esta fila; respostas de prova NÃO usam.
 */
(function(root){
  "use strict";
  function createLatestSender(send,{minIntervalMs=500,clock=()=>Date.now(),
    schedule=(fn,ms)=>setTimeout(fn,ms),cancel=id=>clearTimeout(id),
    onError=()=>{}}={}){
    if(typeof send!=="function")throw new TypeError("Sender obrigatório");
    let pending=null,inFlight=false,timer=null,lastSent=-Infinity,closed=false;
    function arm(immediate=false){
      if(closed||inFlight||pending===null||timer!==null)return;
      const delay=immediate?0:Math.max(0,minIntervalMs-(clock()-lastSent));
      timer=schedule(()=>{timer=null;flush();},delay);
    }
    async function flush(){
      if(closed||inFlight||pending===null)return;
      inFlight=true;
      const value=pending;
      pending=null;
      lastSent=clock();
      try{await send(value);}catch(err){onError(err);}
      finally{inFlight=false;arm();}
    }
    return {
      push(value,{urgent=false}={}){
        if(closed)return;
        // A fila mantém apenas a coordenada mais recente (não respostas).
        pending=value;
        if(urgent && timer!==null){cancel(timer);timer=null;}
        arm(urgent);
      },
      close(){
        closed=true;pending=null;
        if(timer!==null){cancel(timer);timer=null;}
      },
      get pending(){return pending!==null||inFlight;}
    };
  }
  const api={createLatestSender};
  root.ModoProvaPerformance=api;
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof window!=="undefined"?window:globalThis);
