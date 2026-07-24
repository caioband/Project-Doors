-- ChessController
-- Cliente do minigame de xadrez da VotingRoom. Cuida da APRESENTACAO (o server e a autoridade):
--   * Prompt (Chess.PromptPart.ProximityPrompt) -> Join no server -> senta (camera + mouse livre).
--   * GUI StarterGui.ChessSettings: menu (PlayAgainstAI / ChooseDifficultButton / Back), escolha de
--     dificuldade (ChooseDifficult: Easy/Medium/Hard), e partida (so Surrender visivel).
--   * Durante a partida: clique (raycast) seleciona a peca e destaca os lances legais (ChessEngine);
--     o 2o clique numa casa legal envia RequestMove.
--   * Modo IA: quando e a vez da IA (pretas), roda o ChessAI localmente e envia SubmitAIMove.
--   * Sincroniza o tabuleiro logico via Sync (FEN). As Instances das pecas se movem sozinhas (server).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ChessEngine = require(ReplicatedStorage.Shared.SharedModules.ChessEngine)
local ChessAI = require(ReplicatedStorage.Shared.SharedModules.ChessAI)

local ChessController = {}

local LocalPlayer = Players.LocalPlayer

-- Cores dos highlights (aplicadas LOCALMENTE na cor das casas; nao replicam).
local SELECT_COLOR = Color3.fromRGB(80, 140, 255)
local TARGET_COLOR = Color3.fromRGB(90, 210, 120)

local CAMERA_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Distancia (studs) alem da qual consideramos que o player saiu da mesa (ex.: teleporte de round).
local LEAVE_DISTANCE = 30

-- ===== Estado =====
local atTable = false
local uiState = "None" -- "Menu" | "Playing"
local myColor: string? = nil
local myMode: string? = nil -- "AI" | "PvP"
local difficulty = "Easy"
local selectedDifficulty = "Easy"
local gameActive = false
local aiThinking = false

local currentState = nil -- espelho logico (ChessEngine) reconstruido do FEN
local selectedSquare = nil
local legalTargets: { [string]: boolean } = {}
local highlighted: { [BasePart]: Color3 } = {} -- casa -> cor original

-- FOV da camera enquanto sentado na mesa.
local SEATED_FOV = 50

-- Delay (s) de "pensamento" da IA antes de jogar (alem do tempo de calculo).
local AI_THINK_MIN = 0.5
local AI_THINK_MAX = 2

-- Referencias de cena (resolvidas ao sentar).
local chessModel: Instance? = nil
local chessGameBoard: Instance? = nil
local chessCameras: Instance? = nil
local chessPrompt: ProximityPrompt? = nil
local squares: { [string]: BasePart } = {}
local originalFOV = 70

local distanceConn: RBXScriptConnection? = nil

-- ===== Remotes =====
local Comms
local JoinRemote, StartAIRemote, RequestMoveRemote, SubmitAIMoveRemote
local SurrenderRemote, LeaveRemote, GameStartedRemote, SyncRemote, GameEndedRemote

-- ===== GUI (re-resolvida a cada bind; ChessSettings tem ResetOnSpawn) =====
local Gui, Frame, PlayAgainstAI, ChooseDifficultButton, BackBtn, DifficultLevel, Surrender
local ChooseDifficult, DiffBackBtn, EasyBtn, MediumBtn, HardBtn


local function getViewmodel()
	local getController = ChessController.GetController
	local vc = getController and getController("ViewmodelController")
	return vc and vc:GetViewmodel()
end

-- Liga/desliga a Hotbar (UI + binds) enquanto o player esta na mesa.
local function setHotbarEnabled(enabled: boolean)
	local getController = ChessController.GetController
	local hotbar = getController and getController("HotbarHandlerController")
	if hotbar then
		hotbar:SetHotbarEnabled(enabled)
	end
end


-- Confirma se o prompt e o do xadrez (PromptPart sob Chess sob VotingRoom), por ancestralidade.
local function isChessPrompt(prompt: ProximityPrompt): boolean
	local promptPart = prompt.Parent
	if not promptPart or promptPart.Name ~= "PromptPart" then
		return false
	end
	local chess = promptPart.Parent
	if not chess or chess.Name ~= "Chess" then
		return false
	end
	local votingRoom = chess.Parent
	return votingRoom ~= nil and votingRoom.Name == "VotingRoom"
end


-- Resolve o modelo Chess atual e monta as referencias (casas, cameras). ActivePieces pode ainda
-- nao existir (so aparece quando ha partida); resolvida sob demanda.
local function resolveChessRefs(): boolean
	local mapInUse = Workspace:FindFirstChild("MapInUse")
	local vr = mapInUse and mapInUse:FindFirstChild("VotingRoom")
	chessModel = vr and vr:FindFirstChild("Chess")
	if not chessModel then
		return false
	end
	chessGameBoard = chessModel:FindFirstChild("GameBoard")
	chessCameras = chessModel:FindFirstChild("Cameras")
	local promptPart = chessModel:FindFirstChild("PromptPart")
	chessPrompt = promptPart and promptPart:FindFirstChildWhichIsA("ProximityPrompt")
	if not chessGameBoard or not chessCameras then
		return false
	end
	squares = {}
	for _, p in chessGameBoard:GetChildren() do
		if p:IsA("BasePart") and #p.Name == 2 then
			squares[p.Name:upper()] = p
		end
	end
	return true
end


-- ===== Highlights =====
local function highlight(part: BasePart, color: Color3)
	if not highlighted[part] then
		highlighted[part] = part.Color
	end
	part.Color = color
end

local function clearHighlights()
	for part, color in highlighted do
		part.Color = color
	end
	highlighted = {}
end

local function clearSelection()
	selectedSquare = nil
	legalTargets = {}
	clearHighlights()
end

local function selectSquare(coord)
	clearSelection()
	selectedSquare = coord
	local fromSq = squares[ChessEngine.CoordToName(coord.file, coord.rank)]
	if fromSq then
		highlight(fromSq, SELECT_COLOR)
	end
	for _, m in ChessEngine.GenerateLegalMoves(currentState, coord) do
		local toName = ChessEngine.CoordToName(m.to.file, m.to.rank)
		legalTargets[toName] = true
		local tsq = squares[toName]
		if tsq then
			highlight(tsq, TARGET_COLOR)
		end
	end
end


-- ===== GUI: transicoes de estado =====
local function showMenu()
	if not Gui then
		return
	end
	uiState = "Menu"
	Gui.Enabled = true
	PlayAgainstAI.Visible = true
	ChooseDifficultButton.Visible = true
	BackBtn.Visible = true
	DifficultLevel.Visible = true
	DifficultLevel.Text = selectedDifficulty
	ChooseDifficult.Visible = false
	Surrender.Visible = false
end

local function showChooseDifficulty()
	PlayAgainstAI.Visible = false
	ChooseDifficultButton.Visible = false
	BackBtn.Visible = false
	ChooseDifficult.Visible = true
end

local function enterPlaying()
	uiState = "Playing"
	Gui.Enabled = true
	PlayAgainstAI.Visible = false
	ChooseDifficultButton.Visible = false
	BackBtn.Visible = false
	ChooseDifficult.Visible = false
	DifficultLevel.Visible = false
	Surrender.Visible = true
end


-- ===== Camera / assento =====
local function anchorHRP(anchored: boolean)
	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = anchored
	end
end

local function stopDistanceWatch()
	if distanceConn then
		distanceConn:Disconnect()
		distanceConn = nil
	end
end

local leaveTable -- fwd decl

local function startDistanceWatch()
	stopDistanceWatch()
	distanceConn = RunService.Heartbeat:Connect(function()
		if not atTable or not chessModel or not chessModel.Parent then
			leaveTable()
			return
		end
		local character = LocalPlayer.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			leaveTable()
			return
		end
		if (hrp.Position - chessModel:GetPivot().Position).Magnitude > LEAVE_DISTANCE then
			leaveTable()
		end
	end)
end

-- Entra na mesa: pausa o viewmodel, trava a camera no ponto do assento (cor), ancora o personagem,
-- e ao chegar a camera libera o mouse. Mostra a GUI (o estado inicial e definido pelo chamador).
local function enterTable(color: string)
	if not resolveChessRefs() then
		return
	end
	atTable = true
	myColor = color

	local camera = Workspace.CurrentCamera
	originalFOV = camera.FieldOfView

	-- Desabilita o prompt SO para este player (mudanca local; outros ainda podem acionar p/ entrar
	-- no PvP). Reabilitado ao sair.
	if chessPrompt then
		chessPrompt.Enabled = false
	end

	-- Esconde a Hotbar enquanto sentado na mesa (reativada ao sair).
	setHotbarEnabled(false)

	local viewmodel = getViewmodel()
	if viewmodel then
		viewmodel:Pause()
	end
	anchorHRP(true)

	local cameraPart = chessCameras:FindFirstChild(color == "w" and "Player1" or "Player2")
	camera.CameraType = Enum.CameraType.Scriptable
	if cameraPart and cameraPart:IsA("BasePart") then
		local tween = TweenService:Create(camera, CAMERA_TWEEN, { CFrame = cameraPart.CFrame, FieldOfView = SEATED_FOV })
		tween.Completed:Once(function()
			-- Camera na posicao correta: viewmodel desabilitado (ja pausado) + mouse livre/visivel.
			if atTable then
				local vm = getViewmodel()
				if vm then
					vm:SetFreeMouse(true)
				end
			end
		end)
		tween:Play()
	end

	startDistanceWatch()
end

-- Restaura tudo ao sair da mesa (camera/mouse/personagem/GUI/highlights). NAO notifica o server.
local function exitTable()
	if not atTable then
		return
	end
	atTable = false
	uiState = "None"
	gameActive = false
	myColor = nil
	myMode = nil
	clearSelection()
	stopDistanceWatch()

	if Gui then
		Gui.Enabled = false
	end

	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = originalFOV

	-- Reabilita o prompt para este player.
	if chessPrompt then
		chessPrompt.Enabled = true
	end

	-- Reativa a Hotbar.
	setHotbarEnabled(true)

	local viewmodel = getViewmodel()
	if viewmodel then
		viewmodel:SetFreeMouse(false)
	end
	anchorHRP(false)
	if viewmodel then
		viewmodel:Resume()
	end
end

-- Sai da mesa por vontade propria (Back no menu) ou forcado (distancia/round): notifica o server e
-- restaura o estado local. (Se estava jogando, isso conta como desistencia.)
function leaveTable()
	if not atTable then
		return
	end
	if uiState == "Playing" then
		SurrenderRemote:FireServer()
	else
		LeaveRemote:FireServer()
	end
	exitTable()
end


-- ===== IA (modo vs IA) =====
local function maybeTriggerAI()
	if myMode ~= "AI" or myColor ~= "w" or not gameActive or aiThinking then
		return
	end
	if not currentState or currentState.turn ~= "b" then
		return
	end
	aiThinking = true
	task.spawn(function()
		local move = ChessAI.ChooseMove(currentState, difficulty)
		-- "Pensamento": aguarda um tempo aleatorio (0.5–2s) antes de jogar.
		task.wait(AI_THINK_MIN + math.random() * (AI_THINK_MAX - AI_THINK_MIN))
		if move and gameActive and currentState and currentState.turn == "b" then
			SubmitAIMoveRemote:InvokeServer(
				ChessEngine.CoordToName(move.from.file, move.from.rank),
				ChessEngine.CoordToName(move.to.file, move.to.rank),
				move.promotion
			)
		end
		aiThinking = false
	end)
end


-- ===== Clique no tabuleiro =====
local function resolveSquareFromTarget(target: Instance?): string?
	if not target then
		return nil
	end
	if #target.Name == 2 and target.Parent and target.Parent.Name == "GameBoard" then
		return target.Name:upper()
	end
	local sq = target:GetAttribute("Square")
	if typeof(sq) == "string" then
		return sq
	end
	return nil
end

local function handleBoardClick()
	if uiState ~= "Playing" or not currentState or not gameActive then
		return
	end
	if currentState.turn ~= myColor then
		return -- nao e a minha vez
	end

	local mouse = LocalPlayer:GetMouse()
	local name = resolveSquareFromTarget(mouse.Target)
	if not name then
		return
	end
	local coord = ChessEngine.NameToCoord(name)
	if not coord then
		return
	end

	if selectedSquare then
		if legalTargets[name] then
			-- Envia o lance (promocao = auto-dama; server assume dama se nil).
			local fromName = ChessEngine.CoordToName(selectedSquare.file, selectedSquare.rank)
			clearSelection()
			task.spawn(function()
				RequestMoveRemote:InvokeServer(fromName, name, nil)
			end)
			return
		end
		-- Clicou noutra peca minha: re-seleciona. Senao, limpa.
		local p = currentState.board[coord.rank][coord.file]
		if p and p.color == myColor then
			selectSquare(coord)
		else
			clearSelection()
		end
	else
		local p = currentState.board[coord.rank][coord.file]
		if p and p.color == myColor then
			selectSquare(coord)
		end
	end
end


-- ===== Handlers de rede =====
local function onSync(data)
	if typeof(data) ~= "table" or not data.fen then
		return
	end
	currentState = ChessEngine.FromFEN(data.fen)
	if uiState == "Playing" then
		clearSelection() -- limpa highlights apos qualquer lance
		maybeTriggerAI()
	end
end

local function onGameStarted(data)
	myColor = data.color
	myMode = data.mode
	difficulty = data.difficulty or "Easy"
	gameActive = true
	if data.fen then
		currentState = ChessEngine.FromFEN(data.fen)
	end
	if not atTable then
		enterTable(myColor)
	end
	enterPlaying()
	maybeTriggerAI()
end

local function resultText(data): string
	if data.result == "draw" or data.result == "stalemate" then
		return "Draw"
	end
	if data.winner == myColor then
		return "You win!"
	elseif data.winner then
		return "You lose"
	end
	return "Game over"
end

local function onGameEnded(data)
	gameActive = false
	aiThinking = false
	clearSelection()
	-- So mostramos o resultado se ainda estamos na mesa (quem desistiu ja saiu).
	if atTable and Gui then
		Surrender.Visible = false
		DifficultLevel.Visible = true
		DifficultLevel.Text = resultText(data)
		task.delay(3, function()
			if atTable then
				exitTable()
			end
		end)
	end
end


-- ===== Prompt =====
local function onPromptTriggered(prompt: ProximityPrompt)
	if atTable or not isChessPrompt(prompt) then
		return
	end
	task.spawn(function()
		local resp = JoinRemote:InvokeServer()
		if typeof(resp) ~= "table" then
			return
		end
		if resp.mode == "Seated" or resp.mode == "AlreadySeated" then
			enterTable("w")
			showMenu()
		elseif resp.mode == "Joining" then
			myMode = "PvP"
			gameActive = true
			if resp.fen then
				currentState = ChessEngine.FromFEN(resp.fen)
			end
			enterTable(resp.color)
			enterPlaying()
		end
		-- "Busy": mesa em uso; ignora.
	end)
end


-- ===== GUI binding (ResetOnSpawn re-clona a ChessSettings) =====
local function bindGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	Gui = playerGui:WaitForChild("ChessSettings")
	Frame = Gui:WaitForChild("Frame")
	PlayAgainstAI = Frame:WaitForChild("PlayAgainstAI")
	ChooseDifficultButton = Frame:WaitForChild("ChooseDifficultButton")
	BackBtn = Frame:WaitForChild("Back")
	DifficultLevel = Frame:WaitForChild("DifficultLevel")
	Surrender = Frame:WaitForChild("Surrender")
	ChooseDifficult = Frame:WaitForChild("ChooseDifficult")
	DiffBackBtn = ChooseDifficult:WaitForChild("Back")
	local list = ChooseDifficult:WaitForChild("List")
	EasyBtn = list:WaitForChild("Easy")
	MediumBtn = list:WaitForChild("Medium")
	HardBtn = list:WaitForChild("Hard")

	Gui.Enabled = false

	ChooseDifficultButton.Activated:Connect(function()
		if uiState == "Menu" then
			showChooseDifficulty()
		end
	end)

	local function chooseDifficulty(name: string)
		selectedDifficulty = name
		DifficultLevel.Text = name
		showMenu() -- volta ao menu com a dificuldade atualizada
	end
	EasyBtn.Activated:Connect(function()
		chooseDifficulty("Easy")
	end)
	MediumBtn.Activated:Connect(function()
		chooseDifficulty("Medium")
	end)
	HardBtn.Activated:Connect(function()
		chooseDifficulty("Hard")
	end)

	DiffBackBtn.Activated:Connect(function()
		if uiState == "Menu" then
			showMenu()
		end
	end)

	PlayAgainstAI.Activated:Connect(function()
		if uiState ~= "Menu" then
			return
		end
		task.spawn(function()
			StartAIRemote:InvokeServer(selectedDifficulty)
			-- A transicao para "Playing" acontece no GameStarted.
		end)
	end)

	Surrender.Activated:Connect(function()
		if uiState == "Playing" then
			leaveTable()
		end
	end)

	BackBtn.Activated:Connect(function()
		if uiState == "Menu" then
			leaveTable()
		end
	end)
end


function ChessController:Start()
	Comms = ReplicatedStorage:WaitForChild("Comms")
	local chess = Comms:WaitForChild("Chess")
	JoinRemote = chess:WaitForChild("Join")
	StartAIRemote = chess:WaitForChild("StartAI")
	RequestMoveRemote = chess:WaitForChild("RequestMove")
	SubmitAIMoveRemote = chess:WaitForChild("SubmitAIMove")
	SurrenderRemote = chess:WaitForChild("Surrender")
	LeaveRemote = chess:WaitForChild("Leave")
	GameStartedRemote = chess:WaitForChild("GameStarted")
	SyncRemote = chess:WaitForChild("Sync")
	GameEndedRemote = chess:WaitForChild("GameEnded")

	bindGui()
	-- ChessSettings tem ResetOnSpawn: re-vincula (e sai da mesa) a cada respawn.
	LocalPlayer.CharacterAdded:Connect(function()
		if atTable then
			exitTable()
		end
		bindGui()
	end)

	SyncRemote.OnClientEvent:Connect(onSync)
	GameStartedRemote.OnClientEvent:Connect(onGameStarted)
	GameEndedRemote.OnClientEvent:Connect(onGameEnded)

	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			handleBoardClick()
		end
	end)
end


return ChessController
