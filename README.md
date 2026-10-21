# Modo Prova — MVP local

Protótipo funcional de uma avaliação web para laboratório escolar.

## O que já faz

- identificação do estudante;
- regras antes do início;
- solicitação de tela cheia;
- cronômetro configurável;
- questões uma por vez;
- ordem aleatória de questões;
- ordem aleatória de alternativas;
- navegação anterior/próxima;
- marcação para revisão;
- salvamento automático no navegador;
- retomada após atualização/reabertura no mesmo computador;
- bloqueio de copiar, colar, imprimir, botão direito e alguns atalhos enquanto a prova está ativa;
- detecção de troca de aba/janela via `visibilitychange`;
- detecção de saída da tela cheia;
- registro do horário e da questão em cada ocorrência;
- limite configurável de ocorrências;
- encerramento automático ou reinício ao atingir o limite;
- correção automática de questões objetivas;
- nota não exibida ao estudante por padrão;
- painel local do professor (`teacher.html`);
- exportação local em CSV e JSON.

## Como testar

A forma mais confiável é servir a pasta por HTTP.

No Windows, com Python instalado, dentro desta pasta:

```bash
python -m http.server 8000
```

Depois abra:

- prova: `http://localhost:8000/`
- painel local: `http://localhost:8000/teacher.html`

PIN inicial do painel: `2026`.

## Configuração

Edite `config.js`.

Principais opções:

- `durationMinutes`: duração da prova;
- `questionCount`: quantidade de questões sorteadas;
- `maxIncidents`: limite de saídas;
- `actionOnIncidentLimit`: `submit` ou `restart`;
- `shuffleQuestions`: embaralhar questões;
- `shuffleOptions`: embaralhar alternativas;
- `showScoreAfterSubmit`: nesta versão permanece sem exibição da nota ao estudante;
- `teacherPin`: PIN do painel local.

As questões ficam em `questions.js`.

## Limitação importante deste MVP

Este protótipo é **front-end e local**. Isso significa que:

1. o navegador consegue detectar muitas saídas da prova, mas não consegue impedir completamente `Alt+Tab`, outro aplicativo ou outro dispositivo;
2. bloqueios de copiar/atalhos dificultam ações comuns, mas não são segurança absoluta;
3. o PIN do professor está em código cliente e, portanto, **não é autenticação segura**;
4. os resultados ficam no `localStorage` de cada computador e não aparecem automaticamente em um painel central;
5. um estudante tecnicamente experiente ainda pode contornar proteções de JavaScript;
6. fotografia da tela com outro aparelho não pode ser impedida por uma página web.

## Próxima versão recomendada para uso real

Transformar o MVP em aplicação com backend:

- autenticação real do professor;
- banco central de avaliações, questões, tentativas e ocorrências;
- criação/edição de provas em painel;
- acesso por código de prova;
- sessão única por estudante;
- resultados centralizados em tempo real;
- exportação consolidada de notas;
- auditoria de eventos;
- HTTPS e controle de acesso;
- opcionalmente, integração com modo quiosque/ambiente gerenciado do laboratório.

O frontend atual pode ser mantido e ligado a esse backend.
