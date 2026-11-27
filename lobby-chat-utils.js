/* Regras puras: nunca interpolar texto do aluno como HTML.
 * Mensagens curtas; @ seleciona um ID de colega, não confia em nomes digitados.
 */
(function(root){
 "use strict";
 const QUICK=Object.freeze([
  "Olá, pessoal!","Estou pronto!","Boa prova!",
  "Preciso de ajuda","Meu tablet está travando",
  "Não consigo entrar","Professor, tenho uma dúvida"
 ]);
 function clean(text){
  return String(text??"").trim().replace(/[\u0000-\u001F\u007F]/g,"");
 }
 function validate(text){
  const value=clean(text);
  if(!value||value.length>150)throw new Error("Escreva de 1 a 150 caracteres.");
  return value;
 }
 function sortMessages(current,updates,max=60){
  const ids=new Map();
  [...current,...updates].forEach(m=>{
   if(m && Number.isFinite(Number(m.id)))ids.set(String(m.id),m);
  });
  return [...ids.values()].sort((a,b)=>Number(a.id)-Number(b.id)).slice(-max);
 }
 function handleLabel(peer){
  return peer.self?"Você":String(peer.handle||"Colega").slice(0,32);
 }
 const api=Object.freeze({QUICK,clean,validate,sortMessages,handleLabel});
 root.LobbyChatUtils=api;
 if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof window!=="undefined"?window:globalThis);
