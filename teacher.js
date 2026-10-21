(() => {
  const C = window.EXAM_CONFIG;
  const $ = id => document.getElementById(id);
  const resultsKey = `exam_results_${C.examId}`;
  const read = () => { try { return JSON.parse(localStorage.getItem(resultsKey) || '[]'); } catch { return []; } };
  function fmt(iso) { return iso ? new Date(iso).toLocaleString('pt-BR') : '—'; }
  function esc(s='') { return String(s).replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m])); }
  function render() {
    const data = read();
    $('summary').textContent = `${data.length} tentativa(s) armazenada(s) neste navegador.`;
    $('rows').innerHTML = data.map(a => {
      const inc = (a.incidents || []).map(i => `${i.type} · Q${i.question} · ${fmt(i.at)}`).join('\n') || '—';
      const score = a.objectiveTotal != null ? `${a.score}/${a.objectiveTotal}` : '—';
      return `<tr><td>${esc(a.studentName)}</td><td>${esc(a.studentClass)}</td><td>${fmt(a.startedAt)}</td><td>${fmt(a.submittedAt)}</td><td>${score}</td><td class="log">${esc(inc)}</td><td>${esc(a.submitReason || a.status)}</td></tr>`;
    }).join('');
  }
  $('loginBtn').addEventListener('click', () => {
    if ($('pin').value !== C.teacherPin) return alert('PIN incorreto.');
    $('loginCard').classList.add('hidden'); $('panelCard').classList.remove('hidden'); render();
  });
  function download(name, mime, content) {
    const blob = new Blob([content], {type:mime}); const a=document.createElement('a'); a.href=URL.createObjectURL(blob); a.download=name; a.click(); URL.revokeObjectURL(a.href);
  }
  $('exportJson').addEventListener('click', () => download(`resultados_${C.examId}.json`,'application/json',JSON.stringify(read(),null,2)));
  $('exportCsv').addEventListener('click', () => {
    const rows = [['Aluno','Turma','Inicio','Envio','Acertos','TotalObjetivas','Ocorrencias','Motivo']];
    read().forEach(a => rows.push([a.studentName,a.studentClass,a.startedAt,a.submittedAt,a.score,a.objectiveTotal,(a.incidents||[]).length,a.submitReason||a.status]));
    const csv = rows.map(r => r.map(v => `"${String(v ?? '').replace(/"/g,'""')}"`).join(';')).join('\n');
    download(`resultados_${C.examId}.csv`,'text/csv;charset=utf-8','\uFEFF'+csv);
  });
  $('clearData').addEventListener('click', () => { if (confirm('Apagar todos os resultados armazenados neste computador?')) { localStorage.removeItem(resultsKey); render(); } });
})();
