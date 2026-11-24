(() => {
  "use strict";

  const {
    cfg, rpc, signIn, saveTeacherSession, validTeacherSession,
    clearTeacherSession, formatDateTime, setMessage, setConnectionBadge, downloadText
  } = window.ModeProva;

  const $ = id => document.getElementById(id);
  let session = null;
  let dashboardData = null;
  let pollTimer = null;
  let resetTarget = null;
  let resumeTarget = null;
  let questionsData = [];
  let questionsLocked = false;
  let editingQuestionId = null;
  let deleteQuestionTarget = null;
  let bankQuestions = [];
  let bankTotal = 0;
  let bankFilterTimer = null;
  let editorMode = "exam";
  let settingsDirty = false;
  let quickToggleBusy = false;
  const SIMULADO_PRESET_SLUG = "simulado-4bim-1b-2026";
  const difficultyLabels = { facil: "Fácil", media: "Média", dificil: "Difícil" };
  function syncOptionFields() {
    const five = $("questionOptionCount").value === "5";
    $("optionERow").classList.toggle("hidden", !five);
    $("optionECorrect").classList.toggle("hidden", !five);
    $("optionECorrect").disabled = !five;
    if (!five && $("correctAnswerInput").value === "E") $("correctAnswerInput").value = "A";
  }

  function showLogin() {
    $("teacherLogin").classList.remove("hidden");
    $("teacherDashboard").classList.add("hidden");
    $("btnLogout").classList.add("hidden");
    if (pollTimer) clearInterval(pollTimer);
  }

  function showDashboard() {
    $("teacherLogin").classList.add("hidden");
    $("teacherDashboard").classList.remove("hidden");
    $("btnLogout").classList.remove("hidden");
  }

  async function teacherRpc(name, args = {}) {
    session = await validTeacherSession();
    if (!session) throw new Error("Sessão expirada.");
    return rpc(name, args, session.access_token);
  }

  async function login() {
    const email = $("teacherEmail").value.trim();
    const password = $("teacherPassword").value;
    if (!email || !password) {
      setMessage($("teacherLoginMessage"), "Informe e-mail e senha.", "warn");
      return;
    }
    $("btnTeacherLogin").disabled = true;
    try {
      const s = await signIn(email, password);
      saveTeacherSession(s);
      session = await validTeacherSession();
      setMessage($("teacherLoginMessage"), "", "info");
      showDashboard();
      await refreshDashboard();
      await loadQuestions();
      await loadBankQuestions();
      startPolling();
    } catch (err) {
      setMessage($("teacherLoginMessage"), "Falha no login. Verifique as credenciais.", "error");
    } finally {
      $("btnTeacherLogin").disabled = false;
    }
  }

  function statusLabel(status) {
    return {
      ready: "Preparada",
      in_progress: "Em andamento",
      submitted: "Finalizada",
      auto_submitted: "Encerrada automaticamente"
    }[status] || status;
  }

  function statusClass(status) {
    if (status === "in_progress") return "pill info";
    if (status === "submitted") return "pill ok";
    if (status === "auto_submitted") return "pill danger";
    return "pill";
  }

  async function refreshDashboard() {
    try {
      const data = await teacherRpc("teacher_dashboard", { p_exam_slug: cfg.examSlug });
      dashboardData = data;
      renderDashboard(data);
      $("dashboardMessage").textContent = `Atualizado em ${new Date().toLocaleTimeString("pt-BR")}.`;
    } catch (err) {
      if (String(err.message).includes("Sessão")) {
        clearTeacherSession();
        showLogin();
        return;
      }
      $("dashboardMessage").textContent = "Não foi possível atualizar o painel.";
    }
  }

  function renderDashboard(data) {
    renderQuickSimulado(data);
    $("teacherExamLabel").textContent = data.exam_title ? ` — ${data.exam_title}` : "";
    $("dashboardTitle").textContent = data.exam_title || "Avaliação";
    const durationText = data.duration_minutes == null ? "Sem limite de tempo" : data.duration_minutes + " min";
    $("dashboardMeta").textContent =
      (data.assessment_mode === "simulation" ? "Simulado" : "Prova") + " • " + durationText +
      " • limite de " + data.max_occurrences + " ocorrência(s) • " + data.question_count + " questão(ões)";
    // A atualização automática não deve sobrescrever alterações não salvas pelo professor.
    if (!settingsDirty) {
      $("examTitleInput").value = data.exam_title || "";
      const presetValues = ["30","45","60","90","120","180","240"];
      const durationPreset = data.duration_minutes == null ? "none"
        : (presetValues.includes(String(data.duration_minutes)) ? String(data.duration_minutes) : "custom");
      $("examDurationPreset").value = durationPreset;
      $("examDurationCustomGroup").classList.toggle("hidden", durationPreset !== "custom");
      $("examDurationInput").value = data.duration_minutes ?? 60;
      $("examOccurrencesInput").value = data.max_occurrences ?? 3;
      $("examActiveInput").checked = !!data.is_active;
      $("examModeInput").value = data.assessment_mode || "exam";
    }
    $("examActiveBadge").textContent = data.is_active ? "Ativa" : "Inativa";
    $("examActiveBadge").className = data.is_active ? "pill ok" : "pill danger";

    const rows = data.attempts || [];
    $("statTotal").textContent = rows.length;
    $("statProgress").textContent = rows.filter(r => r.status === "in_progress").length;
    $("statFinished").textContent = rows.filter(r => ["submitted","auto_submitted"].includes(r.status)).length;
    $("statViolations").textContent = rows.filter(r => (r.occurrences || 0) > 0).length;

    const tbody = $("attemptsTable").querySelector("tbody");
    tbody.textContent = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");

      const tdName = document.createElement("td");
      tdName.textContent = r.student_name;

      const tdClass = document.createElement("td");
      tdClass.textContent = r.class_group || "—";

      const tdStatus = document.createElement("td");
      const pill = document.createElement("span");
      pill.className = statusClass(r.status);
      pill.textContent = statusLabel(r.status);
      tdStatus.appendChild(pill);

      const tdStart = document.createElement("td");
      tdStart.textContent = formatDateTime(r.started_at);

      const tdSubmit = document.createElement("td");
      tdSubmit.textContent = formatDateTime(r.submitted_at);

      const tdScore = document.createElement("td");
      tdScore.textContent = r.score === null || r.score === undefined
        ? "—"
        : `${Number(r.score).toFixed(1)} / ${Number(r.max_score).toFixed(1)}`;

      const tdOcc = document.createElement("td");
      tdOcc.textContent = String(r.occurrences || 0);

      const tdAction = document.createElement("td");
      tdAction.className = "row-actions";

      const btn = document.createElement("button");
      btn.className = "small secondary";
      btn.textContent = "Detalhes";
      btn.addEventListener("click", () => openDetail(r.attempt_id));

      if (r.status === "in_progress") {
        const resumeBtn = document.createElement("button");
        resumeBtn.className = "small secondary";
        resumeBtn.textContent = r.resume_allowed ? "Retomada liberada" : "Continuar de onde parou";
        resumeBtn.disabled = !!r.resume_allowed;
        resumeBtn.title = r.resume_allowed
          ? "O aluno já pode entrar novamente pelo nome para continuar."
          : "Preserva respostas e tempo já consumido, mas invalida a sessão anterior.";
        resumeBtn.addEventListener("click", () => openResumeAttempt(r));
        tdAction.appendChild(resumeBtn);
      }

      const retryBtn = document.createElement("button");
      retryBtn.className = "small danger";
      retryBtn.textContent = "Nova tentativa (do zero)";
      retryBtn.title = "Apaga a tentativa atual e permite que o aluno recomece do zero.";
      retryBtn.addEventListener("click", () => openResetAttempt(r));

      tdAction.append(btn, retryBtn);

      tr.append(tdName, tdClass, tdStatus, tdStart, tdSubmit, tdScore, tdOcc, tdAction);
      tbody.appendChild(tr);
    });
  }

  // Preset de publicação: altera SOMENTE o estado online no banco.
  // Duração, ocorrências e questões permanecem conforme já foram salvas.
  function renderQuickSimulado(data) {
    const panel = $("simuladoQuickPublish");
    const isPreset = cfg.examSlug === SIMULADO_PRESET_SLUG;
    panel.classList.toggle("hidden", !isPreset);
    if (!isPreset || !data) return;

    const online = !!data.is_active;
    const badge = $("quickSimuladoBadge");
    badge.textContent = online ? "Online para alunos" : "Fora do ar";
    badge.className = online ? "pill ok" : "pill danger";
    const duration = data.duration_minutes == null
      ? "sem limite de tempo" : data.duration_minutes + " minutos";
    $("quickSimuladoInfo").textContent =
      data.question_count + " questões • " + duration +
      " • limite de " + data.max_occurrences + " ocorrências" +
      " • ponderação do preset: 8 fáceis, 9 médias e 3 difíceis";
    const button = $("btnToggleSimuladoOnline");
    button.textContent = quickToggleBusy
      ? "Atualizando publicação…"
      : (online ? "Tirar simulado do ar" : "Colocar simulado online");
    button.className = online ? "danger" : "primary";
    button.disabled = quickToggleBusy ||
      data.assessment_mode !== "simulation" || (!online && data.question_count !== 20);
    button.title = (!online && data.question_count !== 20)
      ? "O preset exige 20 questões ativas; revise a avaliação antes de publicar."
      : "";
  }

  async function toggleSimuladoOnline() {
    if (cfg.examSlug !== SIMULADO_PRESET_SLUG || !dashboardData || quickToggleBusy) return;
    const willActivate = !dashboardData.is_active;
    if (settingsDirty && !window.confirm(
      "Existem alterações não salvas nas configurações. A publicação rápida utiliza apenas os valores que já estão salvos, sem aplicar essas alterações. Continuar?"
    )) return;

    const currentDuration = dashboardData.duration_minutes == null
      ? "sem limite de tempo" : dashboardData.duration_minutes + " minutos";
    const inProgress = (dashboardData.attempts || [])
      .filter(row => row.status === "in_progress").length;
    const confirmation = willActivate
      ? "Colocar o simulado de 01/12 ONLINE agora para os alunos?\n\n" +
        "20 questões • " + currentDuration + " • " +
        dashboardData.max_occurrences + " ocorrências.\n\n" +
        "O botão não altera a prova oficial."
      : "Tirar o simulado de 01/12 do ar agora?\n\n" +
        "Novos acessos serão bloqueados. " +
        (inProgress ? "Há " + inProgress + " tentativa(s) em andamento. " : "") +
        "As tentativas já registradas não serão excluídas.";
    if (!window.confirm(confirmation)) return;

    quickToggleBusy = true;
    renderQuickSimulado(dashboardData);
    $("quickSimuladoMessage").textContent = "Atualizando o estado do simulado…";
    try {
      const result = await teacherRpc("teacher_set_simulado_online", {
        p_online: willActivate
      });
      if (result.is_active !== willActivate) {
        throw new Error("O servidor não confirmou o estado de publicação solicitado.");
      }
      // Sincroniza a interface mesmo quando existem ajustes de formulário não salvos.
      dashboardData = { ...dashboardData, is_active: result.is_active };
      $("examActiveInput").checked = result.is_active;
      renderQuickSimulado(dashboardData);
      await refreshDashboard();
      $("quickSimuladoMessage").textContent = willActivate
        ? "Simulado liberado. O link do aluno já pode ser utilizado."
        : "Simulado retirado do ar. Tentativas e resultados foram preservados.";
    } catch (err) {
      $("quickSimuladoMessage").textContent =
        err.message || "Não foi possível alterar a publicação. Verifique o painel e tente novamente.";
    } finally {
      quickToggleBusy = false;
      renderQuickSimulado(dashboardData);
    }
  }

  async function openDetail(attemptId) {
    try {
      const data = await teacherRpc("teacher_attempt_detail", { p_attempt_id: attemptId });
      $("detailStudent").textContent = data.student_name;
      $("detailMeta").textContent =
        `${data.class_group || "Sem turma"} • ${statusLabel(data.status)} • ocorrências: ${data.occurrences}`;

      const answers = $("detailAnswers");
      answers.textContent = "";
      (data.answers || []).forEach((a, idx) => {
        const box = document.createElement("div");
        box.className = "answer-detail";
        const h = document.createElement("strong");
        h.textContent = `${idx + 1}. ${a.stem}`;
        const p = document.createElement("p");
        if (a.type === "objective") {
          const chosen = a.answer?.value ?? "Sem resposta";
          p.textContent = `Resposta: ${chosen} • Gabarito: ${a.correct_answer ?? "—"}`;
        } else {
          p.textContent = `Resposta: ${a.answer?.text || "Sem resposta"}`;
        }
        box.append(h, p);
        answers.appendChild(box);
      });

      const evBody = $("detailEvents");
      evBody.textContent = "";
      (data.events || []).forEach(e => {
        const tr = document.createElement("tr");
        [formatDateTime(e.occurred_at), e.event_type, e.counted ? "Sim" : "Não", e.question_position || "—"]
          .forEach(v => {
            const td = document.createElement("td");
            td.textContent = String(v);
            tr.appendChild(td);
          });
        evBody.appendChild(tr);
      });

      $("detailModal").classList.remove("hidden");
    } catch {
      alert("Não foi possível carregar os detalhes.");
    }
  }

  async function loadQuestions() {
    try {
      const data = await teacherRpc("teacher_questions", { p_exam_slug: cfg.examSlug });
      questionsData = data.questions || [];
      questionsLocked = !!data.locked;
      renderQuestionList();
    } catch (err) {
      $("questionsMessage").textContent = "Não foi possível carregar as questões.";
    }
  }

  function renderQuestionList() {
    const activeQuestions = questionsData.filter(q => q.active);
    const difficultyCounts = {
      facil: activeQuestions.filter(q => q.difficulty === "facil").length,
      media: activeQuestions.filter(q => q.difficulty === "media").length,
      dificil: activeQuestions.filter(q => q.difficulty === "dificil").length
    };
    const classified = difficultyCounts.facil + difficultyCounts.media + difficultyCounts.dificil;
    const difficultySummary = classified
      ? " • Fácil: " + difficultyCounts.facil +
        " • Média: " + difficultyCounts.media + " • Difícil: " + difficultyCounts.dificil
      : "";
    $("questionsMeta").textContent =
      activeQuestions.length + " ativa(s) • " + questionsData.length + " cadastrada(s)" + difficultySummary;

    const lock = $("questionsLockMessage");
    if (questionsLocked) {
      lock.textContent = "A estrutura da prova está bloqueada porque já existem tentativas registradas. Para preservar igualdade entre os alunos, questões não podem ser criadas, alteradas, excluídas ou reordenadas enquanto houver tentativas.";
      lock.classList.remove("hidden");
    } else {
      lock.classList.add("hidden");
    }
    $("btnNewQuestion").disabled = questionsLocked;

    const list = $("questionList");
    list.textContent = "";
    const difficultyFilter = $("assessmentDifficultyFilter").value;
    const visibleQuestions = questionsData.filter(q =>
      !difficultyFilter ||
      (difficultyFilter === "sem_classificacao" ? !q.difficulty : q.difficulty === difficultyFilter)
    );
    if (!visibleQuestions.length) {
      const empty = document.createElement("p");
      empty.className = "muted";
      empty.textContent = questionsData.length
        ? "Nenhuma questão corresponde a este filtro."
        : "Nenhuma questão cadastrada.";
      list.appendChild(empty);
      $("questionsMessage").textContent = "";
      return;
    }
    $("questionsMessage").textContent = difficultyFilter
      ? visibleQuestions.length + " de " + questionsData.length + " questão(ões) exibida(s)."
      : "";

    visibleQuestions.forEach(q => {
      const index = questionsData.findIndex(item => item.id === q.id);
      const card = document.createElement("div");
      card.className = "question-admin-item";

      const head = document.createElement("div");
      head.className = "question-admin-head";

      const titleWrap = document.createElement("div");
      const title = document.createElement("strong");
      title.textContent = `Questão ${q.position}`;
      const badges = document.createElement("div");
      badges.className = "question-badges";

      const typeBadge = document.createElement("span");
      typeBadge.className = "pill info";
      typeBadge.textContent = "Objetiva";

      const activeBadge = document.createElement("span");
      activeBadge.className = q.active ? "pill ok" : "pill";
      activeBadge.textContent = q.active ? "Ativa" : "Inativa";
      badges.append(typeBadge, activeBadge);
      titleWrap.append(title, badges);

      const actions = document.createElement("div");
      actions.className = "row-actions";

      const up = document.createElement("button");
      up.className = "small secondary";
      up.textContent = "↑";
      up.title = "Mover para cima";
      up.disabled = questionsLocked || index === 0;
      up.addEventListener("click", () => moveQuestion(q.id, -1));

      const down = document.createElement("button");
      down.className = "small secondary";
      down.textContent = "↓";
      down.title = "Mover para baixo";
      down.disabled = questionsLocked || index === questionsData.length - 1;
      down.addEventListener("click", () => moveQuestion(q.id, 1));

      const edit = document.createElement("button");
      edit.className = "small secondary";
      edit.textContent = "Editar";
      edit.disabled = questionsLocked;
      edit.addEventListener("click", () => openQuestionEditor(q));

      const del = document.createElement("button");
      del.className = "small danger";
      del.textContent = "Excluir";
      del.disabled = questionsLocked;
      del.addEventListener("click", () => openDeleteQuestion(q));

      actions.append(up, down, edit, del);
      head.append(titleWrap, actions);

      const stem = document.createElement("p");
      stem.className = "question-admin-stem";
      stem.textContent = q.stem;

      const meta = document.createElement("p");
      meta.className = "muted question-admin-meta";
      meta.textContent = "Gabarito: " + (q.correct_answer || "—") +
        " • " + Number(q.points || 0).toFixed(1) + " ponto(s)" +
        (q.difficulty ? " • " + (difficultyLabels[q.difficulty] || q.difficulty) : "");

      card.append(head, stem, meta);
      list.appendChild(card);
    });
  }


  // Banco permanente: cada aplicação recebe uma cópia; o item original é preservado.
  async function loadBankQuestions() {
    const message = $("bankMessage");
    message.textContent = "Consultando questões…";
    try {
      const data = await teacherRpc("teacher_bank_questions_v2", {
        p_subject: $("bankSubjectFilter").value || null,
        p_search: $("bankSearchInput").value.trim() || null,
        p_difficulty: $("bankDifficultyFilter").value || null
      });
      bankQuestions = data.questions || [];
      bankTotal = Number(data.total || 0);
      renderBankQuestions();
      message.textContent = "Exibindo " + bankQuestions.length + " de " + bankTotal + " questões preservadas.";
    } catch (err) {
      message.textContent = err.message || "Não foi possível consultar o banco.";
    }
  }

  function renderBankQuestions() {
    $("bankMeta").textContent = bankTotal + " questões disponíveis para reutilização";
    const container = $("bankQuestionList");
    container.textContent = "";
    if (!bankQuestions.length) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "Nenhuma questão encontrada com estes filtros.";
      container.appendChild(p);
      return;
    }
    bankQuestions.forEach(q => {
      const item = document.createElement("div");
      item.className = "question-admin-item";
      const header = document.createElement("div");
      header.className = "question-admin-head";
      const detail = document.createElement("div");
      const heading = document.createElement("strong");
      heading.textContent = q.subject + (q.topic ? " — " + q.topic : "");
      const meta = document.createElement("p");
      meta.className = "muted question-admin-meta";
      meta.textContent = q.source_label + " • " + (difficultyLabels[q.difficulty] || "Não classificada") +
        " • " + q.option_count + " alternativas • Gabarito: " + q.correct_answer;
      detail.append(heading, meta);
      const tools = document.createElement("div");
      tools.className = "toolbar";
      const preview = document.createElement("button");
      preview.className = "small secondary";
      preview.textContent = "Visualizar";
      preview.addEventListener("click", () => openBankPreview(q));
      const add = document.createElement("button");
      add.className = "small primary";
      const duplicate = questionsData.some(existing =>
        existing.stem === q.stem && existing.correct_answer === q.correct_answer
        && JSON.stringify(existing.options) === JSON.stringify(q.options)
      );
      add.disabled = questionsLocked || duplicate || ![4,5].includes(q.option_count);
      add.textContent = duplicate ? "Já incluída" : "Adicionar à avaliação";
      if (questionsLocked) add.title = "A avaliação já possui tentativas; não pode ser modificada.";
      if (![4,5].includes(q.option_count)) add.title = "Formato inválido de alternativas.";
      add.addEventListener("click", async () => {
        add.disabled = true;
        $("bankMessage").textContent = "Incluindo questão…";
        try {
          await teacherRpc("teacher_bank_add_to_exam", {
            p_exam_slug: cfg.examSlug,
            p_bank_question_id: q.id
          });
          await loadQuestions();
          await refreshDashboard();
          renderBankQuestions();
          $("bankMessage").textContent = "Incluída na avaliação. O item original permanece no banco.";
        } catch (err) {
          renderBankQuestions();
          $("bankMessage").textContent = err.message || "Não foi possível incluir.";
        }
      });
      tools.append(preview, add);
      header.append(detail, tools);
      const stem = document.createElement("p");
      stem.className = "question-admin-stem";
      stem.textContent = q.stem;
      item.append(header, stem);
      container.appendChild(item);
    });
  }

  function openBankPreview(q) {
    $("questionPreviewTitle").textContent = "Questão do banco — " + q.subject;
    const container = $("questionPreviewList");
    container.textContent = "";
    const heading = document.createElement("h3");
    heading.textContent = q.stem;
    container.appendChild(heading);
    (q.options || []).forEach(option => {
      const p = document.createElement("p");
      p.textContent = option.key + ") " + option.text + (option.key === q.correct_answer ? " ✓" : "");
      if (option.key === q.correct_answer) p.className = "preview-correct";
      container.appendChild(p);
    });
    if (q.explanation) {
      const p = document.createElement("p");
      p.textContent = "Justificativa: " + q.explanation;
      container.appendChild(p);
    }
    $("questionPreviewModal").classList.remove("hidden");
  }

  function openQuestionEditor(q = null, mode = "exam") {
    if (questionsLocked && mode !== "bank") return;
    editorMode = mode;
    editingQuestionId = mode === "bank" ? null : (q?.id || null);
    $("questionEditorTitle").textContent = mode === "bank"
      ? "Nova questão no banco"
      : (q ? "Editar questão " + q.position : "Nova questão da avaliação");
    $("questionBankMetadata").classList.toggle("hidden", mode !== "bank");
    $("questionActiveRow").classList.toggle("hidden", mode === "bank");
    $("questionSubjectInput").value = $("bankSubjectFilter").value || "Lógica de Programação";
    $("questionTopicInput").value = "";
    $("questionDifficultyInput").value = q?.difficulty || "";
    $("questionOptionCount").value = String(q?.options?.length === 5 ? 5 : 4);
    syncOptionFields();
    $("btnSaveQuestion").textContent = mode === "bank" ? "Salvar no banco" : "Salvar questão";
    $("questionStemInput").value = q?.stem || "";
    $("questionExplanationInput").value = q?.explanation || "";
    $("questionActiveInput").checked = q?.active ?? true;
    $("questionPointsInput").value = Number(q?.points ?? 1);

    const optionMap = {};
    (q?.options || []).forEach(o => optionMap[o.key] = o.text);
    ["A","B","C","D","E"].forEach(k => {
      $(`option${k}Input`).value = optionMap[k] || "";
    });
    $("correctAnswerInput").value = q?.correct_answer || "A";
    setMessage($("questionEditorMessage"), "", "info");
    $("questionEditorModal").classList.remove("hidden");
  }

  function closeQuestionEditor() {
    editingQuestionId = null;
    editorMode = "exam";
    $("questionEditorModal").classList.add("hidden");
  }

  async function saveQuestion() {
    if (questionsLocked && editorMode !== "bank") return;
    const stem = $("questionStemInput").value.trim();
    const active = $("questionActiveInput").checked;
    let options = [];
    let correct = null;
    let points = 0;

    if (!stem) {
      setMessage($("questionEditorMessage"), "Informe o enunciado.", "warn");
      return;
    }

    const optionKeys = $("questionOptionCount").value === "5"
      ? ["A","B","C","D","E"] : ["A","B","C","D"];
    options = optionKeys.map(key => ({ key, text: $("option" + key + "Input").value.trim() }));
    if (options.some(o => !o.text)) {
      setMessage($("questionEditorMessage"), "Preencha todas as alternativas do formato escolhido.", "warn");
      return;
    }
    correct = $("correctAnswerInput").value;
    points = Number($("questionPointsInput").value);
    if (!Number.isFinite(points) || points <= 0 || points > 100) {
      setMessage($("questionEditorMessage"), "Informe um valor maior que 0 e de até 100.", "warn");
      return;
    }

    $("btnSaveQuestion").disabled = true;
    setMessage($("questionEditorMessage"), "Salvando…", "info");
    try {
      if (editorMode === "bank") {
        const result = await teacherRpc("teacher_bank_create_v2", {
          p_subject: $("questionSubjectInput").value,
          p_topic: $("questionTopicInput").value.trim() || null,
          p_stem: stem,
          p_options: options,
          p_correct_answer: correct,
          p_explanation: $("questionExplanationInput").value.trim() || null,
          p_points: points,
          p_difficulty: $("questionDifficultyInput").value || null
        });
        closeQuestionEditor();
        await loadBankQuestions();
        $("bankMessage").textContent = result.existing
          ? "Esta versão já existe no banco."
          : "Questão criada no banco; adicione-a quando montar uma avaliação.";
      } else {
        await teacherRpc("teacher_save_question_v3", {
          p_exam_slug: cfg.examSlug,
          p_question_id: editingQuestionId,
          p_type: "objective",
          p_stem: stem,
          p_options: options,
          p_correct_answer: correct,
          p_points: points,
          p_active: active,
          p_explanation: $("questionExplanationInput").value.trim() || null,
          p_difficulty: $("questionDifficultyInput").value || null
        });
        closeQuestionEditor();
        await loadQuestions();
        await loadBankQuestions();
        await refreshDashboard();
        $("questionsMessage").textContent = "Questão salva e preservada no banco.";
      }
    } catch (err) {
      setMessage($("questionEditorMessage"), err.message || "Não foi possível salvar a questão.", "error");
    } finally {
      $("btnSaveQuestion").disabled = false;
    }
  }

  async function moveQuestion(questionId, direction) {
    if (questionsLocked) return;
    try {
      await teacherRpc("teacher_move_question", {
        p_question_id: questionId,
        p_direction: direction
      });
      await loadQuestions();
    } catch (err) {
      $("questionsMessage").textContent = err.message || "Não foi possível reordenar a questão.";
    }
  }

  function openDeleteQuestion(q) {
    if (questionsLocked) return;
    deleteQuestionTarget = q;
    $("deleteQuestionText").textContent = `Excluir definitivamente a questão ${q.position}?`;
    $("deleteQuestionModal").classList.remove("hidden");
  }

  function closeDeleteQuestion() {
    deleteQuestionTarget = null;
    $("deleteQuestionModal").classList.add("hidden");
  }

  async function confirmDeleteQuestion() {
    if (!deleteQuestionTarget) return;
    const target = deleteQuestionTarget;
    $("btnConfirmDeleteQuestion").disabled = true;
    try {
      await teacherRpc("teacher_delete_question", { p_question_id: target.id });
      closeDeleteQuestion();
      await loadQuestions();
      await loadBankQuestions();
      await refreshDashboard();
      $("questionsMessage").textContent = "Questão retirada da avaliação, preservada no banco.";
    } catch (err) {
      $("deleteQuestionText").textContent = err.message || "Não foi possível excluir a questão.";
    } finally {
      $("btnConfirmDeleteQuestion").disabled = false;
    }
  }

  function openQuestionPreview() {
    const difficultyFilter = $("assessmentDifficultyFilter").value;
    const previewLabel = difficultyFilter === "sem_classificacao"
      ? "Sem classificação"
      : (difficultyLabels[difficultyFilter] || "Todas as dificuldades");
    $("questionPreviewTitle").textContent = "Pré-visualização da avaliação — " + previewLabel;
    const area = $("questionPreviewList");
    area.textContent = "";
    const active = questionsData.filter(q => q.active &&
      (!difficultyFilter || (difficultyFilter === "sem_classificacao"
        ? !q.difficulty : q.difficulty === difficultyFilter)));
    if (!active.length) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "Não há questões ativas para pré-visualizar.";
      area.appendChild(p);
    } else {
      active.forEach((q, idx) => {
        const box = document.createElement("div");
        box.className = "preview-question";
        const h = document.createElement("h3");
        h.textContent = `${idx + 1}. ${q.stem}`;
        box.appendChild(h);
        (q.options || []).forEach(o => {
          const p = document.createElement("p");
          p.className = o.key === q.correct_answer ? "preview-correct" : "";
          p.textContent = `${o.key}) ${o.text}${o.key === q.correct_answer ? " ✓" : ""}`;
          box.appendChild(p);
        });
        if (q.explanation) {
          const expl = document.createElement("p");
          expl.textContent = `Justificativa: ${q.explanation}`;
          box.appendChild(expl);
        }
        area.appendChild(box);
      });
    }
    $("questionPreviewModal").classList.remove("hidden");
  }

  async function saveExamSettings() {
    const title = $("examTitleInput").value.trim();
    const selectedDuration = $("examDurationPreset").value;
    const duration = selectedDuration === "none" ? null
      : (selectedDuration === "custom" ? Number($("examDurationInput").value) : Number(selectedDuration));
    const maxOccurrences = Number($("examOccurrencesInput").value);
    const isActive = $("examActiveInput").checked;
    const assessmentMode = $("examModeInput").value;

    if (!title) {
      $("settingsMessage").textContent = "Informe um título para a avaliação.";
      return;
    }
    if (duration !== null && (!Number.isInteger(duration) || duration < 5 || duration > 300)) {
      $("settingsMessage").textContent = "Escolha uma duração válida ou selecione Sem limite de tempo.";
      return;
    }
    if (!Number.isInteger(maxOccurrences) || maxOccurrences < 1 || maxOccurrences > 20) {
      $("settingsMessage").textContent = "O limite de ocorrências deve estar entre 1 e 20.";
      return;
    }

    $("btnSaveSettings").disabled = true;
    $("settingsMessage").textContent = "Salvando…";
    try {
      await teacherRpc("teacher_update_exam_settings", {
        p_exam_slug: cfg.examSlug,
        p_title: title,
        p_duration_minutes: duration,
        p_max_occurrences: maxOccurrences,
        p_is_active: isActive,
        p_assessment_mode: assessmentMode
      });
      settingsDirty = false;
      $("settingsMessage").textContent = "Configurações salvas.";
      await refreshDashboard();
    } catch (err) {
      $("settingsMessage").textContent = err.message || "Não foi possível salvar as configurações.";
    } finally {
      $("btnSaveSettings").disabled = false;
    }
  }

  function openResumeAttempt(row) {
    resumeTarget = row;
    $("resumeAttemptText").textContent =
      `Liberar ${row.student_name} para continuar a tentativa atual de onde parou?`;
    $("resumeAttemptModal").classList.remove("hidden");
  }

  function closeResumeAttempt() {
    resumeTarget = null;
    $("resumeAttemptModal").classList.add("hidden");
  }

  async function confirmResumeAttempt() {
    if (!resumeTarget) return;
    const target = resumeTarget;
    $("btnConfirmResume").disabled = true;
    try {
      await teacherRpc("teacher_allow_resume_attempt", {
        p_attempt_id: target.attempt_id
      });
      closeResumeAttempt();
      await refreshDashboard();
      $("dashboardMessage").textContent =
        `Continuação liberada para ${target.student_name}. O aluno deve entrar novamente pelo nome.`;
    } catch (err) {
      $("resumeAttemptText").textContent =
        String(err.message).includes("Tempo encerrado")
          ? "O tempo original desta tentativa já terminou; não é possível retomá-la."
          : "Não foi possível liberar a continuação. Atualize o painel e tente novamente.";
    } finally {
      $("btnConfirmResume").disabled = false;
    }
  }

  function openResetAttempt(row) {
    resetTarget = row;
    $("resetAttemptText").textContent =
      `Deseja iniciar uma nova tentativa do zero para ${row.student_name}?`;
    $("resetAttemptModal").classList.remove("hidden");
  }

  function closeResetAttempt() {
    resetTarget = null;
    $("resetAttemptModal").classList.add("hidden");
  }

  async function confirmResetAttempt() {
    if (!resetTarget) return;
    const target = resetTarget;
    $("btnConfirmReset").disabled = true;
    try {
      await teacherRpc("teacher_reset_attempt", {
        p_attempt_id: target.attempt_id
      });
      closeResetAttempt();
      await refreshDashboard();
      $("dashboardMessage").textContent =
        `Nova tentativa do zero liberada para ${target.student_name}.`;
    } catch {
      $("resetAttemptText").textContent =
        "Não foi possível liberar a nova tentativa. Atualize o painel e tente novamente.";
    } finally {
      $("btnConfirmReset").disabled = false;
    }
  }

  function csvEscape(v) {
    const s = String(v ?? "");
    return `"${s.replaceAll('"', '""')}"`;
  }

  function exportCsv() {
    if (!dashboardData) return;
    const lines = [
      ["Estudante","Turma","Status","Inicio","Envio","Nota","Maximo","Ocorrencias"].map(csvEscape).join(",")
    ];
    for (const r of dashboardData.attempts || []) {
      lines.push([
        r.student_name, r.class_group, statusLabel(r.status),
        r.started_at || "", r.submitted_at || "", r.score ?? "", r.max_score ?? "", r.occurrences || 0
      ].map(csvEscape).join(","));
    }
    downloadText(`resultado-${cfg.examSlug}.csv`, "\ufeff" + lines.join("\n"), "text/csv;charset=utf-8");
  }

  function startPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(refreshDashboard, 5000);
  }

  async function boot() {
    setConnectionBadge($("teacherConnectionBadge"));
    $("btnTeacherLogin").addEventListener("click", login);
    $("teacherPassword").addEventListener("keydown", e => { if (e.key === "Enter") login(); });
    $("btnLogout").addEventListener("click", () => {
      clearTeacherSession();
      session = null;
      showLogin();
    });
    $("btnRefresh").addEventListener("click", refreshDashboard);
    $("btnExportCsv").addEventListener("click", exportCsv);
    $("btnSaveSettings").addEventListener("click", saveExamSettings);
    $("btnToggleSimuladoOnline").addEventListener("click", toggleSimuladoOnline);
    ["examTitleInput","examDurationPreset","examDurationInput","examOccurrencesInput",
      "examModeInput","examActiveInput"].forEach(id => {
      const el = $(id);
      el.addEventListener("input", () => { settingsDirty = true; });
      el.addEventListener("change", () => { settingsDirty = true; });
    });
    $("examDurationPreset").addEventListener("change", () => {
      $("examDurationCustomGroup").classList.toggle("hidden", $("examDurationPreset").value !== "custom");
    });
    $("questionOptionCount").addEventListener("change", syncOptionFields);
    $("btnBankRefresh").addEventListener("click", loadBankQuestions);
    $("bankSubjectFilter").addEventListener("change", loadBankQuestions);
    $("bankDifficultyFilter").addEventListener("change", loadBankQuestions);
    $("bankSearchInput").addEventListener("input", () => {
      if (bankFilterTimer) clearTimeout(bankFilterTimer);
      bankFilterTimer = setTimeout(loadBankQuestions, 300);
    });
    $("btnBankNewQuestion").addEventListener("click", () => openQuestionEditor(null, "bank"));
    $("btnNewQuestion").addEventListener("click", () => openQuestionEditor());
    $("assessmentDifficultyFilter").addEventListener("change", renderQuestionList);
    $("btnPreviewQuestions").addEventListener("click", openQuestionPreview);
    $("btnCloseQuestionEditor").addEventListener("click", closeQuestionEditor);
    $("btnCancelQuestionEdit").addEventListener("click", closeQuestionEditor);
    $("btnSaveQuestion").addEventListener("click", saveQuestion);
    $("btnCancelDeleteQuestion").addEventListener("click", closeDeleteQuestion);
    $("btnConfirmDeleteQuestion").addEventListener("click", confirmDeleteQuestion);
    $("btnCloseQuestionPreview").addEventListener("click", () => $("questionPreviewModal").classList.add("hidden"));
    $("btnCancelResume").addEventListener("click", closeResumeAttempt);
    $("btnConfirmResume").addEventListener("click", confirmResumeAttempt);
    $("btnCancelReset").addEventListener("click", closeResetAttempt);
    $("btnConfirmReset").addEventListener("click", confirmResetAttempt);
    $("btnCloseDetail").addEventListener("click", () => $("detailModal").classList.add("hidden"));

    session = await validTeacherSession();
    if (session) {
      showDashboard();
      await refreshDashboard();
      await loadQuestions();
      await loadBankQuestions();
      startPolling();
    } else {
      showLogin();
    }
  }

  boot();
})();
