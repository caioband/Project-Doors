local ReplicatedFirst = game:GetService("ReplicatedFirst")

while not ReplicatedFirst:GetAttribute("Loaded") do
	ReplicatedFirst:GetAttributeChangedSignal("Loaded"):Wait()
end

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