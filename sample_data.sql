-- DADOS DE DEMONSTRAÇÃO
-- Execute DEPOIS de schema.sql.
-- Substitua os estudantes e as questões antes da prova real.

insert into public.exams(slug,title,duration_minutes,max_occurrences,is_active)
values(
  '4bim-1b-2026',
  'Avaliação do 4º Bimestre — Técnico em Informática',
  50,
  3,
  true
)
on conflict(slug) do update set
  title=excluded.title,
  duration_minutes=excluded.duration_minutes,
  max_occurrences=excluded.max_occurrences;

delete from public.students
where name in ('Aluno de Teste 1','Aluno de Teste 2','Aluno de Teste 3');

insert into public.students(name,class_group) values
('Aluno de Teste 1','1º INF'),
('Aluno de Teste 2','1º INF'),
('Aluno de Teste 3','1º INF');

do $$
declare
  e uuid;
begin
  select id into e from public.exams where slug='4bim-1b-2026';

  delete from public.questions where exam_id=e;

  insert into public.questions(exam_id,position,type,stem,options,correct_answer,points) values
  (e,1,'objective',
   'Qual componente armazena temporariamente dados e instruções que estão sendo utilizados pelos programas?',
   '[{"key":"A","text":"SSD"},{"key":"B","text":"Memória RAM"},{"key":"C","text":"Fonte de alimentação"},{"key":"D","text":"Gabinete"}]',
   'B',1),

  (e,2,'objective',
   'Em HTML, qual tag é utilizada para criar um link?',
   '[{"key":"A","text":"<a>"},{"key":"B","text":"<img>"},{"key":"C","text":"<p>"},{"key":"D","text":"<link>"}]',
   'A',1),

  (e,3,'objective',
   'No CSS inline, qual forma está sintaticamente correta?',
   '[{"key":"A","text":"style=\"color = blue;\""},{"key":"B","text":"style=\"color: blue;\""},{"key":"C","text":"css=\"color: blue;\""},{"key":"D","text":"style=\"blue: color;\""}]',
   'B',1),

  (e,4,'objective',
   'Em manutenção, qual conduta representa melhor um diagnóstico organizado?',
   '[{"key":"A","text":"Trocar várias peças ao mesmo tempo"},{"key":"B","text":"Começar pela peça mais cara"},{"key":"C","text":"Observar sintomas e testar hipóteses uma por vez"},{"key":"D","text":"Formatar o computador antes de investigar"}]',
   'C',1),

  (e,5,'objective',
   'Qual sequência representa melhor um algoritmo?',
   '[{"key":"A","text":"Ações aleatórias sem objetivo"},{"key":"B","text":"Passos ordenados para resolver um problema"},{"key":"C","text":"Somente cálculos matemáticos"},{"key":"D","text":"Apenas comandos escritos em Python"}]',
   'B',1),

  (e,6,'open',
   'Explique, com suas palavras, por que testar uma hipótese de cada vez ajuda no diagnóstico de um computador.',
   '[]',
   null,0);
end $$;


-- A aplicação atual utiliza somente questões objetivas.
-- Mantém eventual conteúdo aberto antigo apenas como histórico, sem exibi-lo aos alunos.
update public.questions set active=false where type='open';
