local HotbarHandler = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Hotbar = require(ReplicatedStorage.Shared.SharedModules.Hotbar)

-- Estado da luz (Part + SpotLight) que acompanha a camera enquanto a Flashlight esta equipada.
local flashlightPart: Part? = nil
local flashlightConnection: RBXScriptConnection? = nil


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

            createFlashlightLight()
        end,

        OnUnequip = function()
            HotbarHandler._destroyFlashlightLight()

            local viewmodel = getViewmodel()
            if viewmodel then
                viewmodel:DestroyViewmodel()
            end
        end,
    })
end


function HotbarHandler:Start()
    Hotbar:Start()
    registerItemCallbacks()
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
