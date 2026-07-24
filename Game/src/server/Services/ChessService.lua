-- ChessService
-- Autoridade do minigame de xadrez da VotingRoom (Workspace.MapInUse.VotingRoom.Chess).
--   * Dono do estado logico (ChessEngine) e das PECAS fisicas (Instances ancoradas) -> o movimento
--     replica sozinho para jogadores e espectadores.
--   * Ciclo da mesa (instancia unica): Empty -> Seated(A) -> AIGame(A, diff) | PvPGame(A, B).
--   * PvP: se o jogador sentado (A) NAO inicia jogo vs IA, um 2o jogador que aciona o prompt entra
--     e a partida entre A (brancas) e B (pretas) comeca automaticamente.
--   * Modo IA: a IA (MiniMax) roda no CLIENT sentado, que envia o lance via SubmitAIMove; o server
--     valida a legalidade e aplica (mantendo 1 autoridade de regras).
--
-- Remotes em ReplicatedStorage.Comms.Chess:
--   Join (RF)         -> acionado pelo prompt; retorna { mode, color?, fen? }.
--   StartAI (RF)      -> o sentado pede jogo vs IA; args (difficulty); retorna { ok }.
--   RequestMove (RF)  -> lance do proprio jogador; args (from, to, promo?); retorna { ok, reason? }.
--   SubmitAIMove (RF) -> lance calculado da IA (so o humano do AIGame); retorna { ok }.
--   Surrender (RE)    -> desiste.
--   Leave (RE)        -> larga a mesa (a partir do menu).
--   GameStarted (RE)  -> server->participante: { color, mode, difficulty?, fen }.
--   Sync (RE)         -> server->todos: { fen, turn, status, check, mode } a cada mudanca.
--   GameEnded (RE)    -> server->todos: { result, winner, reason }.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ChessEngine = require(ReplicatedStorage.Shared.SharedModules.ChessEngine)

local ChessService = {}

-- Letra do tipo -> nome do template de peca; cor -> pasta.
local TYPE_TO_TEMPLATE = { p = "Pawn", n = "Knight", b = "Bishop", r = "Rook", q = "Queen", k = "King" }
local COLOR_TO_FOLDER = { w = "White", b = "Black" }
local VALID_DIFFICULTY = { Easy = true, Medium = true, Hard = true }

-- Deslize da peca ao mover: tween fluido (ease-in-out) mais longo para um movimento suave.
local MOVE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

-- ===== Estado da mesa =====
local tableState = "Empty" -- "Empty" | "Seated" | "AIGame" | "PvPGame"
local seatedPlayer: Player? = nil
local whitePlayer: Player? = nil
local blackPlayer: Player? = nil -- nil no AIGame (a IA joga de pretas)
local aiDifficulty: string? = nil
local gameState = nil -- estado do ChessEngine (nil quando nao ha partida montada)
local positionHistory: { [string]: number } = {} -- para repeticao tripla

-- ===== Referencias de cena (resolvidas no Start) =====
local chessModel: Instance? = nil
local activePieces: Folder? = nil
local squares: { [string]: BasePart } = {} -- "A1" -> Part
local templates: { [string]: { [string]: BasePart } } = { w = {}, b = {} }
local origTransparency: { [Instance]: number } = {}
-- pieceInstances[rank][file] = Instance? (espelho fisico do tabuleiro logico)
local pieceInstances: { { BasePart? } } = {}

-- ===== Remotes =====
local JoinRemote: RemoteFunction
local StartAIRemote: RemoteFunction
local RequestMoveRemote: RemoteFunction
local SubmitAIMoveRemote: RemoteFunction
local SurrenderRemote: RemoteEvent
local LeaveRemote: RemoteEvent
local GameStartedRemote: RemoteEvent
local SyncRemote: RemoteEvent
local GameEndedRemote: RemoteEvent


-- Garante a hierarquia ReplicatedStorage.Comms.Chess e cria os remotes (idempotente).
local function ensureRemotes()
	local comms = ReplicatedStorage:FindFirstChild("Comms")
	if not comms then
		comms = Instance.new("Folder")
		comms.Name = "Comms"
		comms.Parent = ReplicatedStorage
	end
	local folder = comms:FindFirstChild("Chess")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Chess"
		folder.Parent = comms
	end

	local function ensure(name: string, className: string)
		local r = folder:FindFirstChild(name)
		if not r then
			r = Instance.new(className)
			r.Name = name
			r.Parent = folder
		end
		return r
	end

	JoinRemote = ensure("Join", "RemoteFunction")
	StartAIRemote = ensure("StartAI", "RemoteFunction")
	RequestMoveRemote = ensure("RequestMove", "RemoteFunction")
	SubmitAIMoveRemote = ensure("SubmitAIMove", "RemoteFunction")
	SurrenderRemote = ensure("Surrender", "RemoteEvent")
	LeaveRemote = ensure("Leave", "RemoteEvent")
	GameStartedRemote = ensure("GameStarted", "RemoteEvent")
	SyncRemote = ensure("Sync", "RemoteEvent")
	GameEndedRemote = ensure("GameEnded", "RemoteEvent")
end


-- Resolve o modelo Chess persistente e monta as referencias de cena (casas, templates, folder de
-- pecas). Esconde os templates (Transparency 1 + ancorados), guardando a transparencia original para
-- os clones. Retorna false se algo essencial faltar.
local function resolveScene(): boolean
	local mapInUse = Workspace:WaitForChild("MapInUse", 30)
	local votingRoom = mapInUse and mapInUse:WaitForChild("VotingRoom", 30)
	chessModel = votingRoom and votingRoom:WaitForChild("Chess", 30)
	if not chessModel then
		warn("[ChessService] Chess model nao encontrado em Workspace.MapInUse.VotingRoom.")
		return false
	end

	local gameBoard = chessModel:FindFirstChild("GameBoard")
	if not gameBoard then
		warn("[ChessService] GameBoard nao encontrado.")
		return false
	end
	for _, part in gameBoard:GetChildren() do
		if part:IsA("BasePart") and #part.Name == 2 then
			squares[part.Name:upper()] = part
		end
	end

	local piecesModel = chessModel:FindFirstChild("Pieces")
	if not piecesModel then
		warn("[ChessService] Pieces nao encontrado.")
		return false
	end
	for color, folderName in COLOR_TO_FOLDER do
		local folder = piecesModel:FindFirstChild(folderName)
		for letter, templateName in TYPE_TO_TEMPLATE do
			local inst = folder and folder:FindFirstChild(templateName)
			if inst and inst:IsA("BasePart") then
				templates[color][letter] = inst
				origTransparency[inst] = inst.Transparency
				inst.Anchored = true
				inst.CanCollide = false
				inst.CanQuery = false
				inst.Transparency = 1
			end
		end
	end

	activePieces = chessModel:FindFirstChild("ActivePieces")
	if not activePieces then
		activePieces = Instance.new("Folder")
		activePieces.Name = "ActivePieces"
		activePieces.Parent = chessModel
	end

	return true
end


-- Pequeno recuo (studs) no eixo Y do assentamento, para a peca ficar levemente mais baixa na casa.
local PIECE_Y_OFFSET = 0.04

-- CFrame de assentamento de uma peca numa casa: sobe pela normal da casa metade da casa + metade da
-- peca, mantendo a rotacao atual da peca (alinhada ao tabuleiro, herdada do template).
local function placeCFrame(inst: BasePart, squareName: string): CFrame
	local sq = squares[squareName]
	local up = sq.CFrame.UpVector
	local pos = sq.Position + up * (sq.Size.Y / 2 + inst.Size.Y / 2 - PIECE_Y_OFFSET)
	return CFrame.new(pos) * inst.CFrame.Rotation
end

local function clonePiece(color: string, ptype: string): BasePart
	local template = templates[color][ptype]
	local inst = template:Clone()
	inst.Transparency = origTransparency[template] or 0
	inst.Anchored = true
	inst.CanCollide = false
	inst.CanQuery = true
	inst.Parent = activePieces
	return inst
end

-- Move (com tween) ou assenta (snap) uma peca numa casa, atualizando o atributo Square.
local function positionPiece(inst: BasePart, squareName: string, doTween: boolean)
	local target = placeCFrame(inst, squareName)
	if doTween then
		TweenService:Create(inst, MOVE_TWEEN, { CFrame = target }):Play()
	else
		inst.CFrame = target
	end
	inst:SetAttribute("Square", squareName)
end


-- Monta (ou remonta) o tabuleiro na posicao inicial: limpa as pecas ativas, cria gameState novo e
-- clona as 32 pecas nas casas. Reseta o historico de posicoes.
local function setupNewGame()
	for _, child in activePieces:GetChildren() do
		child:Destroy()
	end
	gameState = ChessEngine.NewGame()
	pieceInstances = {}
	for r = 1, 8 do
		pieceInstances[r] = {}
	end
	for r = 1, 8 do
		for f = 1, 8 do
			local p = gameState.board[r][f]
			if p then
				local inst = clonePiece(p.color, p.type)
				positionPiece(inst, ChessEngine.CoordToName(f, r), false)
				pieceInstances[r][f] = inst
			end
		end
	end
	positionHistory = { [ChessEngine.PositionKey(gameState)] = 1 }
end


-- Texto de status curto (para o atributo replicado e a UI).
local function statusText(status): string
	if status.result == "checkmate" then
		return (status.winner == "w" and "White" or "Black") .. " wins by checkmate"
	elseif status.result == "stalemate" then
		return "Draw — stalemate"
	elseif status.result == "draw" then
		return "Draw — " .. tostring(status.reason)
	else
		local turnName = gameState.turn == "w" and "White" or "Black"
		return status.check and (turnName .. " to move — Check!") or (turnName .. " to move")
	end
end

local function updateAttributes(status)
	if not chessModel then
		return
	end
	chessModel:SetAttribute("Turn", gameState.turn == "w" and "White" or "Black")
	chessModel:SetAttribute("Status", statusText(status))
end

local function broadcastSync(status)
	SyncRemote:FireAllClients({
		fen = ChessEngine.ToFEN(gameState),
		turn = gameState.turn,
		status = statusText(status),
		check = status.check,
		mode = tableState,
	})
end


-- Aplica um lance JA validado: atualiza as Instances (captura/roque/en passant/promocao) e o estado.
local function applyMove(move)
	local desc = ChessEngine.DescribeMove(gameState, move)

	-- Captura (inclui en passant, cuja captureSquare fica atras do peao).
	if desc.captureSquare then
		local cs = desc.captureSquare
		local inst = pieceInstances[cs.rank][cs.file]
		if inst then
			inst:Destroy()
		end
		pieceInstances[cs.rank][cs.file] = nil
	end

	local fromInst = pieceInstances[move.from.rank][move.from.file]
	pieceInstances[move.from.rank][move.from.file] = nil

	-- Promocao: troca a peca (peao -> tipo promovido).
	if desc.promotion then
		if fromInst then
			fromInst:Destroy()
		end
		fromInst = clonePiece(desc.piece.color, desc.promotion)
	end

	if fromInst then
		positionPiece(fromInst, ChessEngine.CoordToName(move.to.file, move.to.rank), true)
	end
	pieceInstances[move.to.rank][move.to.file] = fromInst

	-- Roque: move tambem a torre.
	if desc.castle then
		local rank = move.from.rank
		local rookFromFile = desc.castle == "K" and 8 or 1
		local rookToFile = desc.castle == "K" and 6 or 4
		local rookInst = pieceInstances[rank][rookFromFile]
		pieceInstances[rank][rookFromFile] = nil
		if rookInst then
			positionPiece(rookInst, ChessEngine.CoordToName(rookToFile, rank), true)
		end
		pieceInstances[rank][rookToFile] = rookInst
	end

	gameState = ChessEngine.ApplyMove(gameState, move)
end


local function endGame(result: string, winner: string?, reason: string?)
	if chessModel then
		local text
		if result == "checkmate" then
			text = (winner == "w" and "White" or "Black") .. " wins by checkmate"
		elseif result == "resign" then
			text = (winner == "w" and "White" or "Black") .. " wins (resignation)"
		elseif result == "abandoned" then
			text = "Game abandoned"
		elseif result == "draw" or result == "stalemate" then
			text = "Draw"
		else
			text = "Game over"
		end
		chessModel:SetAttribute("Status", text)
		chessModel:SetAttribute("Turn", "")
	end

	GameEndedRemote:FireAllClients({ result = result, winner = winner, reason = reason })

	-- Libera a mesa (o tabuleiro final fica visivel ate a proxima partida remontar).
	tableState = "Empty"
	seatedPlayer = nil
	whitePlayer = nil
	blackPlayer = nil
	aiDifficulty = nil
end


-- Pos-lance: atualiza atributos, historico, detecta fim de jogo e sincroniza os clients.
local function postMove()
	local status = ChessEngine.GetStatus(gameState)
	updateAttributes(status)

	local key = ChessEngine.PositionKey(gameState)
	positionHistory[key] = (positionHistory[key] or 0) + 1

	local ended, result, winner, reason = false, nil, nil, nil
	if status.result ~= "ongoing" then
		ended, result, winner, reason = true, status.result, status.winner, status.reason
	elseif positionHistory[key] >= 3 then
		ended, result, winner, reason = true, "draw", nil, "repetition"
	end

	broadcastSync(status)
	if ended then
		endGame(result, winner, reason)
	end
end


local function colorOf(player: Player?): string?
	if player and player == whitePlayer then
		return "w"
	elseif player and player == blackPlayer then
		return "b"
	end
	return nil
end

local function buildMove(fromName, toName, promo)
	if typeof(fromName) ~= "string" or typeof(toName) ~= "string" then
		return nil
	end
	local from = ChessEngine.NameToCoord(fromName)
	local to = ChessEngine.NameToCoord(toName)
	if not from or not to then
		return nil
	end
	local promotion = nil
	if typeof(promo) == "string" and (promo == "q" or promo == "r" or promo == "b" or promo == "n") then
		promotion = promo
	end
	return { from = from, to = to, promotion = promotion }
end


-- ===== Handlers dos remotes =====

local function onJoin(player: Player)
	if tableState == "Empty" then
		tableState = "Seated"
		seatedPlayer = player
		return { mode = "Seated", color = "w" }
	elseif tableState == "Seated" then
		if player == seatedPlayer then
			return { mode = "AlreadySeated", color = "w" }
		end
		-- 2o jogador entra: comeca PvP (sentado = brancas, novo = pretas).
		whitePlayer = seatedPlayer
		blackPlayer = player
		seatedPlayer = nil
		tableState = "PvPGame"
		setupNewGame()
		local status = ChessEngine.GetStatus(gameState)
		updateAttributes(status)
		broadcastSync(status)
		local fen = ChessEngine.ToFEN(gameState)
		-- O jogador branco ja estava na mesa (no menu): avisa que a partida comecou.
		GameStartedRemote:FireClient(whitePlayer, { color = "w", mode = "PvP", fen = fen })
		return { mode = "Joining", color = "b", fen = fen }
	end
	return { mode = "Busy" }
end

local function onStartAI(player: Player, difficulty)
	if tableState ~= "Seated" or player ~= seatedPlayer then
		return { ok = false, reason = "not-seated" }
	end
	local diff = tostring(difficulty)
	if not VALID_DIFFICULTY[diff] then
		diff = "Easy"
	end
	whitePlayer = player
	blackPlayer = nil
	seatedPlayer = nil
	aiDifficulty = diff
	tableState = "AIGame"
	setupNewGame()
	local status = ChessEngine.GetStatus(gameState)
	updateAttributes(status)
	broadcastSync(status)
	GameStartedRemote:FireClient(whitePlayer, {
		color = "w",
		mode = "AI",
		difficulty = diff,
		fen = ChessEngine.ToFEN(gameState),
	})
	return { ok = true }
end

local function onRequestMove(player: Player, fromName, toName, promo)
	if tableState ~= "AIGame" and tableState ~= "PvPGame" then
		return { ok = false, reason = "no-game" }
	end
	local color = colorOf(player)
	if not color then
		return { ok = false, reason = "not-a-player" }
	end
	if color ~= gameState.turn then
		return { ok = false, reason = "not-your-turn" }
	end
	local move = buildMove(fromName, toName, promo)
	if not move then
		return { ok = false, reason = "bad-coord" }
	end
	if not ChessEngine.IsLegalMove(gameState, move) then
		return { ok = false, reason = "illegal" }
	end
	applyMove(move)
	postMove()
	return { ok = true }
end

local function onSubmitAIMove(player: Player, fromName, toName, promo)
	-- So o humano do AIGame envia lances DA IA, e so na vez da IA (pretas).
	if tableState ~= "AIGame" or player ~= whitePlayer then
		return { ok = false, reason = "not-ai-game" }
	end
	if not gameState or gameState.turn ~= "b" then
		return { ok = false, reason = "not-ai-turn" }
	end
	local move = buildMove(fromName, toName, promo)
	if not move or not ChessEngine.IsLegalMove(gameState, move) then
		return { ok = false, reason = "illegal" }
	end
	applyMove(move)
	postMove()
	return { ok = true }
end

local function onSurrender(player: Player)
	if tableState ~= "AIGame" and tableState ~= "PvPGame" then
		return
	end
	local color = colorOf(player)
	if not color then
		return
	end
	endGame("resign", ChessEngine.Opposite(color), "surrender")
end

local function onLeave(player: Player)
	if tableState == "Seated" and player == seatedPlayer then
		tableState = "Empty"
		seatedPlayer = nil
	end
end

local function onPlayerRemoving(player: Player)
	if tableState == "Seated" and player == seatedPlayer then
		tableState = "Empty"
		seatedPlayer = nil
	elseif (tableState == "AIGame" or tableState == "PvPGame") and colorOf(player) then
		local color = colorOf(player)
		local winner = tableState == "PvPGame" and ChessEngine.Opposite(color) or nil
		endGame("abandoned", winner, "left")
	end
end


-- Reseta a mesa a forca (ex.: inicio de round). Publico para o RoundService, se quiser hookar.
function ChessService:ResetTable()
	tableState = "Empty"
	seatedPlayer = nil
	whitePlayer = nil
	blackPlayer = nil
	aiDifficulty = nil
end


function ChessService:Init()
	ensureRemotes()
end


function ChessService:Start()
	-- resolveScene usa WaitForChild (yield); roda em thread propria para nao segurar o boot loop dos
	-- Services caso o MapInUse/VotingRoom ainda esteja sendo montado.
	task.spawn(function()
		if not resolveScene() then
			return
		end

		JoinRemote.OnServerInvoke = onJoin
		StartAIRemote.OnServerInvoke = onStartAI
		RequestMoveRemote.OnServerInvoke = onRequestMove
		SubmitAIMoveRemote.OnServerInvoke = onSubmitAIMove
		SurrenderRemote.OnServerEvent:Connect(onSurrender)
		LeaveRemote.OnServerEvent:Connect(onLeave)
		Players.PlayerRemoving:Connect(onPlayerRemoving)

		-- Estado inicial da mesa (sem partida).
		if chessModel then
			chessModel:SetAttribute("Turn", "")
			chessModel:SetAttribute("Status", "Idle")
		end
	end)
end


return ChessService
