local ReplicatedFirst = game:GetService("ReplicatedFirst")
local StarterGui = game:GetService("StarterGui")

while not ReplicatedFirst:GetAttribute("Loaded") do
	ReplicatedFirst:GetAttributeChangedSignal("Loaded"):Wait()
end

-- Esconde a barra de vida padrao do Roblox. SetCoreGuiEnabled pode falhar se o CoreGui ainda nao
-- estiver pronto no boot, entao insistimos ate dar certo (usamos nosso proprio HUD de vida).
task.spawn(function()
	while true do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
		end)
		if ok then
			break
		end
		task.wait(0.1)
	end
end)

local Controllers = {}

local function GetController(controllerName)
	return Controllers[controllerName]
end


for _, child in ipairs(script:GetChildren()) do
	if child:IsA("ModuleScript") then
		local ok, controller = pcall(require, child)
		if ok then
			Controllers[child.Name] = controller
		else
			warn(string.format("[Controllers] Falha ao carregar '%s': %s", child.Name, tostring(controller)))
		end
	end
end


for _, controller in pairs(Controllers) do
	controller.GetController = GetController
end


-- Start ISOLADO por controller: uma falha num Start nao pode abortar o loop e PULAR os demais
-- (a ordem de `pairs` varia por sessao, entao seria uma quebra intermitente). Loga com traceback.
for name, controller in pairs(Controllers) do
	if type(controller.Start) == "function" then
		local ok, err = xpcall(function()
			controller:Start()
		end, debug.traceback)
		if not ok then
			warn(string.format("[Controllers] '%s':Start() falhou: %s", name, tostring(err)))
		end
	end
end