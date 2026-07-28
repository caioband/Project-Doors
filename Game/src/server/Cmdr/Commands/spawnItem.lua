-- Definicao do comando spawnitem. NAO tem Run: a definicao e replicada para o client (o Cmdr move
-- este ModuleScript para ReplicatedStorage), entao um Run embutido rodaria no CLIENT e daria
-- infinite yield no WaitForChild("Server")/ServerScriptService. A implementacao fica no modulo
-- separado spawnItemServer.lua (nao replicado), que o Cmdr anexa como Run SO no servidor.
return {
	Name = "spawnitem",
	Aliases = { "giveitem", "item" },
	Description = "Spawna um item coletavel na frente do personagem (funcional: prompt, volume e valor). Util para testar a mochila sem depender do sorteio dos spawns do mapa.",
	Group = "DefaultAdmin",

	Args = {
		{
			Type = "string",
			Name = "item",
			Description = "Nome do modelo em ServerStorage.Assets.Models.Items (ex.: Fan, Monitor, Typewriter). Vazio ou 'random' sorteia um.",
			Optional = true,
		},
		{
			Type = "player",
			Name = "player",
			Description = "Na frente de quem spawnar (padrao: quem rodou o comando)",
			Optional = true,
		},
	},
}
