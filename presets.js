/*
 * Gerenciador de presets (independente do painel de questões).
 * Toda alteração utiliza RPC autenticada; as avaliações existentes não são reescritas.
 * Presets novos são exames reais no Supabase com is_active=false até publicação manual.
 */
(() => {
  "use strict";
  const { cfg, rpc, validTeacherSession } = window.ModeProva;
  const $ = id => document.getElementById(id);
  const subjects = [
    "Lógica de Programação", "HTML/CSS",
    "Arquitetura e Manutenção", "Planejamento de Carreira e IA"
  ];
  const difficulties = [
    ["facil", "Fáceis"], ["media", "Médias"], ["dificil", "Difíceis"]
  ];
  const defaultCounts = [[2,2,1],[2,2,1],[2,2,1],[2,3,0]];
  let records = [];
  let fetching = false;
  let acting = false;

  const isCustom = slug => /^preset-[0-9a-f]{32}$/.test(slug);
  const teacherUrl = slug => isCustom(slug)
    ? "questoes.html?exame=" + encodeURIComponent(slug)
    : slug === "simulado-4bim-1b-2026"
      ? "questoes.html?avaliacao=simulado"
      : slug === "prova-4bim-1b-2026"
        ? "questoes.html?avaliacao=prova" : "questoes.html";
  const studentUrl = slug => isCustom(slug)
    ? "index.html?exame=" + encodeURIComponent(slug)
    : slug === "simulado-4bim-1b-2026"
      ? "index.html?avaliacao=simulado"
      : slug === "prova-4bim-1b-2026"
        ? "index.html?avaliacao=prova" : "index.html";
  const previewUrl = slug => isCustom(slug)
    ? "preview-aluno.html?exame=" + encodeURIComponent(slug)
    : slug === "simulado-4bim-1b-2026"
      ? "preview-aluno.html?avaliacao=simulado"
      : slug === "prova-4bim-1b-2026"
        ? "preview-aluno.html?avaliacao=prova" : "preview-aluno.html?avaliacao=anterior";

  function message(s) {
    $("presetManagerMessage").textContent = s;
  }
  async function teacherRpc(name, args = {}) {
    const s = await validTeacherSession();
    if (!s?.access_token) throw new Error("Sua sessão expirou. Entre novamente como professor.");
    return rpc(name, args, s.access_token);
  }
  function element(tag, className, textValue) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (textValue !== undefined) el.textContent = String(textValue);
    return el;
  }
  function button(label, action, className = "secondary", disabled = false) {
    const el = element("button", "small " + className, label);
    el.type = "button";
    el.disabled = disabled || acting;
    el.addEventListener("click", action);
    return el;
  }
  function link(label, href) {
    const a = element("a", "preset-action-link", label);
    a.href = href;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    return a;
  }
  function summary(rec) {
    const mode = rec.assessment_mode === "simulation" ? "Simulado" : "Prova";
    const duration = rec.duration_minutes == null
      ? "sem cronômetro" : rec.duration_minutes + " minutos";
    const difficulty = Number(rec.easy_count || 0) + Number(rec.medium_count || 0)
      + Number(rec.hard_count || 0);
    let text = mode + " • " + rec.question_count + " questões • " + duration
      + " • limite de " + rec.max_occurrences + " ocorrências"
      + " • " + rec.attempts_count + " tentativas";
    if (difficulty) {
      text += " • " + rec.easy_count + " fáceis / " + rec.medium_count
        + " médias / " + rec.hard_count + " difíceis";
    }
    return text;
  }

  function renderList() {
    const area = $("presetList");
    area.textContent = "";
    if (!records.length) {
      area.appendChild(element("p", "muted", "Nenhuma avaliação cadastrada."));
      return;
    }
    records.forEach(rec => {
      const card = element("article", "preset-entry" +
        (rec.slug === cfg.examSlug ? " preset-selected" : ""));
      const header = element("div", "preset-entry-heading");
      const heading = element("strong", null, rec.title);
      const badge = element("span",
        rec.archived ? "pill" : rec.is_active ? "pill ok" : "pill",
        rec.archived ? "Arquivado" : rec.is_active ? "Online" : "Rascunho / fora do ar");
      header.append(heading, badge);
      card.appendChild(header);
      const details = element("p", "muted", summary(rec));
      card.appendChild(details);
      if (!rec.custom) {
        card.appendChild(element("p", "field-help",
          "Avaliação existente — preservada; pode servir de modelo para um novo preset."));
      }
      const actions = element("div", "preset-actions");
      if (!rec.archived) {
        const open = element("a", "preset-action-link", "Editar questões");
        open.href = teacherUrl(rec.slug);
        actions.appendChild(open);
        actions.appendChild(link("Prévia do aluno", previewUrl(rec.slug)));
        actions.appendChild(button("Duplicar", () => duplicatePreset(rec)));
      }
      if (rec.custom && !rec.archived) {
        actions.appendChild(button(rec.is_active ? "Tirar do ar" : "Colocar online",
          () => togglePublish(rec), rec.is_active ? "danger" : "primary",
          !rec.is_active && rec.question_count < 1));
        if (rec.slug === cfg.examSlug && rec.question_count === 0 && !rec.is_active) {
          actions.appendChild(button("Montar por dificuldade", () =>
            $("presetAutofill").scrollIntoView({ behavior: "smooth", block: "start" })));
        }
      }
      if (rec.custom) {
        actions.appendChild(button(rec.archived ? "Restaurar" : "Arquivar",
          () => archivePreset(rec), "secondary", rec.is_active));
      }
      if (!rec.archived) {
        const share = element("a", "preset-action-link", "Link do aluno");
        share.href = studentUrl(rec.slug);
        share.target = "_blank";
        share.rel = "noopener noreferrer";
        actions.appendChild(share);
        actions.appendChild(button("Copiar link", () => copyStudentLink(rec)));
      }
      card.appendChild(actions);
      area.appendChild(card);
    });
    const active = records.find(rec => rec.slug === cfg.examSlug);
    renderAutofill(active);
  }

  function renderSourceSelect() {
    const field = $("presetSource");
    const before = field.value;
    field.textContent = "";
    field.appendChild(new Option("Começar vazio — selecionar questões depois", ""));
    records.filter(rec => !rec.archived && rec.question_count > 0).forEach(rec => {
      field.appendChild(new Option(
        rec.title + " (" + rec.question_count + " questões)", rec.slug));
    });
    if ([...field.options].some(opt => opt.value === before)) field.value = before;
  }

  async function refresh() {
    if (fetching || $("teacherDashboard").classList.contains("hidden") ||
        document.body.dataset.teacherPage !== "avaliacoes") return;
    fetching = true;
    message("Atualizando presets…");
    try {
      const items = await teacherRpc("teacher_presets_list");
      if (!Array.isArray(items)) throw new Error("A lista retornou um formato inesperado.");
      records = items;
      renderList();
      renderSourceSelect();
      message(records.length + " avaliação(ões) disponíveis. Os presets novos ficam fora do ar até sua publicação.");
    } catch (err) {
      message("Não foi possível carregar os presets: " + (err.message || err));
    } finally {
      fetching = false;
    }
  }
  function showCreate() {
    $("presetCreateForm").classList.toggle("hidden");
    if (!$("presetCreateForm").classList.contains("hidden")) {
      $("presetTitle").focus();
    }
  }
  function adaptSource() {
    const rec = records.find(x => x.slug === $("presetSource").value);
    if (!rec) return;
    $("presetMode").value = rec.assessment_mode;
    const duration = $("presetDuration");
    const v = rec.duration_minutes == null ? "none" : String(rec.duration_minutes);
    if (![...duration.options].some(o => o.value === v)) {
      duration.value = "custom";
      $("presetCustomDuration").value = v;
    } else {
      duration.value = v;
    }
    syncPresetDuration();
    $("presetOccurrences").value = rec.max_occurrences;
    if (!$("presetTitle").value.trim()) $("presetTitle").value = rec.title + " — cópia";
  }
  async function perform(task) {
    if (acting) return;
    acting = true;
    $("btnPresetCreate").disabled = true;
    $("btnPresetRefresh").disabled = true;
    try { await task(); }
    catch (err) { message("Não foi possível concluir: " + (err.message || err)); }
    finally {
      acting = false;
      $("btnPresetCreate").disabled = false;
      $("btnPresetRefresh").disabled = false;
      renderList(); // Reabilita os controles após qualquer ação concluída.
    }
  }
  function syncPresetDuration() {
    $("presetCustomDurationGroup").classList.toggle(
      "hidden", $("presetDuration").value !== "custom");
  }
  async function createPreset() {
    const title = $("presetTitle").value.trim();
    const mode = $("presetMode").value;
    const durationVal = $("presetDuration").value;
    const duration = durationVal === "none" ? null
      : Number(durationVal === "custom" ? $("presetCustomDuration").value : durationVal);
    const occurrences = Number($("presetOccurrences").value);
    const source = $("presetSource").value || null;
    if (title.length < 5 || title.length > 160 ||
        (duration !== null && (!Number.isInteger(duration) || duration < 5 || duration > 300)) ||
        !Number.isInteger(occurrences) || occurrences < 1 || occurrences > 20) {
      message("Preencha o título, a duração e o limite de ocorrências com valores válidos.");
      return;
    }
    await perform(async () => {
      const r = await teacherRpc("teacher_preset_create", {
        p_title:title,p_assessment_mode:mode,p_duration_minutes:duration,
        p_max_occurrences:occurrences,p_source_slug:source
      });
      if (!r?.ok || !isCustom(r.slug)) throw new Error("O servidor não confirmou a criação.");
      window.location.href = teacherUrl(r.slug);
    });
  }
  async function duplicatePreset(rec) {
    const name = window.prompt("Título do novo preset (a avaliação original será preservada):",
      rec.title + " — cópia");
    if (name === null) return;
    if (!name.trim() || name.trim().length < 5) {
      message("Informe um título com pelo menos 5 caracteres.");
      return;
    }
    await perform(async () => {
      const r = await teacherRpc("teacher_preset_create", {
        p_title:name.trim(),p_assessment_mode:rec.assessment_mode,
        p_duration_minutes:rec.duration_minutes,p_max_occurrences:rec.max_occurrences,
        p_source_slug:rec.slug
      });
      if (!r?.ok) throw new Error("A duplicação não foi confirmada.");
      window.location.href = teacherUrl(r.slug);
    });
  }
  async function togglePublish(rec) {
    const online = !rec.is_active;
    const questionCount = Number(rec.question_count);
    if (online && questionCount < 1) {
      message("Selecione questões antes de colocar o preset online.");
      return;
    }
    const question = online
      ? 'Publicar "' + rec.title + '" agora para os estudantes? Serão disponibilizadas '
        + questionCount + " questões."
      : 'Retirar "' + rec.title + '" do ar? Nenhuma resposta será excluída.';
    if (!window.confirm(question)) return;
    await perform(async () => {
      const r = await teacherRpc("teacher_preset_toggle", {
        p_exam_slug:rec.slug,p_online:online
      });
      if (!r?.ok || r.is_active !== online) throw new Error("Publicação não confirmada.");
      await refresh();
      if (rec.slug === cfg.examSlug) window.location.reload();
    });
  }
  async function archivePreset(rec) {
    const archived = !rec.archived;
    const question = archived
      ? 'Arquivar "' + rec.title + '"? Nenhuma questão ou resposta será excluída.'
      : 'Restaurar "' + rec.title + '" para a lista de presets?';
    if (!window.confirm(question)) return;
    await perform(async () => {
      const r = await teacherRpc("teacher_preset_archive", {
        p_exam_slug:rec.slug,p_archived:archived
      });
      if (!r?.ok || r.archived !== archived) throw new Error("Operação não confirmada.");
      if (archived && rec.slug === cfg.examSlug) {
        window.location.href = "questoes.html?avaliacao=simulado";
        return;
      }
      await refresh();
    });
  }
  async function copyStudentLink(rec) {
    const url = new URL(studentUrl(rec.slug),window.location.href).href;
    try {
      await navigator.clipboard.writeText(url);
      message("Link do aluno copiado: " + rec.title);
    } catch {
      window.prompt("Copie o link do aluno:",url);
    }
  }

  function buildDistribution() {
    const wrap = $("presetDistributionTable");
    wrap.textContent = "";
    const table = element("table", "preset-distribution");
    const head = document.createElement("thead");
    const tr = document.createElement("tr");
    ["Disciplina", ...difficulties.map(v=>v[1]), "Subtotal"].forEach(label =>
      tr.appendChild(element("th", null, label)));
    head.appendChild(tr);table.appendChild(head);
    const body = document.createElement("tbody");
    subjects.forEach((name,i) => {
      const row = document.createElement("tr");
      row.appendChild(element("td",null,name));
      difficulties.forEach(([key],j) => {
        const td = document.createElement("td");
        const inp = document.createElement("input");
        inp.type = "number"; inp.min = "0"; inp.max = "50"; inp.step = "1";
        inp.value = String(defaultCounts[i][j]);
        inp.className = "preset-count-input";
        inp.dataset.subject = name;
        inp.dataset.level = key;
        inp.setAttribute("aria-label", name + " — " + difficulties[j][1]);
        inp.addEventListener("input",updateDistributionTotals);
        td.appendChild(inp); row.appendChild(td);
      });
      row.appendChild(element("td","preset-subtotal",String(defaultCounts[i].reduce((a,b)=>a+b,0))));
      body.appendChild(row);
    });
    table.appendChild(body);wrap.appendChild(table);
    updateDistributionTotals();
  }
  function readDistribution() {
    const rows = subjects.map(subject => ({subject,facil:0,media:0,dificil:0}));
    for (const inp of $("presetDistributionTable").querySelectorAll(".preset-count-input")) {
      const value = Number(inp.value);
      if (!Number.isInteger(value) || value < 0 || value > 50) {
        throw new Error("Informe quantidades inteiras entre 0 e 50.");
      }
      const row = rows.find(x => x.subject === inp.dataset.subject);
      row[inp.dataset.level] = value;
    }
    const total = rows.reduce((sum,row)=>sum+row.facil+row.media+row.dificil,0);
    if (total<1 || total>80) throw new Error("Escolha entre 1 e 80 questões.");
    return {rows,total};
  }
  function updateDistributionTotals() {
    let total = 0; let valid=true;
    $("presetDistributionTable").querySelectorAll("tbody tr").forEach(tr=>{
      let sum=0;
      tr.querySelectorAll("input").forEach(input=>{
        const v=Number(input.value);
        if (!Number.isInteger(v)||v<0||v>50) valid=false;
        else sum+=v;
      });
      tr.querySelector(".preset-subtotal").textContent = valid?String(sum):"—";
      total+=sum;
    });
    $("presetDistributionTotal").textContent =
      valid ? "Total: " + total + " questão(ões)" : "Informe números entre 0 e 50.";
    $("btnPresetAutoFill").disabled = !valid || total<1 || total>80 || acting;
  }
  function renderAutofill(rec) {
    const show = !!rec && rec.custom && !rec.archived &&
      !rec.is_active && rec.question_count === 0 && rec.attempts_count === 0;
    $("presetAutofill").classList.toggle("hidden",!show);
  }
  async function autoFill() {
    const rec = records.find(x=>x.slug===cfg.examSlug);
    if (!rec || !rec.custom || rec.is_active || rec.question_count !== 0) return;
    let plan;
    try { plan=readDistribution(); }
    catch(err){$("presetAutofillMessage").textContent=err.message;return;}
    if (!window.confirm("Montar " + plan.total + " questões automaticamente no preset atual? A seleção será feita com base no banco de questões.")) return;
    await perform(async()=>{
      $("btnPresetAutoFill").disabled=true;
      $("presetAutofillMessage").textContent="Selecionando questões do banco…";
      const r=await teacherRpc("teacher_preset_autofill",{
        p_exam_slug:rec.slug,p_plan:plan.rows
      });
      if (!r?.ok || r.question_count!==plan.total) {
        throw new Error("O servidor não confirmou a montagem completa.");
      }
      window.location.reload();
    });
    updateDistributionTotals();
  }

  $("btnPresetRefresh").addEventListener("click",refresh);
  $("btnPresetNew").addEventListener("click",showCreate);
  $("btnPresetCancel").addEventListener("click",()=>$("presetCreateForm").classList.add("hidden"));
  $("btnPresetCreate").addEventListener("click",createPreset);
  $("btnPresetAutoFill").addEventListener("click",autoFill);
  $("presetSource").addEventListener("change",adaptSource);
  $("presetDuration").addEventListener("change",syncPresetDuration);
  buildDistribution();
  window.addEventListener("modo-prova:teacher-ready",refresh);
  window.addEventListener("modo-prova:teacher-logout",()=>{
    records=[];$("presetList").textContent="";
    $("presetAutofill").classList.add("hidden");
    $("presetCreateForm").classList.add("hidden");
  });
  if (!$("teacherDashboard").classList.contains("hidden")) refresh();
})();
