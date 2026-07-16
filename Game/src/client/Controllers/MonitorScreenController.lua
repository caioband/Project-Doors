-- MonitorScreenController (client)
-- Traz um Frame de uma SurfaceGui para dentro da ScreenGui fullscreen "MonitorsGUI", clonando-o
-- (mantendo o nome) e, opcionalmente, tocando uma animacao do Cascade (RuntimeEngine) sobre o clone.
-- Pensado para ser reutilizado por qualquer puzzle que use esse monitor fullscreen (tablet do Office,
-- puzzle do telefone, etc).
--
-- O Cascade (ReplicatedStorage.CascadeRuntimeEngine / ReplicatedStorage.CascadeAnimations) so existe
-- no Studio, NAO no diretorio de arquivos; por isso e resolvido em runtime via ReplicatedStorage. O
-- AnimationService conecta um loop de render (RunService.PreRender) no require, entao ele so e
-- carregado (lazy) quando realmente formos animar.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local MonitorScreenController = {}

-- Cache do AnimationService do Cascade (require lazy).
local animationService = nil
local function getAnimationService()
    if not animationService then
        local engine = ReplicatedStorage:WaitForChild("CascadeRuntimeEngine")
        animationService = require(engine:WaitForChild("AnimationService"))
    end
    return animationService
end

-- Resolve a ScreenGui MonitorsGUI no PlayerGui (a copia viva; a de StarterGui e apenas o template).
local function getMonitorsGui(): ScreenGui
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    return playerGui:WaitForChild("MonitorsGUI") :: ScreenGui
end

-- Remove qualquer conteudo trazido anteriormente para o monitor.
function MonitorScreenController:Clear()
    local gui = getMonitorsGui()
    for _, child in gui:GetChildren() do
        child:Destroy()
    end
end

-- Toca uma animacao do Cascade (por nome, resolvida em ReplicatedStorage.CascadeAnimations) sobre
-- `instance`. Fino wrapper reutilizavel; retorna o Signal do Cascade. Serve tanto para o clone no
-- monitor quanto para animar o Frame ORIGINAL (world-space) de uma SurfaceGui.
function MonitorScreenController:PlayAnimation(instance: Instance, animationName: string, options: any?)
    return getAnimationService().Play(instance, animationName, options)
end

-- Versao em lote: toca a MESMA animacao do Cascade sobre varias instancias de uma vez. Use
-- `options.Stagger` (segundos) para escalonar o inicio de cada instancia. Retorna o Signal.
function MonitorScreenController:PlayAnimationBatch(instances: { Instance }, animationName: string, options: any?)
    return getAnimationService().PlayBatch(instances, animationName, options)
end

-- Para qualquer animacao do Cascade que esteja rodando sobre `instance` (ex.: um loop como o
-- LoadingStick). No-op se nao houver nenhuma.
function MonitorScreenController:StopAnimation(instance: Instance)
    getAnimationService().Stop(instance)
end

-- Mantem a Hotbar no estado INVERSO ao monitor: com o monitor visivel a Hotbar some (UI + binds
-- off), e volta quando o monitor esconde. Reusa HotbarHandlerController:SetHotbarEnabled.
function MonitorScreenController:_syncHotbar(monitorEnabled: boolean)
    local getController = self.GetController
    local hotbar = getController and getController("HotbarHandlerController")
    if hotbar and hotbar.SetHotbarEnabled then
        hotbar:SetHotbarEnabled(not monitorEnabled)
    end
end

-- Abre o monitor com `sourceFrame`. Se o conteudo atual do monitor JA for esse mesmo frame (existe
-- um filho com o mesmo nome do original), apenas reabre (Enabled = true) reaproveitando o clone
-- existente, SEM re-clonar nem re-animar -> retorna (cloneExistente, nil, false). Caso contrario
-- (conteudo de outro puzzle ou monitor vazio), limpa tudo, clona `sourceFrame` MANTENDO o nome,
-- opcionalmente toca a animacao do Cascade sobre o clone e retorna (clone, animSignal, true).
-- O 3o retorno (`fresh`) diz se e um clone novo (para so entao rodar setup/animacoes que dependem
-- da 1a exibicao). Pensado para reuso do mesmo monitor por varios puzzles (tablet, telefone, ...).
function MonitorScreenController:ShowFrame(sourceFrame: GuiObject, animationName: string?, options: any?)
    local gui = getMonitorsGui()

    -- Mesmo conteudo ja carregado: so reabre, sem mexer no clone nem re-animar.
    local existing = gui:FindFirstChild(sourceFrame.Name)
    if existing then
        gui.Enabled = true
        self:_syncHotbar(true)
        return existing, nil, false
    end

    -- Conteudo diferente (ou vazio): limpa, clona e (opcional) anima.
    self:Clear()
    gui.Enabled = true
    self:_syncHotbar(true)

    local clone = sourceFrame:Clone()
    clone.Parent = gui

    local signal = nil
    if animationName then
        signal = self:PlayAnimation(clone, animationName, options)
    end
    return clone, signal, true
end

-- Esconde o monitor (Enabled = false) MAS mantem o conteudo dentro do MonitorsGUI, para ser
-- reaproveitado numa proxima abertura via :ShowFrame. Use :Clear() para destruir o conteudo.
function MonitorScreenController:Hide()
    getMonitorsGui().Enabled = false
    self:_syncHotbar(false)
end

-- Retorna o conteudo atual do monitor com o nome dado (ou nil se nao estiver la). Nao cria nada;
-- util para quem precisa atualizar o clone exibido (ex.: refletir estado) so quando ele existe.
function MonitorScreenController:GetContent(frameName: string): Instance?
    return getMonitorsGui():FindFirstChild(frameName)
end

return MonitorScreenController
