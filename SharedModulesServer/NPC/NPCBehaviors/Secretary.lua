--!strict
-- NPCBehaviors/Secretary
-- Logica UNICA do NPC "Secretary" (mapa Office). Resolvido pelo NPCService a partir do nome do
-- Model em AIModels (Model.Name == "Secretary"). Para criar outro NPC, adicione um arquivo com o
-- nome do Model aqui; sem arquivo, o NPC usa so os comportamentos base.
--
-- Formato do descritor:
--   Config     - overrides sobre o DEFAULT_CONFIG do NPCAgent (velocidade, deteccao, animacoes...).
--   StartState - estado inicial (default "Idle").
--   States     - (opcional) estados customizados/overrides mesclados APOS o BaseStates.
--
-- No Office, o Secretary NAO spawna na carga do mapa: fica dormente (escondido) e e spawnado como
-- CACADOR (estado "Hunt") pelo NPCService quando o puzzle do monitor falha e a animacao de falha
-- termina no client (ver Controllers/MapBehaviors/Office.lua -> Services/MapBehaviors/Office.lua ->
-- NPCService:SpawnHunter). Por isso comeca correndo atras do player.

local Secretary = {
	Config = {
		-- Velocidade de corrida ao cacar (Hunt/Chase usam ChaseSpeed).
		ChaseSpeed = 25,
		Animations = {
			-- Animacao de corrida do Secretary (tocada no estado Hunt).
			Run = "rbxassetid://130661528773809",
		},
	},

	StartState = "Hunt",

	-- States = { ... }, -- (opcional) comportamentos exclusivos do Secretary futuramente
}

return Secretary
