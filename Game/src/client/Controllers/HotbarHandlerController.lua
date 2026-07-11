local HotbarHandler = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Hotbar = require(ReplicatedStorage.Shared.SharedModules.Hotbar)

local LocalPlayer = Players.LocalPlayer

-- Id da animacao (em loop) tocada no character ao equipar a Flashlight. Por ser tocada no
-- character local, ela replica para os demais jogadores (que veem o modelo na mao direita).
local FLASHLIGHT_ANIM_ID = "rbxassetid://135545662719950"

-- Nome do modelo de flashlight que o servidor solda no character. O cliente do dono destroi
-- a copia local (1a pessoa usa o viewmodel; nao deve enxergar o modelo do mundo).
local EQUIPPED_FLASHLIGHT_NAME = "EquippedFlashlight"

-- Estado da luz (Part + SpotLight) que acompanha a camera enquanto a Flashlight esta equipada.
local flashlightPart: Part? = nil
local flashlightConnection: RBXScriptConnection? = nil

-- Track da animacao de flashlight no character e o watcher que destroi a copia local do modelo.
local flashlightAnimTrack: AnimationTrack? = nil
local equippedModelWatcher: RBXScriptConnection? = nil

-- Remotes do FlashlightService (resolvidos em :Start).
local FlashlightEquipRemote: RemoteEvent? = nil
local FlashlightUnequipRemote: RemoteEvent? = nil


-- Cria uma Part (presa ao CFrame da camera) com um SpotLight dentro dela.
local function createFlashlightLight()
    -- Garante que nao exista uma luz anterior pendurada.
    HotbarHandler._destroyFlashlightLight()

    local camera = workspace.CurrentCamera

    local part = Instance.new("Part")
    part.Name = "FlashlightLight"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.Size = Vector3.new(0.2, 0.2, 0.2)
    part.CFrame = camera.CFrame

    local spotlight = Instance.new("SpotLight")
    spotlight.Angle = 90
    spotlight.Brightness = 3
    spotlight.Color = Color3.fromRGB(255, 255, 255)
    spotlight.Range = 40
    spotlight.Face = Enum.NormalId.Front
    spotlight.Parent = part

    part.Parent = workspace

    -- Mantem a Part colada na CFrame da camera todo frame.
    flashlightConnection = RunService.RenderStepped:Connect(function()
        local cam = workspace.CurrentCamera
        if cam and part.Parent then
            part.CFrame = cam.CFrame
        end
    end)

    flashlightPart = part
end


-- Destroi a Part/SpotLight da Flashlight e desconecta o loop de render.
function HotbarHandler._destroyFlashlightLight()
    if flashlightConnection then
        flashlightConnection:Disconnect()
        flashlightConnection = nil
    end
    if flashlightPart then
        flashlightPart:Destroy()
        flashlightPart = nil
    end
end


-- Obtem (ou cria) o Animator do character local para tocar a animacao de flashlight.
local function getCharacterAnimator(): Animator?
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
    if not humanoid then
        return nil
    end
    local animator = humanoid:FindFirstChildWhichIsA("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    return animator
end


-- Toca a animacao de flashlight no character local, em loop (replica para os demais).
local function playFlashlightCharacterAnim()
    local animator = getCharacterAnimator()
    if not animator then
        return
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = FLASHLIGHT_ANIM_ID

    local track = animator:LoadAnimation(animation)
    track.Looped = true
    track.Priority = Enum.AnimationPriority.Action
    track:Play()
    flashlightAnimTrack = track
end


-- Para a animacao de flashlight do character.
local function stopFlashlightCharacterAnim()
    if flashlightAnimTrack then
        flashlightAnimTrack:Stop()
        flashlightAnimTrack = nil
    end
end


-- Destroi a copia local do modelo equipado (replicado pelo servidor). Para o dono, a 1a
-- pessoa usa o viewmodel, entao o modelo do mundo nao deve aparecer na tela.
local function destroyLocalEquippedModel(child: Instance)
    if child.Name == EQUIPPED_FLASHLIGHT_NAME
        and child:GetAttribute("Owner") == LocalPlayer.UserId then
        child:Destroy()
    end
end


-- Observa o character ate o modelo equipado replicar (e o destroi localmente). Tambem cobre
-- o caso de ele ja existir no momento em que comecamos a observar.
local function startEquippedModelWatcher()
    if equippedModelWatcher then
        equippedModelWatcher:Disconnect()
        equippedModelWatcher = nil
    end

    local character = LocalPlayer.Character
    if not character then
        return
    end

    for _, child in ipairs(character:GetChildren()) do
        destroyLocalEquippedModel(child)
    end
    equippedModelWatcher = character.ChildAdded:Connect(destroyLocalEquippedModel)
end


-- Para de observar o character por novos modelos equipados.
local function stopEquippedModelWatcher()
    if equippedModelWatcher then
        equippedModelWatcher:Disconnect()
        equippedModelWatcher = nil
    end
end


-- Retorna a instancia ativa do Viewmodel (via ViewmodelController), ou nil.
local function getViewmodel()
    local getController = HotbarHandler.GetController
    if not getController then
        return nil
    end
    local viewmodelController = getController("ViewmodelController")
    return viewmodelController and viewmodelController:GetViewmodel()
end


-- Obtem (ou cria) o Animator do modelo de viewmodel para tocar animacoes.
local function getAnimator(model: Model): Animator
    local animator = model:FindFirstChildWhichIsA("Animator", true)
    if animator then
        return animator
    end

    local controller = model:FindFirstChildWhichIsA("Humanoid")
        or model:FindFirstChildWhichIsA("AnimationController")
    if not controller then
        controller = Instance.new("AnimationController")
        controller.Parent = model
    end

    animator = controller:FindFirstChildWhichIsA("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = controller
    end

    return animator
end


-- Toca todas as animacoes da pasta "Flashlight" dentro do viewmodel atual.
local function playFlashlightAnims(viewmodel)
    local model = viewmodel.ViewmodelModel
    if not model then
        return
    end

    local animsFolder = model:FindFirstChild("Anims")
    local flashlightFolder = animsFolder and animsFolder:FindFirstChild("Flashlight")
    if not flashlightFolder then
        warn("playFlashlightAnims: pasta de animacoes 'Flashlight' nao encontrada no viewmodel")
        return
    end

    local animator = getAnimator(model)
    for _, descendant in ipairs(flashlightFolder:GetDescendants()) do
        if descendant:IsA("Animation") then
            local track = animator:LoadAnimation(descendant)
            track:Play()
        end
    end
end


-- Registra os callbacks de equipar/desequipar de cada item da Hotbar.
local function registerItemCallbacks()
    Hotbar:SetItemCallbacks("Flashlight", {
        OnEquip = function()
            local viewmodel = getViewmodel()
            if not viewmodel then
                return
            end

            viewmodel:CloneViewmodel()
            viewmodel:DestroyArm("LeftArm")
            viewmodel:AttachItemToRightArm(ReplicatedStorage.Assets.Models.Items.Flashlight)
            viewmodel:CloneAnimsFolder("Flashlight")
            viewmodel:LoadViewmodelAnims()
            viewmodel:SetViewmodelOffset(Vector3.new(3, -2, 0))
            playFlashlightAnims(viewmodel)

            -- Animacao do character (replica para os demais) + pedido ao servidor para
            -- clonar/soldar o modelo na mao direita e ligar o SpotLight.
            playFlashlightCharacterAnim()
            startEquippedModelWatcher()
            if FlashlightEquipRemote then
                FlashlightEquipRemote:FireServer()
            end

            createFlashlightLight()
        end,

        OnUnequip = function()
            HotbarHandler._destroyFlashlightLight()

            stopFlashlightCharacterAnim()
            stopEquippedModelWatcher()
            if FlashlightUnequipRemote then
                FlashlightUnequipRemote:FireServer()
            end

            local viewmodel = getViewmodel()
            if viewmodel then
                viewmodel:DestroyViewmodel()
            end
        end,
    })
end


function HotbarHandler:Start()
    local comms = ReplicatedStorage:WaitForChild("Comms")
    local flashlightComms = comms:WaitForChild("Flashlight")
    FlashlightEquipRemote = flashlightComms:WaitForChild("Equip") :: RemoteEvent
    FlashlightUnequipRemote = flashlightComms:WaitForChild("Unequip") :: RemoteEvent

    Hotbar:Start()
    registerItemCallbacks()
end

-- Liga/desliga a Hotbar inteira (UI + binds). Chamado pelo DownedController: desativa na morte
-- real do player e reativa no respawn.
function HotbarHandler:SetHotbarEnabled(enabled: boolean)
    if enabled then
        Hotbar:Enable()
    else
        Hotbar:Disable()
    end
end

-- Adiciona um item comprado na loja ao primeiro slot livre da Hotbar.
-- Retorna o numero do slot usado, ou nil se a Hotbar estiver cheia.
function HotbarHandler:AddItem(item): number?
    return Hotbar:AddToFirstFreeSlot(item)
end

-- Pre-carrega os assets de um item assim que ele e adquirido, deixando-o pronto
-- para o primeiro equip. Hoje so a Flashlight tem animacoes a pre-carregar.
-- Atencao: yield (PreloadAsync); chame em task.spawn se nao quiser bloquear.
function HotbarHandler:PreloadItemAssets(item)
    if not item or item.Name ~= "Flashlight" then
        return
    end

    local viewmodel = getViewmodel()
    if viewmodel then
        viewmodel:PreloadAnimsFolder("Flashlight")
    end
end

return HotbarHandler
