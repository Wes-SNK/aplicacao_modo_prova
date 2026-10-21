(() => {
  'use strict';
  const C = window.EXAM_CONFIG;
  const BANK = window.QUESTION_BANK;
  const $ = (id) => document.getElementById(id);
  const storageKey = `exam_attempt_${C.examId}`;
  const resultsKey = `exam_results_${C.examId}`;
  let attempt = null;
  let timerHandle = null;
  let currentIndex = 0;
  let securityArmed = false;
  let incidentModalOpen = false;
  let lastIncidentAt = 0;

  const els = {
    start: $('startScreen'), exam: $('examScreen'), submit: $('submitScreen'), done: $('doneScreen'),
    title: $('examTitle'), subtitle: $('examSubtitle'), rules: $('rulesList'), name: $('studentName'), class: $('studentClass'),
    accept: $('acceptRules'), startBtn: $('startBtn'), headerTitle: $('headerTitle'), studentLine: $('studentLine'), timer: $('timer'),
    incidents: $('incidentCount'), progressFill: $('progressFill'), progressText: $('progressText'), questionCard: $('questionCard'),
    prev: $('prevBtn'), next: $('nextBtn'), flag: $('flagBtn'), reviewSummary: $('reviewSummary'), reviewGrid: $('reviewGrid'),
    backToExam: $('backToExamBtn'), confirmSubmit: $('confirmSubmitBtn'), doneMessage: $('doneMessage'),
    modal: $('incidentModal'), incidentMessage: $('incidentMessage'), resume: $('resumeBtn')
  };

  function nowIso() { return new Date().toISOString(); }
  function uid() { return `${Date.now()}-${Math.random().toString(36).slice(2,10)}`; }
  function normalizeName(s) { return s.trim().replace(/\s+/g, ' '); }
  function hashString(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
    return h >>> 0;
  }
  function mulberry32(a) {
    return function() { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }
  }
  function shuffled(array, rand) {
    const a = [...array];
    for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rand() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
    return a;
  }
  function saveAttempt() { if (attempt) localStorage.setItem(storageKey, JSON.stringify(attempt)); }
  function getSavedAttempt() { try { return JSON.parse(localStorage.getItem(storageKey) || 'null'); } catch { return null; } }

  function buildAttempt(studentName, studentClass) {
    const startedAt = nowIso();
    const seed = hashString(`${studentName}|${studentClass}|${C.examId}|${startedAt}`);
    const rand = mulberry32(seed);
    let selected = [...BANK];
    if (C.shuffleQuestions) selected = shuffled(selected, rand);
    selected = selected.slice(0, Math.min(C.questionCount || selected.length, selected.length));
    const questions = selected.map(q => {
      if (q.type !== 'single') return { ...q };
      const optionPairs = q.options.map((text, idx) => ({ text, originalIndex: idx }));
      const opts = C.shuffleOptions ? shuffled(optionPairs, rand) : optionPairs;
      return { ...q, options: opts.map(o => o.text), correctIndex: opts.findIndex(o => o.originalIndex === q.answer) };
    });
    return {
      id: uid(), examId: C.examId, studentName, studentClass, startedAt,
      deadline: Date.now() + C.durationMinutes * 60 * 1000,
      status: 'in_progress', currentIndex: 0, questions,
      answers: {}, flagged: {}, incidents: [], submittedAt: null, score: null, objectiveTotal: null,
      version: 1
    };
  }

  async function enterFullscreen() {
    if (!C.requireFullscreen) return true;
    if (document.fullscreenElement) return true;
    try { await document.documentElement.requestFullscreen({ navigationUI: 'hide' }); return true; }
    catch { return false; }
  }

  function init() {
    els.title.textContent = C.title;
    els.subtitle.textContent = C.subtitle;
    els.headerTitle.textContent = C.title;
    C.rules.forEach(r => { const li = document.createElement('li'); li.textContent = r; els.rules.appendChild(li); });
    const saved = getSavedAttempt();
    if (saved && saved.status === 'in_progress' && saved.deadline > Date.now()) {
      attempt = saved;
      currentIndex = attempt.currentIndex || 0;
      els.name.value = attempt.studentName;
      els.class.value = attempt.studentClass;
      els.accept.checked = true;
      els.startBtn.textContent = 'Retomar avaliação';
    } else if (saved && saved.status === 'in_progress' && saved.deadline <= Date.now()) {
      attempt = saved;
      submitExam('tempo_esgotado');
    }
    bindEvents();
  }

  function bindEvents() {
    els.startBtn.addEventListener('click', startOrResume);
    els.prev.addEventListener('click', () => goTo(currentIndex - 1));
    els.next.addEventListener('click', () => currentIndex === attempt.questions.length - 1 ? showReview() : goTo(currentIndex + 1));
    els.flag.addEventListener('click', toggleFlag);
    els.backToExam.addEventListener('click', () => { showOnly('exam'); renderQuestion(); });
    els.confirmSubmit.addEventListener('click', () => submitExam('enviado_pelo_aluno'));
    els.resume.addEventListener('click', resumeAfterIncident);

    document.addEventListener('visibilitychange', () => {
      if (securityArmed && document.hidden) recordIncident('troca_de_aba_ou_janela');
    });
    document.addEventListener('fullscreenchange', () => {
      if (securityArmed && C.requireFullscreen && !document.fullscreenElement && !incidentModalOpen) recordIncident('saida_da_tela_cheia');
    });

    ['copy','cut','paste','contextmenu','selectstart','dragstart'].forEach(evt => {
      document.addEventListener(evt, (e) => {
        if (!securityArmed) return;
        if (evt === 'selectstart' && e.target && e.target.tagName === 'TEXTAREA') return;
        e.preventDefault();
      });
    });
    document.addEventListener('keydown', (e) => {
      if (!securityArmed) return;
      const k = e.key.toLowerCase();
      const blocked = (e.ctrlKey && ['c','v','x','a','p','s','u'].includes(k)) ||
        (e.ctrlKey && e.shiftKey && ['i','j','c'].includes(k)) || e.key === 'F12';
      if (blocked) { e.preventDefault(); }
    });
    window.addEventListener('beforeunload', (e) => {
      if (securityArmed && attempt?.status === 'in_progress') { e.preventDefault(); e.returnValue = ''; }
    });
  }

  async function startOrResume() {
    const name = normalizeName(els.name.value);
    const studentClass = normalizeName(els.class.value);
    if (!name) return alert('Informe seu nome completo.');
    if (!studentClass) return alert('Informe sua turma.');
    if (!els.accept.checked) return alert('Marque que leu e compreendeu as regras.');
    const fullscreenOk = await enterFullscreen();
    if (C.requireFullscreen && !fullscreenOk) return alert('Não foi possível entrar em tela cheia. Autorize a tela cheia e tente novamente.');

    const saved = getSavedAttempt();
    if (saved && saved.status === 'in_progress' && saved.studentName === name && saved.studentClass === studentClass && saved.deadline > Date.now()) {
      attempt = saved;
      currentIndex = attempt.currentIndex || 0;
    } else {
      attempt = buildAttempt(name, studentClass);
      currentIndex = 0;
      saveAttempt();
    }
    document.body.classList.add('exam-active');
    securityArmed = true;
    showOnly('exam');
    els.studentLine.textContent = `${attempt.studentName} • ${attempt.studentClass}`;
    updateIncidentCount();
    renderQuestion();
    startTimer();
  }

  function showOnly(which) {
    const map = { start: els.start, exam: els.exam, submit: els.submit, done: els.done };
    Object.entries(map).forEach(([k, el]) => el.classList.toggle('hidden', k !== which));
  }

  function renderQuestion() {
    if (!attempt) return;
    attempt.currentIndex = currentIndex; saveAttempt();
    const q = attempt.questions[currentIndex];
    const answered = attempt.answers[q.id];
    els.questionCard.innerHTML = '';
    const num = document.createElement('div'); num.className = 'question-number'; num.textContent = `Questão ${currentIndex + 1}`;
    const text = document.createElement('div'); text.className = 'question-text'; text.textContent = q.text;
    els.questionCard.append(num, text);

    if (q.type === 'single') {
      const options = document.createElement('div'); options.className = 'options';
      q.options.forEach((opt, idx) => {
        const label = document.createElement('label'); label.className = 'option' + (answered === idx ? ' selected' : '');
        const input = document.createElement('input'); input.type = 'radio'; input.name = `q_${q.id}`; input.checked = answered === idx;
        input.addEventListener('change', () => { attempt.answers[q.id] = idx; saveAttempt(); renderQuestion(); });
        const span = document.createElement('span'); span.textContent = opt;
        label.append(input, span); options.appendChild(label);
      });
      els.questionCard.appendChild(options);
    } else {
      const ta = document.createElement('textarea'); ta.className = 'answer-textarea'; ta.maxLength = q.maxLength || 1000; ta.value = answered || '';
      ta.placeholder = 'Digite sua resposta aqui...';
      const counter = document.createElement('div'); counter.className = 'char-counter';
      const updateCounter = () => counter.textContent = `${ta.value.length}/${ta.maxLength}`;
      ta.addEventListener('input', () => { attempt.answers[q.id] = ta.value; saveAttempt(); updateCounter(); });
      updateCounter(); els.questionCard.append(ta, counter);
    }

    const pct = ((currentIndex + 1) / attempt.questions.length) * 100;
    els.progressFill.style.width = `${pct}%`;
    els.progressText.textContent = `${currentIndex + 1} de ${attempt.questions.length}`;
    els.prev.disabled = !C.allowBackNavigation || currentIndex === 0;
    els.next.textContent = currentIndex === attempt.questions.length - 1 ? 'Revisar e enviar' : 'Próxima';
    els.flag.textContent = attempt.flagged[q.id] ? 'Remover marcação' : 'Marcar para revisar';
    els.flag.classList.toggle('flagged', !!attempt.flagged[q.id]);
  }

  function goTo(i) {
    if (i < 0 || i >= attempt.questions.length) return;
    currentIndex = i; renderQuestion();
  }
  function toggleFlag() {
    const q = attempt.questions[currentIndex];
    attempt.flagged[q.id] = !attempt.flagged[q.id]; saveAttempt(); renderQuestion();
  }

  function showReview() {
    showOnly('submit');
    const unanswered = attempt.questions.filter(q => {
      const a = attempt.answers[q.id]; return a === undefined || a === null || a === '';
    }).length;
    const flagged = attempt.questions.filter(q => attempt.flagged[q.id]).length;
    els.reviewSummary.textContent = `${attempt.questions.length - unanswered} de ${attempt.questions.length} questões respondidas. ${flagged} marcada(s) para revisão.`;
    els.reviewGrid.innerHTML = '';
    attempt.questions.forEach((q, idx) => {
      const a = attempt.answers[q.id];
      const item = document.createElement('button'); item.className = 'review-item'; item.textContent = String(idx + 1);
      if (a === undefined || a === null || a === '') item.classList.add('unanswered');
      if (attempt.flagged[q.id]) item.classList.add('flagged');
      item.addEventListener('click', () => { currentIndex = idx; showOnly('exam'); renderQuestion(); });
      els.reviewGrid.appendChild(item);
    });
  }

  function startTimer() {
    clearInterval(timerHandle);
    const tick = () => {
      if (!attempt || attempt.status !== 'in_progress') return;
      const ms = attempt.deadline - Date.now();
      if (ms <= 0) { els.timer.textContent = '00:00'; submitExam('tempo_esgotado'); return; }
      const totalSec = Math.ceil(ms / 1000);
      const m = Math.floor(totalSec / 60); const s = totalSec % 60;
      els.timer.textContent = `${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
    };
    tick(); timerHandle = setInterval(tick, 1000);
  }

  function updateIncidentCount() { els.incidents.textContent = String(attempt?.incidents?.length || 0); }

  function recordIncident(type) {
    if (!attempt || attempt.status !== 'in_progress') return;
    const now = Date.now();
    if (now - lastIncidentAt < 1200) return;
    lastIncidentAt = now;
    attempt.incidents.push({ type, at: nowIso(), question: currentIndex + 1 });
    saveAttempt(); updateIncidentCount();

    if (attempt.incidents.length >= C.maxIncidents) {
      if (C.actionOnIncidentLimit === 'restart') return restartAttemptByIncident();
      return submitExam('limite_de_ocorrencias');
    }
    incidentModalOpen = true;
    securityArmed = false;
    document.body.classList.add('security-lock');
    const remaining = C.maxIncidents - attempt.incidents.length;
    els.incidentMessage.textContent = `Ocorrência ${attempt.incidents.length} de ${C.maxIncidents}. Restam ${remaining} antes do encerramento automático. Para continuar, retorne ao modo de prova.`;
    els.modal.classList.remove('hidden');
  }

  async function resumeAfterIncident() {
    const ok = await enterFullscreen();
    if (C.requireFullscreen && !ok) return alert('É necessário retornar à tela cheia para continuar.');
    els.modal.classList.add('hidden');
    document.body.classList.remove('security-lock');
    incidentModalOpen = false;
    setTimeout(() => { securityArmed = true; }, 350);
  }

  function scoreAttempt() {
    let correct = 0, total = 0;
    attempt.questions.forEach(q => {
      if (q.type === 'single') { total++; if (attempt.answers[q.id] === q.correctIndex) correct++; }
    });
    return { correct, total };
  }

  function archiveResult() {
    let results = [];
    try { results = JSON.parse(localStorage.getItem(resultsKey) || '[]'); } catch { results = []; }
    results.push(attempt);
    localStorage.setItem(resultsKey, JSON.stringify(results));
  }

  async function submitExam(reason) {
    if (!attempt || attempt.status !== 'in_progress') return;
    securityArmed = false;
    clearInterval(timerHandle);
    const s = scoreAttempt();
    attempt.score = s.correct; attempt.objectiveTotal = s.total;
    attempt.status = 'submitted'; attempt.submittedAt = nowIso(); attempt.submitReason = reason;
    saveAttempt(); archiveResult();
    try { if (document.fullscreenElement) await document.exitFullscreen(); } catch {}
    document.body.classList.remove('exam-active','security-lock');
    els.modal.classList.add('hidden');
    showOnly('done');
    els.doneMessage.textContent = reason === 'limite_de_ocorrencias'
      ? 'A tentativa foi encerrada porque atingiu o limite de saídas da prova. O professor poderá consultar o registro de ocorrências.'
      : reason === 'tempo_esgotado'
        ? 'O tempo terminou e suas respostas foram enviadas automaticamente.'
        : 'Suas respostas foram registradas com sucesso.';
  }

  function restartAttemptByIncident() {
    securityArmed = false;
    const name = attempt.studentName, cls = attempt.studentClass;
    attempt.status = 'restarted_due_to_incidents'; attempt.submittedAt = nowIso();
    archiveResult();
    localStorage.removeItem(storageKey);
    alert('O limite de ocorrências foi atingido. A prova será reiniciada.');
    location.reload();
  }

  init();
})();
