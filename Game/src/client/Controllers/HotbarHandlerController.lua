local HotbarHandler = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hotbar = require(ReplicatedStorage.Shared.SharedModules.Hotbar)


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
            viewmodel:SetViewmodelOffset(Vector3.new(3, 0, 0))
            playFlashlightAnims(viewmodel)
        end,

        OnUnequip = function()
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
