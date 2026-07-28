-- Implementacao SERVER do comando spawnitem (definicao em spawnItem.lua). O Cmdr pareia por
-- nome (<Nome> + <Nome>Server), anexa este retorno como Run e NAO replica modulos *Server para o
-- client — entao este codigo, que acessa o CollectablesService via ServerScriptService, roda so
-- no server.
return function(context, item, player)
	local ServerScriptService = game:GetService("ServerScriptService")
	local CollectablesService = require(
		ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("CollectablesService")
	)

	-- Sem o argumento de player, spawna na frente de quem rodou o comando.
	local target = player or context.Executor
	if not target then
		return "Sem player alvo (rode o comando como um jogador ou passe o argumento)."
	end

	local _ok, message = CollectablesService:SpawnItemInFront(target, item)
	return message
end
