-- ChessAI
-- IA de xadrez: MiniMax (negamax) com poda Alpha-Beta, sobre o ChessEngine.
--   * Avaliacao = material + piece-square tables (+ preferencia por mates rapidos).
--   * Ordenacao de lances (capturas/promocoes primeiro) para a poda cortar mais.
--   * Dificuldade -> profundidade + "ruido" (Easy erra mais; Hard joga o melhor).
--   * ChooseMove YIELDA (task.wait periodico) para nao congelar o frame; chame de uma thread
--     separada (task.spawn) no client sentado.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChessEngine = require(ReplicatedStorage.Shared.SharedModules.ChessEngine)

local ChessAI = {}

-- Valores de material (centipawns).
local PIECE_VALUE = { p = 100, n = 320, b = 330, r = 500, q = 900, k = 20000 }

-- Piece-square tables (Michniewski, "Simplified Evaluation"), do ponto de vista das BRANCAS.
-- Cada tabela e um array de 64: indice 1 = a8, indice 64 = h1 (linha de cima primeiro).
local PST = {
	p = {
		0, 0, 0, 0, 0, 0, 0, 0,
		50, 50, 50, 50, 50, 50, 50, 50,
		10, 10, 20, 30, 30, 20, 10, 10,
		5, 5, 10, 25, 25, 10, 5, 5,
		0, 0, 0, 20, 20, 0, 0, 0,
		5, -5, -10, 0, 0, -10, -5, 5,
		5, 10, 10, -20, -20, 10, 10, 5,
		0, 0, 0, 0, 0, 0, 0, 0,
	},
	n = {
		-50, -40, -30, -30, -30, -30, -40, -50,
		-40, -20, 0, 0, 0, 0, -20, -40,
		-30, 0, 10, 15, 15, 10, 0, -30,
		-30, 5, 15, 20, 20, 15, 5, -30,
		-30, 0, 15, 20, 20, 15, 0, -30,
		-30, 5, 10, 15, 15, 10, 5, -30,
		-40, -20, 0, 5, 5, 0, -20, -40,
		-50, -40, -30, -30, -30, -30, -40, -50,
	},
	b = {
		-20, -10, -10, -10, -10, -10, -10, -20,
		-10, 0, 0, 0, 0, 0, 0, -10,
		-10, 0, 5, 10, 10, 5, 0, -10,
		-10, 5, 5, 10, 10, 5, 5, -10,
		-10, 0, 10, 10, 10, 10, 0, -10,
		-10, 10, 10, 10, 10, 10, 10, -10,
		-10, 5, 0, 0, 0, 0, 5, -10,
		-20, -10, -10, -10, -10, -10, -10, -20,
	},
	r = {
		0, 0, 0, 0, 0, 0, 0, 0,
		5, 10, 10, 10, 10, 10, 10, 5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		0, 0, 0, 5, 5, 0, 0, 0,
	},
	q = {
		-20, -10, -10, -5, -5, -10, -10, -20,
		-10, 0, 0, 0, 0, 0, 0, -10,
		-10, 0, 5, 5, 5, 5, 0, -10,
		-5, 0, 5, 5, 5, 5, 0, -5,
		0, 0, 5, 5, 5, 5, 0, -5,
		-10, 5, 5, 5, 5, 5, 0, -10,
		-10, 0, 5, 0, 0, 0, 0, -10,
		-20, -10, -10, -5, -5, -10, -10, -20,
	},
	k = {
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-20, -30, -30, -40, -40, -30, -30, -20,
		-10, -20, -20, -20, -20, -20, -20, -10,
		20, 20, 0, 0, 0, 0, 20, 20,
		20, 30, 10, 0, 0, 10, 30, 20,
	},
}

-- Valor posicional de uma peca. Para brancas o indice conta de a8 (topo); para pretas espelhamos
-- verticalmente (rank direto), pois as tabelas sao do ponto de vista das brancas.
local function pstValue(piece, f: number, r: number): number
	local tbl = PST[piece.type]
	local idx
	if piece.color == "w" then
		idx = (8 - r) * 8 + f
	else
		idx = (r - 1) * 8 + f
	end
	return tbl[idx]
end

-- Avaliacao estatica do ponto de vista das BRANCAS (centipawns).
local function evaluate(state): number
	local score = 0
	local b = state.board
	for r = 1, 8 do
		local row = b[r]
		for f = 1, 8 do
			local p = row[f]
			if p then
				local v = PIECE_VALUE[p.type] + pstValue(p, f, r)
				if p.color == "w" then
					score += v
				else
					score -= v
				end
			end
		end
	end
	return score
end
ChessAI.Evaluate = evaluate

-- Pontuacao de ordenacao de um lance: MVV-LVA para capturas + bonus de promocao.
local function moveOrderScore(state, m): number
	local s = 0
	local target = state.board[m.to.rank][m.to.file]
	if target then
		local mover = state.board[m.from.rank][m.from.file]
		s += 10 * PIECE_VALUE[target.type] - (mover and PIECE_VALUE[mover.type] or 0)
	end
	if m.promotion then
		s += PIECE_VALUE[m.promotion]
	end
	return s
end

local function orderMoves(state, moves)
	local scored = {}
	for i, m in moves do
		scored[i] = { m = m, s = moveOrderScore(state, m) }
	end
	table.sort(scored, function(a, b)
		return a.s > b.s
	end)
	local out = {}
	for i, e in scored do
		out[i] = e.m
	end
	return out
end

local MATE = 1000000
-- A cada quantos nos damos um task.wait() para diluir a busca entre frames (nao travar).
local YIELD_EVERY = 1500

-- Negamax com poda alpha-beta. Retorna o score do ponto de vista do LADO A MOVER em `state`.
-- `ply` = profundidade a partir da raiz (para preferir mates mais rapidos).
local function search(state, depth: number, alpha: number, beta: number, ply: number, ctx): number
	ctx.nodes += 1
	if ctx.nodes % YIELD_EVERY == 0 then
		task.wait()
	end

	local moves = ChessEngine.GenerateLegalMoves(state)

	if #moves == 0 then
		-- Sem lances: mate (perde) ou afogamento (empate).
		if ChessEngine.IsInCheck(state, state.turn) then
			return -(MATE - ply)
		end
		return 0
	end

	if depth <= 0 then
		local e = evaluate(state)
		return state.turn == "w" and e or -e
	end

	moves = orderMoves(state, moves)

	local best = -math.huge
	for _, m in moves do
		local ns = ChessEngine.ApplyMove(state, m)
		local score = -search(ns, depth - 1, -beta, -alpha, ply + 1, ctx)
		if score > best then
			best = score
		end
		if best > alpha then
			alpha = best
		end
		if alpha >= beta then
			break
		end
	end
	return best
end

-- Dificuldade -> { depth, noise (centipawns de "erro" aleatorio na raiz) }.
local DIFFICULTY = {
	Easy = { depth = 2, noise = 75 },
	Medium = { depth = 3, noise = 20 },
	Hard = { depth = 4, noise = 0 },
}
ChessAI.DIFFICULTY = DIFFICULTY

function ChessAI.ConfigFor(difficulty)
	return DIFFICULTY[difficulty] or DIFFICULTY.Easy
end

-- Escolhe o melhor lance para o lado a mover. YIELDA (chame de uma thread). Retorna
-- (move, score, nodes). `difficulty` = "Easy"|"Medium"|"Hard" (ou passe um {depth,noise}).
function ChessAI.ChooseMove(state, difficulty)
	local cfg = typeof(difficulty) == "table" and difficulty or ChessAI.ConfigFor(difficulty)
	local depth = cfg.depth or 2
	local noise = cfg.noise or 0

	local moves = ChessEngine.GenerateLegalMoves(state)
	if #moves == 0 then
		return nil
	end
	moves = orderMoves(state, moves)

	local ctx = { nodes = 0 }
	local best, bestScore = nil, -math.huge

	if noise <= 0 then
		-- Melhor lance estrito com poda alpha-beta compartilhada na raiz (rapido; usado no Hard).
		local alpha = -math.huge
		for _, m in moves do
			local ns = ChessEngine.ApplyMove(state, m)
			local score = -search(ns, depth - 1, -math.huge, -alpha, 1, ctx)
			if score > bestScore then
				bestScore = score
				best = m
			end
			if score > alpha then
				alpha = score
			end
		end
	else
		-- Easy/Medium: busca com janela cheia por lance da raiz (profundidade rasa, barato) para os
		-- scores serem reais e o "ruido" as vezes escolher um lance um pouco pior (mais humano/variado).
		for _, m in moves do
			local ns = ChessEngine.ApplyMove(state, m)
			local score = -search(ns, depth - 1, -math.huge, math.huge, 1, ctx)
			local effective = score + math.random() * noise
			if effective > bestScore then
				bestScore = effective
				best = m
			end
		end
	end

	return best, bestScore, ctx.nodes
end

return ChessAI
