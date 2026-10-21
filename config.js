window.EXAM_CONFIG = {
  examId: '4bim-2026-piloto',
  title: 'Avaliação — 4º Bimestre',
  subtitle: 'Técnico em Informática — 1º ano',
  durationMinutes: 50,
  questionCount: 8,
  maxIncidents: 3,
  actionOnIncidentLimit: 'submit', // 'submit' ou 'restart'
  requireFullscreen: true,
  shuffleQuestions: true,
  shuffleOptions: true,
  allowBackNavigation: true,
  showScoreAfterSubmit: false,
  teacherPin: '2026', // APENAS protótipo local. Troque antes de usar.
  rules: [
    'Permaneça nesta página durante toda a avaliação.',
    'Não abra outras abas, janelas ou programas durante a prova.',
    'Não copie, cole, imprima ou compartilhe questões.',
    'As respostas são salvas automaticamente neste computador.',
    'Saídas da tela da prova serão registradas.',
    'Ao atingir o limite de ocorrências, a tentativa será encerrada automaticamente.'
  ]
};
