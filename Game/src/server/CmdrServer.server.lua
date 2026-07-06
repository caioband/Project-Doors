local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local externalPackages = ReplicatedStorage:WaitForChild("ExternalPackages")
local cmdr = require(externalPackages:WaitForChild("cmdr"))

local cmdrFolder = script.Parent:WaitForChild("Cmdr")
local commandsFolder = cmdrFolder:WaitForChild("Commands")

cmdr:RegisterCommandsIn(commandsFolder)

-- Permissao (BeforeRun): sem este hook, o Cmdr BLOQUEIA todo comando cujo Group nao seja
-- DefaultUtil/UserAlias por seguranca ("Command blocked ... no BeforeRun hook is configured").
-- Liberamos em Studio e para o dono do jogo (place de usuario); bloqueamos o resto.
cmdr.Registry:RegisterHook("BeforeRun", function(context)
	if RunService:IsStudio() then
		return
	end

	local executor = context.Executor
	if
		executor
		and game.CreatorType == Enum.CreatorType.User
		and executor.UserId == game.CreatorId
	then
		return
	end

	return "Voce nao tem permissao para usar este comando."
end)