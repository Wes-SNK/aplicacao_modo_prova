const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const vm=require("node:vm");
const root=path.resolve(__dirname,"..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const utils=require("../lobby-chat-utils.js");

test("Validação e sanitização de mensagens",()=>{
 assert.equal(utils.validate("  Olá!  "),"Olá!");
 assert.throws(()=>utils.validate(""),/1 a 150/);
 assert.throws(()=>utils.validate("a".repeat(151)),/1 a 150/);
 assert.equal(utils.clean("a\u0000b"),"ab");
 assert.equal(new Set(utils.QUICK).size,utils.QUICK.length);
 assert.ok(utils.QUICK.length>=6);
});

test("Histórico limitado e sem duplicidades",()=>{
 const result=utils.sortMessages([{id:1,body:"a"}],[{id:1,body:"a"},{id:2,body:"b"}]);
 assert.deepEqual(result.map(m=>m.id),[1,2]);
 assert.equal(utils.sortMessages([],Array.from({length:100},(_,i)=>({id:i+1}))).length,60);
});

test("Contrato de segurança: mensagens vinculadas à avaliação e banco fechado",()=>{
 const sql=read("migrations/021_chat_sala_espera.sql");
 for(const name of [
  "student_lobby_chat_read","student_lobby_chat_send",
  "teacher_lobby_chat_read","teacher_lobby_chat_manage",
  "teacher_lobby_chat_send"
 ])assert.match(sql,new RegExp("FUNCTION public\\."+name+"\\("));
 assert.match(sql,/ENABLE ROW LEVEL SECURITY/g);
 assert.match(sql,/REVOKE ALL ON public\.lobby_chat_settings/);
 assert.match(sql,/p_lobby_token uuid/);
 assert.match(sql,/a\.student_id=l\.student_id\)/);
 assert.doesNotMatch(sql,/a\.started_at IS NOT NULL/);
 assert.match(sql,/auth\.uid\(\) IS NULL/);
 assert.match(sql,/3 seconds/);
 assert.match(sql,/length\(v_body\) NOT BETWEEN 1 AND 150/);
 assert.doesNotMatch(sql,/GRANT (?:ALL|SELECT|INSERT|UPDATE) ON public\.lobby_chat_messages TO anon/);
 assert.match(read(".github/workflows/supervision-tests.yml"),/chat-supervised\.sql/);
});

test("Chat aluno: conteúdo somente em textContent e encerramento ao iniciar prova",()=>{
 const chat=read("lobby-chat.js"),lobby=read("lobby.js");
 assert.match(chat,/text\.textContent=m\.body/);
 assert.match(chat,/lobbyChatMentions/);
 assert.match(chat,/student_lobby_chat_send/);
 assert.match(chat,/student_lobby_chat_read/);
 assert.match(chat,/setInterval\(refresh,13000\)/);
 assert.match(lobby,/mp\.lobbyChat\?\.open\(token\)/);
 assert.match(lobby,/mp\.lobbyChat\?\.close\(\)/);
 assert.match(lobby,/showBubble/);
 assert.doesNotMatch(chat,/innerHTML|document\.write/);
 assert.doesNotMatch(lobby,/record_violation\(.+chat/);
});

test("Chat somente no pátio e na área autenticada do professor",()=>{
 const html=read("index.html");
 const preview=read("preview-aluno.html");
 for(const source of [html,preview]){
  for(const id of ["lobbyChatPanel","lobbyChatQuick","lobbyChatMessages",
   "lobbyChatTarget","lobbyChatInput","lobbyChatMentions","lobbyChatToggle"])
   assert.ok(source.includes('id="'+id+'"'),"ID ausente: "+id);
  const scripts=[...source.matchAll(/<script src="([^"]+)"/g)].map(m=>m[1].split("?")[0]);
  assert.ok(scripts.indexOf("lobby-chat-utils.js")<scripts.indexOf("lobby-chat.js"));
  assert.ok(scripts.indexOf("lobby-chat.js")<scripts.indexOf("lobby.js"));
 }
 const shell=read("professor-shell.html"),loader=read("teacher-pages.js");
 for(const id of ["teacherChatSection","teacherChatMessages","teacherChatEnabled",
  "teacherChatPeers","teacherChatSend","teacherChatMuteStudent","teacherChatUnmute"])
   assert.ok(shell.includes('id="'+id+'"'),"ID professor ausente: "+id);
 assert.match(loader,/if\(page==="sala"\)/);
 assert.match(read("chat-professor.js"),/teacherPage!=="sala"/);
 assert.match(loader,/chat-professor\.js/);
 assert.doesNotMatch(read("student.js"),/lobby_chat_send|lobby_chat_read/);
});

test("Mensagens privadas não são convertidas em balões públicos",()=>{
 const chat=read("lobby-chat.js"),sql=read("migrations/021_chat_sala_espera.sql");
 assert.match(chat,/m\.public_message&&!m\.self&&m\.sender_id/);
 assert.match(sql,/'public_message',m\.recipient_student_id IS NULL AND NOT m\.recipient_teacher/);
});

test("Simulação de 30 alunos: filtragem e limite da lista por usuário",()=>{
 const peers=Array.from({length:30},(_,i)=>({id:i+1,handle:"Aluno-"+i}));
 const messages=Array.from({length:450},(_,i)=>({
  id:i+1,body:"Mensagem "+i,recipient:i%30+1
 }));
 for(const student of peers){
  const visible=messages.filter(m=>m.recipient===student.id);
  assert.equal(visible.length,15);
  assert.ok(utils.sortMessages([],visible).length<=60);
 }
});
