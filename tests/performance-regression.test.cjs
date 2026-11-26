/* Regressão de carga LOCAL, sem credenciais, sem alunos reais e sem acesso à rede.
 * Simula 30 clientes em dispositivos com atraso de resposta.
 * Estes testes validam limites de requisições e preservação da última posição,
 * não substituem ensaio de rede com 30 tablets/computadores reais.
 */
const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const perf=require("../client-performance.js");
const read=name=>fs.readFileSync(path.join(__dirname,"..",name),"utf8");
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test("30 alunos: 600 gestos viram poucas gravações, sempre com a última coordenada",async()=>{
  const users=30,gestures=20;
  const recorded=Array.from({length:users},()=>[]);
  let inFlight=0,maxInflight=0;
  const queues=recorded.map((log,i)=>perf.createLatestSender(async value=>{
    inFlight++;
    maxInflight=Math.max(inFlight,maxInflight);
    await sleep(3);
    log.push(value);
    inFlight--;
  },{minIntervalMs:45}));
  for(let gesture=0;gesture<gestures;gesture++)
    for(let student=0;student<users;student++)
      queues[student].push({x:gesture,y:student,emote:null});
  await sleep(120);
  const sends=recorded.reduce((n,log)=>n+log.length,0);
  assert.ok(sends<=users*3,"Enviou muitas posições: "+sends);
  assert.ok(sends>=users,"Nenhum update de alguns alunos");
  recorded.forEach((log,i)=>{
    assert.equal(log.at(-1).x,gestures-1);
    assert.equal(log.at(-1).y,i);
  });
  assert.ok(maxInflight<=users);
  queues.forEach(q=>q.close());
});

test("Fila de movimentação não envia gravações novas após fechar a sala",async()=>{
  const logs=[];
  const q=perf.createLatestSender(async value=>{logs.push(value);},{minIntervalMs:60});
  q.push({x:1});q.push({x:2});q.close();
  await sleep(80);
  assert.equal(logs.length,0);
});

test("Política de otimização não pode alterar correção nem criar ocorrências",()=>{
  const lobby=read("lobby.js");
  const student=read("student.js");
  const html=read("index.html"),preview=read("preview-aluno.html");
  assert.match(lobby,/roomTimer=setInterval\(poll,6500\)/);
  assert.match(lobby,/pollBusy/);
  assert.match(lobby,/avatarNodes=new Map\(\)/);
  assert.match(lobby,/movementSender\.push/);
  assert.match(lobby,/student_lobby_enter/);
  assert.doesNotMatch(lobby,/record_violation|save_answer|correct_answer/);
  assert.match(student,/heartbeatInFlight/);
  assert.match(student,/\}, 15000\);/);
  assert.match(student,/save_answer/);
  assert.match(student,/flushPendingAnswers/);
  assert.match(student,/record_violation/);
  for(const page of [html,preview]){
    assert.ok(page.indexOf('src="client-performance.js"') <
      page.indexOf('src="lobby.js"'));
    assert.match(page,/id="lobbySimpleMode"/);
  }
  const css=read("styles.css");
  assert.match(css,/@media \(pointer: coarse\)/);
  assert.match(css,/min-height:44px/);
  assert.match(css,/@media \(min-width: 801px\) and \(max-width: 1100px\)/);
});
