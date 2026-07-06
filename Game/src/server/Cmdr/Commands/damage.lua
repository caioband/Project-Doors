return {
	Name = "damage",
	Description = "Aplica dano (vida custom) a um player via DownedService, para testar downed/morte.",
	Group = "DefaultAdmin",

	Args = {
		{
			Type = "player",
			Name = "player",
			Description = "Player que recebe o dano",
		},
		{
			Type = "number",
			Name = "amount",
			Description = "Quantidade de dano a aplicar",
		},
	},

	Run = function(_context, player, amount)
		local ServerScriptService = game:GetService("ServerScriptService")
		local DownedService = require(
			ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("DownedService")
		)

		DownedService:ApplyDamage(player, amount)

		return string.format("Aplicado %d de dano em %s.", amount, player.Name)
	end,
}
