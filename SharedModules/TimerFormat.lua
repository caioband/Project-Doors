--!strict
-- TimerFormat
-- Converte um numero de segundos em uma string formatada de cronometro:
--   * < 1h  -> "MM:SS"   (ex.: 65   -> "01:05")
--   * >= 1h -> "H:MM:SS" (ex.: 3725 -> "1:02:05")
-- Valores nil/negativos viram 0. Segundos fracionarios sao arredondados para cima
-- (ex.: 19.4 -> "00:20") para o cronometro nao "pular" o ultimo segundo.

local TimerFormat = {}

function TimerFormat.Format(seconds: number?): string
    local total = math.max(0, math.ceil(tonumber(seconds) or 0))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local secs = total % 60

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%02d:%02d", minutes, secs)
end

return TimerFormat
