const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

const lobby = fs.readFileSync("lobby.js", "utf8");
const css = fs.readFileSync("styles.css", "utf8");

test("avatares remotos são interpolados entre consultas sem novas RPCs por quadro", () => {
  assert.match(lobby, /roomTimer=setInterval\(poll,2000\)/);
  assert.match(css, /transition:left 1\.95s linear,top 1\.95s linear/);
  assert.match(css, /\.lobby-avatar\.own-avatar\{z-index:6;transition:left \.11s linear,top \.11s linear;/);
  assert.doesNotMatch(lobby, /requestAnimationFrame\s*\(.*mp\.rpc/s);
});

test("posição local não retrocede por atualização atrasada do servidor", () => {
  assert.match(lobby, /let ownPositionInitialized=false/);
  assert.match(lobby, /if\(p\.self&&!ownPositionInitialized\)/);
  assert.match(lobby, /const x=p\.self\?pos\.x:Number\(p\.x\)/);
  assert.match(lobby, /if\(dx\|\|dy\)\{pos=next;ownPositionInitialized=true;\}/);
  assert.doesNotMatch(lobby, /movingLocally/);
});

test("envio de posição é limitado e não concorre com leituras", () => {
  assert.match(lobby, /minIntervalMs:550/);
  assert.match(lobby, /pollBusy/);
  assert.match(lobby, /if \(!token \|\| !onScreen \|\| document\.hidden \|\| pollBusy\) return/);
  assert.match(lobby, /roomTimer=setInterval\(poll,2000\)/);
});

test("mapa e comunicação preservados", () => {
  for (const marker of [
    'addEventListener("click",walkToPoint)',
    'mp.lobbyChat?.open(token)',
    'mp.lobbyChat?.close()',
    'showBubble(senderId,message)',
    'student_lobby_enter'
  ]) assert.ok(lobby.includes(marker), marker);
  assert.doesNotMatch(lobby, /lobbySimpleMode|lobbySimpleStatus/);
});
