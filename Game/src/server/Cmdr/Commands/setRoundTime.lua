-- Definicao do comando setroundtime. NAO tem Run: a definicao e replicada para o client (o Cmdr
-- move este ModuleScript para ReplicatedStorage), entao um Run embutido rodaria no CLIENT e daria
-- infinite yield no WaitForChild("Server")/ServerScriptService. A implementacao fica no modulo
-- separado setRoundTimeServer.lua (nao replicado), que o Cmdr anexa como Run SO no servidor.
return {
	Name = "setroundtime",
	Aliases = { "roundtime", "setround" },
	Description = "Ajusta o tempo restante da rodada ativa (segundos). Util para testar a fase de fuga (EscapeArea) sem esperar os 5 min. 0 encerra a rodada quase imediatamente.",
	Group = "DefaultAdmin",

	Args = {
		{
			Type = "number",
			Name = "seconds",
			Description = "Tempo restante da rodada, em segundos (0 = acaba agora)",
		},
	},
}
