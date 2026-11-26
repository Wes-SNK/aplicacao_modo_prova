/* Curiosidades curtas para a sala de espera do curso técnico em informática.
 * Sem perguntas avaliativas, dados pessoais ou chamadas externas.
 * A lista pode ser ampliada sem alterar a lógica da prova.
 */
(function (root) {
  "use strict";
  const facts = Object.freeze([
    "Computadores digitais representam informações usando combinações de bits: 0 e 1.",
    "Um byte normalmente reúne 8 bits. Com ele, é possível representar 256 combinações diferentes.",
    "HTML organiza o conteúdo de uma página; CSS define sua apresentação visual.",
    "Uma cor escrita como #FF0000 em CSS representa vermelho usando a notação hexadecimal.",
    "Ada Lovelace descreveu um algoritmo para a Máquina Analítica de Charles Babbage, no século XIX.",
    "Alan Turing ajudou a fundamentar a ciência da computação ao estudar modelos matemáticos de computação.",
    "Grace Hopper participou do desenvolvimento de linguagens de programação e da evolução dos compiladores.",
    "Um algoritmo é uma sequência organizada de instruções para resolver um problema.",
    "Uma GPU foi projetada para realizar muitas operações em paralelo e também é utilizada em inteligência artificial.",
    "Um SSD armazena dados em memória flash, sem os discos giratórios de um HD tradicional.",
    "A memória RAM costuma perder seu conteúdo quando o computador é desligado.",
    "A memória cache aproxima dados frequentemente usados do processador para acelerar o acesso.",
    "A internet é a rede de redes; a Web é um dos serviços que funcionam sobre ela.",
    "O DNS permite encontrar o endereço IP associado a um nome de domínio, como um site.",
    "HTTPS protege a comunicação entre navegador e servidor usando criptografia.",
    "Uma página pode adaptar seu layout a celulares e computadores: isso se chama design responsivo.",
    "Um fluxograma usa símbolos e setas para representar etapas e decisões de um processo.",
    "Um bug é um defeito de software. Testes ajudam a encontrá-lo antes que afete os usuários.",
    "O código-fonte de programas de software livre pode ser estudado e modificado segundo sua licença.",
    "Um endereço IP ajuda a identificar dispositivos e interfaces na comunicação entre redes."
  ]);
  root.LobbyCuriosities = facts;
  if (typeof module !== "undefined" && module.exports) module.exports=facts;
})(typeof window !== "undefined" ? window : globalThis);
