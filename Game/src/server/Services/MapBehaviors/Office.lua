--!strict
-- MapBehaviors/Office (server)
-- Exemplo de comportamento server de um mapa. E carregado pelo RoundService DEPOIS que o mapa
-- esta carregado para TODOS os players (barreira de prontidao).
--
-- ctx (BehaviorContext):
--   ctx.Map          : Model    -> o mapa clonado (Workspace.MapInUse.ActiveMap)
--   ctx.MapName      : string
--   ctx.LoadId       : number
--   ctx.GetService   : (string) -> Service   -> acessa qualquer Service da place
--   ctx.Connections  : ConnectionPlus        -> maid; desconecta tudo no UnloadMap/Destroying
--
-- Sinalize o fim da rodada com ctx.Map:SetAttribute("RoundOver", true) (o RoundService observa).

local Office = {}

function Office.OnLoad(ctx)
    print(string.format("[Office:server] OnLoad (loadId=%d) - mapa pronto para todos", ctx.LoadId))

    -- Exemplo: acessar outro Service da place.
    -- local voteService = ctx.GetService("VoteService")

    -- Exemplo: reagir a interacoes de partes do mapa com limpeza automatica.
    -- Toda conexao registrada via ctx.Connections keyed em ctx.Map e desconectada no Unload.
    local lever = ctx.Map:FindFirstChild("Lever", true)
    if lever then
        local prompt = lever:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            ctx.Connections:Connect(ctx.Map, "LeverTriggered", prompt.Triggered, function(player: Player)
                print(string.format("[Office:server] %s acionou a Lever", player.Name))
                -- ... logica da rodada ...
            end)
        end
    end
end

function Office.OnUnload(ctx)
    print(string.format("[Office:server] OnUnload (loadId=%d)", ctx.LoadId))
    -- ConnectionPlus ja desconecta o que foi registrado em ctx.Map; limpe aqui estados extras.
end

return Office
