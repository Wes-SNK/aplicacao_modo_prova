# Homologação — Sala de espera, supervisão e monitoramento

Branch: `feature/sala-espera-monitoramento-gather`  
Status: **candidata de homologação; NÃO integrada à main**.  
Projeto de produção preservado: `lqfchjfyftfopgzdwggi`.

## 1. Escopo e critérios de aprovação

A versão implementa a opção de supervisão individual por avaliação, turma completa, liberação individual e coletiva, progresso por respostas, conexão aproximada, cronômetro, ajuda, cadastro de estudantes, códigos individuais opcionais, auditoria e sala de espera lúdica (2D) com modo simples. As avaliações existentes continuam no fluxo anterior se a supervisão não for habilitada.

**Separação de ambientes:** as migrações `migrations/013` até `016` estão somente no GitHub. Não foram aplicadas ao Supabase de produção. Para validação real, utilizar projeto/branch Supabase **de desenvolvimento**, com dados sintéticos, e configurar o cliente de homologação para sua própria URL/chave pública. Uma branch Supabase pode ter custo adicional: conferir preços e obter aprovação antes de criá-la. O CI executa migrações em um PostgreSQL descartável, independente do projeto real.

**Publicação:** não há URL de homologação pública confirmada nesta etapa. GitHub Pages atende à `main`; não se deve usar o link de produção como se fosse o build desta branch. Pode-se testar localmente por HTTP ou configurar um preview isolado de Cloudflare Pages/GitHub Pages, sem substituir o site atual.

## 2. Checklist do professor — ambiente e cadastros

- [ ] Abrir a branch em ambiente de homologação (não na URL de produção).
- [ ] Entrar como professor usando uma conta de teste.
- [ ] Confirmar que as avaliações originais são exibidas e continuam com questões, duração e limites corretos.
- [ ] Conferir a turma completa e os alunos ativos/inativos em **Alunos e turmas**.
- [ ] Cadastrar um estudante fictício, editar seu nome e trocar a turma.
- [ ] Inativar e reativar um estudante de teste; verificar que registros históricos não desaparecem.
- [ ] Selecionar a turma desejada em **Monitoramento e controle da turma**.
- [ ] Ativar **Exigir autorização para iniciar** e salvar. Em avaliações já iniciadas, confirmar bloqueio da mudança quando cabível.
- [ ] Opcional: gerar códigos individuais em CSV, distribuir apenas no ambiente de teste e ativar **Exigir código individual**. Confirmar que os códigos antigos são invalidados quando regenerados.

## 3. Checklist do aluno — sala de espera estilo Gather

- [ ] Com o exame ainda fora do ar, verificar se o estudante pode entrar no pátio, mas não visualizar questões.
- [ ] Testar identificação por nome; quando código estiver exigido, tentar código ausente, inválido e correto.
- [ ] Conferir recepção, pátio, corredor, laboratório e mesa do professor.
- [ ] Testar movimento por **W/A/S/D**, setas, e pelos controles clicáveis.
- [ ] Conferir o movimento do avatar em dois navegadores, com dois estudantes fictícios.
- [ ] Confirmar que os avatares dos colegas não revelam seus nomes reais.
- [ ] Testar as reações **Olá**, **Pronto** e **Dúvida**.
- [ ] Ativar **Modo simples**, verificar legibilidade, acessibilidade e ausência de mapa.
- [ ] Acionar **Preciso de ajuda**, confirmar a notificação no painel e seu encerramento.
- [ ] Atualizar o navegador enquanto aguarda e confirmar a retomada da sala.
- [ ] Simular desconexão de 20–40 segundos e reconexão; verificar que isso não gera infração nem dá acesso antecipado à prova.

## 4. Checklist do professor — autorização e acompanhamento

- [ ] Ver quem **ainda não entrou** na lista geral da turma, mesmo sem tentativa.
- [ ] Ver quem **aguarda**, quem foi **autorizado**, quem está **realizando** e quem **finalizou**.
- [ ] Autorizar individualmente um estudante e confirmar que somente ele pode entrar.
- [ ] Revogar a autorização antes da prova começar.
- [ ] Confirmar que não é possível revogar autorização depois de a prova já ter sido iniciada.
- [ ] **Autorizar todos os presentes**, verificando que ausentes/desconectados não são liberados.
- [ ] Verificar se o aluno autorizado recebe o botão **Entrar na avaliação**.
- [ ] Conferir as quantidades **respondidas/total**, progresso visual e tempo restante.
- [ ] Verificar o indicador de conexão com status de atualização recente, instabilidade ou ausência de sinal.
- [ ] Solicitar ajuda durante a prova e conferir a indicação no monitoramento.
- [ ] Confirmar atendimento de ajuda e o registro no histórico/auditoria.
- [ ] Pesquisar estudante por nome, exportar CSV e conferir pontuação/ocorrências somente nos relatórios apropriados.
- [ ] Conferir se a página de monitoramento responde bem em computador e celular.

## 5. Checklist da avaliação real (somente dados fictícios)

- [ ] Confirmar que **sem autorização** nenhum endpoint consegue iniciar ou entregar questões da avaliação supervisionada.
- [ ] Iniciar após autorização e aceitar as regras da prova.
- [ ] Verificar tela cheia, cronômetro, navegação, marcação para revisão e salvamento de respostas.
- [ ] Registrar respostas e verificar a progressão no painel dentro de até 5–15 segundos.
- [ ] Encerrar a prova e conferir o estado **Finalizado** e a nota sem alterações.
- [ ] Testar continuação de onde parou com autorização do professor.
- [ ] Testar uma nova tentativa autorizada pelo professor (deve preservar as regras existentes).
- [ ] Simular falta de internet durante respostas: salvar no cache local e sincronizar após reconexão.
- [ ] Confirmar que uma queda de internet **não** é registrada como infração por si só.
- [ ] Conferir que a solicitação de ajuda funciona sem sair da página.
- [ ] Verificar o modo **Simulado**, que mostra correção ao final, e o modo **Prova**, que não revela gabaritos.

## 6. Testes automatizados e critérios de aceite

Workflow: `.github/workflows/supervision-tests.yml`. Verificações:

1. Sintaxe dos módulos JavaScript.
2. Correspondência entre IDs de tela e manipuladores JS.
3. Cálculos de progresso, presença, conectividade e limites de movimento.
4. Fluxo simulado aluno na sala: aguardar -> receber autorização -> entrar.
5. Migrações reais aplicadas a **PostgreSQL isolado no CI** e roteiro de integração `tests/supervision-db.sql`: bloqueio de atalhos, autorização, códigos, ajuda, auditoria e permissões.
6. Sem dependências de jogos, chat livre, áudio ou biblioteca gráfica pesada.

**Critério para prosseguir:** GitHub Actions verde, banco de homologação integrado, checklist manual aprovada, sem problema crítico de segurança/acessibilidade e autorização expressa para o merge.

## 7. Procedimento de teste local

Em um computador com Git e Python instalados:

```bash
git clone --branch feature/sala-espera-monitoramento-gather https://github.com/Wes-SNK/aplicacao_modo_prova.git
cd aplicacao_modo_prova
python -m http.server 8000
```

Abrir `http://localhost:8000/professor.html?avaliacao=simulado` e, em outra aba/navegador, `http://localhost:8000/?avaliacao=simulado`.

**Atenção:** esses comandos baixam a interface da branch, mas o `config.js` aponta inicialmente para o Supabase de produção. Antes de testar operações reais de supervisão, substitua **localmente** os valores `supabaseUrl` e `supabasePublishableKey` pelos dados do **projeto de homologação** e confirme as migrações 013–016 somente nele. Não faça testes de envio com estudantes reais ou no banco de produção.

## 8. Migração e retorno seguro

1. Revisar CI e eventuais ressalvas.
2. Preparar o ambiente de homologação, aplicar e testar migrações em ordem: 013, 014, 015, 016.
3. Aprovar o checklist com os usuários finais.
4. Realizar backup do banco de produção e registrar janela de implantação.
5. Aplicar migrações de produção apenas após autorização; configurações novas iniciam desativadas.
6. Integrar a branch à `main` somente após aprovação do professor.
7. Validar testes de fumaça e realizar monitoramento assistido.

**Contingência:** deixar `exam_supervision.enabled=false` na avaliação faz o aluno voltar ao fluxo anterior. Não remover tabelas ou registros de auditoria para reverter a interface; uma reversão de schema exige plano e backup específicos.

## 9. Registro da homologação

| Item | Resultado (aprovado/reprovado) | Observação |
|---|---|---|
| Cadastro e turma | Pendente | |
| Código individual | Pendente | |
| Mapa 2D / modo simples | Pendente | |
| Autorização individual | Pendente | |
| Autorização coletiva | Pendente | |
| Controle de acesso no servidor | Pendente | |
| Progresso / conexão | Pendente | |
| Pedidos de ajuda | Pendente | |
| Auditoria / CSV | Pendente | |
| Modo prova / simulado | Pendente | |
| Conexão instável / retomada | Pendente | |
| Teste visual mobile / desktop | Pendente | |
| Aprovação final | Pendente | |

**Não realizar merge antes de o professor registrar a aprovação final.**
