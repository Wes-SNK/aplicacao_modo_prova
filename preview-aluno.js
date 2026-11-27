// Prévia pedagógica segura: reutiliza integralmente student.js e index.html,
// mas substitui TODAS as operações de aluno por ações locais no navegador.
// Somente as funções de leitura do professor acessam o Supabase, com sessão autenticada.
(() => {
  "use strict";
  const mp = window.ModeProva;
  const readRpc = mp.rpc;
  // Fail closed: mesmo que a validação da URL falhe, student.js não poderá
  // executar endpoints reais de aluno nesta página.
  mp.teacherPreview = true;
  mp.rpc = async () => {
    throw new Error("Prévia indisponível. Volte ao painel do professor.");
  };
  const $ = id => document.getElementById(id);
  const params = new URLSearchParams(window.location.search);
  const query = params.get("avaliacao");
  const customSlug = params.get("exame");
  const allowed = {
    simulado: "simulado-4bim-1b-2026",
    prova: "prova-4bim-1b-2026",
    anterior: "4bim-1b-2026"
  };
  const currentSlug = customSlug
    ? (/^preset-[0-9a-f]{32}$/.test(customSlug) ? customSlug : null)
    : (Object.prototype.hasOwnProperty.call(allowed, query) ? allowed[query] : null);
  if (!currentSlug || mp.cfg.examSlug !== currentSlug) {
    $("btnEnter").disabled = true;
    mp.setMessage($("loginMessage"),
      "Endereço de prévia inválido. Volte ao painel e use o botão Testar como aluno.",
      "error");
    return;
  }

  $("previewBackToTeacher").href = customSlug
    ? "painel.html?exame=" + encodeURIComponent(customSlug)
    : "painel.html" + (query === "prova" ? "?avaliacao=prova" :
      query === "anterior" ? "" : "?avaliacao=simulado");

  let preview = null;
  let previewLobby = null;
  let loggedIn = false;
  const tokenFailure = () => new Error(
    "Entre primeiro no painel do professor. A prévia exige sessão autenticada."
  );

  async function teacherRead(name, params) {
    const session = await mp.validTeacherSession();
    if (!session?.access_token) throw tokenFailure();
    return readRpc(name, params, session.access_token);
  }

  function shuffledForStudent(rows) {
    // O aluno recebe questões em ordem individualizada. Este embaralhamento
    // de prévia é LOCAL e não modifica a ordem cadastrada na avaliação.
    const arr = rows.slice();
    let seed = 2166136261;
    for (const item of arr) {
      const id = String(item.id);
      for (let i = 0; i < id.length; i++) {
        seed ^= id.charCodeAt(i);
        seed = Math.imul(seed, 16777619);
      }
    }
    for (let i = arr.length - 1; i > 0; i--) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const j = Math.floor((seed / 4294967296) * (i + 1));
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr;
  }

  function validateToken(args) {
    if (!preview || args?.p_session_token !== preview.token) {
      throw new Error("Sessão de prévia inválida. Reinicie a simulação.");
    }
  }

  function gradeLocal() {
    let score = 0;
    const total = preview.originalQuestions.reduce((sum, q) => sum + Number(q.points || 0), 0);
    for (const q of preview.originalQuestions) {
      if (preview.answers[q.id]?.value === q.correct_answer) score += Number(q.points || 0);
    }
    preview.score = score;
    preview.total = total;
  }

  async function previewRpc(name, args = {}) {
    switch (name) {
      case "student_lobby_join": {
        if (args.p_exam_slug !== currentSlug) {
          throw new Error("Avaliação diferente da selecionada no painel.");
        }
        const session = await mp.validTeacherSession();
        if (!session?.access_token) throw tokenFailure();
        const studentName = String(args.p_student_name || "").trim();
        if (!studentName) throw new Error("Informe o nome do estudante.");
        previewLobby = {
          token: crypto.randomUUID(), studentName,
          authorized: false, helpPending: false, x: 12, y: 65, emote: null
        };
        return { supervised: true, lobby_allowed: true,
          lobby_token: previewLobby.token, student_name: studentName };
      }
      case "student_lobby_state": {
        if (!previewLobby || args.p_lobby_token !== previewLobby.token) {
          throw new Error("Sala de espera de prévia inválida.");
        }
        return {
          authorized: previewLobby.authorized, is_active: true,
          lobby_allowed: true, help_pending: previewLobby.helpPending,
          peers: [{ id: "preview-self", self: true, style: 0,
            x: previewLobby.x, y: previewLobby.y, emote: previewLobby.emote }]
        };
      }
      case "student_lobby_move": {
        if (!previewLobby || args.p_lobby_token !== previewLobby.token)
          throw new Error("Sala de espera de prévia inválida.");
        previewLobby.x = args.p_x;
        previewLobby.y = args.p_y;
        previewLobby.emote = args.p_emote || null;
        return { ok: true };
      }
      case "student_lobby_help": {
        if (!previewLobby || args.p_lobby_token !== previewLobby.token)
          throw new Error("Sala de espera de prévia inválida.");
        previewLobby.helpPending = !!args.p_request;
        return { ok: true, help_pending: previewLobby.helpPending };
      }
      case "student_lobby_enter": {
        if (!previewLobby || args.p_lobby_token !== previewLobby.token ||
            !previewLobby.authorized) {
          throw new Error("Aguarde a liberação simulada da prova.");
        }
        return previewRpc("start_attempt_by_name", {
          p_exam_slug: currentSlug, p_student_name: previewLobby.studentName
        });
      }
      case "start_attempt_by_name": {
        if (!previewLobby?.authorized) {
          throw new Error("A prévia exige passagem pela sala de espera.");
        }
        if (preview && preview.status === "in_progress") {
          throw new Error("Já existe uma prévia em andamento nesta aba.");
        }
        if (args.p_exam_slug !== currentSlug) {
          throw new Error("Avaliação diferente da selecionada no painel.");
        }
        const [dashboard, set] = await Promise.all([
          teacherRead("teacher_dashboard", { p_exam_slug: currentSlug }),
          teacherRead("teacher_questions", { p_exam_slug: currentSlug })
        ]);
        loggedIn = true;
        const originalQuestions = (set.questions || [])
          .filter(q => q.active && q.type === "objective")
          .sort((a,b) => a.position - b.position);
        if (!originalQuestions.length || dashboard.question_count !== originalQuestions.length) {
          throw new Error("Não há questões disponíveis para esta prévia.");
        }
        preview = {
          token: crypto.randomUUID(),
          originalQuestions,
          questions: shuffledForStudent(originalQuestions),
          answers: {},
          review: {},
          status: "ready",
          startedAt: null,
          endsAt: null,
          occurrences: 0,
          score: 0,
          total: 0,
          duration: dashboard.duration_minutes,
          maxOccurrences: dashboard.max_occurrences,
          mode: dashboard.assessment_mode,
          title: dashboard.exam_title,
          studentName: (args.p_student_name || "PROFESSOR — TESTE").trim()
        };
        return {
          attempt_id: "preview-only",
          session_token: preview.token,
          student_name: preview.studentName,
          exam_title: preview.title,
          assessment_mode: preview.mode,
          duration_minutes: preview.duration,
          max_occurrences: preview.maxOccurrences,
          occurrences: 0,
          questions: preview.questions.map(q => ({
            id: q.id, type: q.type, stem: q.stem, options: q.options
          })),
          status: "ready",
          started_at: null,
          ends_at: null,
          answers: {},
          review_flags: {}
        };
      }
      case "begin_attempt": {
        validateToken(args);
        if (preview.status !== "ready") throw new Error("A prévia já foi iniciada.");
        preview.startedAt = new Date().toISOString();
        preview.endsAt = preview.duration == null ? null
          : new Date(Date.now() + Number(preview.duration) * 60000).toISOString();
        preview.status = "in_progress";
        return {
          started_at: preview.startedAt,
          ends_at: preview.endsAt,
          status: preview.status,
          occurrences: preview.occurrences
        };
      }
      case "save_answer": {
        validateToken(args);
        if (preview.status !== "in_progress") throw new Error("Prévia encerrada.");
        if (!preview.originalQuestions.some(q => q.id === args.p_question_id)) {
          throw new Error("Questão não encontrada na prévia.");
        }
        preview.answers[args.p_question_id] = args.p_answer;
        return { ok: true, saved_at: new Date().toISOString() };
      }
      case "save_review_flag": {
        validateToken(args);
        preview.review[args.p_question_id] = !!args.p_marked;
        return { ok: true };
      }
      case "record_violation": {
        validateToken(args);
        if (preview.status !== "in_progress") {
          return { occurrences: preview.occurrences, status: preview.status };
        }
        preview.occurrences += 1;
        if (preview.occurrences >= preview.maxOccurrences) {
          gradeLocal();
          preview.status = "auto_submitted";
        }
        return { occurrences: preview.occurrences, status: preview.status };
      }
      case "submit_attempt": {
        validateToken(args);
        if (preview.status === "in_progress" || preview.status === "ready") {
          gradeLocal();
          preview.status = ["time_expired","occurrence_limit"].includes(args.p_reason)
            ? "auto_submitted" : "submitted";
        }
        return {
          status: preview.status,
          score: preview.score,
          max_score: preview.total,
          assessment_mode: preview.mode
        };
      }
      case "simulation_result": {
        validateToken(args);
        if (preview.mode !== "simulation" ||
            !["submitted","auto_submitted"].includes(preview.status)) {
          throw new Error("Resultado detalhado indisponível.");
        }
        return {
          score: preview.score,
          max_score: preview.total,
          percentage: preview.total ? Math.round(preview.score / preview.total * 1000) / 10 : 0,
          questions: preview.questions.map(q => ({
            position: q.position,
            stem: q.stem,
            options: q.options,
            answer: preview.answers[q.id] || {},
            correct_answer: q.correct_answer,
            is_correct: preview.answers[q.id]?.value === q.correct_answer,
            points: q.points,
            explanation: q.explanation
          }))
        };
      }
      case "resume_attempt": {
        // A prévia é efêmera e sempre reinicia após atualização da página.
        throw new Error("A prévia anterior terminou. Inicie uma nova simulação.");
      }
      default:
        // NUNCA encaminhar operações de aluno ao Supabase.
        throw new Error("Ação não disponível na prévia: " + name);
    }
  }

  mp.rpc = previewRpc;

  // A prévia possui liberação pedagógica local, sem modificar o preset
  // ou autorizar estudantes no Supabase.
  $("previewReleaseExam").addEventListener("click", async () => {
    if (!previewLobby) return;
    previewLobby.authorized = true;
    $("previewReleaseExam").disabled = true;
    $("previewReleaseExam").textContent = "Liberação simulada realizada";
    await mp.lobbyBridge?.refresh();
  });

  // Se não houver sessão do professor, a página exibe uma instrução clara.
  mp.validTeacherSession().then(session => {
    if (!session?.access_token) {
      const input = $("studentNameInput");
      if (input) input.disabled = true;
      const enter = $("btnEnter");
      if (enter) enter.disabled = true;
      mp.setMessage($("loginMessage"),
        "Entre no painel do professor para usar a prévia. Volte pelo link acima.",
        "warn");
    }
  }).catch(() => {
    $("btnEnter").disabled = true;
    mp.setMessage($("loginMessage"),
      "Não foi possível validar a sessão do professor. Entre novamente no painel.",
      "error");
  });
})();
