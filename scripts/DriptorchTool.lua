--[[
    DriptorchTool.lua

    Especialização customizada que transforma um handTool em uma tocha de
    gotejamento (drip torch) capaz de queimar árvores vivas, árvores mortas
    e tocos.

    ACIONAMENTO: precisa segurar o botão (igual o spray de marcação de
    árvores) - não fica sempre ativa.

    Estrutura confirmada contra o CÓDIGO-FONTE OFICIAL documentado pela
    GIANTS (GDN - gdn.giants-software.com), classe HandToolSprayCan, que é
    a especialização real por trás do spray de marcação. Isso nos deu:

    - InputAction.ACTIVATE_HANDTOOL: ação de input já existente, reutilizável,
      não precisamos registrar uma ação customizada.
    - self:getCarryingPlayer().targeter (PlayerTargeter): sistema oficial de
      mira/raycast do jogador. Muito mais simples e confiável que implementar
      raycast manual.
    - CollisionFlag.TREE + filtro por getHasClassId(hitNode,
      ClassIds.MESH_SPLIT_SHAPE): como o jogo identifica árvores/tocos
      (todos são "split shapes").
    - onHeldStart(): momento certo de registrar o alvo no targeter (só
      enquanto o item está de fato equipado/segurado).

    ESTADO DESTE ARQUIVO: a "casca" (botão, mira, ciclo de vida) agora é
    baseada em código real confirmado. A lógica de QUEIMA em si (reduzir
    escala ao longo do tempo, diferenciar árvore viva/morta/toco, remover o
    objeto) ainda é nossa própria invenção e continua marcada com
    "-- TODO CONFIRMAR" onde relevante.
]]

DriptorchTool = {}

-- MARCA DE VERSÃO DO SCRIPT: incrementada a cada edição, impressa no log
-- assim que a ferramenta é equipada. Serve pra confirmar com certeza qual
-- versão do arquivo está rodando de verdade no jogo, sem depender de
-- "achar" que substituiu o arquivo certo.
DriptorchTool.DEBUG_BUILD = "2026-08-16-BO (NOVO: Corpo agora gira em torno do handNode (pulso), nao mais da propria origem de graphics - braco de alavanca menor, mais natural; cutNode continua orbitando junto)"

-- Tipos de alvo reconhecidos (ainda não sabemos como diferenciar isso na
-- prática - ver TODO em driptorchIsValidTarget)
DriptorchTool.TARGET_LIVE_TREE = 1
DriptorchTool.TARGET_DEAD_TREE = 2
DriptorchTool.TARGET_STUMP = 3


function DriptorchTool.prerequisitesPresent(specializations)
    return true
end


-- Registro do schema de XML (padrão confirmado tanto pelo AnimatedSaw.lua
-- quanto agora pelo HandToolSprayCan.registerXMLPaths oficial)
function DriptorchTool.registerXMLPaths(xmlSchema)
    xmlSchema:setXMLSpecializationType("DriptorchTool")

    -- IMPORTANTE: XMLValueType.TIME espera o valor em SEGUNDOS no XML (o
    -- motor converte pra milissegundos internamente). Os valores padrão
    -- abaixo (5º argumento) também precisam estar em segundos.
    xmlSchema:register(XMLValueType.TIME, "handTool.driptorchTool.burnDurations#liveTree", "Tempo para queimar árvore viva - FALLBACK sem altura (segundos)", 5)
    xmlSchema:register(XMLValueType.TIME, "handTool.driptorchTool.burnDurations#deadTree", "Tempo para queimar árvore morta - FALLBACK sem altura (segundos)", 3)
    xmlSchema:register(XMLValueType.TIME, "handTool.driptorchTool.burnDurations#stump", "Tempo para queimar toco - FALLBACK sem altura (segundos)", 2.2)
    xmlSchema:register(XMLValueType.FLOAT, "handTool.driptorchTool.burnDurations#heightFactor", "Segundos de queima por metro de altura da árvore", 1.1)
    xmlSchema:register(XMLValueType.FLOAT, "handTool.driptorchTool.burnDurations#speedMultiplier", "Multiplicador geral de velocidade (1.1 = 1.1 x mais devagar)", 1.1)
    xmlSchema:register(XMLValueType.FLOAT, "handTool.driptorchTool#range", "Alcance da mira (m)", 1.5)
    xmlSchema:register(XMLValueType.TIME, "handTool.driptorchTool#activationHoldTime", "Tempo mínimo de toque pra evitar acionamento acidental (segundos)", 0.75)
    xmlSchema:register(XMLValueType.NODE_INDEX, "handTool.driptorchTool.flameEffectNode#node", "Nó da chama na ponta da tocha")

    -- TODO CONFIRMAR: SoundManager.registerSampleXMLPaths é o helper padrão
    -- usado pelo motor pra registrar os atributos de um bloco de som (file,
    -- node, loops, volume, etc.) sem precisar declarar cada um manualmente.
    -- Se der erro de schema aqui, pode ser necessário registrar os atributos
    -- do <burning> um por um em vez de usar o helper.
    SoundManager.registerSampleXMLPaths(xmlSchema, "handTool.driptorchTool.sounds", "burning")
    SoundManager.registerSampleXMLPaths(xmlSchema, "handTool.driptorchTool.sounds", "ignite")

    xmlSchema:setXMLSpecializationType()
end


function DriptorchTool.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "driptorchActivate", DriptorchTool.driptorchActivate)
    SpecializationUtil.registerFunction(vehicleType, "driptorchIsValidTarget", DriptorchTool.driptorchIsValidTarget)
    SpecializationUtil.registerFunction(vehicleType, "driptorchGetTreeHeight", DriptorchTool.driptorchGetTreeHeight)
    SpecializationUtil.registerFunction(vehicleType, "driptorchSpawnBurnDecal", DriptorchTool.driptorchSpawnBurnDecal) -- NOVO: decalque de terra queimada
    SpecializationUtil.registerFunction(vehicleType, "driptorchProcessBurn", DriptorchTool.driptorchProcessBurn) -- NOVO: extraído do onUpdate, chamado pelo worldTicker
    SpecializationUtil.registerFunction(vehicleType, "driptorchProcessDecalFade", DriptorchTool.driptorchProcessDecalFade) -- NOVO: fade dos decalques
    SpecializationUtil.registerFunction(vehicleType, "driptorchSpawnFlame", DriptorchTool.driptorchSpawnFlame) -- NOVO: spawn genérico de 1 chama
    SpecializationUtil.registerFunction(vehicleType, "driptorchSpawnMuzzleFlame", DriptorchTool.driptorchSpawnMuzzleFlame) -- NOVO: chama-piloto no bico
    SpecializationUtil.registerFunction(vehicleType, "driptorchSpawnSmallFlames", DriptorchTool.driptorchSpawnSmallFlames) -- NOVO: Fase 1, várias chamas pequenas
    SpecializationUtil.registerFunction(vehicleType, "driptorchApplyFlameJitter", DriptorchTool.driptorchApplyFlameJitter) -- NOVO: variação de escala pro efeito de tremular
end


function DriptorchTool.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", DriptorchTool)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", DriptorchTool)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", DriptorchTool)
    SpecializationUtil.registerEventListener(vehicleType, "onHeldStart", DriptorchTool)
    SpecializationUtil.registerEventListener(vehicleType, "onHeldEnd", DriptorchTool)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", DriptorchTool)
end


-- onLoad recebe xmlFile diretamente (confirmado pelo AnimatedSaw.lua e pelo
-- HandToolSprayCan oficial), tabela da especialização criada manualmente.
function DriptorchTool:onLoad(xmlFile)
    self.spec_driptorchTool = {}
    local spec = self.spec_driptorchTool

    spec.burnDurations = {
        [DriptorchTool.TARGET_LIVE_TREE] = xmlFile:getValue("handTool.driptorchTool.burnDurations#liveTree", 5),
        [DriptorchTool.TARGET_DEAD_TREE] = xmlFile:getValue("handTool.driptorchTool.burnDurations#deadTree", 3),
        [DriptorchTool.TARGET_STUMP]     = xmlFile:getValue("handTool.driptorchTool.burnDurations#stump", 2.2),
    }
    -- Segundos de queima por metro de altura, e um multiplicador geral pra
    -- ajustar a velocidade toda de uma vez sem mexer nos outros números
    -- (pedido do usuário: queima ficou rápida demais no teste - default 2.2
    -- já deixa tudo 2x mais devagar).
    spec.heightFactor = xmlFile:getValue("handTool.driptorchTool.burnDurations#heightFactor", 1.1)
    spec.speedMultiplier = xmlFile:getValue("handTool.driptorchTool.burnDurations#speedMultiplier", 1.1)
    spec.minBurnDuration = 4000 -- ms; piso mínimo pra objetos baixos (tocos) não queimarem quase instantaneamente

    spec.range = xmlFile:getValue("handTool.driptorchTool#range", 2.3) -- era 1.5 - tocos/objetos baixos no chão ficavam fora de alcance
    spec.activationHoldTime = xmlFile:getValue("handTool.driptorchTool#activationHoldTime", 0.75)
    spec.flameEffectNode = xmlFile:getValue("handTool.driptorchTool.flameEffectNode#node", nil, self.components, self.i3dMappings)

    -- NOVO: captura a translação BASE do cutNode (relativa ao pai
    -- Driptorch_root) uma única vez, no carregamento. Necessária pra
    -- recalcular a órbita dele durante o tilt (ver onUpdate) - já que
    -- girar o cutNode em torno de si mesmo não desloca a posição o
    -- suficiente pra acompanhar o Corpo, que orbita em torno da origem de
    -- "graphics" com um braço de alavanca bem maior.
    if spec.flameEffectNode ~= nil then
        spec.cutNodeBaseX, spec.cutNodeBaseY, spec.cutNodeBaseZ = getTranslation(spec.flameEffectNode)
    end

    -- DIAGNÓSTICO NOVO: confirma diretamente se flameEffectNode (cutNode,
    -- i3dMapping "0>0>0>0") resolveu ou ficou nil. Hipótese atual: paths de
    -- profundidade 4 (0>0>0>N) podem não estar resolvendo via i3dMappings,
    -- só o de profundidade 2 (graphics, "0>0") - o engine já confirmou que
    -- firstPersonNode (mesmo padrão de profundidade) falha com warning
    -- "missing first person node". Também loga self.i3dMappings bruto pra
    -- conferir se a tabela carregou as entradas certas do XML.
    Logging.info("[Driptorch] DIAG flameEffectNode resolvido = %s (nil?=%s)",
        tostring(spec.flameEffectNode), tostring(spec.flameEffectNode == nil))
    if self.i3dMappings ~= nil then
        local mapDump = {}
        for k, v in pairs(self.i3dMappings) do
            table.insert(mapDump, tostring(k) .. "=" .. tostring(v))
        end
        Logging.info("[Driptorch] DIAG self.i3dMappings (%d entradas): %s", #mapDump, table.concat(mapDump, " | "))
    else
        Logging.info("[Driptorch] DIAG self.i3dMappings é NIL")
    end

    -- CONFIRMADO E CORRIGIDO (achado grande - possivelmente a causa raiz
    -- do mistério original da tocha invisível, não só da chama-piloto):
    -- diagnóstico anterior revelou que TANTO "cutNode" QUANTO
    -- "Driptorch_root" (a RAIZ de todo o modelo da tocha!) vinham com
    -- visibility=FALSE do .i3d exportado - escala estava perfeita (1,1,1)
    -- em todos os níveis, então a causa nunca foi escala, sempre foi
    -- visibilidade. Se a raiz do modelo inteiro está marcada invisível,
    -- nada dentro dela renderiza, não importa o que a gente faça nível por
    -- nível (bate com o padrão já suspeitado desde o início do projeto: "o
    -- GIANTS Exporter reseta Visibility silenciosamente na exportação").
    --
    -- Corrige agora: sobe a hierarquia a partir de flameEffectNode até a
    -- raiz do MUNDO, forçando visibility=true em cada ancestral (o node
    -- raiz do mundo, RootNode, não deveria precisar disso, mas forçar nele
    -- também não tem efeito colateral). CONFIRMADO no GDN: getParent(node)
    -- e getName(node) são funções reais do Foundation Reference.
    if spec.flameEffectNode ~= nil then
        Logging.info("[Driptorch] Corrigindo visibilidade na hierarquia a partir de flameEffectNode:")
        local walkNode = spec.flameEffectNode
        local depth = 0
        -- CORRIGIDO: getParent no topo da hierarquia retorna 0 (entity id
        -- inválido) em vez de nil - o diagnóstico anterior não tratava
        -- isso como fim da cadeia, causando erros "Unknown entity id 0"
        -- nas chamadas seguintes. Agora para explicitamente quando
        -- parentNode for 0.
        while walkNode ~= nil and walkNode ~= 0 and depth < 20 do
            local okName, nodeName = pcall(getName, walkNode)
            local okVis, visBefore = pcall(getVisibility, walkNode)
            setVisibility(walkNode, true)
            Logging.info("[Driptorch]   nível=%d node=%s nome=%s visibility_antes=%s -> true",
                depth, tostring(walkNode),
                okName and tostring(nodeName) or "?",
                okVis and tostring(visBefore) or "?")
            local okParent, parentNode = pcall(getParent, walkNode)
            if okParent then
                walkNode = parentNode
            else
                walkNode = nil
            end
            depth = depth + 1
        end
    end

    -- NOVO (2026-08-16-BG): a correção acima só cobre os ANCESTRAIS de
    -- flameEffectNode (cutNode). Desde que reorganizamos a hierarquia hoje
    -- (cutNode/firstPersonNode/handNode viraram IRMÃOS de graphics, não
    -- mais descendentes dele - foi isso que resolveu o "Index not found"),
    -- o ramo "graphics -> Corpo" NÃO é mais ancestral de cutNode, então a
    -- correção de visibilidade acima passou a ignorá-lo. Se graphics ou
    -- Corpo também vierem com visibility=false do exportador (mesmo bug
    -- histórico), nada os corrigia mais - possível causa do "some" mesmo
    -- com flameEffectNode e handNode/firstPersonNode já resolvendo certo.
    --
    -- Resolve "graphics" direto via I3DUtil.indexToObject (mesma função
    -- usada internamente por getValue com i3dMappings - API real
    -- confirmada em uso por outros mods), sobe até a raiz (redundante com
    -- acima, mas sem efeito colateral) e desce recursivamente por TODOS os
    -- filhos, corrigindo visibility=true em cada um (cobre Corpo e
    -- qualquer outro node que apareça embaixo de graphics no futuro).
    local graphicsPath = self.i3dMappings ~= nil and self.i3dMappings["graphics"] or nil
    if graphicsPath ~= nil then
        local graphicsNode = I3DUtil.indexToObject(self.components, graphicsPath, self.i3dMappings)
        if graphicsNode ~= nil then
            Logging.info("[Driptorch] Corrigindo visibilidade na hierarquia a partir de graphics (node=%s):", tostring(graphicsNode))

            -- Sobe até a raiz (redundante com o loop de cutNode, mas
            -- inofensivo - garante cobertura mesmo se a árvore mudar de
            -- novo no futuro).
            local upNode = graphicsNode
            local upDepth = 0
            while upNode ~= nil and upNode ~= 0 and upDepth < 20 do
                local okName, nodeName = pcall(getName, upNode)
                local okVis, visBefore = pcall(getVisibility, upNode)
                setVisibility(upNode, true)
                Logging.info("[Driptorch]   [graphics-up] nível=%d node=%s nome=%s visibility_antes=%s -> true",
                    upDepth, tostring(upNode), okName and tostring(nodeName) or "?", okVis and tostring(visBefore) or "?")
                local okParent, parentNode = pcall(getParent, upNode)
                upNode = okParent and parentNode or nil
                upDepth = upDepth + 1
            end

            -- Desce recursivamente por todos os filhos (cobre Corpo e
            -- qualquer node futuro debaixo de graphics).
            local function fixVisibilityRecursive(node, depth)
                if node == nil or depth > 20 then
                    return
                end
                local okName, nodeName = pcall(getName, node)
                local okVis, visBefore = pcall(getVisibility, node)
                setVisibility(node, true)
                Logging.info("[Driptorch]   [graphics-down] nível=%d node=%s nome=%s visibility_antes=%s -> true",
                    depth, tostring(node), okName and tostring(nodeName) or "?", okVis and tostring(visBefore) or "?")
                local numChildren = getNumOfChildren(node)
                if numChildren ~= nil and numChildren > 0 then
                    for i = 0, numChildren - 1 do
                        local child = getChildAt(node, i)
                        if child ~= nil then
                            fixVisibilityRecursive(child, depth + 1)
                        end
                    end
                end
            end
            fixVisibilityRecursive(graphicsNode, 0)
        else
            Logging.info("[Driptorch] DIAG: graphicsPath=%s não resolveu via I3DUtil.indexToObject", tostring(graphicsPath))
        end
    else
        Logging.info("[Driptorch] DIAG: self.i3dMappings['graphics'] não encontrado")
    end

    -- NOVO: captura translação BASE de "graphics" e a posição do
    -- "handNode" (pivô externo) uma única vez, no carregamento. Serve pra
    -- fazer o Corpo girar em torno do PUNHO (handNode) durante o tilt, em
    -- vez de girar em torno da própria origem de graphics (que produzia
    -- um salto de ~10cm na ponta, braço de alavanca grande demais pra um
    -- gesto de "torcer o pulso").
    if graphicsPath ~= nil then
        local graphicsNodeForBase = I3DUtil.indexToObject(self.components, graphicsPath, self.i3dMappings)
        if graphicsNodeForBase ~= nil then
            spec.graphicsBaseX, spec.graphicsBaseY, spec.graphicsBaseZ = getTranslation(graphicsNodeForBase)
        end
    end
    local handNodePath = self.i3dMappings ~= nil and self.i3dMappings["handNode"] or nil
    if handNodePath ~= nil then
        local handNodeForPivot = I3DUtil.indexToObject(self.components, handNodePath, self.i3dMappings)
        if handNodeForPivot ~= nil then
            spec.pivotHandX, spec.pivotHandY, spec.pivotHandZ = getTranslation(handNodeForPivot)
        end
    end
    Logging.info("[Driptorch] DIAG pivo: graphicsBase=%s,%s,%s handNode=%s,%s,%s",
        tostring(spec.graphicsBaseX), tostring(spec.graphicsBaseY), tostring(spec.graphicsBaseZ),
        tostring(spec.pivotHandX), tostring(spec.pivotHandY), tostring(spec.pivotHandZ))

    -- TODO CONFIRMAR: assinatura exata de loadSampleFromXML pode variar -
    -- esse é o padrão mais comum usado em especializações de veículo/handTool
    -- (xmlFile, caminho base, nome do nó filho, diretório base do mod,
    -- components, i3dMappings, loops padrão, grupo de áudio, alvo).
    spec.sounds = {}
    spec.sounds.ignite = g_soundManager:loadSampleFromXML(
        xmlFile,
        "handTool.driptorchTool.sounds",
        "ignite",
        self.baseDirectory,
        self.components,
        0, AudioGroup.VEHICLE, self.i3dMappings, self
    )

    -- NOVO: som "base" carregado UMA VEZ, do jeito que já sabemos que
    -- funciona (self.components resolve "cutNode" - o mesmo que já
    -- funcionava pro burning/ignite originais). Esse vira o som da
    -- chama-piloto (bico da tocha) E o "molde" que cada sessão de queima
    -- clona pra si mesma (ver início da queima em onUpdate) - MULTI-QUEIMA:
    -- cada árvore queimando precisa do seu PRÓPRIO clone de som (posição
    -- própria, volume próprio), não dá mais pra ter uma âncora/clone único
    -- compartilhado como antes (isso só suportava uma queima por vez).
    spec.flameMuzzleScale = 0.017 -- bem pequena - só um "pavio" aceso, não uma fogueira
    -- NOVO: offset da chama-piloto pra nascer no BICO (ponta), não no seu
    -- próprio centro. O plano/cross-billboard da chama é centrado na
    -- própria origem, então metade dele "afunda" pra trás do cutNode sem
    -- esse deslocamento. Local a cutNode (não ao mundo) - eixo e sinal
    -- ainda por confirmar empiricamente (testar um de cada vez). Valor em
    -- metros, JÁ multiplicado pela escala (senão o offset fica pequeno
    -- demais pra acompanhar o flameMuzzleScale).
    spec.flameMuzzleOffsetX = -0
    spec.flameMuzzleOffsetY = -0.003
    spec.flameMuzzleOffsetZ = -0.005 -- CHUTE INICIAL - ajustar por teste
    -- NOVO: rotação da chama-piloto (graus), pra corrigir a orientação
    -- dela em relação ao cutNode - ficou desalinhada depois de rotacionar
    -- o Corpo -90° no Blender sem realinhar o cutNode junto. Ajustar por
    -- teste, um eixo de cada vez.
    spec.flameMuzzleRotationX = 0
    spec.flameMuzzleRotationY = 0
    spec.flameMuzzleRotationZ = 270
    spec.muzzleFlameNode = nil
    spec.sounds.muzzleFlame = g_soundManager:loadSampleFromXML(
        xmlFile,
        "handTool.driptorchTool.sounds",
        "burning",
        self.baseDirectory,
        self.components,
        0, AudioGroup.VEHICLE, self.i3dMappings, self
    )

    -- DECALQUE DE TERRA QUEIMADA: carrega o burnedSoil.i3d UMA VEZ aqui e
    -- guarda o nó como "template" escondido - toda vez que uma árvore
    -- terminar de queimar, clonamos esse template em vez de reler o arquivo
    -- do disco (mais leve em performance).
    --
    -- CONFIRMADO no GDN (I3DManager, categoria I3d/script):
    -- loadSharedI3DFile(filename, callOnCreate, addToPhysics) retorna
    -- (node, sharedLoadRequestId, failedReason). Guardamos o
    -- sharedLoadRequestId pra usar em releaseSharedI3DFile no onDelete -
    -- essa função espera o REQUEST ID, não o filename (era esse o bug do
    -- "Argument 1 has wrong type. Expected: Int. Actual: String").
    spec.decalI3DFilename = Utils.getFilename("burnedSoil.i3d", self.baseDirectory)
    spec.decalSourceRootNode = nil
    spec.decalTemplateNode = nil
    spec.decalSharedLoadRequestId = nil

    local decalRoot, sharedLoadRequestId, failedReason = g_i3DManager:loadSharedI3DFile(spec.decalI3DFilename, false, false)
    spec.decalSharedLoadRequestId = sharedLoadRequestId
    if decalRoot ~= nil then
        spec.decalSourceRootNode = decalRoot
        -- assume que "Circle" é o primeiro (e único) filho do i3d carregado
        spec.decalTemplateNode = getChildAt(decalRoot, 0)

        if spec.decalTemplateNode ~= nil then
            -- o template fica escondido e nunca aparece sozinho - só serve
            -- de origem pra clone() a cada árvore queimada
            setVisibility(spec.decalTemplateNode, false)
        else
            Logging.warning("[Driptorch] burnedSoil.i3d carregou mas não achei o filho esperado (Circle)")
        end
    else
        Logging.warning("[Driptorch] Falha ao carregar burnedSoil.i3d (path: %s) failedReason=%s", tostring(spec.decalI3DFilename), tostring(failedReason))
    end

    -- Guarda os clones ativos pra poder limitar a quantidade total (evita
    -- acumular nós infinitamente numa sessão de jogo longa com muitas
    -- árvores queimadas). Cada entrada é {node=..., age=0} - "age" acumula
    -- dt normalmente (mesma unidade de burnTimer/burnDuration: ms), usado
    -- pelo fade abaixo.
    spec.activeDecals = {}
    spec.maxActiveDecals = 40
    spec.decalLifetime = 3.7 * 60 * 1000       -- 5min opaco antes de começar a sumir (ajustável)
    spec.decalFadeDuration = 29 * 1000       -- 30s de fade até sumir de vez (ajustável)

    -- CHAMA (flame.i3d): mesmo padrão de carregamento do decalque -
    -- carrega uma vez, guarda um template escondido pra clonar. Diferente
    -- do decalque (uma malha só), aqui o template é um Empty com DOIS
    -- planos filhos (cross-billboard) - o clone precisa copiar os filhos
    -- junto (copyChildren=true), diferente do clone do decalque.
    spec.flameI3DFilename = Utils.getFilename("flame.i3d", self.baseDirectory)
    spec.flameSourceRootNode = nil
    spec.flameTemplateNode = nil
    spec.flameSharedLoadRequestId = nil

    local flameRoot, flameSharedLoadRequestId, flameFailedReason = g_i3DManager:loadSharedI3DFile(spec.flameI3DFilename, false, false)
    spec.flameSharedLoadRequestId = flameSharedLoadRequestId
    if flameRoot ~= nil then
        spec.flameSourceRootNode = flameRoot
        -- assume que o Empty (pai dos dois planos em X) é o primeiro filho
        spec.flameTemplateNode = getChildAt(flameRoot, 0)

        if spec.flameTemplateNode ~= nil then
            setVisibility(spec.flameTemplateNode, false)
        else
            Logging.warning("[Driptorch] flame.i3d carregou mas não achei o filho esperado (Empty)")
        end
    else
        Logging.warning("[Driptorch] Falha ao carregar flame.i3d (path: %s) failedReason=%s", tostring(spec.flameI3DFilename), tostring(flameFailedReason))
    end

    -- Parâmetros de chama (ajustáveis, compartilhados entre todas as
    -- sessões de queima) - ver driptorchProcessBurn pra lógica das fases
    -- (várias pequenas -> uma central crescendo até o pico -> 2 degraus de
    -- redução, terminando junto com a árvore). O ESTADO de cada queima em
    -- si (chamas pequenas, chama principal, etc) agora vive dentro de cada
    -- sessão em spec.activeBurns, não mais aqui como campo único.

    spec.flameSmallCount = 13       -- quantas chamas pequenas na Fase 1
    spec.flamePhase1End = 0.71      -- progress em que a Fase 1 termina e a Fase 2 (crescimento) começa
    spec.flameConvergenceFactor = 0.97 -- acelerado a pedido (era 0.55). Velocidade da puxada pro centro (1.0=atinge o centro no fim da
                                       -- Fase 1; 0.5=metade da velocidade, ainda espalhadas quando a Fase
                                       -- 1 termina - ajustar aqui pra mais rápido/devagar)

    -- NOVO DESIGN: alinhado aos "degraus" visíveis de encolhimento da
    -- árvore (setScale do tronco só atualiza a cada 5% de mudança - ver
    -- THROTTLE em driptorchProcessBurn, então existem ~20 degraus ao longo
    -- da queima, em incrementos de flameStageStep). A chama cresce até o
    -- PICO no degrau ANTEPENÚLTIMO, cai pra 50% no PENÚLTIMO, e cai de
    -- novo pra 50% daquilo (25% do pico) no ÚLTIMO degrau - desaparecendo
    -- junto com a árvore (sem sobrevida pós-queima; o design anterior de
    -- "sobrevida" foi abandonado, já que agora a chama já está bem menor
    -- antes mesmo da árvore sumir de vez).
    spec.flameStageStep = 0.037           -- mesmo incremento do throttle da árvore
    spec.flamePeakProgress = 0.95        -- degrau antepenúltimo - onde o crescimento termina e o pico é atingido
    spec.flameGrowthSpeedFactor = 1.7    -- +10% a pedido - cresce mais rápido dentro da mesma janela
                                          -- (flamePhase1End -> flamePeakProgress); com 1.1, atinge o pico um
                                          -- pouco ANTES de flamePeakProgress e fica parado nele até lá
    spec.flameSmallScale = 0.41      -- escala das chamas pequenas da Fase 1
    spec.flameMainStartScale = 0.53  -- escala inicial da chama única (começo da Fase 2)
    spec.flameMainFullScale = 2.1   -- escala "normal" da chama única (era 3.0, -10% a pedido) - atingida
                                     -- ao fim do crescimento gradual; pico/degraus são calculados a partir
                                     -- deste valor, então a redução se propaga automaticamente
    spec.flameBoostMultiplier = 1.29 -- pedido: chama final um pouco maior nos últimos 3 estágios (era 1.3);
                                      -- afeta só pico/50%/25% (cascateiam de peakScale), não a fase de
                                      -- crescimento anterior
                                     -- (flameMainFullScale e flameBoostMultiplier: AJUSTAR visualmente,
                                     -- mesmo processo iterativo que fizemos com o tamanho do decalque)
    spec.flameJitterAmount = 0.17   -- +-8% de variação de escala por frame, pro efeito de "tremular"

    -- ARQUITETURA HÍBRIDA: tanto a queima em andamento quanto o fade dos
    -- decalques precisam continuar progredindo mesmo com a tocha guardada
    -- (não na mão) - mas o onUpdate desta specialization provavelmente só
    -- dispara enquanto o HandTool está equipado. Por isso registramos um
    -- "updateable" separado, a nível de MISSÃO, que roda todo frame
    -- independente do estado da tocha (mesmo padrão usado por triggers e
    -- managers do próprio jogo).
    --
    -- TODO CONFIRMAR: addUpdateable/removeUpdateable é uma API bem
    -- estabelecida no engine (usada por vários mods e pelo próprio jogo),
    -- mas ainda não testamos na prática neste projeto - se o :update(dt)
    -- não disparar como esperado, conferir no GDN.
    --
    -- NOTA: NÃO usar entityExists() aqui - "vehicle" é o objeto Lua da
    -- specialization (uma tabela), não um node id do engine. entityExists
    -- espera um inteiro (node/entity id) e quebra com "Argument 1 has
    -- wrong type" se receber a tabela. A proteção contra objeto deletado
    -- já vem do onDelete, que desregistra este ticker via
    -- removeUpdateable antes do objeto sumir de vez.
    spec.worldTicker = {}
    spec.worldTicker.vehicle = self
    function spec.worldTicker:update(dt)
        self.vehicle:driptorchProcessBurn(dt)
        self.vehicle:driptorchProcessDecalFade(dt)
    end
    g_currentMission:addUpdateable(spec.worldTicker)

    -- Estado do botão (mesmo padrão do HandToolSprayCan: activatePressed é
    -- setado pelo action event, e lido/consumido a cada onUpdate)
    spec.activatePressed = false
    spec.pressHoldTimer = 0 -- acumula enquanto segura mirando num alvo, antes de disparar de verdade
    spec.pressHoldTarget = nil -- node mirado quando o acúmulo começou - se mudar, reinicia (evita cadeia de ignições por oscilação de mira)

    -- MULTI-QUEIMA: em vez de um único conjunto de campos (spec.currentTarget,
    -- spec.burnTimer, etc - um valor cada, só uma queima possível por vez),
    -- cada árvore queimando é uma SESSÃO independente numa lista
    -- (spec.activeBurns) - mesmo padrão já usado em spec.activeDecals. Cada
    -- sessão é uma tabela com: target, targetType, burnTimer, burnDuration,
    -- originalScale, lastAppliedScaleFactor, decalNode/decalFinalScale/
    -- decalStartScale, flameX/flameZ/flameGroundY/flameOuterRadius,
    -- smallFlames, mainFlameNode, mainFlameSpawned, soundAnchor, soundSample.
    -- Isso permite iniciar uma queima nova numa árvore diferente enquanto
    -- outra(s) ainda estão queimando (pedido: "enquanto uma árvore está
    -- queimando, não é possível iniciar fogo em outras").
    spec.activeBurns = {}

    -- TODO CONFIRMAR: criar/carregar o efeito de partícula real (chama na
    -- ponta), provavelmente via g_effectManager:loadEffect(...) - é assim
    -- que o HandToolSprayCan carrega os efeitos dele (spec.effects).
    spec.flameEffect = nil

    -- Balanço/oscilação enquanto segura a tocha (pedido do usuário: em vez
    -- da vibração de motor herdada do chainsaw, um movimento de vaivém tipo
    -- +-5 graus, como quem caminha segurando um pingafogo de verdade).
    -- TODO CONFIRMAR: eixo de rotação (x/y/z) certo depende da orientação
    -- real do futuro modelo 3D - por enquanto oscila no eixo Z (chute
    -- razoável para um objeto empunhado na vertical). Ajustar quando tivermos
    -- o i3d próprio.
    spec.swayAmplitude = math.rad(3)  -- 3 graus pra cada lado
    spec.swaySpeed = 0.0013           -- velocidade da oscilação (ajustar ao testar)

    -- NOVO: inclinação ao segurar o botão de ativação, simulando o gesto
    -- de derramar o combustível em chamas (como um pingafogo de verdade).
    -- Suavizada via lerp (não é instantânea) - inclina progressivamente
    -- enquanto activatePressed=true, volta suavemente ao soltar. Eixo e
    -- sinal ainda por confirmar por teste (X é o chute inicial).
    spec.tiltAngleCurrent = 0          -- estado atual (radianos), animado a cada frame
    spec.tiltAngleTarget = math.rad(19.0) -- CHUTE INICIAL - ajustar por teste (graus de inclinação ao segurar)
    spec.tiltSpeed = 5.3               -- "velocidade" do lerp (maior = mais rápido) - ajustar ao testar
    spec.tiltAxis = "y"                -- CONFIRMADO por teste: inclinação vertical, eixo Y

    -- DIAGNÓSTICO TEMPORÁRIO (remover depois)
    spec.debugLastHasTarget = false
    spec.debugLastActivatePressed = false
end


-- Chamado quando o item é efetivamente pego na mão (confirmado pelo
-- HandToolSprayCan.onHeldStart oficial). É aqui que registramos o alvo no
-- sistema de mira do jogador - só enquanto a ferramenta estiver equipada.
function DriptorchTool:onHeldStart()
    if not self:getCarryingPlayer().isOwner then
        return
    end

    local spec = self.spec_driptorchTool
    local targeter = self:getCarryingPlayer().targeter

    targeter:addTargetType(DriptorchTool, CollisionFlag.TREE, 0, spec.range)
    targeter:addFilterToTargetType(DriptorchTool, function(hitNode, x, y, z)
        return getHasClassId(hitNode, ClassIds.MESH_SPLIT_SHAPE)
    end)

    -- REMOVIDO: o som de queima da ÁRVORE não toca mais ao equipar a
    -- ferramenta - fica atrelado à árvore enquanto ela queima (ver início
    -- da queima em onUpdate + driptorchProcessBurn), independente da tocha
    -- estar na mão ou não.

    -- Toca o som de "acender" uma única vez ao pegar o item
    if spec.sounds.ignite ~= nil then
        g_soundManager:playSample(spec.sounds.ignite)
    end

    -- NOVO: chama-piloto no bico + seu próprio som, enquanto a ferramenta
    -- estiver equipada (independente de estar queimando algo ou não).
    if spec.muzzleFlameNode == nil then
        spec.muzzleFlameNode = self:driptorchSpawnMuzzleFlame()
    end
    if spec.sounds.muzzleFlame ~= nil then
        g_soundManager:playSample(spec.sounds.muzzleFlame)
    end

    -- DIAGNÓSTICO: relata tudo que importa numa linha só, começando pela
    -- marca de versão (confirma que é ESTE arquivo que está rodando).
    Logging.info("[Driptorch] BUILD=%s", tostring(DriptorchTool.DEBUG_BUILD))

    if self.graphicalNode ~= nil then
        local sx, sy, sz = getScale(self.graphicalNode)
        local vis = getVisibility(self.graphicalNode)
        local numChildren = getNumOfChildren(self.graphicalNode)
        local childInfo = "sem filhos"
        if numChildren ~= nil and numChildren > 0 then
            local child = getChildAt(self.graphicalNode, 0)
            if child ~= nil then
                local isShape = getHasClassId(child, ClassIds.SHAPE)
                local childVis = getVisibility(child)
                local csx, csy, csz = getScale(child)
                childInfo = string.format("filho0 nome=%s isShape=%s visibility=%s escala=%s,%s,%s",
                    tostring(getName(child)), tostring(isShape), tostring(childVis),
                    tostring(csx), tostring(csy), tostring(csz))

                -- Bounding box REAL do Corpo em espaço de mundo (nunca vimos
                -- isso direto - só o BV radius do GE, que pode ser outra
                -- coisa). Se width/height/depth vier minúsculo (tipo 0.001),
                -- confirma problema de escala na malha em si, não no nó.
                local ok, minX, maxX, minY, maxY, minZ, maxZ = pcall(getRigidBodyAABB, child)
                if ok and minX ~= nil then
                    Logging.info("[Driptorch] DIAG Corpo AABB: X=%s->%s (largura=%s) Y=%s->%s (altura=%s) Z=%s->%s (profundidade=%s)",
                        tostring(minX), tostring(maxX), tostring(maxX-minX),
                        tostring(minY), tostring(maxY), tostring(maxY-minY),
                        tostring(minZ), tostring(maxZ), tostring(maxZ-minZ))
                else
                    Logging.info("[Driptorch] DIAG getRigidBodyAABB no Corpo falhou ou retornou nil")
                end
            end
        end
        Logging.info("[Driptorch] DIAG graphics: escala=%s,%s,%s visibility=%s filhos=%s (%s)",
            tostring(sx), tostring(sy), tostring(sz), tostring(vis), tostring(numChildren), childInfo)
    else
        Logging.info("[Driptorch] DIAG self.graphicalNode é NIL")
    end

    -- DIAGNÓSTICO NOVO: self.graphicalNodeParent - achado em código-fonte
    -- real (mod LumberJack), nunca checamos antes. Se a escala MUNDIAL
    -- efetiva desse "pai" estiver esmagada (perto de zero), explicaria por
    -- que só escalar o graphicalNode "compensa" o problema.
    if self.graphicalNodeParent ~= nil then
        local psx, psy, psz = getScale(self.graphicalNodeParent)
        local pvis = getVisibility(self.graphicalNodeParent)
        local pname = getName(self.graphicalNodeParent)
        Logging.info("[Driptorch] DIAG graphicalNodeParent: nome=%s escalaLocal=%s,%s,%s visibility=%s",
            tostring(pname), tostring(psx), tostring(psy), tostring(psz), tostring(pvis))
    else
        Logging.info("[Driptorch] DIAG self.graphicalNodeParent é NIL")
    end

    -- DIAGNÓSTICO NOVO: distância REAL até a câmera do jogador (nunca medimos
    -- isso - só media distância entre nós do nosso próprio objeto, que
    -- sempre foi 0, mas isso não prova que o objeto está perto da câmera de
    -- verdade).
    local player = self:getCarryingPlayer()
    if player ~= nil then
        local camCandidate = nil
        local camSource = "nenhum"
        if player.getCameraNode ~= nil then
            camCandidate = player:getCameraNode()
            camSource = "player:getCameraNode()"
        elseif player.cameraNode ~= nil then
            camCandidate = player.cameraNode
            camSource = "player.cameraNode"
        elseif player.camera ~= nil then
            camCandidate = player.camera
            camSource = "player.camera"
        end

        Logging.info("[Driptorch] DIAG camCandidate via %s, type=%s, value=%s",
            tostring(camSource), tostring(type(camCandidate)), tostring(camCandidate))

        -- Se for uma tabela (objeto Lua, não node bruto), lista TODOS os
        -- campos reais dela, em vez de continuar chutando nomes um por um.
        if type(camCandidate) == "table" then
            local fieldList = {}
            for k, v in pairs(camCandidate) do
                if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
                    table.insert(fieldList, tostring(k) .. "=" .. tostring(v))
                else
                    table.insert(fieldList, tostring(k) .. "(" .. type(v) .. ")")
                end
            end
            Logging.info("[Driptorch] DIAG campos de camCandidate: %s", table.concat(fieldList, " | "))

            -- ACHADO: firstPersonCamera é o node real da câmera em 1ª pessoa
            -- (confirmado por isFirstPerson=true nos campos acima).
            if camCandidate.firstPersonCamera ~= nil and self.graphicalNode ~= nil then
                local camNode = camCandidate.firstPersonCamera
                local cwx, cwy, cwz = getWorldTranslation(camNode)
                local gwx, gwy, gwz = getWorldTranslation(self.graphicalNode)
                local distCam = math.sqrt((cwx-gwx)^2 + (cwy-gwy)^2 + (cwz-gwz)^2)
                Logging.info("[Driptorch] DIAG distancia REAL ate camera 1a pessoa: %sm | camPos=%s,%s,%s | graphicsPos=%s,%s,%s",
                    tostring(distCam), tostring(cwx), tostring(cwy), tostring(cwz), tostring(gwx), tostring(gwy), tostring(gwz))

                -- TESTE: empurra o objeto MAIS 0.5m na direção EXATA
                -- (câmera->objeto, calculada matematicamente, não mais
                -- chutando eixo local do Blender). Se isso resolver,
                -- confirma de vez que era questão de distância/direção
                -- errada nos testes anteriores.
                -- (sem forçar escala dessa vez - queremos ver o estado
                -- natural do objeto, incluindo visibility/AABB do Corpo)
            end
        end
    else
        Logging.info("[Driptorch] DIAG getCarryingPlayer() retornou nil")
    end
end


-- Simétrico ao onHeldStart - remove o registro de mira quando larga o item.
-- TODO CONFIRMAR: onHeldEnd e removeTargetType existem e funcionam assim -
-- baseado em PlayerTargeter:removeTargetType(targetKey) que confirmamos
-- existir, mas o gancho de evento onHeldEnd em si não vimos o código-fonte.
function DriptorchTool:onHeldEnd()
    if not self:getCarryingPlayer().isOwner then
        return
    end

    local spec = self.spec_driptorchTool
    local targeter = self:getCarryingPlayer().targeter
    targeter:removeTargetType(DriptorchTool)

    -- REMOVIDO: não para mais o som de queima DA ÁRVORE aqui - ele é
    -- controlado pelo início/fim da queima em si (driptorchProcessBurn),
    -- não pelo estado de "segurando a ferramenta". Continua tocando
    -- (posicional, na árvore) mesmo depois de largar a tocha, se ainda
    -- estiver queimando.

    -- NOVO: apaga a chama-piloto do bico e para o som dela ao desequipar.
    if spec.muzzleFlameNode ~= nil then
        if type(entityExists) ~= "function" or entityExists(spec.muzzleFlameNode) then
            delete(spec.muzzleFlameNode)
        end
        spec.muzzleFlameNode = nil
    end
    if spec.sounds.muzzleFlame ~= nil then
        g_soundManager:stopSample(spec.sounds.muzzleFlame)
    end
end


function DriptorchTool:onDelete()
    local spec = self.spec_driptorchTool

    if spec.sounds ~= nil then
        if spec.sounds.ignite ~= nil then
            g_soundManager:deleteSample(spec.sounds.ignite)
        end
        if spec.sounds.muzzleFlame ~= nil then
            g_soundManager:deleteSample(spec.sounds.muzzleFlame)
        end
    end

    -- NOVO: deleta a chama-piloto e seu node (se o item for deletado com
    -- a ferramenta ainda equipada, por algum motivo)
    if spec.muzzleFlameNode ~= nil then
        if type(entityExists) ~= "function" or entityExists(spec.muzzleFlameNode) then
            delete(spec.muzzleFlameNode)
        end
    end

    -- NOVO: libera o i3d compartilhado do decalque (contrapartida do load
    -- feito no onLoad). CONFIRMADO no GDN: releaseSharedI3DFile espera o
    -- sharedLoadRequestId (integer), não o filename - era esse o bug do
    -- "Argument 1 has wrong type. Expected: Int. Actual: String".
    if spec.decalSharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(spec.decalSharedLoadRequestId, false)
    end

    -- NOVO: libera o flame.i3d compartilhado (mesma contrapartida)
    if spec.flameSharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(spec.flameSharedLoadRequestId, false)
    end

    -- MULTI-QUEIMA: limpa TODAS as sessões ainda ativas (se o item for
    -- deletado no meio de uma ou mais queimas) - cada sessão tem seu
    -- próprio conjunto de chamas pequenas, chama principal, e som (âncora
    -- + sample clonado).
    if spec.activeBurns ~= nil then
        for _, session in ipairs(spec.activeBurns) do
            for _, entry in ipairs(session.smallFlames) do
                if type(entityExists) ~= "function" or entityExists(entry.node) then
                    delete(entry.node)
                end
            end
            if session.mainFlameNode ~= nil then
                if type(entityExists) ~= "function" or entityExists(session.mainFlameNode) then
                    delete(session.mainFlameNode)
                end
            end
            if session.soundSample ~= nil then
                g_soundManager:deleteSample(session.soundSample)
            end
            if session.soundAnchor ~= nil then
                if type(entityExists) ~= "function" or entityExists(session.soundAnchor) then
                    delete(session.soundAnchor)
                end
            end
        end
        spec.activeBurns = {}
    end

    -- NOVO: desregistra o ticker de missão (contrapartida do addUpdateable
    -- feito no onLoad) - evita callback em objeto já deletado.
    if spec.worldTicker ~= nil then
        g_currentMission:removeUpdateable(spec.worldTicker)
    end
end


-- Padrão confirmado pelo HandToolSprayCan.onRegisterActionEvents oficial:
-- reaproveita InputAction.ACTIVATE_HANDTOOL (já existe, não é preciso criar
-- uma ação de input customizada).
--
-- IMPORTANTE: como herdamos de "chainsaw", a especialização HandToolChainsaw
-- também registra o controle axial (rotação manual com o mouse - "Advanced
-- Controls") nesse mesmo evento. O pingafogo não deve ter isso, então
-- limpamos tudo com clearActionEvents() antes de registrar só o nosso botão.
-- Isso funciona porque nosso onRegisterActionEvents roda DEPOIS do da
-- especialização herdada (ordem de registro: specs do tipo pai primeiro,
-- depois a nossa, que foi adicionada por último em handToolTypes).
function DriptorchTool:onRegisterActionEvents()
    if not self:getIsActiveForInput(true) then
        return
    end

    -- Remove qualquer action event já registrado (ex: o controle axial do
    -- chainsaw), deixando só o que registramos abaixo.
    self:clearActionEvents()

    local _, actionEventId = self:addActionEvent(InputAction.ACTIVATE_HANDTOOL, self, self.driptorchActivate, true, true, false, true, nil)
    g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
    g_inputBinding:setActionEventText(actionEventId, g_i18n:getText("action_driptorchBurn"))
end


-- Callback do action event - mesmo padrão de activateSpraying do
-- HandToolSprayCan: só marca a flag, o trabalho de verdade acontece no
-- onUpdate.
function DriptorchTool:driptorchActivate(actionName, inputValue)
    local spec = self.spec_driptorchTool
    spec.activatePressed = inputValue ~= 0
end


-- Cria uma cópia do decalque de terra queimada na posição (worldX, worldZ),
-- alinhado à altura real do terreno nesse ponto (não à altura do alvo
-- original, que já foi deletado quando isso for chamado).
--
-- trunkDiameter: diâmetro aproximado da base da árvore (em metros), usado
-- pra escalar o decalque - árvore fina gera decalque pequeno, árvore grossa
-- gera decalque grande. Se nil (ex: fallback sem AABB disponível), usa o
-- tamanho base da malha (2m) sem escalar.
--
-- TODO CONFIRMAR: assinatura exata de clone() - o padrão mais comum visto em
-- código de mods é clone(node, copyChildren, forceCloneMaterials,
-- callDelayed), mas verificar no GDN antes de considerar isso definitivo.
-- Se der erro de assinatura, ajustar aqui.
function DriptorchTool:driptorchSpawnBurnDecal(worldX, worldZ, trunkDiameter)
    local spec = self.spec_driptorchTool
    Logging.info("[Driptorch][decal] SPAWN chamado: pos=(%.2f,%.2f) trunkDiameter=%s decalsAtivos=%d",
        worldX, worldZ, tostring(trunkDiameter), spec.activeDecals ~= nil and #spec.activeDecals or 0)

    if spec.decalTemplateNode == nil then
        Logging.info("[Driptorch][decal] -> ABORTADO: decalTemplateNode nil (i3d nao carregou)")
        return nil -- decalque não carregou (ver warning no onLoad)
    end

    -- NOVO: teto de sanidade no trunkDiameter. O log mostrou valores tipo
    -- 15.13m - nenhum tronco real de árvore do jogo mede isso; é sinal de
    -- que a AABB está capturando largura de copa/galhos, não só o tronco
    -- fino. Sem esse teto, um trunkDiameter inflado fazia o tamanho de
    -- NASCIMENTO (70% dele) ultrapassar o tamanho FINAL (que tem seu
    -- próprio teto MAX_SCALE), colapsando a animação de crescimento -
    -- decalque nascia praticamente do tamanho final e "crescia" um resto
    -- imperceptível (parecia aparecer de uma vez só).
    local MAX_PLAUSIVEL_TRUNK_DIAMETER = 1.2 -- metros (mantido igual ao teto aplicado na fonte, ver onUpdate)
    if trunkDiameter ~= nil and trunkDiameter > MAX_PLAUSIVEL_TRUNK_DIAMETER then
        Logging.info("[Driptorch][decal] trunkDiameter=%.2f parece incluir copa/galhos, limitando a %.2f",
            trunkDiameter, MAX_PLAUSIVEL_TRUNK_DIAMETER)
        trunkDiameter = MAX_PLAUSIVEL_TRUNK_DIAMETER
    end

    -- Escala proporcional ao diâmetro do tronco: a malha base do decalque
    -- foi modelada com 2m de diâmetro (ver notas do Blender), então um
    -- decalque proporcional ao "raio de rescaldo" ao redor da árvore usa um
    -- multiplicador sobre o diâmetro do tronco - não faz sentido o
    -- decalque ficar do mesmo tamanho do tronco em si, senão fica minúsculo
    -- pra qualquer árvore.
    --
    -- GLOBAL_SIZE_REDUCTION: redutor aplicado por cima de tudo (pedido:
    -- "fica maior que o tronco, mas faz sentido se considerarmos as cinzas
    -- da copa" - então 100% do cálculo por diâmetro ficava grande demais;
    -- 75% do valor calculado é o tamanho final aplicado).
    local DECAL_BASE_DIAMETER = 2.0     -- diâmetro da malha original, em metros
    local TRUNK_TO_DECAL_MULT = 3.5     -- decalque = tronco x 3.5 (área de rescaldo) ANTES do redutor
    local MIN_SCALE = 0.6               -- nunca menor que 60% do tamanho base (40% ficava pequeno demais em árvores finas)
    local MAX_SCALE = 2.5               -- nunca maior que 250% do tamanho base
    local GLOBAL_SIZE_REDUCTION = 0.8625  -- 0.75 * 1.15 (pedido: raio final 15% maior), aplicado por último, sobre o resultado já clampado

    local scaleFactor = 1.0
    if trunkDiameter ~= nil and trunkDiameter > 0 then
        local desiredDiameter = trunkDiameter * TRUNK_TO_DECAL_MULT
        scaleFactor = desiredDiameter / DECAL_BASE_DIAMETER
        scaleFactor = math.max(MIN_SCALE, math.min(MAX_SCALE, scaleFactor))
    end
    scaleFactor = scaleFactor * GLOBAL_SIZE_REDUCTION

    -- NOVO: tamanho de NASCIMENTO do decalque - 70% do diâmetro do
    -- próprio TRONCO (não do tamanho final de rescaldo, que já inclui o
    -- multiplicador de área). A ideia: o decalque nasce praticamente
    -- escondido debaixo da árvore ainda de pé, e vai "aparecendo"/
    -- crescendo conforme ela encolhe durante a queima (ver
    -- driptorchProcessBurn), em vez de surgir do nada.
    local TRUNK_START_FRACTION = 0.85 -- era 0.70; árvores grossas demoravam a aparecer
    local startScaleFactor
    if trunkDiameter ~= nil and trunkDiameter > 0 then
        startScaleFactor = (trunkDiameter * TRUNK_START_FRACTION) / DECAL_BASE_DIAMETER
    else
        -- Sem AABB disponível: usa uma fração pequena do tamanho final
        -- como fallback (mesmo comportamento de antes nesse caso).
        startScaleFactor = scaleFactor * 0.05
    end
    -- Trava de segurança: garante que o nascimento seja sempre MENOR que o
    -- final, pra nunca "encolher" por engano num caso extremo (ex: tronco
    -- muito largo perto do teto MAX_SCALE do tamanho final).
    startScaleFactor = math.min(startScaleFactor, scaleFactor * 0.95)
    startScaleFactor = math.max(startScaleFactor, 0.02) -- nunca zero/negativo (mesh degenerada)

    -- DEDUPLICAÇÃO POR PROXIMIDADE: uma árvore no jogo costuma ser vários
    -- split shapes separados (tronco + cada galho principal) - cada pedaço
    -- vira um alvo de queima independente, e cada queima chama esta função.
    -- Sem essa checagem, vários decalques quase sobrepostos se acumulam na
    -- mesma árvore (efeito de "carimbo múltiplo"/aglomerado irregular).
    --
    -- IMPORTANTE: compara SOMA DOS RAIOS (novo + existente), não uma
    -- distância fixa - um raio fixo pequeno (ex: 1.5m) não bastava quando
    -- os próprios decalques já passam disso de raio (com o multiplicador
    -- de tronco, um decalque pode chegar a ~2.5m de raio). Cada entrada em
    -- activeDecals agora guarda seu próprio "radius" (metade do diâmetro
    -- final aplicado) pra essa comparação funcionar corretamente mesmo
    -- entre decalques de tamanhos bem diferentes.
    local newRadius = (DECAL_BASE_DIAMETER * scaleFactor) / 2
    local OVERLAP_FACTOR = 0.7 -- 0.0=só bloqueia toque exato; 1.0=bloqueia
                                -- qualquer sobra de espaço entre os raios;
                                -- 0.7 tolera uma pequena distância sem
                                -- bloquear árvores genuinamente separadas
    -- REDE DE SEGURANÇA: raio mínimo ABSOLUTO de dedupe, independente do
    -- cálculo proporcional acima. Existe pra cobrir o caso de dois
    -- decalques pequenos (raios somados pequenos) que ainda assim não
    -- deveriam duplicar por estarem claramente na mesma árvore/cluster.
    local ABSOLUTE_MIN_DEDUPE_RADIUS = 2.5

    Logging.info("[Driptorch][decal] scaleFactor calculado=%.3f newRadius=%.2f", scaleFactor, newRadius)

    if spec.activeDecals ~= nil then
        for i, entry in ipairs(spec.activeDecals) do
            if entry.node ~= nil and (type(entityExists) ~= "function" or entityExists(entry.node)) then
                local ex, ey, ez = getWorldTranslation(entry.node)
                local dx = ex - worldX
                local dz = ez - worldZ
                local dist = math.sqrt(dx * dx + dz * dz)
                local combinedRadius = math.max((newRadius + (entry.radius or 0)) * OVERLAP_FACTOR, ABSOLUTE_MIN_DEDUPE_RADIUS)
                Logging.info("[Driptorch][decal] dedupe check #%d: dist=%.2f combinedRadius=%.2f (entry.radius=%s)",
                    i, dist, combinedRadius, tostring(entry.radius))
                if dist <= combinedRadius then
                    -- Já tem decalque cobrindo essa área - não duplica.
                    Logging.info("[Driptorch][decal] -> BLOQUEADO por dedupe (muito perto do decalque #%d)", i)
                    return nil
                end
            end
        end
    end

    local terrainNode = g_currentMission.terrainRootNode
    local worldY = getTerrainHeightAtWorldPos(terrainNode, worldX, 0, worldZ)

    local newDecal = clone(spec.decalTemplateNode, false, false, false)
    if newDecal == nil then
        Logging.warning("[Driptorch] clone() do decalque falhou")
        return nil
    end

    link(getRootNode(), newDecal)
    -- NOVO: offset vertical aumentado de 2cm para 8cm (pedido: mesmo que
    -- "flutue" um pouco em terreno irregular, é melhor que cortar contra o
    -- relevo real do terreno - e o decalque some de qualquer forma depois
    -- do fade-out).
    local DECAL_HEIGHT_OFFSET = 0.08
    setTranslation(newDecal, worldX, worldY + DECAL_HEIGHT_OFFSET, worldZ)

    -- NOVO: alinha o decalque com a inclinação real do terreno, em vez de
    -- ficar sempre perfeitamente na horizontal (que "flutua" acima de
    -- depressões ou fica com o relevo "vazando" por cima em terrenos
    -- inclinados). Amostra a altura em 4 pontos ao redor do centro
    -- (leste/oeste/norte/sul) e estima a normal da superfície por
    -- diferenças finitas - fórmula padrão de normal a partir de heightmap.
    local sampleDist = math.max(newRadius * 0.7, 0.3)
    local hE = getTerrainHeightAtWorldPos(terrainNode, worldX + sampleDist, 0, worldZ)
    local hW = getTerrainHeightAtWorldPos(terrainNode, worldX - sampleDist, 0, worldZ)
    local hN = getTerrainHeightAtWorldPos(terrainNode, worldX, 0, worldZ + sampleDist)
    local hS = getTerrainHeightAtWorldPos(terrainNode, worldX, 0, worldZ - sampleDist)

    local slopeX = (hE - hW) / (2 * sampleDist)
    local slopeZ = (hN - hS) / (2 * sampleDist)
    local nx, ny, nz = -slopeX, 1.0, -slopeZ
    local nLen = math.sqrt(nx * nx + ny * ny + nz * nz)
    if nLen > 0.0001 then
        nx, ny, nz = nx / nLen, ny / nLen, nz / nLen
    else
        nx, ny, nz = 0, 1, 0
    end

    -- Direção "para frente" aleatória - só pra variar a orientação/textura
    -- entre decalques (o círculo em si é simétrico, não importa qual
    -- direção). setDirection alinha o eixo Y local do node com "up" (a
    -- normal calculada acima) e o eixo Z local com essa direção.
    --
    -- TODO CONFIRMAR: assinatura exata de setDirection(node, dirX,dirY,dirZ,
    -- upX,upY,upZ) - função comum no engine pra orientar objetos por
    -- direção+up (usada em veículos/IA), mas nunca usamos antes neste
    -- projeto. Se o comportamento não bater (decalque girando errado),
    -- conferir no GDN.
    local yaw = math.random() * 2 * math.pi
    local dirX, dirZ = math.cos(yaw), math.sin(yaw)

    if type(setDirection) == "function" then
        setDirection(newDecal, dirX, 0, dirZ, nx, ny, nz)
    else
        -- Fallback defensivo: sem setDirection disponível, mantém o
        -- comportamento anterior (sempre horizontal, só gira no eixo Y).
        setRotation(newDecal, 0, yaw, 0)
    end

    -- CORRIGIDO: "colorTint" é float3 ADITIVO (diffuseColor + colorTint,
    -- saturado) segundo a definição real do decalShader.xml - não é alfa,
    -- não controla transparência. O 4º argumento que passávamos antes era
    -- descartado silenciosamente. Abandonado - o fade agora é feito via
    -- ESCALA (setScale), mecanismo já validado no projeto inteiro: o
    -- decalque nasce em startScaleFactor (~70% do diâmetro do tronco,
    -- calculado acima) e cresce até scaleFactor (tamanho final de
    -- rescaldo) durante a queima (ver driptorchProcessBurn), depois
    -- encolhe de volta a zero no fade-out por idade (ver
    -- driptorchProcessDecalFade).
    setScale(newDecal, startScaleFactor, 1, startScaleFactor)
    setVisibility(newDecal, true)

    table.insert(spec.activeDecals, { node = newDecal, age = 0, radius = newRadius, scaleFactor = scaleFactor })
    Logging.info("[Driptorch][decal] -> CRIADO com sucesso em (%.2f,%.2f) raio=%.2f startScale=%.3f. Total ativos agora=%d",
        worldX, worldZ, newRadius, startScaleFactor, #spec.activeDecals)

    -- Limite de decalques simultâneos: remove o mais antigo se estourar
    if #spec.activeDecals > spec.maxActiveDecals then
        local oldest = table.remove(spec.activeDecals, 1)
        if oldest ~= nil and oldest.node ~= nil then
            if type(entityExists) ~= "function" or entityExists(oldest.node) then
                delete(oldest.node)
            end
        end
    end

    return newDecal, scaleFactor, startScaleFactor
end


-- ===========================================================================
-- CHAMA: efeito visual de fogo (cross-billboard, flame.i3d) durante a
-- queima. Dirigida pelo mesmo "progress" (0->1) que já rege o encolhimento
-- da árvore e o crescimento do decalque:
--   Fase 1 (0 -> flamePhase1End): várias chamas pequenas nascem no raio do
--   decalque e convergem pro centro
--   Fase 2 (flamePhase1End -> flamePeakProgress): uma chama única cresce
--   até o PICO, atingido no degrau ANTEPENÚLTIMO do encolhimento da árvore
--   Degrau PENÚLTIMO: cai pra 50% do pico
--   Degrau ÚLTIMO: cai pra 50% daquilo (25% do pico), desaparece junto com
--   a árvore
-- ===========================================================================

-- Spawn genérico de UMA chama na posição indicada, na escala indicada.
-- Reaproveitado tanto pelas chamas pequenas (Fase 1) quanto pela chama
-- única (Fase 2/3).
--
-- TODO CONFIRMAR: clone() aqui usa copyChildren=TRUE (diferente do
-- decalque, que usa false) - o template da chama é um Empty com DOIS
-- planos filhos (cross-billboard), então precisa copiar a subárvore
-- inteira. Nunca testamos clone() com copyChildren=true neste projeto -
-- se o clone vier sem os dois planos, conferir a assinatura no GDN.
function DriptorchTool:driptorchSpawnFlame(worldX, worldZ, scale)
    local spec = self.spec_driptorchTool
    if spec.flameTemplateNode == nil then
        return nil -- flame.i3d não carregou (ver warning no onLoad)
    end

    local terrainNode = g_currentMission.terrainRootNode
    local worldY = getTerrainHeightAtWorldPos(terrainNode, worldX, 0, worldZ)

    local newFlame = clone(spec.flameTemplateNode, true, false, false)
    if newFlame == nil then
        Logging.warning("[Driptorch] clone() da chama falhou")
        return nil
    end

    link(getRootNode(), newFlame)
    setTranslation(newFlame, worldX, worldY, worldZ) -- em pé, direto no chão (sem offset - já é vertical)
    -- Rotação aleatória removida (era suspeita de causar o "afastamento"
    -- visual da chama conforme cresce - a causa real era o pivô do Empty
    -- descentralizado, já corrigido no Blender).
    setScale(newFlame, scale, scale, scale) -- uniforme nos 3 eixos (não achatado como o decalque)
    setVisibility(newFlame, true)

    return newFlame
end


-- Chama-piloto no bico da tocha: pequena, sempre presente enquanto a
-- ferramenta está equipada (independente de estar queimando algo ou não).
-- Diferente de driptorchSpawnFlame (que ancora no MUNDO, com altura do
-- terreno), essa vira FILHA de spec.flameEffectNode - segue a posição E
-- rotação da tocha automaticamente (o engine cuida disso via hierarquia de
-- transform), sem precisar recalcular posição a cada frame.
function DriptorchTool:driptorchSpawnMuzzleFlame()
    local spec = self.spec_driptorchTool
    if spec.flameTemplateNode == nil or spec.flameEffectNode == nil then
        return nil
    end

    local newFlame = clone(spec.flameTemplateNode, true, false, false)
    if newFlame == nil then
        Logging.warning("[Driptorch] clone() da chama-piloto falhou")
        return nil
    end

    -- NOVO: força visibilidade do PAI (flameEffectNode) também - hipótese:
    -- visibilidade pode CASCATEAR na hierarquia (pai invisível = filhos não
    -- renderizam, mesmo com setVisibility(filho, true) explícito). Como
    -- flameEffectNode provavelmente é só um marcador/ponto de ancoragem
    -- sem malha própria, forçar visível nele não deveria ter efeito visual
    -- próprio (nada pra desenhar), só desbloquear os filhos se essa
    -- hipótese estiver certa.
    setVisibility(spec.flameEffectNode, true)

    link(spec.flameEffectNode, newFlame)
    -- Offset pra nascer no BICO, não no centro da chama (ver
    -- spec.flameMuzzleOffsetX/Y/Z, declarados no onLoad - ajustar lá por
    -- tentativa e erro, sem precisar mexer nesta função de novo).
    setTranslation(newFlame, spec.flameMuzzleOffsetX, spec.flameMuzzleOffsetY, spec.flameMuzzleOffsetZ)
    -- setRotation espera RADIANOS - os parâmetros ficam em graus (mais
    -- intuitivo pra ajustar por teste), conversão aqui.
    setRotation(newFlame,
        math.rad(spec.flameMuzzleRotationX),
        math.rad(spec.flameMuzzleRotationY),
        math.rad(spec.flameMuzzleRotationZ))
    setScale(newFlame, spec.flameMuzzleScale, spec.flameMuzzleScale, spec.flameMuzzleScale)
    setVisibility(newFlame, true)

    return newFlame
end


-- Fase 1: spawna N chamas pequenas distribuídas ao redor da BORDA do
-- decalque (não mais baseado no tronco - fonte de dado ruidosa, como já
-- vimos com o decalque). Nascem a outerRadius (90% do raio do decalque) e
-- vão sendo puxadas pro centro ao longo da Fase 1 (ver driptorchProcessBurn)
-- - cada entrada guarda seu próprio ângulo fixo, pra recalcular a posição
-- a cada frame conforme o raio de convergência diminui.
-- Retorna (smallFlames, groundY) em vez de escrever em campos temporários
-- do spec - cada sessão de queima (spec.activeBurns) guarda seu próprio
-- resultado, sem risco de uma sessão nova sobrescrever o resultado de
-- outra ainda em uso.
function DriptorchTool:driptorchSpawnSmallFlames(centerX, centerZ, count, outerRadius)
    local spec = self.spec_driptorchTool
    local smallFlames = {}

    local terrainNode = g_currentMission.terrainRootNode
    local groundY = getTerrainHeightAtWorldPos(terrainNode, centerX, 0, centerZ)

    -- Distribui em ângulos uniformemente espaçados ao redor do círculo
    -- (não totalmente aleatório) - garante cobertura mesmo com poucas
    -- chamas, com uma pitada de jitter pra não ficar mecânico demais.
    local angleStep = (2 * math.pi) / count
    for i = 1, count do
        local baseAngle = (i - 1) * angleStep
        local angleJitter = (math.random() - 0.5) * angleStep * 0.5 -- até metade do espaçamento
        local angle = baseAngle + angleJitter

        local fx = centerX + math.cos(angle) * outerRadius
        local fz = centerZ + math.sin(angle) * outerRadius

        local flameNode = self:driptorchSpawnFlame(fx, fz, spec.flameSmallScale)
        if flameNode ~= nil then
            table.insert(smallFlames, { node = flameNode, angle = angle })
        end
    end

    return smallFlames, groundY
end


-- Aplica variação aleatória de escala (efeito de "tremular") por cima de
-- uma escala-base já calculada. Chamado todo frame pra cada chama ativa.
function DriptorchTool:driptorchApplyFlameJitter(node, baseScale)
    local spec = self.spec_driptorchTool
    local jitter = 1.0 + (math.random() - 0.3) * 2 * spec.flameJitterAmount
    local jitteredScale = baseScale * jitter
    setScale(node, jitteredScale, jitteredScale, jitteredScale)
end


-- TODO CONFIRMAR (ainda em aberto - é a única parte sem precedente oficial
-- que encontramos): como diferenciar árvore viva / árvore morta / toco a
-- partir do node retornado pelo targeter. Todos batem no filtro
-- MESH_SPLIT_SHAPE, então a diferenciação deve vir de alguma propriedade do
-- próprio split shape (crescimento da árvore, ou se já foi cortada/tem
-- toco). Precisamos investigar SplitUtil ou o TreePlantManager pra achar
-- essa distinção.
--
-- DECISÃO DE DESIGN (não mudar sem confirmar com o usuário): diferente do
-- HandToolSprayCan oficial, que tem getIsSprayingAllowed() checando
-- mission.accessHandler:canFarmAccessLand(...), o pingafogo NÃO deve
-- verificar propriedade de campo - funciona em qualquer terreno,
-- independente de quem é o dono.
function DriptorchTool:driptorchIsValidTarget(hitNode)
    if hitNode == nil or hitNode == 0 then
        return false, nil
    end

    -- NOVO: filtra árvores DEITADAS (cortadas/tombadas). Motivo: testes
    -- mostraram árvores deitadas "crescendo" (em vez de encolher) durante
    -- a queima, e chamas se afastando/multiplicando de forma incorreta -
    -- causa raiz ainda não confirmada com certeza (pode envolver múltiplos
    -- nós físicos ao longo de uma tora deitada, ou orientação/escala
    -- interagindo mal com nossa lógica). Solução pragmática por enquanto:
    -- só aceitar árvores em pé.
    --
    -- CONFIRMADO no GDN (categoria Foundation): localDirectionToWorld
    -- converte uma direção local do objeto pra coordenadas de mundo -
    -- usamos isso pra comparar o "pra cima" local do objeto com o "pra
    -- cima" do mundo (eixo Y). Produto escalar (upY) próximo de 1 = em pé;
    -- próximo de 0 ou negativo = deitado/tombado.
    local VERTICAL_THRESHOLD = 0.7
    local okDir, upX, upY, upZ = pcall(localDirectionToWorld, hitNode, 0, 1, 0)
    if okDir and upY ~= nil and upY < VERTICAL_THRESHOLD then
        return false, nil
    end

    -- Placeholder: por enquanto trata qualquer split shape em pé como
    -- árvore viva
    return true, DriptorchTool.TARGET_LIVE_TREE
end


-- CONFIRMADO contra a doc oficial da GIANTS (GDN, categoria Physics, LUADOC
-- FS25): getRigidBodyAABB(transformId) retorna minX, maxX, minY, maxY, minZ,
-- maxZ em coordenadas de MUNDO, e existe de fato na versão atual do engine
-- (v1.20.0.0). "maxY - minY" nos dá a altura do bounding box do objeto no
-- eixo vertical - uma aproximação razoável da altura da árvore em pé (não é
-- necessariamente idêntico ao "Length" mostrado no painel de info do jogo,
-- que pode medir ao longo do eixo principal do tronco em vez do eixo vertical
-- puro, mas pra árvore em pé os dois devem ficar bem próximos).
--
-- IMPORTANTE: a função retorna nil se o objeto ainda não foi adicionado à
-- física (comportamento documentado oficialmente) - por isso a checagem
-- abaixo antes de usar o valor.
--
-- NOTA (chute inicial descartado): tentamos achar antes uma função tipo
-- "getSplitShapeStats" (existia no engine da FS17, usada pelo WoodSellTrigger
-- oficial para medir toras vendidas) - mas confirmamos na doc atual da FS25
-- que ela NÃO existe mais nessa versão do engine. Por isso usamos
-- getRigidBodyAABB, que está confirmado presente agora.
function DriptorchTool:driptorchGetTreeHeight(hitNode)
    if hitNode == nil or hitNode == 0 then
        return nil
    end

    local minX, maxX, minY, maxY, minZ, maxZ = getRigidBodyAABB(hitNode)
    if minY == nil or maxY == nil then
        return nil
    end

    return maxY - minY
end


-- Processa a queima em andamento (encolhimento progressivo do alvo até
-- deletar). Extraído do onUpdate original - agora é chamado pelo
-- spec.worldTicker (registrado via g_currentMission:addUpdateable), então
-- continua progredindo mesmo com a tocha guardada, não só enquanto
-- equipada.
-- MULTI-QUEIMA: processa TODAS as sessões ativas em spec.activeBurns (não
-- mais uma única queima singular). Itera de trás pra frente pra poder
-- remover sessões concluídas com table.remove sem bagunçar os índices
-- ainda não visitados (mesmo padrão já usado em driptorchProcessDecalFade).
function DriptorchTool:driptorchProcessBurn(dt)
    local spec = self.spec_driptorchTool

    for i = #spec.activeBurns, 1, -1 do
        local session = spec.activeBurns[i]

        -- Checagem defensiva: só continua se o objeto ainda existir de fato
        -- (proteção contra o node já ter sido removido por outro sistema).
        -- TODO CONFIRMAR: "entityExists" foi sugerido por uma fonte externa
        -- não confiável (a mesma que inventou "TreeMarkingSpray", que já
        -- confirmamos NÃO existir na doc oficial). Chamando de forma
        -- defensiva (só se a função existir) pra não travar se for inválida.
        if type(entityExists) == "function" and not entityExists(session.target) then
            table.remove(spec.activeBurns, i)
        else
            session.burnTimer = session.burnTimer + dt

            local progress = math.min(session.burnTimer / session.burnDuration, 1.0)
            local scaleFactor = 1.0 - progress

            -- CRESCIMENTO DO DECALQUE (substitui o antigo "fade-in" por
            -- colorTint, que nunca funcionou de verdade - ver nota em
            -- driptorchSpawnBurnDecal sobre colorTint ser float3 aditivo,
            -- não alfa). Interpola LINEARMENTE (sem easing) entre o tamanho
            -- de NASCIMENTO (~70% do diâmetro do tronco) e o tamanho FINAL
            -- de rescaldo, acompanhando o mesmo progresso (0->1) que
            -- encolhe a árvore.
            if session.decalNode ~= nil and session.decalFinalScale ~= nil and session.decalStartScale ~= nil then
                local startS = session.decalStartScale
                local finalS = session.decalFinalScale
                local decalScale = startS + (finalS - startS) * progress
                setScale(session.decalNode, decalScale, 1, decalScale)
            end

            -- CHAMA - fases dirigidas pelo mesmo "progress":
            --   Fase 1 (0 -> flamePhase1End): chamas pequenas convergindo
            --   Fase 2 (flamePhase1End -> flamePeakProgress): chama única crescendo até o PICO
            --   Degrau penúltimo (flamePeakProgress -> +flameStageStep): cai pra 50% do pico
            --   Degrau último (daí -> 1.0): cai pra 50% daquilo (25% do pico), some com a árvore
            if progress < spec.flamePhase1End then
                -- FASE 1: chamas pequenas já spawnadas no início da queima -
                -- além do jitter de tremular, PUXA cada uma pro centro
                -- conforme a Fase 1 avança.
                local INNER_RADIUS = 0.19 -- metros; distância mínima do centro
                local t1raw = progress / spec.flamePhase1End
                local t1 = math.min(t1raw * spec.flameConvergenceFactor, 1.0)
                local currentRadius = session.flameOuterRadius + (INNER_RADIUS - session.flameOuterRadius) * t1

                local SMALL_GROWTH_TARGET_FRACTION = 0.73
                local smallTargetScale = spec.flameMainStartScale * SMALL_GROWTH_TARGET_FRACTION
                local currentSmallScale = spec.flameSmallScale + (smallTargetScale - spec.flameSmallScale) * t1

                for _, entry in ipairs(session.smallFlames) do
                    local fx = session.flameX + math.cos(entry.angle) * currentRadius
                    local fz = session.flameZ + math.sin(entry.angle) * currentRadius
                    setTranslation(entry.node, fx, session.flameGroundY, fz)
                    self:driptorchApplyFlameJitter(entry.node, currentSmallScale)
                end
            else
                -- Transição 1->2: dispara só uma vez por sessão (guarda
                -- mainFlameSpawned). Deleta as pequenas, spawna a única
                -- central.
                if not session.mainFlameSpawned then
                    for _, entry in ipairs(session.smallFlames) do
                        if type(entityExists) ~= "function" or entityExists(entry.node) then
                            delete(entry.node)
                        end
                    end
                    session.smallFlames = {}

                    session.mainFlameNode = self:driptorchSpawnFlame(session.flameX, session.flameZ, spec.flameMainStartScale)
                    session.mainFlameSpawned = true
                end

                if session.mainFlameNode ~= nil then
                    local peakScale = spec.flameMainFullScale * spec.flameBoostMultiplier
                    local penultimateStageStart = spec.flamePeakProgress + spec.flameStageStep
                    local baseScale

                    if progress < spec.flamePeakProgress then
                        local tGrowRaw = (progress - spec.flamePhase1End) / (spec.flamePeakProgress - spec.flamePhase1End)
                        local tGrow = math.min(tGrowRaw * spec.flameGrowthSpeedFactor, 1.0)
                        baseScale = spec.flameMainStartScale + (peakScale - spec.flameMainStartScale) * tGrow
                    elseif progress < penultimateStageStart then
                        baseScale = peakScale * 0.43
                    else
                        baseScale = peakScale * 0.31
                    end
                    self:driptorchApplyFlameJitter(session.mainFlameNode, baseScale)

                    -- Volume do som DESSA sessão acompanha a proporção da
                    -- escala atual da chama principal em relação ao pico.
                    -- CONFIRMADO: setSampleVolume espera o ID numérico
                    -- bruto (.soundSample), não a tabela-wrapper inteira.
                    if type(setSampleVolume) == "function" and session.soundSample ~= nil and session.soundSample.soundSample ~= nil then
                        local volumeFraction = math.max(0.3, math.min(baseScale / peakScale, 1.0))
                        setSampleVolume(session.soundSample.soundSample, volumeFraction)
                    end
                end
            end

            -- THROTTLE: só aplica setScale (e o updateSubtreeTransform que
            -- junto com ele) quando o encolhimento mudar pelo menos 5%
            -- (~20 atualizações ao longo de toda a queima), ou no frame
            -- final.
            local scaleChanged = session.lastAppliedScaleFactor == nil
                or math.abs(scaleFactor - session.lastAppliedScaleFactor) >= 0.05
                or progress >= 1.0

            if scaleChanged then
                local ox, oy, oz = session.originalScale[1], session.originalScale[2], session.originalScale[3]
                setScale(session.target, ox * scaleFactor, oy * scaleFactor, oz * scaleFactor)

                -- TODO CONFIRMAR: "updateSubtreeTransform" também veio de
                -- fonte não confiável - hipótese é que a colisão física do
                -- objeto não acompanha o encolhimento visual até ele ser
                -- deletado. Chamando de forma defensiva.
                if type(updateSubtreeTransform) == "function" then
                    updateSubtreeTransform(session.target)
                end

                session.lastAppliedScaleFactor = scaleFactor
            end

            if progress >= 1.0 then
                Logging.info("[Driptorch] Queima concluída, deletando target=%s", tostring(session.target))

                -- O decalque já foi criado no INÍCIO da queima e vem
                -- crescendo neste mesmo update - aqui só garante tamanho
                -- final exato e solta a referência; o decalque em si
                -- continua existindo em spec.activeDecals.
                if session.decalNode ~= nil and session.decalFinalScale ~= nil then
                    local finalScale = session.decalFinalScale
                    setScale(session.decalNode, finalScale, 1, finalScale)
                end

                -- A chama principal já está no ÚLTIMO degrau (25% do
                -- pico) quando a árvore desaparece - deleta direto, junto
                -- com a árvore, sem sobrevida pós-queima.
                if session.mainFlameNode ~= nil then
                    if type(entityExists) ~= "function" or entityExists(session.mainFlameNode) then
                        delete(session.mainFlameNode)
                    end
                end

                -- Para e deleta o som DESTA sessão (cada sessão tem seu
                -- próprio clone + âncora - ver início da queima).
                if session.soundSample ~= nil then
                    g_soundManager:stopSample(session.soundSample)
                    g_soundManager:deleteSample(session.soundSample)
                end
                if session.soundAnchor ~= nil then
                    if type(entityExists) ~= "function" or entityExists(session.soundAnchor) then
                        delete(session.soundAnchor)
                    end
                end

                -- TODO CONFIRMAR: precisa disparar isso via EVENTO em
                -- multiplayer (ver bloco de comentário no fim do arquivo),
                -- senão o objeto some só na tela de quem estava queimando.
                delete(session.target) -- TODO CONFIRMAR: pode exigir função
                                        -- específica do treePlantManager
                                        -- (NÃO usar "removeTreeStump" - não
                                        -- confirmado na doc oficial)

                table.remove(spec.activeBurns, i)
            end
        end
    end
end


-- Processa o "fade" (na verdade encolhimento de escala, ver nota abaixo)
-- dos decalques ativos até deletar. Também roda no worldTicker, então
-- continua mesmo sem a tocha na mão - já que os decalques nem dependem da
-- tocha pra existir, isso é o comportamento certo por padrão.
--
-- CORRIGIDO: originalmente isso animava "colorTint" esperando controlar
-- opacidade via um suposto 4º componente (alfa). Confirmado, olhando a
-- definição real do decalShader.xml, que "colorTint" é float3 ADITIVO
-- (diffuseColor + colorTint, saturado) - não tem componente alfa, não
-- controla transparência. O 4º argumento que passávamos era descartado
-- silenciosamente; o "fade" nunca funcionou de verdade por esse caminho.
-- Trocado para encolher a ESCALA do decalque até zero (mesmo mecanismo
-- usado no crescimento, em driptorchProcessBurn) - visualmente diferente
-- de um fade de opacidade, mas com efeito equivalente (a mancha vai
-- sumindo), usando uma função (setScale) que sabemos que funciona de
-- verdade neste engine.
function DriptorchTool:driptorchProcessDecalFade(dt)
    local spec = self.spec_driptorchTool
    if spec.activeDecals == nil then
        return
    end

    -- Itera de trás pra frente pra poder remover entradas com table.remove
    -- sem bagunçar os índices ainda não visitados.
    for i = #spec.activeDecals, 1, -1 do
        local entry = spec.activeDecals[i]
        entry.age = entry.age + dt

        if entry.age > spec.decalLifetime then
            local fadeElapsed = entry.age - spec.decalLifetime
            local fadeProgress = math.min(fadeElapsed / spec.decalFadeDuration, 1.0)
            local shrinkFactor = 1.0 - fadeProgress
            local fullScale = entry.scaleFactor or entry.radius or 1.0
            local currentScale = fullScale * shrinkFactor
            setScale(entry.node, currentScale, 1, currentScale)

            if fadeProgress >= 1.0 then
                if type(entityExists) ~= "function" or entityExists(entry.node) then
                    delete(entry.node)
                end
                table.remove(spec.activeDecals, i)
            end
        end
    end
end


function DriptorchTool:onUpdate(dt)
    local spec = self.spec_driptorchTool
    local player = self:getCarryingPlayer()
    local allowInput = player ~= nil and player.isOwner or false

    -- Balanço/oscilação: aplica sempre que o item estiver na mão, sem
    -- depender de estar queimando ou não - é só o "jeito de segurar".
    -- Mesma técnica do AnimatedSaw.lua (seno + g_time), mas em rotação
    -- em vez de translação.
    if self:getIsHeld() and self.graphicalNode ~= nil then
        local angle = math.sin(g_time * spec.swaySpeed) * spec.swayAmplitude

        -- NOVO: inclinação (derramar combustível) - lerp suave em direção
        -- ao alvo (inclinado se activatePressed, neutro se não).
        local tiltTarget = spec.activatePressed and spec.tiltAngleTarget or 0
        local tiltDiff = tiltTarget - spec.tiltAngleCurrent
        spec.tiltAngleCurrent = spec.tiltAngleCurrent + tiltDiff * math.min(spec.tiltSpeed * dt / 1000, 1)

        -- Combina sway (Z, e Y*0.2 já calibrado) com tilt (eixo
        -- configurável, somado por cima do sway correspondente).
        local rx, ry, rz = 0, angle * 0.2, angle
        if spec.tiltAxis == "x" then
            rx = rx + spec.tiltAngleCurrent
        elseif spec.tiltAxis == "y" then
            ry = ry + spec.tiltAngleCurrent
        else
            rz = rz + spec.tiltAngleCurrent
        end

        -- NOVO: em vez de girar "graphics" em torno da própria origem
        -- (braço de alavanca grande, ~10cm de salto na ponta), gira em
        -- torno de um PIVÔ EXTERNO (posição do handNode - o punho) -
        -- só a componente de TILT usa esse pivô (sway continua leve,
        -- girando em torno da origem própria, sem problema perceptível).
        -- Matemática: pega o vetor BASE de graphics em relação ao pivô
        -- (handNode), rotaciona esse vetor pelo ângulo de tilt, soma de
        -- volta a posição do pivô - resultado: graphics "orbita" o punho
        -- em vez de girar solto no espaço.
        if spec.graphicsBaseX ~= nil and spec.pivotHandX ~= nil then
            local tiltOnly = 0
            local axis = spec.tiltAxis
            if axis == "x" then tiltOnly = spec.tiltAngleCurrent
            elseif axis == "y" then tiltOnly = spec.tiltAngleCurrent
            else tiltOnly = spec.tiltAngleCurrent end

            local dx = spec.graphicsBaseX - spec.pivotHandX
            local dy = spec.graphicsBaseY - spec.pivotHandY
            local dz = spec.graphicsBaseZ - spec.pivotHandZ
            local cosA, sinA = math.cos(tiltOnly), math.sin(tiltOnly)
            local ndx, ndy, ndz = dx, dy, dz
            if axis == "y" then
                ndx = dx * cosA + dz * sinA
                ndz = -dx * sinA + dz * cosA
            elseif axis == "x" then
                ndy = dy * cosA - dz * sinA
                ndz = dy * sinA + dz * cosA
            else -- "z"
                ndx = dx * cosA - dy * sinA
                ndy = dx * sinA + dy * cosA
            end
            setTranslation(self.graphicalNode, spec.pivotHandX + ndx, spec.pivotHandY + ndy, spec.pivotHandZ + ndz)
        end

        setRotation(self.graphicalNode, rx, ry, rz)

        -- NOVO (revisado): girar a CHAMA diretamente não bastava - ela é
        -- um cross-billboard quase simétrico no eixo Y (rotação própria
        -- quase imperceptível), e mais importante: só girar a chama não
        -- move a POSIÇÃO dela, que continua fixa no cutNode (que é
        -- estático, não acompanha o Corpo inclinando).
        --
        -- Fix real: rotacionar o cutNode (PAI da chama, via link()) pelo
        -- mesmo ângulo de tilt. Como a chama é filha dele, herda
        -- automaticamente tanto a rotação quanto o deslocamento de
        -- posição (arco em torno da origem do cutNode) - passa a
        -- acompanhar o movimento do bico de verdade, não só girar no
        -- próprio eixo. Só o TILT é aplicado aqui (não o sway) - cutNode
        -- fica parado durante o sway comum, só se move junto na
        -- inclinação de queima, como pedido.
        if spec.flameEffectNode ~= nil and spec.cutNodeBaseX ~= nil then
            local cutRx, cutRy, cutRz = 0, 0, 0
            if spec.tiltAxis == "x" then
                cutRx = spec.tiltAngleCurrent
            elseif spec.tiltAxis == "y" then
                cutRy = spec.tiltAngleCurrent
            else
                cutRz = spec.tiltAngleCurrent
            end
            setRotation(spec.flameEffectNode, cutRx, cutRy, cutRz)

            -- FIX REAL: rotacionar o cutNode em torno de si mesmo quase
            -- não desloca a posição dele (offset da chama é pequeno).
            -- Agora que "graphics" (e o Corpo) passou a orbitar em torno
            -- do handNode (não mais da própria origem), o cutNode precisa
            -- orbitar em torno do MESMO pivô (handNode) pra continuar
            -- sincronizado - recalcula a translação dele rotacionando o
            -- vetor BASE (relativo ao handNode, não mais à origem) pelo
            -- ângulo atual de tilt, no mesmo eixo.
            local bx, by, bz = spec.cutNodeBaseX, spec.cutNodeBaseY, spec.cutNodeBaseZ
            if spec.pivotHandX ~= nil then
                bx = spec.cutNodeBaseX - spec.pivotHandX
                by = spec.cutNodeBaseY - spec.pivotHandY
                bz = spec.cutNodeBaseZ - spec.pivotHandZ
            end
            local cosA, sinA = math.cos(spec.tiltAngleCurrent), math.sin(spec.tiltAngleCurrent)
            local newX, newY, newZ = bx, by, bz
            if spec.tiltAxis == "y" then
                newX = bx * cosA + bz * sinA
                newZ = -bx * sinA + bz * cosA
            elseif spec.tiltAxis == "x" then
                newY = by * cosA - bz * sinA
                newZ = by * sinA + bz * cosA
            else -- "z"
                newX = bx * cosA - by * sinA
                newY = bx * sinA + by * cosA
            end
            if spec.pivotHandX ~= nil then
                newX = newX + spec.pivotHandX
                newY = newY + spec.pivotHandY
                newZ = newZ + spec.pivotHandZ
            end
            setTranslation(spec.flameEffectNode, newX, newY, newZ)

            -- Rotação PRÓPRIA da chama (orientação) continua combinada
            -- por cima da base calibrada, além da nova órbita de posição.
            if spec.muzzleFlameNode ~= nil then
                local flameRx = math.rad(spec.flameMuzzleRotationX) + cutRx
                local flameRy = math.rad(spec.flameMuzzleRotationY) + cutRy
                local flameRz = math.rad(spec.flameMuzzleRotationZ) + cutRz
                setRotation(spec.muzzleFlameNode, flameRx, flameRy, flameRz)
            end

            -- DIAGNÓSTICO TEMPORÁRIO (throttle ~1x/seg) - confirma se o
            -- código está rodando e os valores realmente mudando.
            spec.debugTiltLogTimer = (spec.debugTiltLogTimer or 0) + dt
            if spec.debugTiltLogTimer > 1000 then
                spec.debugTiltLogTimer = 0
                local okWx, wx, wy, wz = pcall(getWorldTranslation, spec.muzzleFlameNode or spec.flameEffectNode)
                Logging.info("[Driptorch] DIAG tilt: tiltAngleCurrent=%.4frad (%.2f°) cutNode translation base=%.4f,%.4f,%.4f -> nova=%.4f,%.4f,%.4f flameNode existe=%s worldPos=%s",
                    spec.tiltAngleCurrent, math.deg(spec.tiltAngleCurrent), bx, by, bz, newX, newY, newZ,
                    tostring(spec.muzzleFlameNode ~= nil),
                    okWx and string.format("%.4f,%.4f,%.4f", wx, wy, wz) or "erro")
            end
        end
    end

    if allowInput then
        -- O targeter já faz o trabalho de mira/raycast pra gente; só
        -- consultamos o resultado (mesmo padrão do HandToolSprayCan.onUpdate)
        local targetInfo = player.targeter.closestTargetsByKey[DriptorchTool]

        -- DIAGNÓSTICO TEMPORÁRIO (remover depois de descobrir o problema):
        -- loga só quando o estado muda, pra não inundar o log.
        local hasTarget = targetInfo ~= nil
        if hasTarget ~= spec.debugLastHasTarget then
            if hasTarget then
                Logging.info("[Driptorch] Alvo encontrado: node=%s nome=%s", tostring(targetInfo.node), tostring(getName(targetInfo.node)))
            else
                Logging.info("[Driptorch] Alvo perdido/nenhum alvo")
            end
            spec.debugLastHasTarget = hasTarget
        end

        if spec.activatePressed ~= spec.debugLastActivatePressed then
            Logging.info("[Driptorch] activatePressed = %s", tostring(spec.activatePressed))
            spec.debugLastActivatePressed = spec.activatePressed
        end
        -- FIM DO DIAGNÓSTICO TEMPORÁRIO

        -- MULTI-QUEIMA: não existe mais um "if spec.currentTarget == nil"
        -- bloqueando novas queimas - várias árvores podem estar queimando
        -- ao mesmo tempo agora. A única checagem necessária é: essa árvore
        -- específica já não está em queima (evita reiniciar a mesma árvore
        -- duas vezes se o jogador continuar mirando nela).
        if spec.activatePressed and targetInfo ~= nil then
            -- NOVO: se o alvo MUDOU desde o último frame (oscilação de
            -- mira, comum em pilhas densas de toras/galhos sobrepostos),
            -- reinicia o acúmulo do zero - evita uma cadeia de ignições em
            -- pedaços diferentes durante um único toque contínuo do botão
            -- (bug visto nos testes: vários focos de fogo brotando de uma
            -- pilha a partir de um único "segurar" o botão).
            if spec.pressHoldTarget ~= targetInfo.node then
                spec.pressHoldTimer = 0
                spec.pressHoldTarget = targetInfo.node
            end

            -- DIAGNÓSTICO TEMPORÁRIO: loga o início do acúmulo
            if spec.pressHoldTimer == 0 then
                Logging.info("[Driptorch] Começou a acumular hold (activationHoldTime=%s)", tostring(spec.activationHoldTime))
            end

            -- Acumula tempo de toque contínuo, mirando no mesmo alvo,
            -- antes de disparar de verdade (evita queimar por engano
            -- com um toque muito rápido/acidental).
            spec.pressHoldTimer = spec.pressHoldTimer + dt

            if spec.pressHoldTimer >= spec.activationHoldTime then
                Logging.info("[Driptorch] Threshold atingido (pressHoldTimer=%s) - tentando iniciar queima", tostring(spec.pressHoldTimer))
                local isValid, targetType = self:driptorchIsValidTarget(targetInfo.node)
                Logging.info("[Driptorch] driptorchIsValidTarget retornou isValid=%s targetType=%s", tostring(isValid), tostring(targetType))

                local alreadyBurning = false
                for _, existingSession in ipairs(spec.activeBurns) do
                    if existingSession.target == targetInfo.node then
                        alreadyBurning = true
                        break
                    end
                end

                if isValid and alreadyBurning then
                    Logging.info("[Driptorch] Alvo já está queimando (outra sessão ativa) - ignorando novo disparo")
                elseif isValid then
                    local session = {}
                    session.target = targetInfo.node
                    session.targetType = targetType

                    -- Tenta calcular a duração pela altura real da
                    -- árvore; se ainda não soubermos ler isso (ver TODO
                    -- em driptorchGetTreeHeight), cai no valor fixo por
                    -- tipo (burnDurations) como fallback.
                    local treeHeight = self:driptorchGetTreeHeight(targetInfo.node)
                    local baseDuration
                    if treeHeight ~= nil then
                        -- heightFactor é FLOAT puro (sem conversão automática
                        -- de unidade, diferente de burnDurations que usa
                        -- XMLValueType.TIME e já vem em ms). heightFactor
                        -- representa "segundos por metro", então o resultado
                        -- aqui está em SEGUNDOS - precisa *1000 pra bater com
                        -- burnTimer/burnDuration, que trabalham em ms.
                        baseDuration = treeHeight * spec.heightFactor * 1000
                        Logging.info("[Driptorch] Duração calculada por altura: altura=%sm heightFactor=%s -> base=%sms", tostring(treeHeight), tostring(spec.heightFactor), tostring(baseDuration))
                    else
                        baseDuration = spec.burnDurations[targetType]
                        Logging.info("[Driptorch] Altura indisponível (getRigidBodyAABB retornou nil), usando fallback fixo por tipo: base=%sms", tostring(baseDuration))
                    end

                    session.burnDuration = baseDuration * spec.speedMultiplier

                    -- NOVO: piso mínimo - objetos bem baixos (tocos) geram
                    -- duração calculada minúscula (proporcional à altura),
                    -- espremendo todas as fases da chama (pequenas ->
                    -- convergência -> única -> pico -> 2 degraus) num
                    -- instante quase instantâneo, quase um "flash" abrupto.
                    if session.burnDuration < spec.minBurnDuration then
                        session.burnDuration = spec.minBurnDuration
                    end

                    session.burnTimer = 0

                    local sx, sy, sz = getScale(targetInfo.node)
                    session.originalScale = { sx, sy, sz }
                    session.lastAppliedScaleFactor = 1.0

                    -- O decalque nasce JÁ AQUI, no INÍCIO da queima (evita
                    -- AABB distorcida por galhos caídos no final, que
                    -- causava "carimbo múltiplo"). Nasce invisível
                    -- (colorTint) e faz fade-in acompanhando o progresso.
                    local dtx, dty, dtz = getWorldTranslation(targetInfo.node)

                    -- NOVO (multi-queima): cada sessão cria seu PRÓPRIO
                    -- node âncora + clone de som, independente das demais -
                    -- antes havia uma âncora/clone ÚNICOS compartilhados,
                    -- o que só suportava uma queima por vez.
                    session.soundAnchor = createTransformGroup("driptorchBurningSoundAnchor")
                    link(getRootNode(), session.soundAnchor)
                    setTranslation(session.soundAnchor, dtx, dty, dtz)
                    if spec.sounds.muzzleFlame ~= nil then
                        session.soundSample = g_soundManager:cloneSample(spec.sounds.muzzleFlame, session.soundAnchor, self)
                        if session.soundSample ~= nil then
                            g_soundManager:playSample(session.soundSample)
                        end
                    end

                    -- Centro geométrico via AABB - usado só pras chamas
                    -- (não pro decalque, que já está validado com dtx/dtz
                    -- puro - copas grandes/assimétricas desviam mais a
                    -- média da AABB do centro real do tronco, então as
                    -- chamas também usam dtx/dtz puro, não a AABB).
                    local flameCenterX = dtx
                    local flameCenterZ = dtz

                    local trunkDiameter = nil
                    local okAABB0, minX0, maxX0, minY0, maxY0, minZ0, maxZ0 = pcall(getRigidBodyAABB, targetInfo.node)
                    if okAABB0 and minX0 ~= nil and maxX0 ~= nil and minZ0 ~= nil and maxZ0 ~= nil then
                        local rawDiffX = maxX0 - minX0
                        local rawDiffZ = maxZ0 - minZ0
                        if rawDiffX < 0 or rawDiffZ < 0 then
                            Logging.info("[Driptorch] AVISO: AABB com min/max invertido (rawDiffX=%.3f rawDiffZ=%.3f) - usando math.abs", rawDiffX, rawDiffZ)
                        end
                        -- math.abs em cada eixo antes do max - o log
                        -- mostrou trunkDiameter NEGATIVO em alguns casos,
                        -- sinal de min/max invertidos pra árvores em
                        -- certas rotações.
                        trunkDiameter = math.max(math.abs(rawDiffX), math.abs(rawDiffZ))

                        -- Teto de sanidade: pinheiros e árvores cônicas
                        -- (tronco fino, mas copa/galhos capturados pela
                        -- AABB horizontal) geravam valores generosos
                        -- demais sem isso.
                        local MAX_PLAUSIVEL_TRUNK_DIAMETER = 1.2
                        if trunkDiameter > MAX_PLAUSIVEL_TRUNK_DIAMETER then
                            Logging.info("[Driptorch] trunkDiameter=%.2f parece incluir copa/galhos, limitando a %.2f",
                                trunkDiameter, MAX_PLAUSIVEL_TRUNK_DIAMETER)
                            trunkDiameter = MAX_PLAUSIVEL_TRUNK_DIAMETER
                        end
                    else
                        Logging.info("[Driptorch] AABB indisponível no início da queima, decalque usará tamanho base")
                    end

                    session.decalNode, session.decalFinalScale, session.decalStartScale = self:driptorchSpawnBurnDecal(dtx, dtz, trunkDiameter)

                    -- Chamas pequenas nascem no MESMO raio do decalque no
                    -- seu tamanho INICIAL (não o final - o decalque também
                    -- nasce pequeno e cresce). O raio em metros é
                    -- numericamente igual ao scaleFactor, já que
                    -- DECAL_BASE_DIAMETER=2.0.
                    local FLAME_OUTER_FRACTION = 1.0
                    local decalRadiusMeters = session.decalStartScale or 1.0
                    local flameOuterRadius = decalRadiusMeters * FLAME_OUTER_FRACTION

                    -- Piso de segurança baseado no diâmetro do tronco (já
                    -- limitado a 1.2m) - em árvores GROSSAS de verdade, o
                    -- raio baseado no decalque podia ficar menor que o
                    -- próprio tronco, posicionando as chamas "dentro" dele.
                    if trunkDiameter ~= nil and trunkDiameter > 0 then
                        local TRUNK_HUG_FACTOR = 1.1
                        local trunkFloorRadius = (trunkDiameter / 2) * TRUNK_HUG_FACTOR
                        if trunkFloorRadius > flameOuterRadius then
                            flameOuterRadius = trunkFloorRadius
                        end
                    end

                    -- Variação aleatória SEMPRE PRA FORA do piso (nunca
                    -- reduz - só adiciona): elimina o caso "chamas dentro
                    -- do tronco" e simula uma derramada de combustível
                    -- "humana"/imperfeita.
                    local RANDOM_EXTRA_FRACTION = 0.43
                    local randomExtra = flameOuterRadius * math.random() * RANDOM_EXTRA_FRACTION
                    flameOuterRadius = flameOuterRadius + randomExtra

                    Logging.info("[Driptorch][flame] Spawnando %d chamas pequenas em (%.2f,%.2f) raio_externo=%.2f",
                        spec.flameSmallCount, flameCenterX, flameCenterZ, flameOuterRadius)

                    session.flameX = flameCenterX
                    session.flameZ = flameCenterZ
                    session.mainFlameSpawned = false
                    session.mainFlameNode = nil
                    session.flameOuterRadius = flameOuterRadius

                    session.smallFlames, session.flameGroundY = self:driptorchSpawnSmallFlames(flameCenterX, flameCenterZ, spec.flameSmallCount, flameOuterRadius)

                    -- CONFIRMADO contra o código-fonte oficial do
                    -- TreePlantManager: o jogo chama removeFromPhysics
                    -- antes de mexer na transformação de um split shape.
                    removeFromPhysics(session.target)

                    table.insert(spec.activeBurns, session)

                    Logging.info("[Driptorch] QUEIMA INICIADA! target=%s burnDuration=%s originalScale=%s,%s,%s sessõesAtivas=%d", tostring(session.target), tostring(session.burnDuration), tostring(sx), tostring(sy), tostring(sz), #spec.activeBurns)
                end

                spec.pressHoldTimer = 0
                spec.pressHoldTarget = nil
            end
        else
            -- Soltou o botão ou perdeu o alvo antes do tempo mínimo -
            -- zera o acúmulo, precisa recomeçar o toque do zero.
            spec.pressHoldTimer = 0
            spec.pressHoldTarget = nil
        end
    end

    -- NOTA: o processamento da queima em andamento (encolhimento, fim de
    -- queima, spawn do decalque) e o fade dos decalques NÃO estão mais
    -- aqui - foram movidos pra driptorchProcessBurn/driptorchProcessDecalFade,
    -- chamados pelo spec.worldTicker (registrado em onLoad via
    -- g_currentMission:addUpdateable). Isso garante que continuam
    -- progredindo mesmo com a tocha guardada, não só enquanto equipada.
end


--[[
    SOBRE MULTIPLAYER (importante, não pular):
    A remoção de um objeto do mapa (árvore/toco) é uma mudança de estado que
    TODOS os clientes precisam ver. O padrão oficial (visto no
    HandToolSprayCan) é: o cliente detecta a ação e envia um EVENTO pro
    servidor via g_client:getServerConnection():sendEvent(MeuEvento.new(...)),
    e o servidor processa a lógica de verdade e sincroniza de volta.

    Precisamos criar uma classe de evento separada, ex. DriptorchBurnEvent.lua,
    seguindo esse mesmo padrão (Event subclass com emptyNew/new/readStream/
    writeStream/run). Fica pro próximo passo, depois que a lógica local
    estiver validada em single-player.
]]

_G.DriptorchTool = DriptorchTool
