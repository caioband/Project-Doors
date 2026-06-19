-- MapBehaviors/Office (client)
-- Comportamento client do mapa Office. E carregado pelo MapController quando o mapa
-- e resolvido localmente, ANTES de confirmar prontidao ao servidor (MapReady).
--
-- ctx:
--   ctx.Map           : Model    -> o mapa em Workspace.MapInUse.ActiveMap
--   ctx.MapName       : string
--   ctx.LoadId        : number
--   ctx.GetController : (string) -> Controller  -> acessa qualquer Controller da place
--   ctx.Connections   : ConnectionPlus           -> maid; desconecta tudo no Unload/Destroying

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local spr = require(ReplicatedStorage.Shared.SharedModules.SpringEffects)
local UIAnimator = require(ReplicatedStorage.UIAnimator)

local Office = {}

-- Resolve um caminho aninhado a partir de uma instancia raiz (nil se algum no faltar).
local function resolve(root: Instance?, ...: string): Instance?
    local current = root
    for _, name in { ... } do
        if not current then
            return nil
        end
        current = current:FindFirstChild(name)
    end
    return current
end

function Office.OnLoad(ctx)
    print(string.format("[Office:client] OnLoad (loadId=%d)", ctx.LoadId))

    local managerPC = resolve(ctx.Map, "Model", "ManagerPC")
    if not managerPC then
        warn("[Office:client] ManagerPC nao encontrado no mapa")
        return
    end

    local prompt = resolve(managerPC, "Keyboard", "Union", "ProximityPrompt") :: ProximityPrompt?
    local cameraPart = resolve(managerPC, "Cameras", "1") :: BasePart?
    local container = resolve(managerPC, "SmallMonitor", "Part", "SurfaceGui", "Container") :: Frame?
    local textBox = container and container:FindFirstChild("TextBox") :: TextBox?
    local warning = container and container:FindFirstChild("Warning") :: TextLabel?

    if not (prompt and cameraPart and container and textBox and warning) then
        warn("[Office:client] Instancias do ManagerPC faltando; abortando bind")
        return
    end

    -- Senha temporaria do monitor.
    local password = "1234"

    -- Guarda os valores de repouso para a tremida sempre voltar ao estado original.
    local textBoxBasePos = textBox.Position
    local textBoxBaseColor = textBox.TextColor3
    local warningBasePos = warning.Position
    local warningBaseRot = warning.Rotation
    local warningBaseColor = warning.TextColor3

    -- Tremida ao errar a senha: o TextBox treme so na posicao; o Warning (TextLabel) treme na
    -- posicao e rotacao, e ainda pisca vermelho voltando para a cor original. As nudges iniciais
    -- sao corrigidas por springs subamortecidos (damping baixo), gerando o balanco da tremida.
    local function shakeOnWrongPassword()
        -- TextBox: apenas posicao.
        textBox.Position = textBoxBasePos + UDim2.fromScale(0.05, 0)
        textBox.TextColor3 = Color3.fromRGB(255, 0, 0)
        spr.target(textBox, 0.25, 7, { Position = textBoxBasePos })
        spr.target(textBox, 1, 2.5, { TextColor3 = textBoxBaseColor })

        -- Warning: posicao + rotacao, e flash vermelho de volta a cor original.
        warning.Position = warningBasePos + UDim2.fromScale(0.04, 0)
        warning.Rotation = warningBaseRot + 10
        warning.TextColor3 = Color3.fromRGB(255, 0, 0)
        spr.target(warning, 0.25, 7, {
            Position = warningBasePos,
            Rotation = warningBaseRot,
        })
        spr.target(warning, 1, 2.5, { TextColor3 = warningBaseColor })
    end

    -- Checa a senha digitada quando o player confirma (Enter) e treme se estiver errada.
    ctx.Connections:Connect(ctx.Map, "OfficePasswordCheck", textBox.FocusLost, function(enterPressed)
        if not enterPressed then
            return
        end
        if textBox.Text ~= password then
            shakeOnWrongPassword()
        end
    end)

    -- Evita reprocessar caso o prompt seja acionado mais de uma vez.
    local activated = false

    ctx.Connections:Connect(ctx.Map, "OfficeManagerPC", prompt.Triggered, function()
        if activated then
            return
        end
        activated = true

        -- Tira quaisquer modelos do viewmodel e para o loop de render dele, liberando a camera.
        local viewmodel = ctx.GetController("ViewmodelController"):GetViewmodel()
        if viewmodel then
            viewmodel:DestroyViewmodel()
            viewmodel:Pause()
        end

        -- Trava a camera na CFrame da Part de referencia (Cameras.1).
        local camera = workspace.CurrentCamera
        camera.CameraType = Enum.CameraType.Scriptable
        camera.CFrame = cameraPart.CFrame

        -- Libera/exibe o cursor enquanto o player estiver olhando para o monitor.
        UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true

        -- Com a camera ja posicionada, cresce o TextBox em Y.Scale ate .3 com um spring.
        task.wait(1)
        local size = textBox.Size
        spr.target(textBox, 0.7, 3.5, {
            Size = UDim2.new(size.X.Scale, size.X.Offset, 0.3, 0),
        })

        -- Quando a animacao de crescimento terminar, escreve o aviso com o efeito "Glitch".
        spr.completed(textBox, function()
            task.wait(.5)
            UIAnimator.ShowText(container, warning, "Pick the next call", {
                effect = "Glitch",
                onComplete = function()
                    -- Acabou a animacao: remove os labels de caractere gerados pelo efeito
                    -- e devolve a visibilidade ao label original.
                    for _, child in container:GetChildren() do
                        if child:GetAttribute("CharLabel") then
                            child:Destroy()
                        end
                    end
                    warning.Text = "Pick the next call"
                    warning.Visible = true
                end,
            })
        end)
    end)
end

function Office.OnUnload(ctx)
    print(string.format("[Office:client] OnUnload (loadId=%d)", ctx.LoadId))

    -- Limpa todas as conexoes registradas para este mapa.
    ctx.Connections:DisconnectAll(ctx.Map)
end

return Office
