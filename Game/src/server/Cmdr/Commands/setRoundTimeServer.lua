-- Implementacao SERVER do comando setroundtime (definicao em setRoundTime.lua). O Cmdr pareia por
-- nome (<Nome> + <Nome>Server), anexa este retorno como Run e NAO replica modulos *Server para o
-- client — entao este codigo, que acessa o RoundService via ServerScriptService, roda so no server.
return function(_context, seconds)
	local ServerScriptService = game:GetService("ServerScriptService")
	local RoundService = require(
		ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("RoundService")
	)

	local _ok, message = RoundService:SetRoundTime(seconds)
	return message
end
