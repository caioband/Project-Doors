-- ChessEngine
-- Engine de xadrez em Lua puro (sem Instances), compartilhado entre server e client.
--   * Server: autoridade das regras (valida cada lance).
--   * Client: mesmo engine para destacar lances legais.
--
-- Representacao:
--   Cor:   "w" | "b"
--   Peca:  "p" (peao) "n" (cavalo) "b" (bispo) "r" (torre) "q" (dama) "k" (rei)
--   Coord: { file = 1..8 (a..h), rank = 1..8 (1..8) }
--   Estado: {
--     board = board[rank][file] = { color, type } | nil,
--     turn = "w"|"b",
--     castling = { wK, wQ, bK, bQ } (direitos de roque),
--     enPassant = Coord? (casa ALVO capturavel en passant, ou nil),
--     halfmove = number (relogio de 50 lances: plies sem captura/lance de peao),
--     fullmove = number,
--   }
--   Lance: { from = Coord, to = Coord, promotion = PieceType? }
--          (roque/en passant sao inferidos do tabuleiro em ApplyMove/DescribeMove)

local ChessEngine = {}

-- ===== Helpers de baixo nivel =====

local function inBounds(f: number, r: number): boolean
	return f >= 1 and f <= 8 and r >= 1 and r <= 8
end

local function opposite(color: string): string
	return color == "w" and "b" or "w"
end
ChessEngine.Opposite = opposite

-- Deep copy do estado (board + castling + enPassant). Usado em ApplyMove (imutavel) e pela IA.
local function cloneState(s)
	local nb = {}
	for r = 1, 8 do
		local row = {}
		local sr = s.board[r]
		for f = 1, 8 do
			local p = sr[f]
			if p then
				row[f] = { color = p.color, type = p.type }
			end
		end
		nb[r] = row
	end
	return {
		board = nb,
		turn = s.turn,
		castling = { wK = s.castling.wK, wQ = s.castling.wQ, bK = s.castling.bK, bQ = s.castling.bQ },
		enPassant = s.enPassant and { file = s.enPassant.file, rank = s.enPassant.rank } or nil,
		halfmove = s.halfmove,
		fullmove = s.fullmove,
	}
end
ChessEngine.Clone = cloneState

local FILES = "abcdefgh"

-- Coord -> nome de casa ("E4") e vice-versa. Os Parts do tabuleiro usam nome MAIUSCULO.
function ChessEngine.CoordToName(f: number, r: number): string
	return FILES:sub(f, f):upper() .. tostring(r)
end
function ChessEngine.NameToCoord(name: string)
	local fc = name:sub(1, 1):lower()
	local f = FILES:find(fc, 1, true)
	local r = tonumber(name:sub(2, 2))
	if f and r and inBounds(f, r) then
		return { file = f, rank = r }
	end
	return nil
end

function ChessEngine.PieceAt(state, f: number, r: number)
	if not inBounds(f, r) then
		return nil
	end
	return state.board[r][f]
end

-- ===== Direcoes =====
local KNIGHT = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
local KING = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local BISHOP_DIR = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local ROOK_DIR = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- ===== Ataques / xeque =====

-- A casa (f,r) esta atacada por alguma peca da cor byColor?
function ChessEngine.IsSquareAttacked(state, f: number, r: number, byColor: string): boolean
	local b = state.board

	-- Peoes: um peao de byColor ataca em diagonal "para frente" (branco sobe, preto desce).
	local pawnRank = byColor == "w" and r - 1 or r + 1
	for _, df in { -1, 1 } do
		local pf = f + df
		if inBounds(pf, pawnRank) then
			local p = b[pawnRank][pf]
			if p and p.color == byColor and p.type == "p" then
				return true
			end
		end
	end

	-- Cavalos
	for _, d in KNIGHT do
		local pf, pr = f + d[1], r + d[2]
		if inBounds(pf, pr) then
			local p = b[pr][pf]
			if p and p.color == byColor and p.type == "n" then
				return true
			end
		end
	end

	-- Rei
	for _, d in KING do
		local pf, pr = f + d[1], r + d[2]
		if inBounds(pf, pr) then
			local p = b[pr][pf]
			if p and p.color == byColor and p.type == "k" then
				return true
			end
		end
	end

	-- Deslizantes diagonais (bispo/dama)
	for _, d in BISHOP_DIR do
		local pf, pr = f + d[1], r + d[2]
		while inBounds(pf, pr) do
			local p = b[pr][pf]
			if p then
				if p.color == byColor and (p.type == "b" or p.type == "q") then
					return true
				end
				break
			end
			pf, pr = pf + d[1], pr + d[2]
		end
	end

	-- Deslizantes ortogonais (torre/dama)
	for _, d in ROOK_DIR do
		local pf, pr = f + d[1], r + d[2]
		while inBounds(pf, pr) do
			local p = b[pr][pf]
			if p then
				if p.color == byColor and (p.type == "r" or p.type == "q") then
					return true
				end
				break
			end
			pf, pr = pf + d[1], pr + d[2]
		end
	end

	return false
end

local function kingPos(state, color: string)
	for r = 1, 8 do
		local row = state.board[r]
		for f = 1, 8 do
			local p = row[f]
			if p and p.color == color and p.type == "k" then
				return f, r
			end
		end
	end
	return nil
end

function ChessEngine.IsInCheck(state, color: string): boolean
	local kf, kr = kingPos(state, color)
	if not kf then
		return false
	end
	return ChessEngine.IsSquareAttacked(state, kf, kr, opposite(color))
end

-- ===== Geracao de lances pseudo-legais =====

local function addPawnMoves(state, f, r, color, moves)
	local b = state.board
	local dir = color == "w" and 1 or -1
	local startRank = color == "w" and 2 or 7
	local promoRank = color == "w" and 8 or 1

	-- Avanco de 1
	local nr = r + dir
	if inBounds(f, nr) and not b[nr][f] then
		if nr == promoRank then
			for _, pt in { "q", "r", "b", "n" } do
				table.insert(moves, { from = { file = f, rank = r }, to = { file = f, rank = nr }, promotion = pt })
			end
		else
			table.insert(moves, { from = { file = f, rank = r }, to = { file = f, rank = nr } })
			-- Avanco de 2 (so da casa inicial e com as duas casas livres)
			if r == startRank and not b[r + 2 * dir][f] then
				table.insert(moves, { from = { file = f, rank = r }, to = { file = f, rank = r + 2 * dir } })
			end
		end
	end

	-- Capturas diagonais (inclui en passant)
	for _, df in { -1, 1 } do
		local cf, cr = f + df, r + dir
		if inBounds(cf, cr) then
			local tp = b[cr][cf]
			local isEp = state.enPassant ~= nil and state.enPassant.file == cf and state.enPassant.rank == cr
			if (tp and tp.color ~= color) or isEp then
				if cr == promoRank then
					for _, pt in { "q", "r", "b", "n" } do
						table.insert(moves, { from = { file = f, rank = r }, to = { file = cf, rank = cr }, promotion = pt })
					end
				else
					table.insert(moves, { from = { file = f, rank = r }, to = { file = cf, rank = cr } })
				end
			end
		end
	end
end

local function addStepMoves(state, f, r, color, dirs, moves)
	local b = state.board
	for _, d in dirs do
		local nf, nr = f + d[1], r + d[2]
		if inBounds(nf, nr) then
			local tp = b[nr][nf]
			if not tp or tp.color ~= color then
				table.insert(moves, { from = { file = f, rank = r }, to = { file = nf, rank = nr } })
			end
		end
	end
end

local function addSlideMoves(state, f, r, color, dirs, moves)
	local b = state.board
	for _, d in dirs do
		local nf, nr = f + d[1], r + d[2]
		while inBounds(nf, nr) do
			local tp = b[nr][nf]
			if not tp then
				table.insert(moves, { from = { file = f, rank = r }, to = { file = nf, rank = nr } })
			else
				if tp.color ~= color then
					table.insert(moves, { from = { file = f, rank = r }, to = { file = nf, rank = nr } })
				end
				break
			end
			nf, nr = nf + d[1], nr + d[2]
		end
	end
end

local function addCastleMoves(state, f, r, color, moves)
	local rank = color == "w" and 1 or 8
	-- So se o rei esta na casa inicial (e5 -> file 5) e nao esta em xeque.
	if r ~= rank or f ~= 5 then
		return
	end
	if ChessEngine.IsInCheck(state, color) then
		return
	end
	local b = state.board
	local enemy = opposite(color)
	local kSide = color == "w" and state.castling.wK or state.castling.bK
	local qSide = color == "w" and state.castling.wQ or state.castling.bQ

	-- Lado do rei: files 6,7 vazios; rei passa por 6 e chega em 7; torre em 8; 6 e 7 nao atacados.
	if kSide and not b[rank][6] and not b[rank][7] then
		local rook = b[rank][8]
		if rook and rook.type == "r" and rook.color == color then
			if not ChessEngine.IsSquareAttacked(state, 6, rank, enemy) and not ChessEngine.IsSquareAttacked(state, 7, rank, enemy) then
				table.insert(moves, { from = { file = 5, rank = rank }, to = { file = 7, rank = rank } })
			end
		end
	end

	-- Lado da dama: files 2,3,4 vazios; rei passa por 4 e chega em 3; torre em 1; 4 e 3 nao atacados.
	if qSide and not b[rank][2] and not b[rank][3] and not b[rank][4] then
		local rook = b[rank][1]
		if rook and rook.type == "r" and rook.color == color then
			if not ChessEngine.IsSquareAttacked(state, 4, rank, enemy) and not ChessEngine.IsSquareAttacked(state, 3, rank, enemy) then
				table.insert(moves, { from = { file = 5, rank = rank }, to = { file = 3, rank = rank } })
			end
		end
	end
end

local function genPseudo(state)
	local moves = {}
	local color = state.turn
	local b = state.board
	for r = 1, 8 do
		local row = b[r]
		for f = 1, 8 do
			local p = row[f]
			if p and p.color == color then
				local t = p.type
				if t == "p" then
					addPawnMoves(state, f, r, color, moves)
				elseif t == "n" then
					addStepMoves(state, f, r, color, KNIGHT, moves)
				elseif t == "k" then
					addStepMoves(state, f, r, color, KING, moves)
					addCastleMoves(state, f, r, color, moves)
				elseif t == "b" then
					addSlideMoves(state, f, r, color, BISHOP_DIR, moves)
				elseif t == "r" then
					addSlideMoves(state, f, r, color, ROOK_DIR, moves)
				elseif t == "q" then
					addSlideMoves(state, f, r, color, BISHOP_DIR, moves)
					addSlideMoves(state, f, r, color, ROOK_DIR, moves)
				end
			end
		end
	end
	return moves
end

-- ===== Aplicar lance (retorna NOVO estado) =====

local function clearRookRight(s, f, r)
	if r == 1 and f == 1 then
		s.castling.wQ = false
	elseif r == 1 and f == 8 then
		s.castling.wK = false
	elseif r == 8 and f == 1 then
		s.castling.bQ = false
	elseif r == 8 and f == 8 then
		s.castling.bK = false
	end
end

-- Aplica `move` a `state` e devolve um NOVO estado. Mecanicas especiais (roque, en passant,
-- promocao) sao inferidas do tabuleiro, entao funciona tanto para lances da geracao quanto para
-- lances vindos do input do jogador ({from,to,promotion?}).
function ChessEngine.ApplyMove(state, move)
	local s = cloneState(state)
	local from, to = move.from, move.to
	local piece = s.board[from.rank][from.file]
	if not piece then
		return s
	end
	local movingColor = piece.color
	local enemy = opposite(movingColor)
	local isPawn = piece.type == "p"

	local targetPiece = s.board[to.rank][to.file]
	local isCapture = targetPiece ~= nil

	-- En passant: peao move na diagonal para a casa-alvo vazia registrada em enPassant.
	local isEnPassant = false
	if isPawn and s.enPassant and to.file == s.enPassant.file and to.rank == s.enPassant.rank and not targetPiece then
		isEnPassant = true
	end

	-- Move a peca.
	s.board[to.rank][to.file] = piece
	s.board[from.rank][from.file] = nil

	-- Remove o peao capturado en passant (fica na casa (to.file, from.rank)).
	if isEnPassant then
		s.board[from.rank][to.file] = nil
		isCapture = true
	end

	-- Roque: move a torre para o outro lado do rei.
	if piece.type == "k" and math.abs(to.file - from.file) == 2 then
		local rank = from.rank
		if to.file == 7 then
			s.board[rank][6] = s.board[rank][8]
			s.board[rank][8] = nil
		elseif to.file == 3 then
			s.board[rank][4] = s.board[rank][1]
			s.board[rank][1] = nil
		end
	end

	-- Promocao (default dama).
	if isPawn and (to.rank == 8 or to.rank == 1) then
		s.board[to.rank][to.file] = { color = movingColor, type = move.promotion or "q" }
	end

	-- Direitos de roque.
	if piece.type == "k" then
		if movingColor == "w" then
			s.castling.wK = false
			s.castling.wQ = false
		else
			s.castling.bK = false
			s.castling.bQ = false
		end
	elseif piece.type == "r" then
		clearRookRight(s, from.file, from.rank)
	end
	if isCapture and targetPiece and targetPiece.type == "r" then
		clearRookRight(s, to.file, to.rank)
	end

	-- Casa-alvo de en passant (so no avanco duplo de peao).
	if isPawn and math.abs(to.rank - from.rank) == 2 then
		s.enPassant = { file = from.file, rank = (from.rank + to.rank) // 2 }
	else
		s.enPassant = nil
	end

	-- Relogio de 50 lances e contador de lances.
	if isPawn or isCapture then
		s.halfmove = 0
	else
		s.halfmove += 1
	end
	if movingColor == "b" then
		s.fullmove += 1
	end
	s.turn = enemy
	return s
end

-- ===== Lances legais =====

-- Lances legais do lado a mover. Se `fromCoord` for passado, filtra so os que saem dessa casa
-- (usado pelo client para destacar as casas de destino da peca selecionada).
function ChessEngine.GenerateLegalMoves(state, fromCoord)
	local pseudo = genPseudo(state)
	local color = state.turn
	local legal = {}
	for _, m in pseudo do
		if not fromCoord or (m.from.file == fromCoord.file and m.from.rank == fromCoord.rank) then
			local ns = ChessEngine.ApplyMove(state, m)
			if not ChessEngine.IsInCheck(ns, color) then
				table.insert(legal, m)
			end
		end
	end
	return legal
end

-- O lance {from,to,promotion?} e legal no estado atual?
function ChessEngine.IsLegalMove(state, move): boolean
	local legal = ChessEngine.GenerateLegalMoves(state, move.from)
	for _, m in legal do
		if m.to.file == move.to.file and m.to.rank == move.to.rank then
			-- Promocao: se o lance legal exige promocao, exige que o tipo bata (default dama).
			if m.promotion then
				if (move.promotion or "q") == m.promotion then
					return true
				end
			else
				return true
			end
		end
	end
	return false
end

-- ===== Fim de jogo / status =====

function ChessEngine.IsInsufficientMaterial(state): boolean
	local minors = 0
	local bishops = {}
	for r = 1, 8 do
		for f = 1, 8 do
			local p = state.board[r][f]
			if p then
				if p.type == "q" or p.type == "r" or p.type == "p" then
					return false
				end
				if p.type ~= "k" then
					minors += 1
					if p.type == "b" then
						table.insert(bishops, { color = p.color, sq = (f + r) % 2 })
					end
				end
			end
		end
	end
	if minors <= 1 then
		-- K vs K, ou K + um cavalo/bispo vs K.
		return true
	end
	-- K+B vs K+B com bispos na mesma cor de casa.
	if minors == 2 and #bishops == 2 and bishops[1].sq == bishops[2].sq and bishops[1].color ~= bishops[2].color then
		return true
	end
	return false
end

-- Status do estado atual do lado a mover:
--   { result = "ongoing"|"checkmate"|"stalemate"|"draw", winner = "w"|"b"|nil, check = boolean, reason? }
function ChessEngine.GetStatus(state)
	local inCheck = ChessEngine.IsInCheck(state, state.turn)
	local legal = ChessEngine.GenerateLegalMoves(state)
	if #legal == 0 then
		if inCheck then
			return { result = "checkmate", winner = opposite(state.turn), check = true }
		end
		return { result = "stalemate", winner = nil, check = false }
	end
	if state.halfmove >= 100 then
		return { result = "draw", reason = "fifty-move", winner = nil, check = inCheck }
	end
	if ChessEngine.IsInsufficientMaterial(state) then
		return { result = "draw", reason = "insufficient-material", winner = nil, check = inCheck }
	end
	return { result = "ongoing", winner = nil, check = inCheck }
end

-- Chave da posicao (para deteccao de repeticao pelo consumidor). Board + turno + roque + en passant.
function ChessEngine.PositionKey(state): string
	local t = {}
	for r = 1, 8 do
		for f = 1, 8 do
			local p = state.board[r][f]
			t[#t + 1] = p and (p.color .. p.type) or "--"
		end
	end
	t[#t + 1] = state.turn
	t[#t + 1] = (state.castling.wK and "K" or "")
		.. (state.castling.wQ and "Q" or "")
		.. (state.castling.bK and "k" or "")
		.. (state.castling.bQ and "q" or "")
	t[#t + 1] = state.enPassant and (state.enPassant.file .. "," .. state.enPassant.rank) or "-"
	return table.concat(t, "/")
end

-- Descreve os EFEITOS fisicos de um lance no estado atual (para o server atualizar as Instances):
--   { from, to, piece, captureSquare?, isEnPassant?, castle = "K"|"Q"|nil, promotion = PieceType?|nil }
function ChessEngine.DescribeMove(state, move)
	local from, to = move.from, move.to
	local piece = state.board[from.rank][from.file]
	local desc = { from = from, to = to, piece = piece }
	if not piece then
		return desc
	end
	local target = state.board[to.rank][to.file]
	if target then
		desc.captureSquare = { file = to.file, rank = to.rank }
	end
	if piece.type == "p" and state.enPassant and to.file == state.enPassant.file and to.rank == state.enPassant.rank and not target then
		desc.captureSquare = { file = to.file, rank = from.rank }
		desc.isEnPassant = true
	end
	if piece.type == "k" and math.abs(to.file - from.file) == 2 then
		desc.castle = (to.file == 7) and "K" or "Q"
	end
	if piece.type == "p" and (to.rank == 8 or to.rank == 1) then
		desc.promotion = move.promotion or "q"
	end
	return desc
end

-- ===== Serializacao FEN (para replicar o estado server->client) =====

function ChessEngine.ToFEN(state): string
	local rows = {}
	for r = 8, 1, -1 do
		local row = ""
		local empty = 0
		for f = 1, 8 do
			local p = state.board[r][f]
			if p then
				if empty > 0 then
					row = row .. empty
					empty = 0
				end
				local ch = p.type
				if p.color == "w" then
					ch = ch:upper()
				end
				row = row .. ch
			else
				empty += 1
			end
		end
		if empty > 0 then
			row = row .. empty
		end
		rows[#rows + 1] = row
	end
	local castle = (state.castling.wK and "K" or "")
		.. (state.castling.wQ and "Q" or "")
		.. (state.castling.bK and "k" or "")
		.. (state.castling.bQ and "q" or "")
	if castle == "" then
		castle = "-"
	end
	local ep = state.enPassant and ChessEngine.CoordToName(state.enPassant.file, state.enPassant.rank):lower() or "-"
	return string.format("%s %s %s %s %d %d", table.concat(rows, "/"), state.turn, castle, ep, state.halfmove, state.fullmove)
end

function ChessEngine.FromFEN(fen: string)
	local board = {}
	for r = 1, 8 do
		board[r] = {}
	end
	local parts = string.split(fen, " ")
	local rows = string.split(parts[1], "/")
	for i, rowStr in rows do
		local r = 9 - i -- rows[1] = rank 8
		local f = 1
		for ch in rowStr:gmatch(".") do
			local n = tonumber(ch)
			if n then
				f += n
			else
				local color = ch:match("%u") and "w" or "b"
				board[r][f] = { color = color, type = ch:lower() }
				f += 1
			end
		end
	end
	local castleStr = parts[3] or "-"
	return {
		board = board,
		turn = parts[2] or "w",
		castling = {
			wK = castleStr:find("K") ~= nil,
			wQ = castleStr:find("Q") ~= nil,
			bK = castleStr:find("k") ~= nil,
			bQ = castleStr:find("q") ~= nil,
		},
		enPassant = (parts[4] and parts[4] ~= "-") and ChessEngine.NameToCoord(parts[4]) or nil,
		halfmove = tonumber(parts[5]) or 0,
		fullmove = tonumber(parts[6]) or 1,
	}
end

-- ===== Posicao inicial =====

function ChessEngine.NewGame()
	local board = {}
	for r = 1, 8 do
		board[r] = {}
	end
	local back = { "r", "n", "b", "q", "k", "b", "n", "r" }
	for f = 1, 8 do
		board[1][f] = { color = "w", type = back[f] }
		board[2][f] = { color = "w", type = "p" }
		board[7][f] = { color = "b", type = "p" }
		board[8][f] = { color = "b", type = back[f] }
	end
	return {
		board = board,
		turn = "w",
		castling = { wK = true, wQ = true, bK = true, bQ = true },
		enPassant = nil,
		halfmove = 0,
		fullmove = 1,
	}
end

return ChessEngine
