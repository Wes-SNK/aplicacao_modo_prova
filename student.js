(() => {
  "use strict";

  const { cfg, rpc, setMessage, setConnectionBadge } = window.ModeProva;

  const $ = (id) => document.getElementById(id);
  const screens = ["screenLogin", "screenRules", "screenExam", "screenFinished"];

  let state = {
    sessionToken: null,
    attemptId: null,
    studentName: null,
    examTitle: null,
    durationMinutes: 0,
    maxOccurrences: 0,
    occurrences: 0,
    questions: [],
    answers: {},
    review: {},
    index: 0,
    startedAt: null,
    endsAt: null,
    status: null,
    active: false,
    submitting: false,
    lastViolationAt: 0,
    lastViolationType: null,
    pendingSync: {}
  };

  const CACHE_KEY = `modoProva:${cfg.examSlug}:session`;
  const ANSWER_CACHE_KEY = `modoProva:${cfg.examSlug}:answers`;

  function showScreen(id) {
    screens.forEach(s => $(s).classList.toggle("hidden", s !== id));
  }

  function saveSessionCache() {
    if (!state.sessionToken) return;
    localStorage.setItem(CACHE_KEY, JSON.stringify({
      sessionToken: state.sessionToken,
      attemptId: state.attemptId
    }));
  }

  function clearSessionCache() {
    localStorage.removeItem(CACHE_KEY);
    localStorage.removeItem(ANSWER_CACHE_KEY);
  }

  function loadAnswerCache() {
    try { return JSON.parse(localStorage.getItem(ANSWER_CACHE_KEY) || "{}"); }
    catch { return {}; }
  }

  function saveAnswerCache() {
    localStorage.setItem(ANSWER_CACHE_KEY, JSON.stringify(state.answers));
  }

  function isFullscreen() {
    return !!document.fullscreenElement;
  }

  async function requestFullscreen() {
    const root = document.documentElement;
    if (root.requestFullscreen) {
      await root.requestFullscreen({ navigationUI: "hide" }).catch(() => null);
    }
  }

  function environmentChecks() {
    $("checkStorage").className = "dot";
    try {
      localStorage.setItem("__mp_test", "1");
      localStorage.removeItem("__mp_test");
      $("checkStorage").classList.add("ok");
    } catch { $("checkStorage").classList.add("bad"); }

    $("checkFullscreen").className = "dot " +
      (document.documentElement.requestFullscreen ? "ok" : "bad");

    $("checkOnline").className = "dot " + (navigator.onLine ? "ok" : "bad");

    const screenOk = window.innerWidth >= 800 && window.innerHeight >= 500;
    $("checkScreen").className = "dot " + (screenOk ? "ok" : "warn");
  }

  function seededNumber(text) {
    let h = 2166136261;
    for (let i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return h >>> 0;
  }

  function shuffledOptions(options, seedText) {
    const arr = [...options];
    let seed = seededNumber(seedText) || 1;
    const rand = () => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return seed / 4294967296;
    };
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  }

  function normalizeQuestion(q) {
    const options = Array.isArray(q.options) ? q.options : [];
    return {
      id: q.id,
      type: q.type,
      stem: q.stem,
      // A ordem muda entre tentativas, mas permanece estável ao recarregar.
      options: shuffledOptions(options, `${state.sessionToken || ""}:${q.id}`)
    };
  }

  function hydrate(payload) {
    state.sessionToken = payload.session_token;
    state.attemptId = payload.attempt_id;
    state.studentName = payload.student_name;
    state.examTitle = payload.exam_title;
    state.durationMinutes = payload.duration_minutes;
    state.maxOccurrences = payload.max_occurrences;
    state.occurrences = payload.occurrences || 0;
    state.questions = (payload.questions || []).map(normalizeQuestion);
    state.startedAt = payload.started_at || null;
    state.endsAt = payload.ends_at || null;
    state.status = payload.status;
    state.answers = payload.answers || loadAnswerCache() || {};
    state.review = JSON.parse(localStorage.getItem(`${ANSWER_CACHE_KEY}:review`) || "{}");
    saveSessionCache();
  }

  async function tryResume() {
    let cached = null;
    try { cached = JSON.parse(localStorage.getItem(CACHE_KEY) || "null"); }
    catch {}
    if (!cached?.sessionToken) return false;

    try {
      const payload = await rpc("resume_attempt", { p_session_token: cached.sessionToken });
      if (!payload || payload.status === "submitted" || payload.status === "auto_submitted") {
        clearSessionCache();
        return false;
      }
      hydrate(payload);
      if (payload.status === "ready") {
        renderRules();
        showScreen("screenRules");
      } else {
        state.active = true;
        renderExam();
        showScreen("screenExam");
        await requestFullscreen();
        startTimer();
        flushPendingAnswers();
      }
      return true;
    } catch {
      return false;
    }
  }

  async function enterWithName() {
    const studentName = $("studentNameInput").value.trim();
    if (!studentName) {
      setMessage($("loginMessage"), "Informe seu nome completo.", "warn");
      return;
    }
    $("btnEnter").disabled = true;
    setMessage($("loginMessage"), "Localizando estudante…", "info");
    try {
      const payload = await rpc("start_attempt_by_name", {
        p_exam_slug: cfg.examSlug,
        p_student_name: studentName,
        p_user_agent: navigator.userAgent
      });
      hydrate(payload);
      renderRules();
      showScreen("screenRules");
      setMessage($("loginMessage"), "", "info");
    } catch (err) {
      setMessage($("loginMessage"), humanError(err.message), "error");
    } finally {
      $("btnEnter").disabled = false;
    }
  }

  function humanError(msg) {
    const m = String(msg || "");
    if (m.includes("Estudante não encontrado")) return "Nome não encontrado. Digite seu nome completo conforme a lista da turma.";
    if (m.includes("Nome ambíguo")) return "Há mais de um estudante com esse nome. Chame o professor.";
    if (m.includes("Avaliação indisponível")) return "Esta avaliação não está disponível neste momento.";
    if (m.includes("já iniciada")) return "Esta avaliação já foi iniciada para este estudante. Se for você, use o mesmo computador e chame o professor se a prova não for retomada automaticamente.";\n    if (m.includes("já finalizada")) return "Esta avaliação já foi finalizada para este estudante.";
    if (m.includes("configurada")) return m;
    return "Não foi possível acessar a avaliação. Verifique a conexão e tente novamente.";
  }

  function renderRules() {
    $("studentGreeting").textContent = `Olá, ${state.studentName}. Leia as regras.`;
    $("examLabel").textContent = state.examTitle ? ` — ${state.examTitle}` : "";
    $("ruleDuration").textContent = `${state.durationMinutes} min`;
    $("ruleQuestionCount").textContent = String(state.questions.length);
    $("ruleMaxOccurrences").textContent = String(state.maxOccurrences);
    $("acceptRules").checked = false;
    $("btnStart").disabled = true;
  }

  async function beginExam() {
    $("btnStart").disabled = true;
    try {
      await requestFullscreen();
      const payload = await rpc("begin_attempt", { p_session_token: state.sessionToken });
      state.startedAt = payload.started_at;
      state.endsAt = payload.ends_at;
      state.status = payload.status;
      state.occurrences = payload.occurrences || state.occurrences;
      state.active = true;
      renderExam();
      showScreen("screenExam");
      startTimer();
    } catch (err) {
      setMessage($("ruleMessage"), "Não foi possível iniciar a prova. Tente novamente.", "error");
      $("btnStart").disabled = false;
    }
  }

  function renderExam() {
    $("studentName").textContent = state.studentName || "—";
    $("occurrenceCount").textContent = state.occurrences;
    $("occurrenceMax").textContent = state.maxOccurrences;
    buildQuestionNav();
    renderQuestion();
  }

  function buildQuestionNav() {
    const nav = $("questionNav");
    nav.textContent = "";
    state.questions.forEach((q, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "qnav";
      b.textContent = i + 1;
      b.addEventListener("click", () => {
        state.index = i;
        renderQuestion();
      });
      nav.appendChild(b);
    });
    refreshQuestionNav();
  }

  function refreshQuestionNav() {
    document.querySelectorAll(".qnav").forEach((b, i) => {
      const q = state.questions[i];
      const ans = state.answers[q.id];
      b.classList.toggle("current", i === state.index);
      b.classList.toggle("answered", !!ans && (
        (ans.value !== undefined && ans.value !== "") ||
        (ans.text !== undefined && ans.text.trim() !== "")
      ));
      b.classList.toggle("review", !!state.review[q.id]);
    });
  }

  function renderQuestion() {
    const q = state.questions[state.index];
    if (!q) return;
    $("questionNumber").textContent = `Questão ${state.index + 1} de ${state.questions.length}`;
    $("questionStem").textContent = q.stem;
    $("markReview").checked = !!state.review[q.id];
    $("btnPrev").disabled = state.index === 0;
    $("btnNext").disabled = state.index === state.questions.length - 1;

    const area = $("answerArea");
    area.textContent = "";
    const current = state.answers[q.id] || {};

    if (q.type === "objective") {
      q.options.forEach(opt => {
        const label = document.createElement("label");
        label.className = "option";
        const input = document.createElement("input");
        input.type = "radio";
        input.name = `q-${q.id}`;
        input.value = opt.key;
        input.checked = current.value === opt.key;
        input.addEventListener("change", () => {
          state.answers[q.id] = { value: opt.key };
          queueSave(q.id);
          refreshQuestionNav();
        });
        const span = document.createElement("span");
        span.textContent = `${opt.key}) ${opt.text}`;
        label.append(input, span);
        area.appendChild(label);
      });
    } else {
      const textarea = document.createElement("textarea");
      textarea.rows = 8;
      textarea.placeholder = "Digite sua resposta…";
      textarea.value = current.text || "";
      let timer = null;
      textarea.addEventListener("input", () => {
        state.answers[q.id] = { text: textarea.value };
        saveAnswerCache();
        refreshQuestionNav();
        $("saveStatus").textContent = "Salvando…";
        clearTimeout(timer);
        timer = setTimeout(() => queueSave(q.id), 500);
      });
      area.appendChild(textarea);
    }

    refreshQuestionNav();
    $("saveStatus").textContent = "Resposta salva automaticamente quando alterada.";
  }

  function cachePending(qid) {
    state.pendingSync[qid] = state.answers[qid];
    localStorage.setItem(`${ANSWER_CACHE_KEY}:pending`, JSON.stringify(state.pendingSync));
  }

  async function queueSave(qid) {
    saveAnswerCache();
    cachePending(qid);
    if (!navigator.onLine) {
      $("saveStatus").textContent = "Sem conexão: resposta guardada neste computador.";
      return;
    }
    try {
      await rpc("save_answer", {
        p_session_token: state.sessionToken,
        p_question_id: qid,
        p_answer: state.answers[qid]
      });
      delete state.pendingSync[qid];
      localStorage.setItem(`${ANSWER_CACHE_KEY}:pending`, JSON.stringify(state.pendingSync));
      $("saveStatus").textContent = "Resposta salva.";
    } catch {
      $("saveStatus").textContent = "Resposta guardada localmente; aguardando sincronização.";
    }
  }

  async function flushPendingAnswers() {
    try {
      const cached = JSON.parse(localStorage.getItem(`${ANSWER_CACHE_KEY}:pending`) || "{}");
      state.pendingSync = { ...cached, ...state.pendingSync };
    } catch {}
    if (!navigator.onLine || !state.sessionToken) return;
    for (const [qid, ans] of Object.entries(state.pendingSync)) {
      try {
        await rpc("save_answer", {
          p_session_token: state.sessionToken,
          p_question_id: qid,
          p_answer: ans
        });
        delete state.pendingSync[qid];
      } catch {}
    }
    localStorage.setItem(`${ANSWER_CACHE_KEY}:pending`, JSON.stringify(state.pendingSync));
  }

  function startTimer() {
    const timerEl = $("timer");
    timerEl.classList.remove("hidden");

    const tick = async () => {
      if (!state.active || !state.endsAt) return;
      const remaining = new Date(state.endsAt).getTime() - Date.now();
      if (remaining <= 0) {
        timerEl.textContent = "00:00";
        await submitExam("time_expired", true);
        return;
      }
      const totalSec = Math.ceil(remaining / 1000);
      const min = Math.floor(totalSec / 60);
      const sec = totalSec % 60;
      timerEl.textContent = `${String(min).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
      timerEl.classList.toggle("danger-text", remaining <= 5 * 60 * 1000);
      setTimeout(tick, 500);
    };
    tick();
  }

  async function recordViolation(type) {
    if (!state.active || state.submitting) return;

    const now = Date.now();
    // Evita contar duas vezes o mesmo gesto (ex.: trocar aba também pode sair do fullscreen).
    if (now - state.lastViolationAt < 1500) return;
    state.lastViolationAt = now;
    state.lastViolationType = type;

    try {
      const q = state.questions[state.index];
      const payload = await rpc("record_violation", {
        p_session_token: state.sessionToken,
        p_event_type: type,
        p_question_id: q?.id || null,
        p_details: {
          visibility: document.visibilityState,
          fullscreen: isFullscreen(),
          index: state.index + 1
        }
      });
      state.occurrences = payload.occurrences;
      $("occurrenceCount").textContent = state.occurrences;
      showViolationToast(`Ocorrência registrada: ${state.occurrences}/${state.maxOccurrences}`);

      if (payload.status === "auto_submitted") {
        state.active = false;
        finishUi("A avaliação foi encerrada automaticamente após atingir o limite de ocorrências.");
      }
    } catch {
      showViolationToast("A ocorrência não pôde ser enviada agora; ela será registrada localmente.");
      const localEvents = JSON.parse(localStorage.getItem(`${ANSWER_CACHE_KEY}:events`) || "[]");
      localEvents.push({ type, at: new Date().toISOString(), question_id: state.questions[state.index]?.id || null });
      localStorage.setItem(`${ANSWER_CACHE_KEY}:events`, JSON.stringify(localEvents));
    }
  }

  function showViolationToast(text) {
    const t = $("violationToast");
    t.textContent = text;
    t.classList.remove("hidden");
    setTimeout(() => t.classList.add("hidden"), 3500);
  }

  async function submitExam(reason = "submitted", automatic = false) {
    if (state.submitting || !state.active) return;
    if (!automatic && !confirm("Deseja realmente finalizar a prova? Depois do envio não será possível voltar.")) return;
    state.submitting = true;
    await flushPendingAnswers();

    try {
      const payload = await rpc("submit_attempt", {
        p_session_token: state.sessionToken,
        p_reason: reason
      });
      state.active = false;
      state.status = payload.status;
      finishUi(reason === "time_expired"
        ? "O tempo da avaliação terminou e as respostas foram enviadas."
        : "Suas respostas foram enviadas com sucesso.");
    } catch {
      state.submitting = false;
      alert("Não foi possível enviar a prova agora. Verifique a conexão antes de tentar novamente.");
    }
  }

  async function flushLocalEvents() {
    if (!state.sessionToken || !navigator.onLine) return;
    let events = [];
    try { events = JSON.parse(localStorage.getItem(`${ANSWER_CACHE_KEY}:events`) || "[]"); } catch {}
    if (!events.length) return;
    const remaining = [];
    for (const e of events) {
      try {
        await rpc("record_violation", {
          p_session_token: state.sessionToken,
          p_event_type: e.type,
          p_question_id: e.question_id,
          p_details: { recovered_offline_event: true, original_at: e.at }
        });
      } catch { remaining.push(e); }
    }
    localStorage.setItem(`${ANSWER_CACHE_KEY}:events`, JSON.stringify(remaining));
  }

  function finishUi(message) {
    $("timer").classList.add("hidden");
    $("finishedMessage").textContent = message;
    $("fullscreenOverlay").classList.add("hidden");
    showScreen("screenFinished");
    clearSessionCache();
    document.exitFullscreen?.().catch(() => {});
  }

  function installSecurityHandlers() {
    ["copy", "cut", "paste", "contextmenu", "dragstart", "selectstart"].forEach(eventName => {
      document.addEventListener(eventName, e => {
        if (!state.active) return;
        const target = e.target;
        // Permite selecionar/digitar dentro de textarea de questão aberta, mas não copiar/colar.
        if (eventName === "selectstart" && target?.tagName === "TEXTAREA") return;
        e.preventDefault();
      });
    });

    document.addEventListener("keydown", e => {
      if (!state.active) return;
      const k = e.key.toLowerCase();
      const blockedCtrl = e.ctrlKey && ["c","v","x","p","s","u","l","r"].includes(k);
      const blockedDev = e.key === "F12" || (e.ctrlKey && e.shiftKey && ["i","j","c"].includes(k));
      if (blockedCtrl || blockedDev) {
        e.preventDefault();
        showViolationToast("Atalho desabilitado durante a avaliação.");
      }
    }, true);

    document.addEventListener("visibilitychange", () => {
      if (state.active && document.visibilityState === "hidden") {
        recordViolation("visibility_hidden");
      }
    });

    document.addEventListener("fullscreenchange", () => {
      if (!state.active || state.submitting) return;
      if (!isFullscreen()) {
        $("fullscreenOverlay").classList.remove("hidden");
        recordViolation("fullscreen_exit");
      } else {
        $("fullscreenOverlay").classList.add("hidden");
      }
    });

    window.addEventListener("beforeunload", e => {
      if (!state.active) return;
      e.preventDefault();
      e.returnValue = "";
    });
  }

  function installUiHandlers() {
    $("appTitle").textContent = cfg.appTitle || "Modo Prova";
    setConnectionBadge($("connectionBadge"));
    environmentChecks();

    $("btnEnter").addEventListener("click", enterWithName);
    $("studentNameInput").addEventListener("keydown", e => {
      if (e.key === "Enter") enterWithName();
    });

    $("acceptRules").addEventListener("change", () => {
      $("btnStart").disabled = !$("acceptRules").checked;
    });
    $("btnStart").addEventListener("click", beginExam);

    $("btnPrev").addEventListener("click", () => {
      if (state.index > 0) { state.index--; renderQuestion(); }
    });
    $("btnNext").addEventListener("click", () => {
      if (state.index < state.questions.length - 1) { state.index++; renderQuestion(); }
    });

    $("markReview").addEventListener("change", e => {
      const q = state.questions[state.index];
      if (!q) return;
      state.review[q.id] = e.target.checked;
      localStorage.setItem(`${ANSWER_CACHE_KEY}:review`, JSON.stringify(state.review));
      refreshQuestionNav();
    });

    $("btnSubmit").addEventListener("click", () => submitExam("submitted", false));
    $("btnReturnFullscreen").addEventListener("click", requestFullscreen);

    window.addEventListener("online", async () => {
      environmentChecks();
      await flushPendingAnswers();
      await flushLocalEvents();
    });
    window.addEventListener("offline", environmentChecks);
    window.addEventListener("resize", environmentChecks);
  }

  async function boot() {
    installUiHandlers();
    installSecurityHandlers();
    try {
      const resumed = await tryResume();
      if (!resumed) showScreen("screenLogin");
    } catch (err) {
      showScreen("screenLogin");
      setMessage($("loginMessage"), err.message, "error");
    }
  }

  boot();
})();
