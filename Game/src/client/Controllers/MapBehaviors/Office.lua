-- MapBehaviors/Office (client)
-- Exemplo de comportamento client de um mapa. E carregado pelo MapController quando o mapa
-- e resolvido localmente, ANTES de confirmar prontidao ao servidor (MapReady).
--
-- ctx:
--   ctx.Map           : Model    -> o mapa em Workspace.MapInUse.ActiveMap
--   ctx.MapName       : string
--   ctx.LoadId        : number
--   ctx.GetController : (string) -> Controller  -> acessa qualquer Controller da place
--   ctx.Connections   : ConnectionPlus           -> maid; desconecta tudo no Unload/Destroying

local Office = {}

function Office.OnLoad(ctx)
    print(string.format("[Office:client] OnLoad (loadId=%d)", ctx.LoadId))

    -- Exemplo: acessar um Controller compartilhado da place.
    -- local viewmodel = ctx.GetController("ViewmodelController"):GetViewmodel()

    -- Exemplo: efeito local reagindo a uma parte do mapa, com limpeza automatica.
    -- ctx.Connections:Connect(ctx.Map, "SomeEvent", someSignal, function() ... end)
end

function Office.OnUnload(ctx)
    print(string.format("[Office:client] OnUnload (loadId=%d)", ctx.LoadId))
end

return Office
